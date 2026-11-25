`timescale 1ns/1ps
`include "uvm_macros.svh"

package early_w_checker_pkg;
  import uvm_pkg::*;
  import axi4_uvm_pkg::*;

  class early_w_checker_test extends uvm_test;
    `uvm_component_utils(early_w_checker_test)
    typedef virtual axi4_if #(32,64,4,1) vif_t;
    typedef axi4_agent_cfg#(32,64,4,1) cfg_t;
    typedef axi4_protocol_checker#(32,64,4,1) checker_t;
    vif_t vif;
    checker_t chk;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      cfg_t cfg;
      super.build_phase(phase);
      if (!uvm_config_db#(vif_t)::get(this, "", "vif", vif))
        `uvm_fatal("EARLY_W", "Missing standalone interface")
      cfg = new("cfg");
      cfg.vif = vif;
      uvm_config_db#(cfg_t)::set(this, "chk", "cfg", cfg);
      chk = checker_t::type_id::create("chk", this);
    endfunction

    task send_w(bit [63:0] data, bit [7:0] strobe, bit last);
      @(negedge vif.aclk);
      vif.wvalid = 1;
      vif.wdata = data;
      vif.wstrb = strobe;
      vif.wlast = last;
      @(posedge vif.aclk);
      if (!(vif.wvalid && vif.wready)) `uvm_fatal("EARLY_W", "Missing W handshake")
      `uvm_info("EARLY_W_EVT", $sformatf("W data=%016h wstrb=%02h last=%0d", data, strobe, last), UVM_LOW)
      @(negedge vif.aclk);
      vif.wvalid = 0;
    endtask

    task send_aw(bit [3:0] id, bit [31:0] addr, bit [7:0] len, bit [2:0] size, bit [1:0] burst);
      @(negedge vif.aclk);
      vif.awvalid = 1;
      vif.awid = id;
      vif.awaddr = addr;
      vif.awlen = len;
      vif.awsize = size;
      vif.awburst = burst;
      @(posedge vif.aclk);
      if (!(vif.awvalid && vif.awready)) `uvm_fatal("EARLY_W", "Missing AW handshake")
      `uvm_info("EARLY_W_EVT", $sformatf("AW id=%0h addr=%08h len=%0d size=%0d burst=%0d",
                                         id, addr, len, size, burst), UVM_LOW)
      @(negedge vif.aclk);
      vif.awvalid = 0;
    endtask

    task send_b(bit [3:0] id);
      @(negedge vif.aclk);
      vif.bvalid = 1;
      vif.bid = id;
      vif.bresp = 0;
      @(posedge vif.aclk);
      if (!(vif.bvalid && vif.bready)) `uvm_fatal("EARLY_W", "Missing B handshake")
      `uvm_info("EARLY_W_EVT", $sformatf("B id=%0h", id), UVM_LOW)
      @(negedge vif.aclk);
      vif.bvalid = 0;
    endtask

    task run_phase(uvm_phase phase);
      bit bad = $test$plusargs("CLOSURE_BAD_EARLY_WSTRB");
      phase.raise_objection(this);
      vif.awvalid = 0;
      vif.awlock = 0;
      vif.wvalid = 0;
      vif.bvalid = 0;
      vif.arvalid = 0;
      vif.rvalid = 0;
      vif.awready = 1;
      vif.wready = 1;
      vif.bready = 1;
      wait (vif.areset_n === 1'b1);
      // Two whole bursts before AW, deliberately with distinct lengths and IDs.
      send_w(64'h1111_2222_3333_4444, 8'h0c, 0);
      send_w(64'h5555_6666_7777_8888, bad ? 8'h31 : 8'h30, 1);
      send_w(64'h9999_aaaa_bbbb_cccc, 8'h80, 1);
      send_aw(3, 32'h1022, 1, 1, 1);
      send_b(3);
      send_aw(9, 32'h1047, 0, 0, 0);
      send_b(9);
      // AW after the first W beat and before WLAST.
      send_w(64'h11, 8'h01, 0);
      send_aw(7, 32'h1080, 1, 0, 1);
      send_w(64'h2200, 8'h02, 1);
      send_b(7);
      // AW-first control.
      send_aw(1, 32'h1090, 0, 1, 1);
      send_w(64'h3344, 8'h03, 1);
      send_b(1);
      repeat (2) @(negedge vif.aclk);
      if (chk.aw_hs != 4 || chk.w_hs != 6 || chk.b_hs != 4 ||
          chk.early_w_bursts.size() != 0 || chk.early_w_strbs.size() != 0 ||
          chk.aw_q.size() != 0 || chk.w_active)
        `uvm_fatal("EARLY_W", "Unexpected handshakes or unpaired metadata")
      `uvm_info("EARLY_W_DONE", $sformatf("bad=%0d complete_early=2 partial_early=1 aw_first=1", bad), UVM_LOW)
      phase.drop_objection(this);
    endtask
  endclass
endpackage

module early_w_checker_top;
  import uvm_pkg::*;
  import early_w_checker_pkg::*;
  bit aclk;
  bit areset_n;
  axi4_if #(32,64,4,1) axi (.*);
  always #5 aclk = ~aclk;

  initial begin
    repeat (4) @(negedge aclk);
    areset_n = 1;
  end

  initial begin
    uvm_config_db#(virtual axi4_if #(32,64,4,1))::set(null, "*", "vif", axi);
    run_test("early_w_checker_test");
  end

  initial begin
    #10000;
    $fatal(1, "Early-W standalone watchdog");
  end
endmodule
