class axi4_dut_id_width_test extends axi4_dut_base_test;
  `uvm_component_utils(axi4_dut_id_width_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    axi4_sequencer#(ADDR_W, DATA_W, ID_W, USER_W) seqr;
    axi4_write_expect_resp_seq#(ADDR_W, DATA_W, ID_W, USER_W) wr;
    axi4_read_expect_resp_seq#(ADDR_W, DATA_W, ID_W, USER_W) rd;

    phase.raise_objection(this);
    seqr = env.get_master_sequencer(0);
    if (seqr == null)
      `uvm_fatal("ID_WIDTH", "Master sequencer missing")
    if (ID_W != 4 || DATA_W != 64)
      `uvm_fatal("ID_WIDTH", "Requires ID_W=4 and DATA_W=64")

    wait (vif.areset_n === 1'b1);

    for (int i = 0; i < 3; i++) begin
      wr = new($sformatf("id_write_%0d", i));
      wr.id = (i == 1) ? 4'hF : 4'h0;
      wr.addr = 32'h00008000 + i*8;
      wr.expected_bresp = AXI4_RESP_OKAY;
      wr.start(seqr);
      `uvm_info("ID_WIDTH",
        $sformatf("WRITE index=%0d ID=%0h complete", i, wr.id),
        UVM_NONE)
    end

    for (int i = 0; i < 3; i++) begin
      rd = new($sformatf("id_read_%0d", i));
      rd.id = (i == 1) ? 4'hF : 4'h0;
      rd.addr = 32'h00008000 + i*8;
      rd.expected_rresp = AXI4_RESP_OKAY;
      rd.start(seqr);
      `uvm_info("ID_WIDTH",
        $sformatf("READ index=%0d ID=%0h complete", i, rd.id),
        UVM_NONE)
    end

    repeat (32) @(posedge vif.aclk);
    phase.drop_objection(this);
  endtask
endclass
