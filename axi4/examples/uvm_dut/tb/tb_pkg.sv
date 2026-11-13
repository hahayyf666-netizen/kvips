package tb_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  import axi4_types_pkg::*;
  import axi4_uvm_pkg::*;

  // Small, portable RAL model used by the DUT integration test.  It is kept
  // in the example package so the AXI4 VIP itself remains free of register
  // map assumptions.
  class axi4_dut_reg extends uvm_reg;
    uvm_reg_field value;
    `uvm_object_utils(axi4_dut_reg)
    function new(string name = "axi4_dut_reg"); super.new(name, 32, UVM_NO_COVERAGE); endfunction
    virtual function void build();
      value = uvm_reg_field::type_id::create("value");
      value.configure(this, 32, 0, "RW", 0, 32'h0, 1, 1, 0);
    endfunction
  endclass

  class axi4_dut_regfile extends uvm_reg_block;
    axi4_dut_reg regs[4];
    `uvm_object_utils(axi4_dut_regfile)
    function new(string name = "axi4_dut_regfile"); super.new(name, UVM_NO_COVERAGE); endfunction
    virtual function void build();
      default_map = create_map("axi4_map", 'h0, 8, UVM_LITTLE_ENDIAN, 1);
      foreach (regs[i]) begin
        regs[i] = axi4_dut_reg::type_id::create($sformatf("reg%0d", i));
        regs[i].configure(this, null, $sformatf("reg%0d", i));
        regs[i].build();
        default_map.add_reg(regs[i], i * 8, "RW");
      end
      lock_model();
    endfunction
  endclass

  class axi4_dut_reg_adapter extends uvm_reg_adapter;
    `uvm_object_utils(axi4_dut_reg_adapter)
    function new(string name = "axi4_dut_reg_adapter");
      super.new(name);
      supports_byte_enable = 1;
      provides_responses = 0;
    endfunction
    virtual function uvm_sequence_item reg2bus(const ref uvm_reg_bus_op rw);
      axi4_item#(32, 64, 4, 1) tr;
      tr = axi4_item#(32, 64, 4, 1)::type_id::create("ral_axi_item");
      tr.is_write = (rw.kind == UVM_WRITE);
      tr.addr = rw.addr;
      tr.id = '0;
      tr.len = 0;
      tr.size = 3'd2; // 32-bit register transfer on a 64-bit data bus
      tr.burst = AXI4_BURST_INCR;
      tr.allocate_payload();
      tr.data[0] = '0;
      tr.strb[0] = '0;
      if (tr.is_write) begin
        tr.data[0][31:0] = rw.data[31:0];
        tr.strb[0][3:0] = (rw.byte_en == '0) ? 4'hf : rw.byte_en[3:0];
      end
      return tr;
    endfunction
    virtual function void bus2reg(uvm_sequence_item bus_item, ref uvm_reg_bus_op rw);
      axi4_item#(32, 64, 4, 1) tr;
      if (!$cast(tr, bus_item)) begin
        rw.status = UVM_NOT_OK;
        return;
      end
      rw.kind = tr.is_write ? UVM_WRITE : UVM_READ;
      rw.data = (tr.is_write || tr.data.size() == 0) ? '0 : tr.data[0];
      if (tr.is_write) rw.status = (tr.bresp == AXI4_RESP_OKAY) ? UVM_IS_OK : UVM_NOT_OK;
      else rw.status = ((tr.rresp.size() == 0) || (tr.rresp[0] == AXI4_RESP_OKAY)) ? UVM_IS_OK : UVM_NOT_OK;
    endfunction
  endclass

  class axi4_objtn_clear_catcher extends uvm_report_catcher;
    function new(string name = "axi4_objtn_clear_catcher");
      super.new(name);
    endfunction
    virtual function action_e catch();
      if (get_id() == "OBJTN_CLEAR") return CAUGHT;
      return THROW;
    endfunction
  endclass

  class axi4_dut_base_test extends uvm_test;
    `uvm_component_utils(axi4_dut_base_test)

    localparam int ADDR_W = 32;
    localparam int DATA_W = 64;
    localparam int ID_W   = 4;
    localparam int USER_W = 1;

`ifdef VERILATOR
    virtual axi4_if #(ADDR_W, DATA_W, ID_W, USER_W) vif;
`else
    typedef virtual axi4_if #(ADDR_W, DATA_W, ID_W, USER_W) axi4_vif_t;
    axi4_vif_t vif;
`endif

    axi4_env_cfg#(ADDR_W, DATA_W, ID_W, USER_W) env_cfg;
    axi4_env#(ADDR_W, DATA_W, ID_W, USER_W)     env;
    axi4_scoreboard#(ADDR_W, DATA_W, ID_W, USER_W) sb;
    axi4_dut_regfile ral;
    axi4_dut_reg_adapter ral_adapter;
    uvm_reg_predictor#(axi4_item#(ADDR_W, DATA_W, ID_W, USER_W)) ral_predictor;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    virtual function void post_build_cfg();
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);

`ifdef VERILATOR
      uvm_root::get().set_report_severity_id_action(UVM_WARNING, "OBJTN_CLEAR", UVM_NO_ACTION);
      uvm_root::get().set_report_id_action("OBJTN_CLEAR", UVM_NO_ACTION);
      begin
        uvm_phase run_phase;
        uvm_objection run_obj;
        run_phase = uvm_run_phase::get();
        run_obj = (run_phase == null) ? null : run_phase.get_objection();
        if (run_obj != null) begin
          run_obj.set_report_severity_id_action(UVM_WARNING, "OBJTN_CLEAR", UVM_NO_ACTION);
          run_obj.set_report_id_action("OBJTN_CLEAR", UVM_NO_ACTION);
          run_obj.set_drain_time(this, 20_000ns);
        end
      end
      begin
        axi4_objtn_clear_catcher c;
        c = new();
        uvm_report_cb::add(null, c);
      end
`endif
`ifdef UVM_NO_DPI
      uvm_root::get().set_report_severity_id_action(UVM_WARNING, "UVM/COMP/NAME", UVM_NO_ACTION);
      uvm_root::get().set_report_severity_id_action(UVM_INFO, "UVM/COMP/NAMECHECK", UVM_NO_ACTION);
`endif

      if (!uvm_config_db#(virtual interface axi4_if #(ADDR_W, DATA_W, ID_W, USER_W))::get(this, "", "vif", vif)) begin
        `uvm_fatal(get_type_name(), "Missing vif in config DB (key: vif)")
      end

      env_cfg = axi4_env_cfg#(ADDR_W, DATA_W, ID_W, USER_W)::type_id::create("env_cfg");

      begin
        axi4_agent_cfg#(ADDR_W, DATA_W, ID_W, USER_W) m_cfg;
        m_cfg = axi4_agent_cfg#(ADDR_W, DATA_W, ID_W, USER_W)::type_id::create("m_cfg");
        m_cfg.set_role_master();
        m_cfg.vif = vif;
        m_cfg.monitor_enable = 1'b1;
        env_cfg.add_agent_cfg(m_cfg);
      end

      begin
        axi4_agent_cfg#(ADDR_W, DATA_W, ID_W, USER_W) s_cfg;
        s_cfg = axi4_agent_cfg#(ADDR_W, DATA_W, ID_W, USER_W)::type_id::create("s_cfg");
        s_cfg.set_role_slave();
        s_cfg.vif = vif;
        s_cfg.is_slave = 1'b0;
        s_cfg.monitor_enable = 1'b0;
        s_cfg.slave_mem_enable = 1'b0;
        env_cfg.add_agent_cfg(s_cfg);
      end

      post_build_cfg();

      uvm_config_db#(axi4_env_cfg#(ADDR_W, DATA_W, ID_W, USER_W))::set(this, "env", "cfg", env_cfg);
      env = axi4_env#(ADDR_W, DATA_W, ID_W, USER_W)::type_id::create("env", this);
      sb = axi4_scoreboard#(ADDR_W, DATA_W, ID_W, USER_W)::type_id::create("sb", this);
      ral = axi4_dut_regfile::type_id::create("ral");
      ral.build();
      ral_adapter = axi4_dut_reg_adapter::type_id::create("ral_adapter");
      ral_predictor = uvm_reg_predictor#(axi4_item#(ADDR_W, DATA_W, ID_W, USER_W))::type_id::create("ral_predictor", this);
      ral_predictor.map = ral.default_map;
      ral_predictor.adapter = ral_adapter;
    endfunction

    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      env.ap.connect(sb.analysis_export);
      env.ap.connect(ral_predictor.bus_in);
    endfunction
  endclass

  class axi4_dut_smoke_test extends axi4_dut_base_test;
    `uvm_component_utils(axi4_dut_smoke_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      axi4_sequencer#(ADDR_W, DATA_W, ID_W, USER_W) seqr;
      axi4_write_readback_seq#(ADDR_W, DATA_W, ID_W, USER_W) seq;
      phase.raise_objection(this);
      seqr = env.get_master_sequencer(0);
      if (seqr == null) `uvm_fatal(get_type_name(), "Master sequencer not found at index 0")
      seq = new("seq");
      seq.num_txns = $urandom_range(64, 32);
      seq.max_len  = 3;
      seq.enable_incr  = 1'b1;
      seq.enable_fixed = 1'b0;
      seq.enable_wrap  = 1'b0;
      seq.enable_narrow = 1'b0;
      `uvm_info("AXI4_DUT_SUMMARY", $sformatf("txns=%0d wr_txns=%0d rd_txns=%0d", seq.num_txns, seq.num_txns, seq.num_txns), UVM_NONE)
      seq.start(seqr);
      wait (vif.areset_n === 1'b1);
      repeat (128) @(posedge vif.aclk);
      phase.drop_objection(this);
    endtask
  endclass

  class axi4_dut_burst_mix_test extends axi4_dut_base_test;
    `uvm_component_utils(axi4_dut_burst_mix_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      axi4_sequencer#(ADDR_W, DATA_W, ID_W, USER_W) seqr;
      axi4_write_readback_seq#(ADDR_W, DATA_W, ID_W, USER_W) seq;
      phase.raise_objection(this);
      seqr = env.get_master_sequencer(0);
      if (seqr == null) `uvm_fatal(get_type_name(), "Master sequencer not found at index 0")
      seq = new("seq");
      seq.num_txns = $urandom_range(128, 64);
      seq.max_len  = 7;
      seq.enable_incr  = 1'b1;
      seq.enable_fixed = 1'b1;
      seq.enable_wrap  = 1'b0;
      seq.enable_narrow = 1'b0;
      `uvm_info("AXI4_DUT_SUMMARY", $sformatf("txns=%0d wr_txns=%0d rd_txns=%0d", seq.num_txns, seq.num_txns, seq.num_txns), UVM_NONE)
      seq.start(seqr);
      wait (vif.areset_n === 1'b1);
      repeat (256) @(posedge vif.aclk);
      phase.drop_objection(this);
    endtask
  endclass

  class axi4_dut_narrow_test extends axi4_dut_base_test;
    `uvm_component_utils(axi4_dut_narrow_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      axi4_sequencer#(ADDR_W, DATA_W, ID_W, USER_W) seqr;
      axi4_write_readback_seq#(ADDR_W, DATA_W, ID_W, USER_W) seq;
      phase.raise_objection(this);
      seqr = env.get_master_sequencer(0);
      if (seqr == null) `uvm_fatal(get_type_name(), "Master sequencer not found at index 0")
      seq = new("seq");
      seq.num_txns = $urandom_range(96, 48);
      seq.max_len  = 3;
      seq.enable_incr  = 1'b1;
      seq.enable_fixed = 1'b0;
      seq.enable_wrap  = 1'b0;
      seq.enable_narrow = 1'b1;
      `uvm_info("AXI4_DUT_SUMMARY", $sformatf("txns=%0d wr_txns=%0d rd_txns=%0d", seq.num_txns, seq.num_txns, seq.num_txns), UVM_NONE)
      seq.start(seqr);
      wait (vif.areset_n === 1'b1);
      repeat (192) @(posedge vif.aclk);
      phase.drop_objection(this);
    endtask
  endclass

  class axi4_dut_wrap_test extends axi4_dut_base_test;
    `uvm_component_utils(axi4_dut_wrap_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      axi4_sequencer#(ADDR_W, DATA_W, ID_W, USER_W) seqr;
      axi4_write_readback_seq#(ADDR_W, DATA_W, ID_W, USER_W) seq;
      phase.raise_objection(this);
      seqr = env.get_master_sequencer(0);
      if (seqr == null) `uvm_fatal(get_type_name(), "Master sequencer not found at index 0")
      seq = new("seq");
      seq.num_txns = 24;
      seq.max_len = 15;
      seq.enable_incr = 1'b0;
      seq.enable_fixed = 1'b0;
      seq.enable_wrap = 1'b1;
      seq.enable_narrow = 1'b0;
      seq.start(seqr);
      repeat (128) @(posedge vif.aclk);
      phase.drop_objection(this);
    endtask
  endclass

  class axi4_dut_strobe_test extends axi4_dut_base_test;
    `uvm_component_utils(axi4_dut_strobe_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      axi4_sequencer#(ADDR_W, DATA_W, ID_W, USER_W) seqr;
      axi4_strobe_patterns_seq#(ADDR_W, DATA_W, ID_W, USER_W) seq;
      phase.raise_objection(this);
      seqr = env.get_master_sequencer(0);
      if (seqr == null) `uvm_fatal(get_type_name(), "Master sequencer not found at index 0")
      seq = new("seq");
      seq.start(seqr);
      repeat (64) @(posedge vif.aclk);
      phase.drop_objection(this);
    endtask
  endclass

  class axi4_dut_unaligned_test extends axi4_dut_base_test;
    `uvm_component_utils(axi4_dut_unaligned_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      axi4_sequencer#(ADDR_W, DATA_W, ID_W, USER_W) seqr;
      axi4_unaligned_byte_seq#(ADDR_W, DATA_W, ID_W, USER_W) seq;
      phase.raise_objection(this);
      seqr = env.get_master_sequencer(0);
      if (seqr == null) `uvm_fatal(get_type_name(), "Master sequencer not found at index 0")
      seq = new("seq");
      seq.start(seqr);
      repeat (64) @(posedge vif.aclk);
      phase.drop_objection(this);
    endtask
  endclass

  class axi4_dut_boundary_test extends axi4_dut_base_test;
    `uvm_component_utils(axi4_dut_boundary_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      axi4_sequencer#(ADDR_W, DATA_W, ID_W, USER_W) seqr;
      axi4_corner_case_seq#(ADDR_W, DATA_W, ID_W, USER_W) seq;
      phase.raise_objection(this);
      seqr = env.get_master_sequencer(0);
      if (seqr == null) `uvm_fatal(get_type_name(), "Master sequencer not found at index 0")
      seq = new("seq");
      seq.base_addr = 32'h10000;
      seq.start(seqr);
      repeat (512) @(posedge vif.aclk);
      phase.drop_objection(this);
    endtask
  endclass

  class axi4_dut_pipeline_test extends axi4_dut_base_test;
    `uvm_component_utils(axi4_dut_pipeline_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    virtual function void post_build_cfg();
      env_cfg.agent_cfgs[0].master_pipelined = 1'b1;
      env_cfg.agent_cfgs[0].max_outstanding_reads = 2;
      env_cfg.agent_cfgs[0].max_outstanding_writes = 2;
      env_cfg.agent_cfgs[0].master_aw_delay_min = 1;
      env_cfg.agent_cfgs[0].master_aw_delay_max = 2;
      env_cfg.agent_cfgs[0].master_ar_delay_min = 1;
      env_cfg.agent_cfgs[0].master_ar_delay_max = 2;
      // Random R-channel backpressure from Master
      env_cfg.agent_cfgs[0].master_rready_random = 1'b1;
      env_cfg.agent_cfgs[0].master_rready_low_min = 3;
      env_cfg.agent_cfgs[0].master_rready_low_max = 5;
    endfunction
    task run_phase(uvm_phase phase);
      axi4_sequencer#(ADDR_W, DATA_W, ID_W, USER_W) seqr;
      axi4_same_id_pipeline_seq#(ADDR_W, DATA_W, ID_W, USER_W) seq;
      phase.raise_objection(this);
      seqr = env.get_master_sequencer(0);
      if (seqr == null) `uvm_fatal(get_type_name(), "Master sequencer not found at index 0")
      seq = new("seq");
      seq.num_txns = 16;
      seq.start(seqr);
      repeat (256) @(posedge vif.aclk);
      phase.drop_objection(this);
    endtask
  endclass

  class axi4_dut_error_test extends axi4_dut_base_test;
    `uvm_component_utils(axi4_dut_error_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      axi4_sequencer#(ADDR_W, DATA_W, ID_W, USER_W) seqr;
      axi4_write_expect_resp_seq#(ADDR_W, DATA_W, ID_W, USER_W) wr;
      axi4_read_expect_resp_seq#(ADDR_W, DATA_W, ID_W, USER_W) rd;
      phase.raise_objection(this);
      seqr = env.get_master_sequencer(0);
      if (seqr == null) `uvm_fatal(get_type_name(), "Master sequencer not found at index 0")
      wr = new("wr");
      wr.addr = 32'h0010_0000;
      wr.expected_bresp = AXI4_RESP_DECERR;
      wr.start(seqr);
      rd = new("rd");
      rd.addr = 32'h0010_0000;
      rd.expected_rresp = AXI4_RESP_DECERR;
      rd.start(seqr);
      repeat (32) @(posedge vif.aclk);
      phase.drop_objection(this);
    endtask
  endclass

  class axi4_dut_delay_test extends axi4_dut_base_test;
    `uvm_component_utils(axi4_dut_delay_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    virtual function void post_build_cfg();
      // Non-pipelined master: RREADY stays asserted in drive_read, so do not
      // enable master_rready_random (it only warns and is a no-op).
      env_cfg.agent_cfgs[0].inter_txn_gap_min = 1;
      env_cfg.agent_cfgs[0].inter_txn_gap_max = 3;
      env_cfg.agent_cfgs[0].master_w_beat_gap_min = 1;
      env_cfg.agent_cfgs[0].master_w_beat_gap_max = 2;
      env_cfg.agent_cfgs[0].master_bready_random = 1'b1;
      env_cfg.agent_cfgs[0].master_bready_low_min = 1;
      env_cfg.agent_cfgs[0].master_bready_low_max = 3;
    endfunction
    task run_phase(uvm_phase phase);
      axi4_sequencer#(ADDR_W, DATA_W, ID_W, USER_W) seqr;
      axi4_write_readback_seq#(ADDR_W, DATA_W, ID_W, USER_W) seq;
      phase.raise_objection(this);
      seqr = env.get_master_sequencer(0);
      if (seqr == null) `uvm_fatal(get_type_name(), "Master sequencer not found at index 0")
      seq = new("seq");
      seq.num_txns = 32;
      seq.max_len = 7;
      seq.enable_fixed = 1'b1;
      seq.enable_incr = 1'b1;
      seq.enable_wrap = 1'b0;
      seq.enable_narrow = 1'b0;
      seq.start(seqr);
      repeat (256) @(posedge vif.aclk);
      phase.drop_objection(this);
    endtask
  endclass

  class axi4_dut_ral_test extends axi4_dut_base_test;
    `uvm_component_utils(axi4_dut_ral_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      axi4_sequencer#(ADDR_W, DATA_W, ID_W, USER_W) seqr;
      uvm_status_e status;
      uvm_reg_data_t data;
      phase.raise_objection(this);
      seqr = env.get_master_sequencer(0);
      if (seqr == null) `uvm_fatal(get_type_name(), "Master sequencer not found at index 0")
      ral.default_map.set_sequencer(seqr, ral_adapter);
      ral.default_map.set_auto_predict(0);
      ral.regs[0].write(status, 32'h1234_5678, UVM_FRONTDOOR);
      if (status != UVM_IS_OK) `uvm_fatal(get_type_name(), "RAL write to reg0 failed")
      ral.regs[1].write(status, 32'hcafebabe, UVM_FRONTDOOR);
      if (status != UVM_IS_OK) `uvm_fatal(get_type_name(), "RAL write to reg1 failed")
      ral.regs[0].read(status, data, UVM_FRONTDOOR);
      if ((status != UVM_IS_OK) || (data[31:0] != 32'h1234_5678))
        `uvm_fatal(get_type_name(), $sformatf("RAL readback reg0 failed status=%s data=0x%0h", status.name(), data))
      ral.regs[1].read(status, data, UVM_FRONTDOOR);
      if ((status != UVM_IS_OK) || (data[31:0] != 32'hcafebabe))
        `uvm_fatal(get_type_name(), $sformatf("RAL readback reg1 failed status=%s data=0x%0h", status.name(), data))
      repeat (64) @(posedge vif.aclk);
      phase.drop_objection(this);
    endtask
  endclass


  // Directed AXI4 burst verification sequence
  class axi4_directed_burst_seq #(
    int ADDR_W = 32,
    int DATA_W = 64,
    int ID_W   = 4,
    int USER_W = 1
  ) extends axi4_base_seq#(ADDR_W, DATA_W, ID_W, USER_W);

    // WRAP burst starting address, configured by the test
    logic [ADDR_W-1:0] start_addr;
    axi4_burst_e burst_type = AXI4_BURST_WRAP;
    logic [2:0] size_cfg = 3'd2;
    logic [7:0] len_cfg = 8'd3;

    `uvm_object_param_utils(
      axi4_directed_burst_seq#(ADDR_W, DATA_W, ID_W, USER_W)
    )

    function new(string name = "axi4_directed_burst_seq");
      super.new(name);

    // Default WRAP starting address
       start_addr = 'h2000;
     endfunction

task body();

  axi4_item#(ADDR_W, DATA_W, ID_W, USER_W) wr;
  axi4_item#(ADDR_W, DATA_W, ID_W, USER_W) rd;
  int unsigned bus_bytes;
  int unsigned bytes_per_beat;
  longint unsigned beat_a;
  int unsigned lane;
 // Create write transaction
  wr = new("wr");
  // Configure AXI4 WRAP transaction
  wr.is_write = 1'b1;
  wr.id       = '0;
  wr.addr     = start_addr;
  wr.len      = len_cfg;
  wr.size     = size_cfg;
  wr.burst    = burst_type;
  wr.user     = '0;

  // Allocate payload arrays
  wr.allocate_payload();
// Fill four different data patterns
bus_bytes      = DATA_W / 8;
bytes_per_beat = (1 << wr.size);

for (int unsigned i = 0; i < wr.num_beats(); i++) begin

  // Generate different WDATA patterns
  case (i)
    0: wr.data[i] = 64'hA1A2_A3A4_A5A6_A7A8;
    1: wr.data[i] = 64'hB1B2_B3B4_B5B6_B7B8;
    2: wr.data[i] = 64'hC1C2_C3C4_C5C6_C7C8;
    3: wr.data[i] = 64'hD1D2_D3D4_D5D6_D7D8;
    default: wr.data[i] = '0;
  endcase

  // Calculate current beat address
  beat_a = axi4_beat_addr(
    longint'(wr.addr),
    int'(wr.size),
    int'(wr.len),
    wr.burst,
    i
  );

  // Calculate starting byte lane
  lane = int'(beat_a % bus_bytes);

  // Generate WSTRB
  if (bytes_per_beat >= bus_bytes)
    wr.strb[i] = '1;
  else
    wr.strb[i] =
      (((1 << bytes_per_beat) - 1) << lane);

  `uvm_info(get_type_name(),
    $sformatf(
      "Beat=%0d Addr=0x%0h Lane=%0d WSTRB=0x%0h WDATA=0x%0h",
      i, beat_a, lane, wr.strb[i], wr.data[i]
    ),
    UVM_LOW)

end
  // Send the complete WRAP write transaction
  start_item(wr);
  finish_item(wr);

  // Check whether the transaction was aborted
  if (wr.reset_aborted || wr.timeout_aborted) begin
    `uvm_fatal(get_type_name(),
      "WRAP write transaction was aborted")
  end

  // Check write response
  if (wr.bresp != AXI4_RESP_OKAY) begin
    `uvm_fatal(get_type_name(),
      $sformatf("Expected BRESP=OKAY, got %0d", wr.bresp))
  end

  `uvm_info(get_type_name(),
    "Burst write completed with BRESP=OKAY",
    UVM_LOW)

  // Create matching read transaction
     rd = new("rd");

       // Configure AXI4 WRAP read transaction
     rd.is_write = 1'b0;
     rd.id       = wr.id;
     rd.addr     = wr.addr;
     rd.len      = wr.len;
     rd.size     = wr.size;
     rd.burst    = wr.burst;
     rd.user     = wr.user;

                       // Allocate read payload arrays
    rd.allocate_payload();

  // Send the complete WRAP read transaction
  start_item(rd);
  finish_item(rd);

  // Check whether the read transaction was aborted
  if (rd.reset_aborted || rd.timeout_aborted) begin
    `uvm_fatal(get_type_name(),
      "WRAP read transaction was aborted")
  end

  // Check RRESP for every beat
  for (int unsigned i = 0; i < rd.num_beats(); i++) begin
    if (rd.rresp[i] != AXI4_RESP_OKAY) begin
      `uvm_fatal(get_type_name(),
        $sformatf(
          "Expected RRESP=OKAY at beat %0d, got %0d",
          i, rd.rresp[i]
        ))
    end
  end

  `uvm_info(get_type_name(),
    "Burst read completed with all RRESP=OKAY",
    UVM_LOW)
`uvm_info(get_type_name(),
    $sformatf(
      "BURST WRITE: addr=0x%0h len=%0d size=%0d beats=%0d data_slots=%0d strb_slots=%0d",
      wr.addr, wr.len, wr.size, wr.num_beats(),
      wr.data.size(), wr.strb.size()
    ),
    UVM_LOW)

endtask

  endclass


  // Directed WRAP alignment test
  class axi4_dut_wrap_alignment_test extends axi4_dut_base_test;

    `uvm_component_utils(axi4_dut_wrap_alignment_test)

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);

      axi4_sequencer#(ADDR_W, DATA_W, ID_W, USER_W) seqr;

      axi4_directed_burst_seq#(
        ADDR_W, DATA_W, ID_W, USER_W
      ) seq;

      logic [ADDR_W-1:0] selected_addr;
      axi4_item#(ADDR_W, DATA_W, ID_W, USER_W) probe;
      bit random_ok;

      // Keep simulation alive
      phase.raise_objection(this);

      // Get master sequencer
      seqr = env.get_master_sequencer(0);

      if (seqr == null)
        `uvm_fatal(get_type_name(),
          "Master sequencer not found")

      // Default starting address
      selected_addr = 'h2000;

      // Override address through command line
      void'($value$plusargs(
        "WRAP_ADDR=%h", selected_addr
      ));

      // Create and configure sequence
      seq = new("seq");
      seq.start_addr = selected_addr;
      // Constraint-only probe
      probe = new("probe");

      // Disable only the default INCR constraint
      probe.c_burst_default.constraint_mode(0);

      // Experiment A: legal WRAP address
      random_ok = probe.randomize() with {
        is_write == 1'b1;
        addr     == 32'h0000_2008;
        len      == 8'd3;
        size     == 3'd2;
        burst    == AXI4_BURST_WRAP;
      };

      if (!random_ok) begin
        `uvm_fatal(get_type_name(),
          "Legal WRAP address 0x2008 was rejected")
      end else begin
        `uvm_info(get_type_name(),
          "Constraint PASS: 0x2008 accepted",
          UVM_LOW)
      end

      // Experiment B: illegal WRAP address
      random_ok = probe.randomize() with {
        is_write == 1'b1;
        addr     == 32'h0000_2002;
        len      == 8'd3;
        size     == 3'd2;
        burst    == AXI4_BURST_WRAP;
      };

      if (random_ok) begin
        `uvm_fatal(get_type_name(),
          "Illegal WRAP address 0x2002 was accepted")
      end else begin
        `uvm_info(get_type_name(),
          "Constraint PASS: 0x2002 rejected",
          UVM_LOW)
      end

      `uvm_info(get_type_name(),
        $sformatf(
          "Starting WRAP test: AWADDR=0x%0h",
          selected_addr
        ),
        UVM_LOW)

      // Start sequence
      seq.start(seqr);

      // Allow monitor and scoreboard to finish processing
      repeat (128) @(posedge vif.aclk);

      phase.drop_objection(this);

    endtask

  endclass

  // Directed FIXED burst test
  class axi4_dut_fixed_test extends axi4_dut_base_test;

    `uvm_component_utils(axi4_dut_fixed_test)

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);

      axi4_sequencer#(ADDR_W, DATA_W, ID_W, USER_W) seqr;

      axi4_directed_burst_seq#(
        ADDR_W, DATA_W, ID_W, USER_W
      ) seq;

      phase.raise_objection(this);

      seqr = env.get_master_sequencer(0);

      if (seqr == null)
        `uvm_fatal(get_type_name(),
          "Master sequencer not found")

      // Configure FIXED burst
      seq = new("seq");
      seq.start_addr = 'h3000;
      seq.burst_type = AXI4_BURST_FIXED;
      seq.len_cfg = 8'd3;
      seq.size_cfg = 3'd3;

      `uvm_info(get_type_name(),
        "Starting FIXED test: AWADDR=0x3000 LEN=3 SIZE=3",
        UVM_LOW)

      seq.start(seqr);

      repeat (128) @(posedge vif.aclk);

      phase.drop_objection(this);

    endtask

  endclass

  // Directed INCR burst test
  class axi4_dut_incr_test extends axi4_dut_base_test;

    `uvm_component_utils(axi4_dut_incr_test)

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);

      axi4_sequencer#(ADDR_W, DATA_W, ID_W, USER_W) seqr;

      axi4_directed_burst_seq#(
        ADDR_W, DATA_W, ID_W, USER_W
      ) seq;

      phase.raise_objection(this);

      seqr = env.get_master_sequencer(0);

      if (seqr == null)
        `uvm_fatal(get_type_name(),
          "Master sequencer not found")

      // Configure INCR burst
      seq = new("seq");
      seq.start_addr = 'h4000;
      seq.burst_type = AXI4_BURST_INCR;
      seq.len_cfg = 8'd3;
      seq.size_cfg = 3'd3;

      `uvm_info(get_type_name(),
        "Starting INCR test: AWADDR=0x4000 LEN=3 SIZE=3",
        UVM_LOW)

      seq.start(seqr);

      repeat (128) @(posedge vif.aclk);

      phase.drop_objection(this);

    endtask

  endclass

  // Directed Narrow Transfer test
  class axi4_dut_narrow_directed_test extends axi4_dut_base_test;

    `uvm_component_utils(axi4_dut_narrow_directed_test)

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);

      axi4_sequencer#(ADDR_W, DATA_W, ID_W, USER_W) seqr;

      axi4_directed_burst_seq#(
        ADDR_W, DATA_W, ID_W, USER_W
      ) seq;

      logic [ADDR_W-1:0] base_addr;

      phase.raise_objection(this);

      seqr = env.get_master_sequencer(0);

      if (seqr == null)
        `uvm_fatal(get_type_name(),
          "Master sequencer not found")

      // Test SIZE=0, 1 and 2
      for (int unsigned size_i = 0; size_i < 3; size_i++) begin

        base_addr = 32'h5000 + (size_i * 32'h0100);

        // Step 1: Initialize four full-width words
        seq = new($sformatf("prefill_size_%0d", size_i));
        seq.start_addr = base_addr;
        seq.burst_type = AXI4_BURST_INCR;
        seq.len_cfg = 8'd3;
        seq.size_cfg = 3'd3;

        `uvm_info(get_type_name(),
          $sformatf("Prefill SIZE=%0d at 0x%0h",
            size_i, base_addr),
          UVM_LOW)

        seq.start(seqr);

        // Step 2: Run the Narrow Transfer
        seq = new($sformatf("narrow_size_%0d", size_i));
        seq.start_addr = base_addr;
        seq.burst_type = AXI4_BURST_INCR;
        seq.len_cfg = 8'd3;
        seq.size_cfg = size_i[2:0];

        `uvm_info(get_type_name(),
          $sformatf("Narrow test SIZE=%0d at 0x%0h",
            size_i, base_addr),
          UVM_LOW)

        seq.start(seqr);

      end

      repeat (128) @(posedge vif.aclk);

      phase.drop_objection(this);

    endtask

  endclass

  // Directed 4KB boundary test
  class axi4_dut_4kb_boundary_test extends axi4_dut_base_test;

    `uvm_component_utils(axi4_dut_4kb_boundary_test)

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);

      axi4_sequencer#(ADDR_W, DATA_W, ID_W, USER_W) seqr;

      axi4_directed_burst_seq#(
        ADDR_W, DATA_W, ID_W, USER_W
      ) seq;

      axi4_item#(ADDR_W, DATA_W, ID_W, USER_W) probe;
      bit random_ok;

      phase.raise_objection(this);

      seqr = env.get_master_sequencer(0);

      if (seqr == null)
        `uvm_fatal(get_type_name(), "Master sequencer not found")

      probe = new("probe");

      // Legal: ends exactly at 4KB boundary
      random_ok = probe.randomize() with {
        is_write == 1'b1;
        addr == 32'h0000_1FF0;
        len == 8'd1;
        size == 3'd3;
        burst == AXI4_BURST_INCR;
      };

      if (!random_ok)
        `uvm_fatal(get_type_name(), "Legal 4KB burst rejected")
      else
        `uvm_info(get_type_name(), "4KB PASS: 0x1FF0 accepted", UVM_LOW)

      // Illegal: crosses 4KB boundary
      random_ok = probe.randomize() with {
        is_write == 1'b1;
        addr == 32'h0000_1FF8;
        len == 8'd1;
        size == 3'd3;
        burst == AXI4_BURST_INCR;
      };

      if (random_ok)
        `uvm_fatal(get_type_name(), "Illegal 4KB crossing accepted")
      else
        `uvm_info(get_type_name(), "4KB PASS: 0x1FF8 rejected", UVM_LOW)

      // Send legal transaction
      seq = new("seq");
      seq.start_addr = 'h1FF0;
      seq.burst_type = AXI4_BURST_INCR;
      seq.len_cfg = 8'd1;
      seq.size_cfg = 3'd3;

      seq.start(seqr);

      repeat (128) @(posedge vif.aclk);

      phase.drop_objection(this);

    endtask

  endclass

  // Intentional illegal 4KB crossing for SVA negative testing
  class axi4_dut_4kb_sva_negative_test extends axi4_dut_base_test;

    `uvm_component_utils(axi4_dut_4kb_sva_negative_test)

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);

      axi4_sequencer#(ADDR_W, DATA_W, ID_W, USER_W) seqr;

      axi4_directed_burst_seq#(
        ADDR_W, DATA_W, ID_W, USER_W
      ) seq;

      phase.raise_objection(this);

      seqr = env.get_master_sequencer(0);

      if (seqr == null)
        `uvm_fatal(get_type_name(), "Master sequencer not found")

      // Manually configure an illegal transaction.
      // Deliberately do NOT call randomize().
      seq = new("seq");
      seq.start_addr = 'h1FF8;
      seq.burst_type = AXI4_BURST_INCR;
      seq.len_cfg = 8'd1;
      seq.size_cfg = 3'd3;

      `uvm_info(get_type_name(),
        "NEGATIVE TEST: sending illegal 4KB crossing",
        UVM_LOW)

      seq.start(seqr);

      repeat (128) @(posedge vif.aclk);

      phase.drop_objection(this);

    endtask

  endclass


endpackage
