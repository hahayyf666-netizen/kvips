package tb_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  import axi4_types_pkg::*;
  import axi4_uvm_pkg::*;

  // Independent AXI4 Burst Address Reference Model.
  // This function does NOT call axi4_beat_addr().
  function automatic bit tb_expected_beat_addr(
      input  longint unsigned start_addr,
      input  int unsigned     size,
      input  int unsigned     len,
      input  axi4_burst_e     burst,
      input  int unsigned     beat,
      input  int unsigned     data_w,
      output longint unsigned expected_addr
  );

      longint unsigned bytes_per_beat;
      longint unsigned aligned_addr;
      longint unsigned wrap_bytes;
      longint unsigned wrap_base;
      longint unsigned wrap_limit;
      int unsigned bus_bytes;

      expected_addr = start_addr;

      if (data_w == 0 || (data_w % 8) != 0)
          return 1'b0;

      bus_bytes = data_w / 8;

      if ((bus_bytes & (bus_bytes - 1)) != 0)
          return 1'b0;

      if (size >= 64)
          return 1'b0;

      bytes_per_beat = 64'd1 << size;

      if (bytes_per_beat > bus_bytes)
          return 1'b0;

      if (beat > len)
          return 1'b0;

      case (burst)

          AXI4_BURST_FIXED: begin
              if (len > 15)
                  return 1'b0;

              expected_addr = start_addr;
          end

          AXI4_BURST_INCR: begin
              if (len > 255)
                  return 1'b0;

              if (beat == 0) begin
                  expected_addr = start_addr;
              end
              else begin
                  aligned_addr =
                      (start_addr / bytes_per_beat)
                      * bytes_per_beat;

                  expected_addr =
                      aligned_addr
                      + longint'(beat) * bytes_per_beat;
              end
          end

          AXI4_BURST_WRAP: begin

              if (!(len == 1 || len == 3 ||
                    len == 7 || len == 15))
                  return 1'b0;

              if ((start_addr % bytes_per_beat) != 0)
                  return 1'b0;

              wrap_bytes =
                  bytes_per_beat * (longint'(len) + 1);

              wrap_base =
                  (start_addr / wrap_bytes) * wrap_bytes;

              wrap_limit = wrap_base + wrap_bytes;

              expected_addr = start_addr;

              for (int unsigned n = 0; n < beat; n++) begin

                  expected_addr =
                      expected_addr + bytes_per_beat;

                  if (expected_addr >= wrap_limit)
                      expected_addr = wrap_base;
              end
          end

          default: return 1'b0;

      endcase

      return 1'b1;

  endfunction


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

  // Directed FIXED/WRAP x SIZE cross coverage test.
  class axi4_dut_burst_size_cross_test extends axi4_dut_base_test;

    `uvm_component_utils(axi4_dut_burst_size_cross_test)

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);

      axi4_sequencer#(ADDR_W, DATA_W, ID_W, USER_W) seqr;

      axi4_directed_burst_seq#(
        ADDR_W, DATA_W, ID_W, USER_W
      ) seq;

      logic [ADDR_W-1:0] fixed_addr;
      logic [ADDR_W-1:0] wrap_addr;

      phase.raise_objection(this);

      seqr = env.get_master_sequencer(0);

      if (seqr == null)
        `uvm_fatal(get_type_name(),
          "Master sequencer not found")

      // Run FIXED and WRAP for SIZE=0, 1 and 2.
      for (int unsigned size_i = 0; size_i < 3; size_i++) begin

        // Choose aligned addresses for each transfer size.
        case (size_i)
          0: begin
            fixed_addr = 'h6001;
            wrap_addr  = 'h7001;
          end

          1: begin
            fixed_addr = 'h6102;
            wrap_addr  = 'h7102;
          end

          2: begin
            fixed_addr = 'h6204;
            wrap_addr  = 'h7204;
          end

          default:
            `uvm_fatal(get_type_name(), "Unsupported SIZE")
        endcase

        // --------------------------------
        // FIXED + SIZE
        // --------------------------------
        seq = new($sformatf("fixed_size_%0d", size_i));

        seq.start_addr = fixed_addr;
        seq.burst_type = AXI4_BURST_FIXED;
        seq.len_cfg    = 8'd3;
        seq.size_cfg   = size_i[2:0];

        `uvm_info(get_type_name(),
          $sformatf(
            "Starting FIXED + SIZE=%0d ADDR=0x%0h LEN=3",
            size_i, fixed_addr
          ),
          UVM_LOW)

        seq.start(seqr);

        // --------------------------------
        // WRAP + SIZE
        // --------------------------------
        seq = new($sformatf("wrap_size_%0d", size_i));

        seq.start_addr = wrap_addr;
        seq.burst_type = AXI4_BURST_WRAP;
        seq.len_cfg    = 8'd3;
        seq.size_cfg   = size_i[2:0];

        `uvm_info(get_type_name(),
          $sformatf(
            "Starting WRAP + SIZE=%0d ADDR=0x%0h LEN=3",
            size_i, wrap_addr
          ),
          UVM_LOW)

        seq.start(seqr);

      end

      repeat (128) @(posedge vif.aclk);

      phase.drop_objection(this);

    endtask

  endclass

  // Directed AXI4 maximum-length INCR burst test.
  class axi4_dut_len_256_test extends axi4_dut_base_test;

    `uvm_component_utils(axi4_dut_len_256_test)

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

      seq = new("seq");

      seq.start_addr = 'h8000;
      seq.burst_type = AXI4_BURST_INCR;
      seq.len_cfg    = 8'd255;
      seq.size_cfg   = 3'd3;

      `uvm_info(get_type_name(),
        "Starting INCR maximum burst: ADDR=0x8000 LEN=255 SIZE=3 BEATS=256",
        UVM_LOW)

      seq.start(seqr);

      repeat (128) @(posedge vif.aclk);

      phase.drop_objection(this);

    endtask

  endclass


  // Directed sideband attribute coverage sequence.
  class axi4_sideband_coverage_seq #(
    int ADDR_W = 32,
    int DATA_W = 64,
    int ID_W   = 4,
    int USER_W = 1
  ) extends axi4_base_seq#(ADDR_W, DATA_W, ID_W, USER_W);

    `uvm_object_param_utils(
      axi4_sideband_coverage_seq#(ADDR_W, DATA_W, ID_W, USER_W)
    )

    function new(string name = "axi4_sideband_coverage_seq");
      super.new(name);
    endfunction

    task body();

      axi4_item#(ADDR_W, DATA_W, ID_W, USER_W) wr;
      axi4_item#(ADDR_W, DATA_W, ID_W, USER_W) rd;

      logic [3:0] qos_v;
      logic [2:0] prot_v;
      logic [3:0] cache_v;
      logic [3:0] region_v;

      for (int unsigned i = 0; i < 8; i++) begin

        // Generate representative QOS values.
        case (i)
          1: qos_v = 4'd1;
          2: qos_v = 4'd4;
          3: qos_v = 4'd12;
          4: qos_v = 4'd15;
          default: qos_v = 4'd0;
        endcase

        // Cover all eight PROT values.
        prot_v = i[2:0];

        // Cover CACHE=0 and CACHE=F.
        cache_v = (i < 4) ? 4'h0 : 4'hF;

        // Cover REGION=0 and REGION=15.
        region_v = (i < 4) ? 4'h0 : 4'hF;

        // -------------------------
        // Write transaction
        // -------------------------
        wr = new($sformatf("sideband_wr_%0d", i));

        wr.is_write = 1'b1;
        wr.id       = '0;
        wr.addr     = 32'h9000 + i * (DATA_W/8);
        wr.len      = 8'd0;
        wr.size     = $clog2(DATA_W/8);
        wr.burst    = AXI4_BURST_INCR;
        wr.lock     = 1'b0;

        wr.qos      = qos_v;
        wr.prot     = prot_v;
        wr.cache    = cache_v;
        wr.region   = region_v;
        wr.user     = '0;

        wr.allocate_payload();

        wr.data[0] = 64'hA5A5_0000_0000_0000 | i;
        wr.strb[0] = '1;

        start_item(wr);
        finish_item(wr);

        if (wr.reset_aborted || wr.timeout_aborted)
          `uvm_fatal(get_type_name(), "Sideband write aborted")

        if (wr.bresp != AXI4_RESP_OKAY)
          `uvm_fatal(get_type_name(), "Sideband write BRESP error")

        // -------------------------
        // Read transaction
        // -------------------------
        rd = new($sformatf("sideband_rd_%0d", i));

        rd.is_write = 1'b0;
        rd.id       = '0;
        rd.addr     = wr.addr;
        rd.len      = wr.len;
        rd.size     = wr.size;
        rd.burst    = wr.burst;
        rd.lock     = 1'b0;

        rd.qos      = qos_v;
        rd.prot     = prot_v;
        rd.cache    = cache_v;
        rd.region   = region_v;
        rd.user     = '0;

        rd.allocate_payload();

        start_item(rd);
        finish_item(rd);

        if (rd.reset_aborted || rd.timeout_aborted)
          `uvm_fatal(get_type_name(), "Sideband read aborted")

        if (rd.rresp.size() != 1 ||
            rd.rresp[0] != AXI4_RESP_OKAY)
          `uvm_fatal(get_type_name(), "Sideband read RRESP error")

        if (rd.data[0] !== wr.data[0])
          `uvm_fatal(get_type_name(), "Sideband readback mismatch")

        `uvm_info(get_type_name(),
          $sformatf(
            "Sideband case=%0d QOS=%0d PROT=%0d CACHE=%h REGION=%h",
            i, qos_v, prot_v, cache_v, region_v
          ),
          UVM_LOW)

      end

    endtask

  endclass


  // Directed sideband coverage test.
  class axi4_dut_sideband_coverage_test extends axi4_dut_base_test;

    `uvm_component_utils(axi4_dut_sideband_coverage_test)

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);

      axi4_sequencer#(ADDR_W, DATA_W, ID_W, USER_W) seqr;

      axi4_sideband_coverage_seq#(
        ADDR_W, DATA_W, ID_W, USER_W
      ) seq;

      phase.raise_objection(this);

      seqr = env.get_master_sequencer(0);

      if (seqr == null)
        `uvm_fatal(get_type_name(), "Master sequencer not found")

      seq = new("seq");
      seq.start(seqr);

      repeat (64) @(posedge vif.aclk);

      phase.drop_objection(this);

    endtask

  endclass

  // Lock attribute sampling sequence.
  class axi4_lock_coverage_seq #(
    int ADDR_W = 32,
    int DATA_W = 64,
    int ID_W   = 4,
    int USER_W = 1
  ) extends axi4_base_seq#(ADDR_W, DATA_W, ID_W, USER_W);

    `uvm_object_param_utils(
      axi4_lock_coverage_seq#(ADDR_W, DATA_W, ID_W, USER_W)
    )

    function new(string name = "axi4_lock_coverage_seq");
      super.new(name);
    endfunction

    task body();

      axi4_item#(ADDR_W, DATA_W, ID_W, USER_W) wr;
      axi4_item#(ADDR_W, DATA_W, ID_W, USER_W) rd;

      // First: initialize memory using a normal write.
      wr = new("lock_normal_write");

      wr.is_write = 1'b1;
      wr.id       = '0;
      wr.addr     = 'hA000;
      wr.len      = 8'd0;
      wr.size     = 3'd3;
      wr.burst    = AXI4_BURST_INCR;
      wr.lock     = 1'b0;
      wr.user     = '0;

      wr.allocate_payload();

      wr.data[0] = 64'hA55A_1234_5678_9ABC;
      wr.strb[0] = '1;

      start_item(wr);
      finish_item(wr);

      if (wr.reset_aborted || wr.timeout_aborted)
        `uvm_fatal(get_type_name(), "Normal write aborted")

      if (wr.bresp != AXI4_RESP_OKAY)
        `uvm_fatal(get_type_name(), "Normal write BRESP error")

      // Second: issue a read with ARLOCK=1.
      rd = new("lock_attribute_read");

      rd.is_write = 1'b0;
      rd.id       = '0;
      rd.addr     = wr.addr;
      rd.len      = 8'd0;
      rd.size     = 3'd3;
      rd.burst    = AXI4_BURST_INCR;
      rd.lock     = 1'b1;
      rd.user     = '0;

      rd.allocate_payload();

      start_item(rd);
      finish_item(rd);

      if (rd.reset_aborted || rd.timeout_aborted)
        `uvm_fatal(get_type_name(), "LOCK read aborted")

      if (rd.rresp.size() != 1 ||
          rd.rresp[0] != AXI4_RESP_OKAY)
        `uvm_fatal(get_type_name(), "LOCK read RRESP error")

      if (rd.data[0] !== wr.data[0])
        `uvm_fatal(get_type_name(), "LOCK readback mismatch")

      `uvm_info(get_type_name(),
        "LOCK=1 read attribute sampling completed",
        UVM_LOW)

    endtask

  endclass


  // Directed LOCK attribute coverage test.
  class axi4_dut_lock_coverage_test extends axi4_dut_base_test;

    `uvm_component_utils(axi4_dut_lock_coverage_test)

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);

      axi4_sequencer#(ADDR_W, DATA_W, ID_W, USER_W) seqr;

      axi4_lock_coverage_seq#(
        ADDR_W, DATA_W, ID_W, USER_W
      ) seq;

      phase.raise_objection(this);

      seqr = env.get_master_sequencer(0);

      if (seqr == null)
        `uvm_fatal(get_type_name(), "Master sequencer not found")

      seq = new("seq");
      seq.start(seqr);

      repeat (64) @(posedge vif.aclk);

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




  // Sequence: generate a write with Missing WLAST on its final beat.
  class axi4_missing_wlast_seq #(
    int ADDR_W = 32,
    int DATA_W = 64,
    int ID_W = 4,
    int USER_W = 1
  ) extends axi4_base_seq#(ADDR_W, DATA_W, ID_W, USER_W);

    `uvm_object_param_utils(
      axi4_missing_wlast_seq#(ADDR_W, DATA_W, ID_W, USER_W)
    )

    function new(string name = "axi4_missing_wlast_seq");
      super.new(name);
    endfunction

    task body();
      axi4_item#(ADDR_W, DATA_W, ID_W, USER_W) wr;

      wr = new("missing_wlast_write");
      wr.is_write = 1'b1;
      wr.id = 4'h3;
      wr.addr = 32'h0000_C000;
      wr.len = 8'd3;
      wr.size = $clog2(DATA_W/8);
      wr.burst = AXI4_BURST_INCR;
      wr.user = '0;
      wr.allocate_payload();

      for (int unsigned i = 0; i < wr.num_beats(); i++) begin
        wr.data[i] = 64'hA5A5_0000_0000_0000 + i;
        wr.strb[i] = '1;
      end

      wr.wlast_fault_missing = 1'b1;

      `uvm_info(get_type_name(),
        "Starting 4-beat Missing WLAST negative test", UVM_NONE)

      start_item(wr);
      finish_item(wr);

      if (wr.reset_aborted || wr.timeout_aborted)
        `uvm_fatal(get_type_name(), "Missing WLAST write aborted")

      if (wr.bresp != AXI4_RESP_OKAY)
        `uvm_fatal(get_type_name(), "Unexpected BRESP")

      `uvm_info(get_type_name(),
        "Missing WLAST sequence completed", UVM_NONE)
    endtask

  endclass


  // Test: launch the negative sequence.
  class axi4_dut_missing_wlast_test extends axi4_dut_base_test;

    `uvm_component_utils(axi4_dut_missing_wlast_test)

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
      axi4_sequencer#(ADDR_W, DATA_W, ID_W, USER_W) seqr;
      axi4_missing_wlast_seq#(ADDR_W, DATA_W, ID_W, USER_W) seq;

      phase.raise_objection(this);

      seqr = env.get_master_sequencer(0);
      if (seqr == null)
        `uvm_fatal(get_type_name(), "Master sequencer not found")

      seq = new("seq");
      seq.start(seqr);

      repeat (16) @(posedge vif.aclk);

      phase.drop_objection(this);
    endtask

  endclass




  // Sequence: deliberately assert WLAST before the final beat.
  class axi4_premature_wlast_seq #(
    int ADDR_W = 32,
    int DATA_W = 64,
    int ID_W = 4,
    int USER_W = 1
  ) extends axi4_base_seq#(ADDR_W, DATA_W, ID_W, USER_W);

    `uvm_object_param_utils(
      axi4_premature_wlast_seq#(ADDR_W, DATA_W, ID_W, USER_W)
    )

    function new(string name = "axi4_premature_wlast_seq");
      super.new(name);
    endfunction

    task body();
      axi4_item#(ADDR_W, DATA_W, ID_W, USER_W) wr;

      wr = new("premature_wlast_write");
      wr.is_write = 1'b1;
      wr.id = 4'h4;
      wr.addr = 32'h0000_C100;
      wr.len = 8'd3;
      wr.size = $clog2(DATA_W/8);
      wr.burst = AXI4_BURST_INCR;
      wr.user = '0;
      wr.allocate_payload();

      for (int unsigned i = 0; i < wr.num_beats(); i++) begin
        wr.data[i] = 64'h5A5A_0000_0000_0000 + i;
        wr.strb[i] = '1;
      end

      // Beat index 1 means the second beat.
      wr.wlast_fault_premature_beat = 1;

      `uvm_info(get_type_name(),
        "Starting 4-beat Premature WLAST negative test",
        UVM_NONE)

      start_item(wr);
      finish_item(wr);

      if (wr.reset_aborted || wr.timeout_aborted)
        `uvm_fatal(get_type_name(), "Premature WLAST write aborted")

      if (wr.bresp != AXI4_RESP_OKAY)
        `uvm_fatal(get_type_name(), "Unexpected BRESP")

      `uvm_info(get_type_name(),
        "Premature WLAST sequence completed",
        UVM_NONE)
    endtask

  endclass


  class axi4_dut_premature_wlast_test extends axi4_dut_base_test;

    `uvm_component_utils(axi4_dut_premature_wlast_test)

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
      axi4_sequencer#(ADDR_W, DATA_W, ID_W, USER_W) seqr;
      axi4_premature_wlast_seq#(ADDR_W, DATA_W, ID_W, USER_W) seq;

      phase.raise_objection(this);

      seqr = env.get_master_sequencer(0);
      if (seqr == null)
        `uvm_fatal(get_type_name(), "Master sequencer not found")

      seq = new("seq");
      seq.start(seqr);

      repeat (16) @(posedge vif.aclk);

      phase.drop_objection(this);
    endtask

  endclass



  // Independent AXI4 Burst Address Reference Test.
  class axi4_dut_addr_ref_test extends uvm_test;

    `uvm_component_utils(axi4_dut_addr_ref_test)

    function new(string name = "axi4_dut_addr_ref_test",
                 uvm_component parent = null);
      super.new(name, parent);
    endfunction

    task automatic check_case(
        input string name,
        input longint unsigned start_addr,
        input int unsigned size,
        input int unsigned len,
        input axi4_burst_e burst,
        input int unsigned data_w,
        input longint unsigned golden[]
    );

      longint unsigned ref_addr;
      longint unsigned common_addr;
      int unsigned common_diff;

      common_diff = 0;

      `uvm_info("ADDR_REF",
        $sformatf("Checking %s", name), UVM_LOW)

      for (int unsigned i = 0; i <= len; i++) begin

        if (!tb_expected_beat_addr(
              start_addr, size, len, burst,
              i, data_w, ref_addr)) begin

          `uvm_error("ADDR_REF",
            $sformatf("%s Beat %0d: reference rejected inputs",
                      name, i))
          continue;
        end

        // Check independent reference against manual golden address.
        if (ref_addr !== golden[i]) begin
          `uvm_error("ADDR_REF",
            $sformatf(
              "%s Beat %0d: REF=0x%0h GOLDEN=0x%0h",
              name, i, ref_addr, golden[i]))
        end

        // Compare existing project function against golden address.
        common_addr = axi4_beat_addr(
            start_addr, size, len, burst, i
        );

        if (common_addr !== golden[i]) begin
          common_diff++;

          `uvm_info("ADDR_REF_DIFF",
            $sformatf(
              "%s Beat %0d: COMMON=0x%0h EXPECTED=0x%0h",
              name, i, common_addr, golden[i]),
            UVM_NONE)
        end

        `uvm_info("ADDR_REF_BEAT",
          $sformatf(
            "%s Beat=%0d REF=0x%0h COMMON=0x%0h GOLDEN=0x%0h",
            name, i, ref_addr, common_addr, golden[i]),
          UVM_LOW)

      end

      `uvm_info("ADDR_REF_CASE",
        $sformatf("%s completed, common function differences=%0d",
                  name, common_diff),
        UVM_NONE)

    endtask


    task run_phase(uvm_phase phase);

      longint unsigned fixed_exp[4];
      longint unsigned incr_exp[4];
      longint unsigned wrap_exp[4];
      longint unsigned unaligned_exp[3];

      phase.raise_objection(this);

      // Case 1: FIXED
      fixed_exp[0] = 'h1028;
      fixed_exp[1] = 'h1028;
      fixed_exp[2] = 'h1028;
      fixed_exp[3] = 'h1028;

      check_case("FIXED",
        'h1028, 3, 3, AXI4_BURST_FIXED, 64, fixed_exp);

      // Case 2: Aligned INCR
      incr_exp[0] = 'h1028;
      incr_exp[1] = 'h1030;
      incr_exp[2] = 'h1038;
      incr_exp[3] = 'h1040;

      check_case("ALIGNED_INCR",
        'h1028, 3, 3, AXI4_BURST_INCR, 64, incr_exp);

      // Case 3: WRAP
      wrap_exp[0] = 'h1028;
      wrap_exp[1] = 'h1030;
      wrap_exp[2] = 'h1038;
      wrap_exp[3] = 'h1020;

      check_case("WRAP",
        'h1028, 3, 3, AXI4_BURST_WRAP, 64, wrap_exp);

      // Case 4: Unaligned INCR
      unaligned_exp[0] = 'h1007;
      unaligned_exp[1] = 'h1008;
      unaligned_exp[2] = 'h100C;

      check_case("UNALIGNED_INCR",
        'h1007, 2, 2, AXI4_BURST_INCR, 64,
        unaligned_exp);

      `uvm_info("ADDR_REF",
        "All independent address reference cases completed",
        UVM_NONE)

      phase.drop_objection(this);

    endtask

  endclass


  // End-to-end Unaligned INCR test with independent byte checks.

  // End-to-end Unaligned INCR test with independent byte checks.

  // Independent Unaligned INCR end-to-end sequence.
  class axi4_dut_unaligned_incr_e2e_seq #(
    int ADDR_W = 32,
    int DATA_W = 64,
    int ID_W   = 4,
    int USER_W = 1
  ) extends axi4_base_seq#(ADDR_W, DATA_W, ID_W, USER_W);

    `uvm_object_param_utils(
      axi4_dut_unaligned_incr_e2e_seq#(ADDR_W, DATA_W, ID_W, USER_W)
    )

    function new(string name = "axi4_dut_unaligned_incr_e2e_seq");
      super.new(name);
    endfunction

    task body();

      axi4_item#(ADDR_W, DATA_W, ID_W, USER_W) wr;
      axi4_item#(ADDR_W, DATA_W, ID_W, USER_W) rd;

      // WRITE TRANSACTION
      wr = new("unaligned_write");

      wr.is_write = 1'b1;
      wr.id       = '0;
      wr.addr     = 32'h1007;
      wr.len      = 8'd2;
      wr.size     = 3'd2;
      wr.burst    = AXI4_BURST_INCR;
      wr.user     = '0;

      wr.allocate_payload();

      wr.data[0] = 64'hA700_0000_0000_0000;
      wr.strb[0] = 8'h80;

      wr.data[1] = 64'h0000_0000_B3B2_B1B0;
      wr.strb[1] = 8'h0F;

      wr.data[2] = 64'hC7C6_C5C4_0000_0000;
      wr.strb[2] = 8'hF0;

      `uvm_info(get_type_name(),
        "Starting independent Unaligned INCR write", UVM_LOW)

      start_item(wr);
      finish_item(wr);

      if (wr.reset_aborted || wr.timeout_aborted)
        `uvm_fatal(get_type_name(), "Write transaction aborted")

      if (wr.bresp != AXI4_RESP_OKAY)
        `uvm_error(get_type_name(),
          $sformatf("Unexpected BRESP=%0d", wr.bresp))
      else
        `uvm_info(get_type_name(), "BRESP OKAY", UVM_LOW)

      // READ TRANSACTION
      rd = new("unaligned_read");

      rd.is_write = 1'b0;
      rd.id       = wr.id;
      rd.addr     = wr.addr;
      rd.len      = wr.len;
      rd.size     = wr.size;
      rd.burst    = wr.burst;
      rd.user     = wr.user;

      rd.allocate_payload();

      `uvm_info(get_type_name(),
        "Starting independent Unaligned INCR read", UVM_LOW)

      start_item(rd);
      finish_item(rd);

      if (rd.reset_aborted || rd.timeout_aborted)
        `uvm_fatal(get_type_name(), "Read transaction aborted")

      if (rd.rresp.size() != 3)
        `uvm_error(get_type_name(), "Unexpected RRESP array size")
      else begin
        for (int unsigned i = 0; i < 3; i++) begin
          if (rd.rresp[i] != AXI4_RESP_OKAY)
            `uvm_error(get_type_name(),
              $sformatf("RRESP error at Beat %0d", i))
        end
      end

      // Independent byte checks.
      if (rd.data[0][63:56] !== 8'hA7)
        `uvm_error(get_type_name(),
          $sformatf("Beat 0 mismatch: got %h", rd.data[0][63:56]))
      else
        `uvm_info(get_type_name(), "Beat 0 Lane 7 PASS", UVM_LOW)

      if (rd.data[1][31:0] !== 32'hB3B2_B1B0)
        `uvm_error(get_type_name(),
          $sformatf("Beat 1 mismatch: got %h", rd.data[1][31:0]))
      else
        `uvm_info(get_type_name(), "Beat 1 Lanes 0-3 PASS", UVM_LOW)

      if (rd.data[2][63:32] !== 32'hC7C6_C5C4)
        `uvm_error(get_type_name(),
          $sformatf("Beat 2 mismatch: got %h", rd.data[2][63:32]))
      else
        `uvm_info(get_type_name(), "Beat 2 Lanes 4-7 PASS", UVM_LOW)

      `uvm_info(get_type_name(),
        "Independent Unaligned INCR data checks completed",
        UVM_NONE)

    endtask

  endclass


  // Test: starts the independent Unaligned INCR sequence.
  class axi4_dut_unaligned_incr_e2e_test extends axi4_dut_base_test;

    `uvm_component_utils(axi4_dut_unaligned_incr_e2e_test)

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);

      axi4_sequencer#(ADDR_W, DATA_W, ID_W, USER_W) seqr;

      axi4_dut_unaligned_incr_e2e_seq#(
        ADDR_W, DATA_W, ID_W, USER_W
      ) seq;

      phase.raise_objection(this);

      seqr = env.get_master_sequencer(0);

      if (seqr == null)
        `uvm_fatal(get_type_name(), "Master sequencer not found")

      seq = new("seq");
      seq.start(seqr);

      repeat (16) @(posedge vif.aclk);

      phase.drop_objection(this);

    endtask

  endclass



endpackage
