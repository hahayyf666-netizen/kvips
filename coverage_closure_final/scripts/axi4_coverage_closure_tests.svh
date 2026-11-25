// Supplemental VCS suites for the 32-bit address, 64-bit RAM example.
typedef axi4_item#(32,64,4,1) closure_item_t;

class axi4_closure_pair_seq extends uvm_sequence#(closure_item_t);
  function new(string name);
    super.new(name);
  endfunction

  task send_item(closure_item_t tr);
    start_item(tr);
    finish_item(tr);
    if (tr.timeout_aborted || tr.reset_aborted)
      `uvm_fatal("CLOSURE", $sformatf("Transaction aborted addr=%08h", tr.addr))
  endtask

  function closure_item_t request(bit write, bit [31:0] addr, bit [7:0] len,
                                  bit [2:0] size, axi4_burst_e burst, bit [3:0] id);
    closure_item_t tr = new(write ? "closure_wr" : "closure_rd");
    tr.is_write = write;
    tr.addr = addr;
    tr.len = len;
    tr.size = size;
    tr.burst = burst;
    tr.id = id;
    tr.user = '0;
    tr.allocate_payload();
    return tr;
  endfunction

  task read_word(bit [31:0] addr, bit [63:0] data, axi4_resp_e response,
                 bit attributes = 0);
    closure_item_t rd = request(0, addr, 0, 3, AXI4_BURST_INCR, 5);
    if (attributes) begin
      rd.user = 1;
      rd.cache = 4'hf;
      rd.prot = 3'h7;
      rd.region = 4'hf;
    end
    send_item(rd);
    if (rd.rresp.size() != 1 || rd.rresp[0] !== response ||
        (response == AXI4_RESP_OKAY && rd.data[0] !== data))
      `uvm_fatal("CLOSURE_READ", $sformatf("addr=%08h resp=%0d data=%016h", addr, rd.rresp[0], rd.data[0]))
  endtask

  task word_pair(bit [31:0] addr, bit [63:0] data,
                 axi4_resp_e response = AXI4_RESP_OKAY, bit attributes = 0);
    closure_item_t wr = request(1, addr, 0, 3, AXI4_BURST_INCR, 5);
    wr.data[0] = data;
    wr.strb[0] = '1;
    if (attributes) begin
      wr.user = 1;
      wr.cache = 4'hf;
      wr.prot = 3'h7;
      wr.region = 4'hf;
    end
    send_item(wr);
    if (wr.bresp !== response)
      `uvm_fatal("CLOSURE_WRITE", $sformatf("addr=%08h expected=%0d actual=%0d", addr, response, wr.bresp))
    read_word(addr, data, response, attributes);
  endtask
endclass

class axi4_closure_toggle_seq extends axi4_closure_pair_seq;
  function new(string name);
    super.new(name);
  endfunction

  task body();
    const bit [63:0] sentinel = 64'h1357_9bdf_2468_ace0;
    word_pair(32'h20, '0);
    word_pair(32'h20, '1);
    word_pair(32'h20, 64'haaaa_aaaa_aaaa_aaaa);
    word_pair(32'h20, 64'h5555_5555_5555_5555);
    for (int i = 0; i < 64; i++) begin
      bit [63:0] pattern = 64'h1 << i;
      word_pair(32'h20, pattern);
      word_pair(32'h20, ~pattern);
    end
    word_pair(0, sentinel);
    for (int i = 3; i < 32; i++) begin
      bit [31:0] addr = 32'h1 << i;
      if (i < 16) begin
        word_pair(addr, sentinel ^ {addr, addr});
      end else begin
        word_pair(addr, ~sentinel, AXI4_RESP_DECERR);
        // Do not rewrite the sentinel after DECERR. This catches address aliasing.
        read_word(0, sentinel, AXI4_RESP_OKAY);
        // Restore BRESP to OKAY even after the last unmapped address.
        word_pair(32'h20, sentinel);
      end
      `uvm_info("CLOSURE_ADDR", $sformatf("bit=%0d address=%08h mapped=%0d", i, addr, i < 16), UVM_LOW)
    end
    word_pair(32'hfff8, sentinel);
    word_pair(32'h20, ~sentinel, AXI4_RESP_OKAY, 1);
    word_pair(32'h20, sentinel);
    `uvm_info("CLOSURE_TOGGLE", "patterns=132 address_cases=29 decerr_pairs=16 sentinel_reads=16 last_mapped=fff8 sideband_roundtrip=1", UVM_LOW)
  endtask
endclass

class axi4_dut_closure_toggle_test extends axi4_dut_base_test;
  `uvm_component_utils(axi4_dut_closure_toggle_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    axi4_closure_toggle_seq seq = new("toggle_seq");
    phase.raise_objection(this);
    seq.start(env.get_master_sequencer(0));
    repeat (8) @(vif.mon_cb);
    phase.drop_objection(this);
  endtask
endclass

class axi4_closure_random_shape;
  rand bit [1:0] page_index;
  rand bit [7:0] word_index;
  rand bit [2:0] lane;
  rand bit [2:0] size;
  rand bit [7:0] len;
  rand axi4_burst_e burst;
  rand bit [3:0] id;
  rand bit [1:0] delay_cycles;

  constraint legal_shape {
    size inside {[0:3]};
    burst inside {AXI4_BURST_FIXED, AXI4_BURST_INCR, AXI4_BURST_WRAP};
    solve burst before len;
    if (burst == AXI4_BURST_FIXED) len inside {[0:15]};
    if (burst == AXI4_BURST_WRAP) len inside {1,3,7,15};
  }
endclass

class axi4_closure_random_seq extends axi4_closure_pair_seq;
  localparam int SAMPLES = 132;
  typedef bit [31:0] addr_t;
  bit [63:0] expected_word[addr_t];
  int unsigned masks[9];
  int unsigned bursts[3], sizes[4], delays[4], ids[16];
  int unsigned total_beats, randomize_failures, pages;
  bit [7:0] length_or, length_and = '1;

  function new(string name);
    super.new(name);
  endfunction

  function addr_t lane_word(closure_item_t tr, int beat);
    longint unsigned addr;
    if (!tb_expected_beat_addr({32'b0, tr.addr}, int'(tr.size), int'(tr.len), tr.burst, beat, 64, addr))
      `uvm_fatal("CLOSURE_RANDOM", "Reference rejected generated parameters")
    return addr_t'(addr);
  endfunction

  task prefill_page(addr_t page);
    for (int part = 0; part < 2; part++) begin
      closure_item_t wr = request(1, page + part*2048, 255, 3, AXI4_BURST_INCR, 0);
      foreach (wr.data[beat]) begin
        wr.data[beat] = '0;
        wr.strb[beat] = '1;
        expected_word[wr.addr + beat*8] = '0;
      end
      send_item(wr);
      if (wr.bresp !== AXI4_RESP_OKAY)
        `uvm_fatal("CLOSURE_RANDOM", "Page prefill failed")
    end
    pages++;
  endtask

  task exercise(axi4_closure_random_shape shape, int sample_index);
    addr_t page = addr_t'((1+4*int'(shape.page_index))*4096);
    // The first half of the page leaves room even for 256 8-byte beats.
    addr_t start_addr = page + int'(shape.word_index)*8 + ((int'(shape.lane) >> shape.size) << shape.size);
    closure_item_t wr = request(1, start_addr, shape.len, shape.size, shape.burst, shape.id);
    closure_item_t rd = request(0, start_addr, shape.len, shape.size, shape.burst, shape.id);
    wr.aw_delay_cycles = int'(shape.delay_cycles);
    wr.w_beat_gap_cycles = int'(shape.delay_cycles);
    rd.ar_delay_cycles = int'(shape.delay_cycles);
    if (!expected_word.exists(page)) prefill_page(page);
    foreach (wr.data[beat]) begin
      addr_t addr = lane_word(wr, beat);
      addr_t word_addr = addr & 32'hffff_fff8;
      bit [7:0] legal_mask = 8'(((1 << (1 << shape.size)) - 1) << addr[2:0]);
      if (addr[31:12] != page[31:12] || !expected_word.exists(word_addr))
        `uvm_fatal("CLOSURE_RANDOM", "Generated beat lies outside initialized page")
      wr.data[beat] = {$urandom(), $urandom()};
      wr.strb[beat] = 8'($urandom()) & legal_mask;
      masks[$countones(wr.strb[beat])]++;
      for (int lane = 0; lane < 8; lane++)
        if (wr.strb[beat][lane]) expected_word[word_addr][lane*8 +: 8] = wr.data[beat][lane*8 +: 8];
    end
    send_item(wr);
    if (wr.bresp !== AXI4_RESP_OKAY)
      `uvm_fatal("CLOSURE_RANDOM", "Random mapped write did not return OKAY")
    send_item(rd);
    foreach (rd.data[beat]) begin
      addr_t word_addr = lane_word(rd, beat) & 32'hffff_fff8;
      if (rd.rresp[beat] !== AXI4_RESP_OKAY || rd.data[beat] !== expected_word[word_addr])
        `uvm_fatal("CLOSURE_RANDOM", $sformatf("sample=%0d addr=%08h beat=%0d expected=%016h actual=%016h",
                                               sample_index, word_addr, beat, expected_word[word_addr], rd.data[beat]))
    end
    total_beats += wr.num_beats();
    bursts[shape.burst]++;
    sizes[shape.size]++;
    delays[shape.delay_cycles]++;
    ids[shape.id]++;
    length_or |= shape.len;
    length_and &= shape.len;
    `uvm_info("CLOSURE_RANDOM_SAMPLE", $sformatf("index=%0d address=%08h burst=%0d len=%0d size=%0d id=%0d delay=%0d",
                                                sample_index, start_addr, shape.burst, shape.len, shape.size,
                                                shape.id, shape.delay_cycles), UVM_LOW)
  endtask

  task body();
    axi4_closure_random_shape shape = new();
    for (int i = 0; i < SAMPLES; i++) begin
      if (!shape.randomize()) begin
        randomize_failures++;
        `uvm_error("CLOSURE_RANDOM", $sformatf("randomize failed at sample %0d", i))
        continue;
      end
      exercise(shape, i);
    end
    `uvm_info("CLOSURE_RANDOM_SUMMARY", $sformatf("attempts=%0d generated_pairs=%0d randomize_failures=%0d beats_per_direction=%0d prefill_writes=%0d len_or=%02h len_and=%02h",
              SAMPLES, SAMPLES-randomize_failures, randomize_failures, total_beats, 2*pages, length_or, length_and), UVM_LOW)
    `uvm_info("CLOSURE_RANDOM_DISTRIBUTION", $sformatf("burst=%p size=%p id=%p delays=%p strobe_pop=%p",
              bursts, sizes, ids, delays, masks), UVM_LOW)
  endtask
endclass

class axi4_dut_closure_random_test extends axi4_dut_base_test;
  `uvm_component_utils(axi4_dut_closure_random_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    axi4_closure_random_seq seq = new("random_seq");
    phase.raise_objection(this);
    seq.start(env.get_master_sequencer(0));
    repeat (8) @(vif.mon_cb);
    phase.drop_objection(this);
  endtask
endclass

class axi4_dut_closure_bready_test extends axi4_dut_base_test;
  `uvm_component_utils(axi4_dut_closure_bready_test)
  int unsigned stalled_cycles, stalled_responses, hold_run, longest_hold, hold_errors, b_handshakes;
  bit [5:0] mid_hold_payload;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void post_build_cfg();
    env_cfg.agent_cfgs[0].master_pipelined = 1;
    env_cfg.agent_cfgs[0].max_outstanding_reads = 2;
    env_cfg.agent_cfgs[0].max_outstanding_writes = 2;
    env_cfg.agent_cfgs[0].master_bready_random = !$test$plusargs("CLOSURE_BREADY_CONTROL");
    env_cfg.agent_cfgs[0].master_bready_low_min = 4;
    env_cfg.agent_cfgs[0].master_bready_low_max = 7;
    env_cfg.agent_cfgs[0].master_rready_random = 1;
    env_cfg.agent_cfgs[0].master_rready_low_min = 3;
    env_cfg.agent_cfgs[0].master_rready_low_max = 5;
  endfunction

  task watch_b();
    forever begin
      @(vif.mon_cb);
      if (!vif.areset_n) continue;
      if (hold_run > 0 && ({vif.mon_cb.bid, vif.mon_cb.bresp} !== mid_hold_payload ||
                           vif.mon_cb.bvalid !== 1'b1)) begin
        hold_errors++;
        `uvm_error("CLOSURE_B_HOLD", "BVALID or BID/BRESP changed before handshake")
      end
      if (vif.mon_cb.bvalid && !vif.mon_cb.bready) begin
        if (hold_run == 0) mid_hold_payload = {vif.mon_cb.bid, vif.mon_cb.bresp};
        hold_run++;
        stalled_cycles++;
      end
      if (vif.mon_cb.bvalid && vif.mon_cb.bready) begin
        b_handshakes++;
        if (hold_run > 0) begin
          stalled_responses++;
          if (hold_run > longest_hold) longest_hold = hold_run;
          `uvm_info("CLOSURE_B_EVENT", $sformatf("stall_cycles=%0d bid=%0d bresp=%0d", hold_run,
                                                   vif.mon_cb.bid, vif.mon_cb.bresp), UVM_LOW)
        end
        hold_run = 0;
      end
    end
  endtask

  task run_phase(uvm_phase phase);
    axi4_same_id_pipeline_seq#(32,64,4,1) seq = new("bready_seq");
    phase.raise_objection(this);
    seq.num_txns = 64;
    seq.id = 4'ha;
    fork
      watch_b();
    join_none
    seq.start(env.get_master_sequencer(0));
    repeat (16) @(negedge vif.aclk);
    if (b_handshakes != seq.num_txns || hold_run != 0 || hold_errors != 0 ||
        (!$test$plusargs("CLOSURE_BREADY_CONTROL") && (stalled_responses == 0 || longest_hold < 2)))
      `uvm_fatal("CLOSURE_B_HOLD", "Missing completion, meaningful stall or stable response")
    `uvm_info("CLOSURE_B_SUMMARY", $sformatf("b_handshakes=%0d stalled_responses=%0d stalled_cycles=%0d max_run=%0d hold_errors=%0d",
              b_handshakes, stalled_responses, stalled_cycles, longest_hold, hold_errors), UVM_LOW)
    disable fork;
    phase.drop_objection(this);
  endtask
endclass
