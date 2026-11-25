class axi4_dut_fc_seq extends axi4_closure_pair_seq;
  typedef enum {SIZE_LANE, WSTRB_BEAT, RRESP_BEAT} mode_e;
  mode_e mode;

  function new(string name);
    super.new(name);
  endfunction

  function bit [63:0] masked_word(bit [63:0] old_data, bit [63:0] new_data, bit [7:0] mask);
    for (int lane = 0; lane < 8; lane++)
      if (mask[lane]) old_data[8*lane +: 8] = new_data[8*lane +: 8];
    return old_data;
  endfunction

  task prefill_word(bit [31:0] addr, bit [63:0] word_data);
    closure_item_t tr = request(1, addr, 0, 3, AXI4_BURST_INCR, 4'ha);
    tr.data[0] = word_data;
    tr.strb[0] = '1;
    send_item(tr);
    if (tr.bresp !== AXI4_RESP_OKAY) `uvm_fatal("FC_DATA", "Prefill BRESP must be OKAY")
  endtask

  // For these directed INCR cases the reference uses the aligned transfer stride.
  function bit [31:0] beat_address(bit [31:0] start_addr, bit [2:0] size, int index);
    if (index == 0) return start_addr;
    return ((start_addr >> size) + index) << size;
  endfunction

  task masked_incr(bit [31:0] start_addr, bit [2:0] size, input bit [7:0] masks[$]);
    typedef bit [31:0] addr_t;
    bit [63:0] expected[addr_t];
    closure_item_t wr = request(1, start_addr, 8'(masks.size()-1), size, AXI4_BURST_INCR, 4'hb);
    closure_item_t rd = request(0, start_addr, wr.len, size, AXI4_BURST_INCR, 4'hb);
    foreach (masks[i]) begin
      addr_t addr = beat_address(start_addr, size, i);
      addr_t word_addr = addr & 32'hfffffff8;
      if (!expected.exists(word_addr)) begin
        expected[word_addr] = 64'h1357_9bdf_2468_ace0 ^ {32'b0, word_addr};
        prefill_word(word_addr, expected[word_addr]);
      end
      wr.data[i] = 64'hfedc_ba98_7654_3210 ^ (64'(i) << 48);
      wr.strb[i] = masks[i];
      expected[word_addr] = masked_word(expected[word_addr], wr.data[i], masks[i]);
    end
    send_item(wr);
    if (wr.bresp !== AXI4_RESP_OKAY) `uvm_fatal("FC_DATA", "Masked write BRESP must be OKAY")
    send_item(rd);
    foreach (rd.data[i]) begin
      addr_t addr = beat_address(start_addr, size, i);
      logic [7:0] valid_lanes;
      int lo = int'(addr[2:0]);
      int high = ((lo >> size) + 1) << size;
      valid_lanes = 8'(((1 << high) - 1) ^ ((1 << lo) - 1));
      if (rd.rresp[i] !== AXI4_RESP_OKAY ||
          masked_word('0, rd.data[i], valid_lanes) !==
          masked_word('0, expected[addr & 32'hfffffff8], valid_lanes))
        `uvm_fatal("FC_DATA", $sformatf("Narrow read mismatch addr=%08h beat=%0d", addr, i))
    end
    foreach (expected[word_addr]) read_word(word_addr, expected[word_addr], AXI4_RESP_OKAY);
    `uvm_info("FC_CHECK", $sformatf("masked_incr addr=%08h size=%0d beats=%0d masks=%p PASS",
              start_addr, size, masks.size(), masks), UVM_LOW)
  endtask

  task check_rresp(bit [31:0] addr, axi4_resp_e resp);
    closure_item_t rd = request(0, addr, 3, 3, AXI4_BURST_INCR, 4'hc);
    if (resp == AXI4_RESP_OKAY)
      for (int i = 0; i < 4; i++) prefill_word(addr+8*i, 64'h7f65_4321_abcd_eff0 + 64'(i));
    send_item(rd);
    foreach (rd.data[i]) begin
      logic [63:0] expected = (resp == AXI4_RESP_OKAY) ? (64'h7f65_4321_abcd_eff0 + 64'(i)) : '0;
      if (rd.rresp[i] !== resp || rd.data[i] !== expected)
        `uvm_fatal("FC_DATA", $sformatf("Read result addr=%08h beat=%0d mismatch", addr, i))
    end
    `uvm_info("FC_CHECK", $sformatf("rresp addr=%08h id=c beats=4 resp=%0d PASS", addr, resp), UVM_LOW)
  endtask

  task body();
    bit [7:0] masks[$];
    case (mode)
      SIZE_LANE: begin
        for (int size = 0; size < 4; size++) begin
          for (int lane = 0; lane < 8; lane++) begin
            int high = ((lane >> size) + 1) << size;
            masks = '{8'(((1 << high) - 1) ^ ((1 << lane) - 1))};
            masked_incr(32'h5100 + 8*(size*8+lane) + lane, 3'(size), masks);
          end
        end
      end
      WSTRB_BEAT: begin
        masks = '{8'h20,8'ha5,8'hff,8'h00};
        masked_incr(32'h5500, 3, masks);
        masks = '{8'h01,8'h0c,8'h10,8'h00};
        masked_incr(32'h5560, 1, masks);
      end
      RRESP_BEAT: begin
        check_rresp(32'h5a00, AXI4_RESP_OKAY);
        check_rresp(32'h10010, AXI4_RESP_DECERR);
      end
    endcase
  endtask
endclass

class axi4_dut_fc_data_test extends axi4_dut_base_test;
  protected axi4_dut_fc_seq::mode_e mode;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    axi4_dut_fc_seq seq = new("fc_data");
    phase.raise_objection(this);
    seq.mode = mode;
    seq.start(env.get_master_sequencer(0));
    repeat (4) @(negedge vif.aclk);
    phase.drop_objection(this);
  endtask
endclass

class axi4_dut_fc_size_lane_test extends axi4_dut_fc_data_test;
  `uvm_component_utils(axi4_dut_fc_size_lane_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
    mode = axi4_dut_fc_seq::SIZE_LANE;
  endfunction
endclass

class axi4_dut_fc_wstrb_beat_test extends axi4_dut_fc_data_test;
  `uvm_component_utils(axi4_dut_fc_wstrb_beat_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
    mode = axi4_dut_fc_seq::WSTRB_BEAT;
  endfunction
endclass

class axi4_dut_fc_rresp_beat_test extends axi4_dut_fc_data_test;
  `uvm_component_utils(axi4_dut_fc_rresp_beat_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
    mode = axi4_dut_fc_seq::RRESP_BEAT;
  endfunction
endclass

class axi4_dut_fc_backpressure_burst_test extends axi4_dut_base_test;
  `uvm_component_utils(axi4_dut_fc_backpressure_burst_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void post_build_cfg();
    env_cfg.agent_cfgs[0].is_master = 1'b0;
  endfunction

  // All drive tasks start and return on negedges. Only the test owns master pins.
  task issue_addr(bit wr, bit [31:0] addr, bit [3:0] id, bit [7:0] len, axi4_burst_e burst);
    if (wr) begin
      vif.awaddr = addr;
      vif.awid = id;
      vif.awlen = len;
      vif.awsize = 3;
      vif.awburst = burst;
      vif.awvalid = 1;
      do @(posedge vif.aclk); while (!vif.awready);
      @(negedge vif.aclk);
      vif.awvalid = 0;
    end else begin
      vif.araddr = addr;
      vif.arid = id;
      vif.arlen = len;
      vif.arsize = 3;
      vif.arburst = burst;
      vif.arvalid = 1;
      do @(posedge vif.aclk); while (!vif.arready);
      @(negedge vif.aclk);
      vif.arvalid = 0;
    end
  endtask

  task write_beats(int beats, bit [63:0] data, int second_beat_gap);
    for (int i = 0; i < beats; i++) begin
      if (i == 1 && second_beat_gap != 0) begin
        vif.wvalid = 0;
        repeat (second_beat_gap) @(negedge vif.aclk);
      end
      vif.wvalid = 1;
      vif.wdata = data;
      vif.wstrb = '1;
      vif.wlast = (i == beats-1);
      do @(posedge vif.aclk); while (!vif.wready);
      @(negedge vif.aclk);
    end
    vif.wvalid = 0;
  endtask

  task complete_b(bit [3:0] id, int hold_cycles);
    while (vif.bvalid !== 1'b1) @(negedge vif.aclk);
    repeat (hold_cycles) @(negedge vif.aclk);
    vif.bready = 1;
    @(posedge vif.aclk);
    if (vif.bvalid !== 1'b1 || vif.bid !== id || vif.bresp !== AXI4_RESP_OKAY)
      `uvm_fatal("FC_B", "B completion mismatch")
    @(negedge vif.aclk);
    vif.bready = 0;
  endtask

  task complete_r(bit [3:0] id, int beats, bit [63:0] data, int hold_cycles);
    for (int i = 0; i < beats; i++) begin
      while (vif.rvalid !== 1'b1) @(negedge vif.aclk);
      repeat (hold_cycles) @(negedge vif.aclk);
      vif.rready = 1;
      @(posedge vif.aclk);
      if (vif.rvalid !== 1'b1 || vif.rid !== id || vif.rresp !== AXI4_RESP_OKAY ||
          vif.rlast !== (i == beats-1) || vif.rdata !== data)
        `uvm_fatal("FC_R", $sformatf("R mismatch id=%0h beat=%0d", id, i))
      @(negedge vif.aclk);
      vif.rready = 0;
    end
  endtask

  task stalled_pair(axi4_burst_e burst, int hold_cycles, int beats, bit [31:0] addr);
    bit [63:0] data = 64'h159d_ea00_1111_2222 ^ {32'b0, addr};
    issue_addr(1, addr, 3, 8'(beats-1), burst);
    write_beats(beats, data, int'(hold_cycles == 2));
    complete_b(3, hold_cycles);
    issue_addr(0, addr, 4, 8'(beats-1), burst);
    complete_r(4, beats, data, hold_cycles);
    `uvm_info("FC_CHECK", $sformatf("response_stall addr=%08h burst=%0d beats=%0d cycles=%0d PASS",
              addr, burst, beats, hold_cycles), UVM_LOW)
  endtask

  task queued_addresses(int hold_cycles, bit [31:0] addr);
    bit [63:0] first_data = 64'h1122_3344_abcd_9876;
    bit [63:0] next_data = ~first_data;
    issue_addr(1, addr, 5, 0, AXI4_BURST_INCR);
    write_beats(1, first_data, 0);
    fork
      issue_addr(1, addr+8, 6, 0, AXI4_BURST_INCR);
      complete_b(5, hold_cycles);
    join
    write_beats(1, next_data, 0);
    complete_b(6, 0);

    issue_addr(0, addr, 5, 0, AXI4_BURST_INCR);
    while (vif.rvalid !== 1'b1) @(negedge vif.aclk);
    fork
      issue_addr(0, addr+8, 6, 0, AXI4_BURST_INCR);
      complete_r(5, 1, first_data, hold_cycles);
    join
    complete_r(6, 1, next_data, 0);
    `uvm_info("FC_CHECK", $sformatf("queued_address addr=%08h response_cycles=%0d PASS",
              addr, hold_cycles), UVM_LOW)
  endtask

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    vif.awvalid = 0;
    vif.arvalid = 0;
    vif.wvalid = 0;
    vif.bready = 0;
    vif.rready = 0;
    {vif.awlock,vif.awcache,vif.awprot,vif.awqos,vif.awregion,vif.awuser} = '0;
    {vif.arlock,vif.arcache,vif.arprot,vif.arqos,vif.arregion,vif.aruser} = '0;
    vif.wuser = 0;
    wait (vif.areset_n === 1'b1);
    @(negedge vif.aclk);
    for (int burst = 0; burst < 3; burst++)
      for (int cycles = 0; cycles <= 6; cycles += 2)
        stalled_pair(axi4_burst_e'(burst), cycles, 4, 32'h7008 + 256*burst + 32*cycles);
    stalled_pair(AXI4_BURST_FIXED, 2, 1, 32'h7400);
    stalled_pair(AXI4_BURST_INCR, 2, 1, 32'h7408);
    queued_addresses(0, 32'h7500);
    queued_addresses(2, 32'h7520);
    queued_addresses(6, 32'h7540);
    repeat (4) @(negedge vif.aclk);
    phase.drop_objection(this);
  endtask
endclass
