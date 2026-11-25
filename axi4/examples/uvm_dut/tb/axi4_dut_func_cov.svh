typedef axi4_item#(32,64,4,1) ram_fc_item_t;
typedef enum int {FC_TX, FC_W, FC_R, FC_STALL} ram_fc_kind_e;
typedef enum int {FC_AW, FC_W_CH, FC_B, FC_AR, FC_R_CH} ram_fc_channel_e;
typedef enum int {FC_SINGLE, FC_FIRST, FC_MIDDLE, FC_LAST} ram_fc_position_e;
typedef enum int {FC_ZERO, FC_ONE, FC_PARTIAL, FC_ALL} ram_fc_strobe_e;
typedef enum int {FC_NONE, FC_SHORT, FC_MEDIUM, FC_LONG} ram_fc_stall_e;

typedef struct packed {
  ram_fc_kind_e kind;
  bit [1:0] burst;
  bit [7:0] len;
  bit [2:0] size;
  bit [2:0] lane;
  ram_fc_position_e position;
  ram_fc_strobe_e strobe;
  bit [1:0] resp;
  ram_fc_channel_e channel;
  ram_fc_stall_e stall;
  bit multi;
} ram_fc_sample_t;

class ram_fc_observation;
  logic [31:0] addr;
  logic [3:0] id;
  logic [1:0] burst;
  logic [2:0] size;
  logic [7:0] len;
  logic [1:0] bresp;
  int unsigned addr_wait, b_wait;
  int unsigned beat_wait[$];
  logic [63:0] data[$];
  logic [7:0] strb[$];
  logic [1:0] resp[$];
  bit well_formed = 1;

  function new(logic [31:0] addr, logic [3:0] id, logic [1:0] burst,
               logic [2:0] size, logic [7:0] len, int unsigned addr_wait);
    this.addr = addr;
    this.id = id;
    this.burst = burst;
    this.size = size;
    this.len = len;
    this.addr_wait = addr_wait;
  endfunction
endclass

class axi4_dut_func_cov extends uvm_subscriber#(ram_fc_item_t);
  virtual axi4_if#(32,64,4,1) vif;
  ram_fc_observation active[2], completed[2];
  ram_fc_item_t published[2];
  int unsigned waits[5];
  int unsigned matched_reads, matched_writes;
  bit trace_enable;

  covergroup cov_ram_enhanced with function sample(ram_fc_sample_t ev);
    option.per_instance = 1;
    cp_burst: coverpoint ev.burst iff (ev.kind == FC_TX ||
        (ev.kind == FC_STALL && (ev.channel inside {FC_B,FC_R_CH}))) {
      bins fixed_b = {0}; bins incr_b = {1}; bins wrap_b = {2};
    }
    cp_len: coverpoint ev.len iff (ev.kind == FC_TX) {
      bins beats_1 = {0}; bins beats_2 = {1}; bins beats_4 = {3};
      bins beats_8 = {7}; bins beats_16 = {15}; bins beats_256 = {255};
    }
    cp_size: coverpoint ev.size iff (ev.kind inside {FC_TX,FC_W}) {
      bins size_0 = {0}; bins size_1 = {1}; bins size_2 = {2}; bins size_3 = {3};
    }
    cp_start_lane: coverpoint ev.lane iff (ev.kind == FC_TX) { bins lane[] = {[0:7]}; }
    cp_w_pos: coverpoint ev.position iff (ev.kind == FC_W) {
      bins single_beat = {FC_SINGLE}; bins first = {FC_FIRST};
      bins middle = {FC_MIDDLE}; bins last_beat = {FC_LAST};
    }
    cp_w_class: coverpoint ev.strobe iff (ev.kind == FC_W) {
      bins zero_strobe = {FC_ZERO}; bins single_lane = {FC_ONE};
      bins partial_strobe = {FC_PARTIAL}; bins all_legal = {FC_ALL};
    }
    cp_r_pos: coverpoint ev.position iff (ev.kind == FC_R) {
      bins single_beat = {FC_SINGLE}; bins first = {FC_FIRST};
      bins middle = {FC_MIDDLE}; bins last_beat = {FC_LAST};
    }
    cp_rresp_beat: coverpoint ev.resp iff (ev.kind == FC_R) {
      bins okay = {0}; bins decerr = {3};
    }
    cp_channel: coverpoint ev.channel iff (ev.kind == FC_STALL) {
      bins aw = {FC_AW}; bins w = {FC_W_CH}; bins b = {FC_B};
      bins ar = {FC_AR}; bins r = {FC_R_CH};
    }
    cp_stall: coverpoint ev.stall iff (ev.kind == FC_STALL) {
      bins none = {FC_NONE}; bins short_wait = {FC_SHORT};
      bins medium_wait = {FC_MEDIUM}; bins long_wait = {FC_LONG};
    }
    cp_response_channel: coverpoint ev.channel iff (ev.kind == FC_STALL) {
      bins b = {FC_B}; bins r = {FC_R_CH};
    }
    cp_response_length: coverpoint ev.multi iff (ev.kind == FC_STALL &&
        (ev.channel inside {FC_B,FC_R_CH}) && ev.stall != FC_NONE) {
      bins single_beat = {0}; bins multi_beat = {1};
    }
    cx_burst_len: cross cp_burst, cp_len iff (ev.kind == FC_TX) {
      ignore_bins fixed_256 = binsof(cp_burst.fixed_b) && binsof(cp_len.beats_256);
      ignore_bins wrap_1 = binsof(cp_burst.wrap_b) && binsof(cp_len.beats_1);
      ignore_bins wrap_256 = binsof(cp_burst.wrap_b) && binsof(cp_len.beats_256);
    }
    cx_size_start_lane: cross cp_size, cp_start_lane iff (ev.kind == FC_TX);
    cx_w_pos_class: cross cp_w_pos, cp_w_class iff (ev.kind == FC_W);
    cx_size_w_class: cross cp_size, cp_w_class iff (ev.kind == FC_W) {
      ignore_bins size0_nonfull = binsof(cp_size.size_0) &&
          (binsof(cp_w_class.single_lane) || binsof(cp_w_class.partial_strobe));
      ignore_bins size1_partial = binsof(cp_size.size_1) && binsof(cp_w_class.partial_strobe);
    }
    cx_rresp_pos: cross cp_rresp_beat, cp_r_pos iff (ev.kind == FC_R);
    cx_channel_stall: cross cp_channel, cp_stall iff (ev.kind == FC_STALL) {
      ignore_bins w_long = binsof(cp_channel.w) && binsof(cp_stall.long_wait);
    }
    cx_response_stall: cross cp_response_channel, cp_burst, cp_stall
        iff (ev.kind == FC_STALL && (ev.channel inside {FC_B,FC_R_CH}));
    cx_response_stall_length: cross cp_response_channel, cp_burst, cp_response_length
        iff (ev.kind == FC_STALL && (ev.channel inside {FC_B,FC_R_CH}) && ev.stall != FC_NONE) {
      ignore_bins wrap_single = binsof(cp_burst.wrap_b) && binsof(cp_response_length.single_beat);
    }
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    cov_ram_enhanced = new;
    trace_enable = $test$plusargs("DUT_FCOV_TRACE");
  endfunction

  function void emit(ram_fc_sample_t ev);
    cov_ram_enhanced.sample(ev);
    if (trace_enable)
      `uvm_info("FCOV_SAMPLE", $sformatf("%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
          ev.kind, ev.burst, ev.len, ev.size, ev.lane, ev.position,
          ev.strobe, ev.resp, ev.channel, ev.stall, ev.multi), UVM_LOW)
  endfunction

  function void emit_stall(ram_fc_sample_t header, ram_fc_channel_e channel, int unsigned cycles);
    header.kind = FC_STALL;
    header.channel = channel;
    if (cycles == 0) header.stall = FC_NONE;
    else if (cycles <= 2) header.stall = FC_SHORT;
    else if (cycles <= 5) header.stall = FC_MEDIUM;
    else header.stall = FC_LONG;
    emit(header);
  endfunction

  function bit valid_frame(ram_fc_observation obs, ram_fc_item_t txn);
    int beats = int'(obs.len) + 1;
    if (!obs.well_formed || $isunknown({obs.addr, obs.id, obs.burst, obs.size, obs.len}) ||
        obs.addr !== txn.addr || obs.id !== txn.id || obs.burst !== txn.burst ||
        obs.size !== txn.size || obs.len !== txn.len || obs.data.size() != beats ||
        txn.data.size() != beats ||
        (txn.is_write && (obs.bresp !== txn.bresp || txn.strb.size() != beats)) ||
        (!txn.is_write && txn.rresp.size() != beats)) return 0;
    if (axi4_crosses_4kb({1'b0, obs.addr}, int'(obs.size), int'(obs.len)) &&
        obs.burst != AXI4_BURST_FIXED) return 0;
    foreach (obs.data[i]) begin
      if (obs.data[i] !== txn.data[i]) return 0;
      if (txn.is_write && (obs.strb[i] !== txn.strb[i] || obs.beat_wait[i] > 3)) return 0;
      if (!txn.is_write && (obs.resp[i] !== txn.rresp[i] ||
          !(obs.resp[i] inside {AXI4_RESP_OKAY,AXI4_RESP_DECERR}))) return 0;
    end
    return 1;
  endfunction

  function void retire(int dir);
    ram_fc_observation obs = completed[dir];
    ram_fc_item_t txn = published[dir];
    ram_fc_sample_t header, ev;
    ram_fc_sample_t beat_samples[$];
    if (obs == null || txn == null) return;
    completed[dir] = null;
    published[dir] = null;
    if (!valid_frame(obs, txn)) begin
      `uvm_error("FCOV_FRAME", $sformatf("Monitor/bus frame mismatch dir=%0d addr=%08h id=%0h",
                dir, obs.addr, obs.id))
      return;
    end

    header = '0;
    header.kind = FC_TX;
    header.burst = obs.burst;
    header.len = obs.len;
    header.size = obs.size;
    header.lane = obs.addr[2:0];
    header.multi = (obs.len != 0);
    foreach (txn.data[i]) begin
      longint unsigned addr;
      int unsigned lo, upper;
      logic [7:0] lane_mask;
      if (!tb_expected_beat_addr({32'b0,txn.addr}, int'(txn.size), int'(txn.len),
                                 txn.burst, i, 64, addr)) begin
        `uvm_error("FCOV_ADDR", "Unsupported or illegal burst")
        return;
      end
      ev = header;
      ev.position = (txn.len == 0) ? FC_SINGLE :
                    ((i == 0) ? FC_FIRST : ((i == int'(txn.len)) ? FC_LAST : FC_MIDDLE));
      if (txn.is_write) begin
        ev.kind = FC_W;
        lo = int'(addr[2:0]);
        upper = ((lo >> txn.size) + 1) << txn.size;
        lane_mask = '0;
        for (int lane = lo; lane < upper; lane++) lane_mask[lane] = 1'b1;
        if ((txn.strb[i] & ~lane_mask) !== '0) begin
          `uvm_error("FCOV_WSTRB", $sformatf("Illegal lanes on addr=%08h beat=%0d", obs.addr, i))
          return;
        end
        if (txn.strb[i] == 0) ev.strobe = FC_ZERO;
        else if (txn.strb[i] == lane_mask) ev.strobe = FC_ALL;
        else if ($countones(txn.strb[i]) == 1) ev.strobe = FC_ONE;
        else ev.strobe = FC_PARTIAL;
      end else begin
        ev.kind = FC_R;
        ev.resp = txn.rresp[i];
      end
      beat_samples.push_back(ev);
    end

    // All evidence for the completed transaction is now checked.
    emit(header);
    emit_stall(header, txn.is_write ? FC_AW : FC_AR, obs.addr_wait);
    foreach (beat_samples[i]) begin
      emit(beat_samples[i]);
      emit_stall(header, txn.is_write ? FC_W_CH : FC_R_CH, obs.beat_wait[i]);
    end
    if (txn.is_write) begin
      emit_stall(header, FC_B, obs.b_wait);
      matched_writes++;
    end else matched_reads++;
  endfunction

  virtual function void write(ram_fc_item_t txn);
    int dir;
    if (txn == null || txn.reset_aborted || txn.timeout_aborted) return;
    dir = int'(txn.is_write);
    if (published[dir] != null) `uvm_fatal("FCOV_FRAME", "Unexpected overlapping Monitor completions")
    published[dir] = txn;
    retire(dir);
  endfunction

  function void count_wait(ram_fc_channel_e channel, logic valid, logic ready);
    if (valid !== 1'b1) waits[channel] = 0;
    else if (ready === 1'b0) waits[channel]++;
  endfunction

  function void snapshot_beat(int dir, logic [63:0] data, logic [7:0] strb,
                              logic [1:0] resp, logic last_bit, ram_fc_channel_e channel);
    ram_fc_observation obs = active[dir];
    if (obs == null) `uvm_fatal("FCOV_FRAME", "Data handshake without accepted address")
    if (last_bit !== (obs.data.size() == int'(obs.len)))
      obs.well_formed = 0;
    obs.data.push_back(data);
    if (dir) obs.strb.push_back(strb);
    else obs.resp.push_back(resp);
    obs.beat_wait.push_back(waits[channel]);
    waits[channel] = 0;
  endfunction

  function void finish_frame(int dir);
    if (completed[dir] != null) `uvm_fatal("FCOV_FRAME", "Unexpected overlapping bus completions")
    completed[dir] = active[dir];
    active[dir] = null;
    retire(dir);
  endfunction

  task run_phase(uvm_phase phase);
    forever begin
      @(vif.mon_cb);
      if (vif.areset_n !== 1'b1) begin
        foreach (active[i]) begin
          active[i] = null;
          published[i] = null;
          completed[i] = null;
        end
        foreach (waits[i]) waits[i] = 0;
        continue;
      end
      count_wait(FC_AW, vif.mon_cb.awvalid, vif.mon_cb.awready);
      count_wait(FC_W_CH, vif.mon_cb.wvalid, vif.mon_cb.wready);
      count_wait(FC_B, vif.mon_cb.bvalid, vif.mon_cb.bready);
      count_wait(FC_AR, vif.mon_cb.arvalid, vif.mon_cb.arready);
      count_wait(FC_R_CH, vif.mon_cb.rvalid, vif.mon_cb.rready);
      if (vif.mon_cb.awvalid && vif.mon_cb.awready) begin
        if (active[1] != null) `uvm_fatal("FCOV_FRAME", "RAM accepted a second outstanding AW")
        active[1] = new(vif.mon_cb.awaddr, vif.mon_cb.awid, vif.mon_cb.awburst,
                        vif.mon_cb.awsize, vif.mon_cb.awlen, waits[FC_AW]);
        waits[FC_AW] = 0;
      end
      if (vif.mon_cb.arvalid && vif.mon_cb.arready) begin
        if (active[0] != null) `uvm_fatal("FCOV_FRAME", "RAM accepted a second outstanding AR")
        active[0] = new(vif.mon_cb.araddr, vif.mon_cb.arid, vif.mon_cb.arburst,
                        vif.mon_cb.arsize, vif.mon_cb.arlen, waits[FC_AR]);
        waits[FC_AR] = 0;
      end
      if (vif.mon_cb.wvalid && vif.mon_cb.wready)
        snapshot_beat(1, vif.mon_cb.wdata, vif.mon_cb.wstrb, '0, vif.mon_cb.wlast, FC_W_CH);
      if (vif.mon_cb.bvalid && vif.mon_cb.bready) begin
        if (active[1] == null) `uvm_fatal("FCOV_FRAME", "Unexpected B handshake")
        if (vif.mon_cb.bid !== active[1].id) active[1].well_formed = 0;
        active[1].bresp = vif.mon_cb.bresp;
        active[1].b_wait = waits[FC_B];
        waits[FC_B] = 0;
        finish_frame(1);
      end
      if (vif.mon_cb.rvalid && vif.mon_cb.rready) begin
        snapshot_beat(0, vif.mon_cb.rdata, '0, vif.mon_cb.rresp, vif.mon_cb.rlast, FC_R_CH);
        if (vif.mon_cb.rid !== active[0].id) active[0].well_formed = 0;
        if (vif.mon_cb.rlast) finish_frame(0);
      end
    end
  endtask

  function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    foreach (completed[i])
      if (completed[i] != null || published[i] != null)
        `uvm_error("FCOV_FRAME", "Unmatched completion in RAM end-of-test")
    `uvm_info("FCOV_SUMMARY", $sformatf("matched_writes=%0d matched_reads=%0d",
              matched_writes, matched_reads), UVM_LOW)
  endfunction
endclass
