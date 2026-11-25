`timescale 1ns/1ps

// Direct-pin stimulus and a synthetic responder with disjoint pin ownership.
// No DUT and no UVM driver are elaborated.
module top;
  bit aclk;
  logic areset_n;
  axi4_if #(32, 64, 4, 1) axi (.*);

  localparam bit [3:0] ID = 4'd7;
  localparam bit [31:0] ADDR = 32'h100;
  localparam bit [63:0] DATA = 64'h6ac1_0c55_10be_f91a;
  localparam bit [1:0] OKAY = 2'b00;
  localparam bit [1:0] EXOKAY = 2'b01;

  always #5 aclk = ~aclk;
  initial #2500 $fatal(1, "Checker-only watchdog expired");

  initial begin
    `include "kvips_wave_dump.svh"
    `KVIPS_MAYBE_ENABLE_WAVES_SCOPE("kvips_axi4_checker", top)
  end

  task automatic master_idle();
    {axi.awvalid, axi.wvalid, axi.bready, axi.arvalid, axi.rready} = '0;
    {axi.awid, axi.awaddr, axi.awlen, axi.awsize, axi.awburst, axi.awlock,
     axi.awcache, axi.awprot, axi.awqos, axi.awregion, axi.awuser} = '0;
    {axi.arid, axi.araddr, axi.arlen, axi.arsize, axi.arburst, axi.arlock,
     axi.arcache, axi.arprot, axi.arqos, axi.arregion, axi.aruser} = '0;
    {axi.wdata, axi.wstrb, axi.wlast, axi.wuser} = '0;
  endtask

  task automatic responder_idle();
    {axi.awready, axi.wready, axi.arready, axi.bvalid, axi.rvalid} = '0;
    {axi.bid, axi.bresp, axi.buser, axi.rid, axi.rdata, axi.rresp, axi.rlast, axi.ruser} = '0;
  endtask

  // Both roles set pins on the falling edge. The rising edge is observable by
  // the interface's clocking block as well as its procedural checker.
  task automatic aw(bit [7:0] len, bit lock_bit = 0);
    {axi.awid, axi.awaddr, axi.awlen, axi.awsize, axi.awburst, axi.awlock} =
        {ID, ADDR, len, 3'd3, 2'b01, lock_bit};
    axi.awvalid = 1;
    @(posedge aclk);
    if (axi.awready !== 1'b1) $fatal(1, "AW not accepted");
    @(negedge aclk);
    axi.awvalid = 0;
  endtask

  task automatic w(bit last_bit);
    {axi.wdata, axi.wstrb, axi.wlast} = {DATA, 8'hff, last_bit};
    axi.wvalid = 1;
    @(posedge aclk);
    if (axi.wready !== 1'b1) $fatal(1, "W not accepted");
    @(negedge aclk);
    axi.wvalid = 0;
  endtask

  task automatic b(bit [3:0] id, bit [1:0] resp);
    {axi.bid, axi.bresp} = {id, resp};
    axi.bvalid = 1;
    @(posedge aclk);
    if (axi.bready !== 1'b1) $fatal(1, "B not accepted");
    @(negedge aclk);
    axi.bvalid = 0;
  endtask

  task automatic ar(bit [7:0] len, bit lock_bit = 0, bit [3:0] id = ID);
    {axi.arid, axi.araddr, axi.arlen, axi.arsize, axi.arburst, axi.arlock} =
        {id, ADDR, len, 3'd3, 2'b01, lock_bit};
    axi.arvalid = 1;
    @(posedge aclk);
    if (axi.arready !== 1'b1) $fatal(1, "AR not accepted");
    @(negedge aclk);
    axi.arvalid = 0;
  endtask

  task automatic r(bit [3:0] id, bit last_bit, bit [1:0] resp = OKAY);
    {axi.rid, axi.rdata, axi.rlast, axi.rresp} = {id, DATA, last_bit, resp};
    axi.rvalid = 1;
    @(posedge aclk);
    if (axi.rready !== 1'b1) $fatal(1, "R not accepted");
    @(negedge aclk);
    axi.rvalid = 0;
  endtask

  task automatic check_clear();
    if (axi.kvips_wr_fifo.size() != 0 || axi.kvips_outs_w != 0 || axi.kvips_outs_r != 0)
      $fatal(1, "Checker retains outstanding state across epoch");
    for (int i = 0; i < 16; i++) begin
      if (axi.kvips_wr_done_lock_q.exists(4'(i)) && axi.kvips_wr_done_lock_q[4'(i)].size())
        $fatal(1, "Pending B context at ID=%0d", i);
      if (axi.kvips_rd_beats_q.exists(4'(i)) && axi.kvips_rd_beats_q[4'(i)].size())
        $fatal(1, "Pending R context at ID=%0d", i);
      if (axi.kvips_rd_lock_q.exists(4'(i)) && axi.kvips_rd_lock_q[4'(i)].size())
        $fatal(1, "Pending R lock context at ID=%0d", i);
    end
  endtask

  task automatic reset_epoch();
    areset_n = 0;
    master_idle();
    responder_idle();
    repeat (2) @(negedge aclk);
    check_clear();
    areset_n = 1;
    {axi.awready, axi.wready, axi.arready, axi.bready, axi.rready} = '1;
  endtask

  task automatic clean_pair();
    aw(0);
    w(1);
    b(ID, OKAY);
    ar(0);
    r(ID, 1);
    check_clear();
  endtask

  task automatic aw_hold_violation();
    axi.awready = 0;
    {axi.awid, axi.awaddr, axi.awlen, axi.awsize, axi.awburst, axi.awlock} =
        {ID, ADDR, 8'd0, 3'd3, 2'b01, 1'b0};
    axi.awvalid = 1;
    @(posedge aclk);
    @(negedge aclk);
    axi.awaddr = ADDR + 8;
    @(negedge aclk);
    axi.awready = 1;
    @(posedge aclk);
    @(negedge aclk);
    axi.awvalid = 0;
    repeat (2) @(negedge aclk);
  endtask

  task automatic locked_control();
    clean_pair();
    ar(0, 1);
    r(ID, 1, EXOKAY);
    aw(0, 1);
    w(1);
    b(ID, EXOKAY);
    clean_pair();
  endtask

  // The old R completion and the new AR are both legal on this edge. Check
  // the actual second-ID queue and expose the competing counter NBAs.
  task automatic overlap_control();
    ar(0);
    fork
      ar(0, 0, 4'd8);
      r(ID, 1);
    join
    if (!axi.kvips_rd_beats_q.exists(4'd8) || axi.kvips_rd_beats_q[4'd8].size() != 1)
      $fatal(1, "Expected real queue entry for the second read");
    $display("OVERLAP_COUNTER time=%0t id=8 queued=%0d outstanding=%0d",
             $time, axi.kvips_rd_beats_q[4'd8].size(), axi.kvips_outs_r);
    r(4'd8, 1);
  endtask

  initial begin : scenario
    string name;
    if (!$value$plusargs("SCENARIO=%s", name)) $fatal(1, "Missing SCENARIO");
    reset_epoch();
    if (!axi.kvips_axi4_assertions_on || !axi.kvips_axi4_excl_checks_on || !axi.kvips_axi4_known_checks_on)
      $fatal(1, "Expected interface, exclusive and known-value checks enabled");
    $display("CHECKER_CONFIGURATION assertions=%0d excl=%0d known=%0d",
             axi.kvips_axi4_assertions_on, axi.kvips_axi4_excl_checks_on, axi.kvips_axi4_known_checks_on);
    $display("CHECKER_CASE_BEGIN %s time=%0t", name, $time);
    case (name)
      "w_without_aw":        w(1);
      "missing_wlast":        begin aw(1); w(0); w(0); end
      "premature_wlast":      begin aw(1); w(1); end
      "w_overflow":          begin aw(1); w(0); w(0); w(0); end
      "orphan_b":            b(4'd12, OKAY);
      "b_exokay_unlocked":   begin aw(0); w(1); b(ID, EXOKAY); end
      "orphan_r":            r(4'd12, 1);
      "missing_rlast":        begin ar(1); r(ID, 0); r(ID, 0); end
      "premature_rlast":      begin ar(1); r(ID, 1); end
      "r_overflow":          begin ar(1); r(ID, 0); r(ID, 0); r(ID, 0); end
      "r_exokay_unlocked":   begin ar(0); r(ID, 1, EXOKAY); end
      "aw_hold_violation":    aw_hold_violation();
      "locked_ok_control":   locked_control();
      "r_count_overlap_control": overlap_control();
      default: $fatal(1, "Unknown scenario %s", name);
    endcase
    $display("CHECKER_CASE_END %s time=%0t", name, $time);
    reset_epoch();
    $display("CHECKER_RESET_CLEAR %s time=%0t", name, $time);
    clean_pair();
    repeat (2) @(negedge aclk);
    $display("CHECKER_RECOVERY_PASS %s time=%0t", name, $time);
    $finish;
  end
endmodule
