//------------------------------------------------------------------------------
// AXI4 independent channel-order checker
//------------------------------------------------------------------------------
// This checker observes the interface directly.  It deliberately does not use
// monitor reconstruction or the scoreboard, so orphaned and mis-framed B/R
// traffic is reported even when a monitor-side association would hide it.
//------------------------------------------------------------------------------

`ifndef KVIPS_AXI4_PROTOCOL_CHECKER_SVH
`define KVIPS_AXI4_PROTOCOL_CHECKER_SVH

class axi4_protocol_checker #(
  int ADDR_W = 32,
  int DATA_W = 64,
  int ID_W   = 4,
  int USER_W = 1
) extends uvm_component;

  localparam string RID = "AXI4_CHK";

`ifdef VERILATOR
  axi4_agent_cfg#(ADDR_W, DATA_W, ID_W, USER_W) cfg;
  virtual axi4_if #(ADDR_W, DATA_W, ID_W, USER_W) vif;
`else
  typedef virtual axi4_if #(ADDR_W, DATA_W, ID_W, USER_W) axi4_vif_t;
  axi4_agent_cfg#(ADDR_W, DATA_W, ID_W, USER_W) cfg;
  axi4_vif_t vif;
`endif

  typedef struct {
    logic [ID_W-1:0]   id;
    int unsigned       beats;
    logic [ADDR_W-1:0] addr;
    logic [2:0]        size;
    logic [1:0]        burst;
  } aw_state_t;

  typedef struct {
    int unsigned beats_left;
  } rd_state_t;

  aw_state_t aw_q[$];
  int unsigned early_w_bursts[$];
  logic [DATA_W/8-1:0] w_strbs[$];
  logic [DATA_W/8-1:0] early_w_strbs[$];
  int unsigned w_beats;
  bit          w_active;
  int unsigned wr_done[logic [ID_W-1:0]][$];
  rd_state_t   rd_q[logic [ID_W-1:0]][$];

  longint unsigned aw_hs;
  longint unsigned w_hs;
  longint unsigned b_hs;
  longint unsigned ar_hs;
  longint unsigned r_hs;
  longint unsigned checker_errors;
  longint unsigned sideband_errors;

  `uvm_component_param_utils(axi4_protocol_checker#(ADDR_W, DATA_W, ID_W, USER_W))

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(axi4_agent_cfg#(ADDR_W, DATA_W, ID_W, USER_W))::get(this, "", "cfg", cfg)) begin
      `uvm_fatal(RID, "Missing cfg in config DB (key: cfg)")
    end
    vif = cfg.vif;
`ifndef VERILATOR
    if (vif == null) `uvm_fatal(RID, "cfg.vif is null")
`endif
    clear_state();
  endfunction

  function void clear_state();
    aw_q.delete();
    early_w_bursts.delete();
    w_strbs.delete();
    early_w_strbs.delete();
    w_beats = 0;
    w_active = 1'b0;
    foreach (wr_done[id]) wr_done[id].delete();
    wr_done.delete();
    foreach (rd_q[id]) rd_q[id].delete();
    rd_q.delete();
  endfunction

  function void checker_error(string msg);
    checker_errors++;
    `uvm_error(RID, msg)
  endfunction

  function void check_sidebands(bit is_write);
    logic [2:0] prot_v;
    logic [3:0] cache_v;
    logic [3:0] qos_v;
    logic [3:0] region_v;
    if (!cfg.sideband_policy_enable) return;
    prot_v   = is_write ? vif.awprot   : vif.arprot;
    cache_v  = is_write ? vif.awcache  : vif.arcache;
    qos_v    = is_write ? vif.awqos    : vif.arqos;
    region_v = is_write ? vif.awregion : vif.arregion;
    if (!cfg.sideband_prot_allow_mask[prot_v]) begin
      sideband_errors++;
      `uvm_error(RID, $sformatf("%sPROT value %0d rejected by configured policy", is_write ? "AW" : "AR", prot_v))
    end
    if (!cfg.sideband_cache_allow_mask[cache_v]) begin
      sideband_errors++;
      `uvm_error(RID, $sformatf("%sCACHE value %0d rejected by configured policy", is_write ? "AW" : "AR", cache_v))
    end
    if (!cfg.sideband_qos_allow_mask[qos_v]) begin
      sideband_errors++;
      `uvm_error(RID, $sformatf("%sQOS value %0d rejected by configured policy", is_write ? "AW" : "AR", qos_v))
    end
    if (!cfg.sideband_region_allow_mask[region_v]) begin
      sideband_errors++;
      `uvm_error(RID, $sformatf("%sREGION value %0d rejected by configured policy", is_write ? "AW" : "AR", region_v))
    end
  endfunction

  // Check legal WSTRB lanes for one AXI write beat.
  function void check_wstrb_for_beat(
    input aw_state_t aw,
    input int unsigned beat,
    input logic [DATA_W/8-1:0] strobe
  );
    longint unsigned start_addr, aligned_addr, beat_addr;
    longint unsigned bus_base, step, wrap_bytes, wrap_base;
    int unsigned lower_lane, upper_lane;
    logic [DATA_W/8-1:0] allowed_mask, illegal_mask;

    if (aw.size > $clog2(DATA_W/8)) begin
      checker_error("AWSIZE exceeds data bus width");
      return;
    end

    step = 64'd1 << aw.size;
    start_addr = aw.addr;
    aligned_addr = (start_addr / step) * step;

    case (aw.burst)
      2'b00: beat_addr = start_addr;
      2'b01: begin
        if (beat == 0)
          beat_addr = start_addr;
        else
          beat_addr = aligned_addr + beat*step;
      end
      2'b10: begin
        wrap_bytes = step * aw.beats;
        if (wrap_bytes == 0) begin
          checker_error("Invalid WRAP burst size");
          return;
        end
        wrap_base = (start_addr / wrap_bytes) * wrap_bytes;
        beat_addr = wrap_base +
          ((start_addr-wrap_base+beat*step) % wrap_bytes);
      end
      default: begin
        checker_error("Reserved AWBURST value");
        return;
      end
    endcase

    if ((beat == 0) || (aw.burst == 2'b00)) begin
      bus_base = (start_addr/(DATA_W/8))*(DATA_W/8);
      lower_lane = int'(start_addr-bus_base);
      upper_lane = int'(aligned_addr+step-1-bus_base);
    end else begin
      bus_base = (beat_addr/(DATA_W/8))*(DATA_W/8);
      lower_lane = int'(beat_addr-bus_base);
      upper_lane = lower_lane + int'(step)-1;
    end

    if ((lower_lane >= DATA_W/8) ||
        (upper_lane >= DATA_W/8) ||
        (lower_lane > upper_lane)) begin
      checker_error("Invalid calculated byte lane range");
      return;
    end

    allowed_mask = '0;
    for (int unsigned lane=lower_lane;
         lane<=upper_lane; lane++)
      allowed_mask[lane] = 1'b1;

    illegal_mask = strobe & ~allowed_mask;
    if (illegal_mask !== '0) begin
      checker_error($sformatf(
        "WSTRB out of legal lanes: AWID=%0h beat=%0d AWADDR=%0h SIZE=%0d WSTRB=%0h allowed=%0h illegal=%0h",
        aw.id, beat, aw.addr, aw.size,
        strobe, allowed_mask, illegal_mask));
    end
  endfunction

  function void complete_write_burst(int unsigned beats);
    aw_state_t aw;
    if (aw_q.size() != 0) begin
      aw = aw_q.pop_front();
      if (aw.beats != beats) begin
        checker_error($sformatf("W burst length mismatch for AWID=0x%0h expected=%0d observed=%0d",
                               aw.id, aw.beats, beats));
      end

      // Current master driver completes AW before sending W.
      if (w_strbs.size() != beats) begin
        checker_error($sformatf(
          "WSTRB capture count mismatch: beats=%0d captured=%0d",
          beats, w_strbs.size()));
      end

      for (int unsigned i=0; i<beats; i++) begin
        if ((i < aw.beats) && (i < w_strbs.size()))
          check_wstrb_for_beat(aw, i, w_strbs[i]);
      end

      wr_done[aw.id].push_back(1);
    end else begin
      early_w_bursts.push_back(beats);
      foreach (w_strbs[i])
        early_w_strbs.push_back(w_strbs[i]);
    end
  endfunction

  function void accept_aw();
    aw_state_t aw;
    int unsigned early_beats;

    aw.id = vif.awid;
    aw.beats = int'(vif.awlen) + 1;
    aw.addr = vif.awaddr;
    aw.size = vif.awsize;
    aw.burst = vif.awburst;
    aw_hs++;
    check_sidebands(1'b1);

    // Match oldest completed W burst, even if another W
    // burst is currently being received.
    if ((early_w_bursts.size() != 0) &&
        (aw_q.size() == 0)) begin

      early_beats = early_w_bursts.pop_front();

      if (early_beats != aw.beats) begin
        checker_error($sformatf(
          "Early W burst length mismatch AWID=0x%0h expected=%0d observed=%0d",
          aw.id, aw.beats, early_beats));
      end

      // Consume exactly this completed W burst. The FIFO order supplies
      // the association because AXI4 W has no transaction ID.
      for (int unsigned i = 0; i < early_beats; i++) begin
        if (early_w_strbs.size() == 0) begin
          checker_error("Early WSTRB cache underflow");
        end else begin
          logic [DATA_W/8-1:0] strobe;
          strobe = early_w_strbs.pop_front();
          if (i < aw.beats)
            check_wstrb_for_beat(aw, i, strobe);
        end
      end

      wr_done[aw.id].push_back(1);
    end else begin
      aw_q.push_back(aw);
    end
  endfunction

  function void accept_w();
    w_hs++;
    if (!w_active) begin
      w_active = 1'b1;
      w_beats = 0;
      w_strbs.delete();
    end
    w_strbs.push_back(vif.wstrb);
    w_beats++;
    if (vif.wlast) begin
      complete_write_burst(w_beats);
      w_active = 1'b0;
      w_beats = 0;
    end
  endfunction

  function void accept_b();
    b_hs++;
    if (!wr_done.exists(vif.bid) || (wr_done[vif.bid].size() == 0)) begin
      checker_error($sformatf("B handshake has no completed write for BID=0x%0h", vif.bid));
    end else begin
      void'(wr_done[vif.bid].pop_front());
    end
  endfunction

  function void accept_ar();
    rd_state_t rd;
    rd.beats_left = int'(vif.arlen) + 1;
    rd_q[vif.arid].push_back(rd);
    ar_hs++;
    check_sidebands(1'b0);
  endfunction

  function void accept_r();
    rd_state_t rd;
    r_hs++;
    if (!rd_q.exists(vif.rid) || (rd_q[vif.rid].size() == 0)) begin
      checker_error($sformatf("R handshake has no outstanding read for RID=0x%0h", vif.rid));
      return;
    end
    rd = rd_q[vif.rid][0];
    if (rd.beats_left == 0) begin
      checker_error($sformatf("R beat overflow for RID=0x%0h", vif.rid));
    end else begin
      if (vif.rlast && (rd.beats_left != 1)) begin
        checker_error($sformatf("RLAST asserted early for RID=0x%0h beats_left=%0d", vif.rid, rd.beats_left));
      end
      if (!vif.rlast && (rd.beats_left == 1)) begin
        checker_error($sformatf("RLAST missing on final beat for RID=0x%0h", vif.rid));
      end
      rd.beats_left--;
      if (rd.beats_left == 0) begin
        void'(rd_q[vif.rid].pop_front());
      end else begin
        rd_q[vif.rid][0] = rd;
      end
    end
  endfunction

  task run_phase(uvm_phase phase);
    forever begin
      @(posedge vif.aclk);
      if (vif.areset_n !== 1'b1) begin
        clear_state();
        continue;
      end
      if (vif.awvalid && vif.awready) accept_aw();
      if (vif.wvalid  && vif.wready)  accept_w();
      if (vif.bvalid  && vif.bready)  accept_b();
      if (vif.arvalid && vif.arready) accept_ar();
      if (vif.rvalid  && vif.rready)  accept_r();
    end
  endtask

  function void report_phase(uvm_phase phase);
    `uvm_info(RID, $sformatf("Channel checker summary: AW=%0d W=%0d B=%0d AR=%0d R=%0d errors=%0d sideband_errors=%0d",
                             aw_hs, w_hs, b_hs, ar_hs, r_hs, checker_errors, sideband_errors), UVM_LOW)
  endfunction

endclass

`endif // KVIPS_AXI4_PROTOCOL_CHECKER_SVH
