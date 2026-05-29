// =============================================================================
// testbench.sv  —  Multi-Core MESI Cache Coherence Testbench (QuestaSim)
// =============================================================================
// mesi_pkg is defined in design.sv (same -mfcu compile unit), so only
// an import statement is needed here — no include, no package redefinition.
// =============================================================================

`timescale 1ns/1ps
import mesi_pkg::*;

module multicore_cache_tb;

    localparam integer NUM_CORES  = 4;
    localparam integer ADDR_WIDTH = 32;
    localparam integer DATA_WIDTH = 32;
    localparam integer BLOCK_SIZE = 4;
    localparam integer NUM_LINES  = 1024;
    localparam integer LINE_WIDTH = DATA_WIDTH * BLOCK_SIZE;

    localparam integer NUM_STRESS = 200;
    localparam integer CLK_PERIOD = 10;
    localparam integer TIMEOUT    = NUM_STRESS * 4 * 80;

    // =========================================================================
    // DUT ports
    // =========================================================================
    logic                    clk;
    logic                    rst_n;

    logic [ADDR_WIDTH-1:0]   cpu_req_addr   [0:NUM_CORES-1];
    logic [DATA_WIDTH-1:0]   cpu_req_datain [0:NUM_CORES-1];
    logic [DATA_WIDTH/8-1:0] cpu_req_wstrb  [0:NUM_CORES-1];
    logic                    cpu_req_rw     [0:NUM_CORES-1];
    logic                    cpu_req_valid  [0:NUM_CORES-1];
    logic [DATA_WIDTH-1:0]   cpu_req_dataout[0:NUM_CORES-1];
    logic                    cache_ready    [0:NUM_CORES-1];

    logic [ADDR_WIDTH-1:0]   mem_req_addr;
    logic [LINE_WIDTH-1:0]   mem_req_dataout;
    logic                    mem_req_rw;
    logic                    mem_req_valid;
    logic [LINE_WIDTH-1:0]   mem_req_datain;
    logic                    mem_req_done;

    // =========================================================================
    // DUT instantiation
    // =========================================================================
    multicore_top #(
        .NUM_CORES  (NUM_CORES),
        .ADDR_WIDTH (ADDR_WIDTH),
        .DATA_WIDTH (DATA_WIDTH),
        .BLOCK_SIZE (BLOCK_SIZE),
        .NUM_LINES  (NUM_LINES)
    ) dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .cpu_req_addr    (cpu_req_addr),
        .cpu_req_datain  (cpu_req_datain),
        .cpu_req_wstrb   (cpu_req_wstrb),
        .cpu_req_rw      (cpu_req_rw),
        .cpu_req_valid   (cpu_req_valid),
        .cpu_req_dataout (cpu_req_dataout),
        .cache_ready     (cache_ready),
        .mem_req_addr    (mem_req_addr),
        .mem_req_dataout (mem_req_dataout),
        .mem_req_rw      (mem_req_rw),
        .mem_req_valid   (mem_req_valid),
        .mem_req_datain  (mem_req_datain),
        .mem_req_done    (mem_req_done)
    );

    // =========================================================================
    // Clock
    // =========================================================================
    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // =========================================================================
    // Waveform dump
    // =========================================================================
    initial begin
        $dumpfile("multicore_cache_tb.vcd");
        $dumpvars(0, multicore_cache_tb);
    end

    // =========================================================================
    // Timeout watchdog
    // =========================================================================
    int cyc;
    initial begin
        cyc = 0;
        forever begin
            @(posedge clk);
            cyc++;
            if (cyc > TIMEOUT) begin
                $display("\n[TB] TIMEOUT at %0t ns after %0d cycles", $time, cyc);
                $finish;
            end
        end
    end

    // =========================================================================
    // Shadow memory — 1 MB byte-addressable ground-truth model
    // =========================================================================
    localparam integer MEM_SIZE = 1 << 20;
    logic [7:0] shadow_mem [0:MEM_SIZE-1];

    initial foreach (shadow_mem[i]) shadow_mem[i] = 8'hAA;

    function automatic logic [DATA_WIDTH-1:0] shadow_read_word(
        input logic [ADDR_WIDTH-1:0] addr
    );
        logic [DATA_WIDTH-1:0] v;
        v = '0;
        for (int b = 0; b < DATA_WIDTH/8; b++)
            v[b*8 +: 8] = shadow_mem[(addr & (MEM_SIZE-4)) | b];
        return v;
    endfunction

    function automatic logic [LINE_WIDTH-1:0] shadow_read_line(
        input logic [ADDR_WIDTH-1:0] addr
    );
        logic [LINE_WIDTH-1:0] v;
        v = '0;
        for (int b = 0; b < LINE_WIDTH/8; b++)
            v[b*8 +: 8] = shadow_mem[(addr & (MEM_SIZE-LINE_WIDTH/8)) | b];
        return v;
    endfunction

    task automatic shadow_write_word(
        input logic [ADDR_WIDTH-1:0]   addr,
        input logic [DATA_WIDTH-1:0]   data,
        input logic [DATA_WIDTH/8-1:0] wstrb
    );
        for (int b = 0; b < DATA_WIDTH/8; b++)
            if (wstrb[b])
                shadow_mem[(addr & (MEM_SIZE-4)) | b] = data[b*8 +: 8];
    endtask

    task automatic shadow_write_line(
        input logic [ADDR_WIDTH-1:0] addr,
        input logic [LINE_WIDTH-1:0] data
    );
        for (int b = 0; b < LINE_WIDTH/8; b++)
            shadow_mem[(addr & (MEM_SIZE-LINE_WIDTH/8)) | b] = data[b*8 +: 8];
    endtask

    // =========================================================================
    // Counters
    // =========================================================================
    int total_ops, check_errors, total_reads, total_writes;

    // =========================================================================
    // LFSR RNG
    // =========================================================================
    logic [31:0] lfsr_mem;
    logic [31:0] lfsr_stim;

    function automatic logic [31:0] lfsr_step(input logic [31:0] s);
        return {s[30:0], 1'b0} ^ ({32{s[31]}} & 32'h80200003);
    endfunction

    // =========================================================================
    // Memory model thread
    // — waits for mem_req_valid using a while loop (QuestaSim-compatible)
    // =========================================================================
    int mem_lat;

    initial lfsr_mem = 32'hDEAD_CAFE;

    always begin
        mem_req_done   = 1'b0;
        mem_req_datain = '0;

        // Wait for mem_req_valid — compatible with all simulators
        while (!mem_req_valid) @(posedge clk);

        // Random 1-4 cycle latency
        lfsr_mem = lfsr_step(lfsr_mem);
        mem_lat  = int'(lfsr_mem[1:0]) + 1;
        repeat(mem_lat) @(posedge clk);
        @(negedge clk);

        if (mem_req_rw)
            shadow_write_line(mem_req_addr, mem_req_dataout);
        else
            mem_req_datain = shadow_read_line(mem_req_addr);

        mem_req_done = 1'b1;
        @(posedge clk);
        @(negedge clk);
        mem_req_done = 1'b0;
    end

    // =========================================================================
    // do_op — issue one CPU operation and wait for completion
    // =========================================================================
    task automatic do_op(
        input int                      core,
        input logic [ADDR_WIDTH-1:0]   addr,
        input logic                    is_write,
        input logic [DATA_WIDTH-1:0]   wdata = '0,
        input logic [DATA_WIDTH/8-1:0] wstrb = 4'hF
    );
        while (!cache_ready[core]) @(posedge clk);
        @(negedge clk);

        cpu_req_addr [core]  = addr;
        cpu_req_rw   [core]  = is_write;
        cpu_req_valid[core]  = 1'b1;
        cpu_req_datain[core] = is_write ? wdata : '0;
        cpu_req_wstrb [core] = is_write ? wstrb : '0;

        @(posedge clk);
        @(negedge clk);
        cpu_req_valid[core] = 1'b0;

        while (!cache_ready[core]) @(posedge clk);
    endtask

    // =========================================================================
    // check_read — read and verify against shadow model
    // =========================================================================
    task automatic check_read(
        input int                    core,
        input logic [ADDR_WIDTH-1:0] addr,
        input string                 test_name
    );
        logic [DATA_WIDTH-1:0] expected, got;
        expected = shadow_read_word(addr);
        do_op(core, addr, 1'b0);
        got = cpu_req_dataout[core];
        total_reads++;
        if (got !== expected) begin
            $display("[FAIL] %s | Core%0d addr=0x%08h got=0x%08h exp=0x%08h",
                     test_name, core, addr, got, expected);
            check_errors++;
        end else begin
            $display("[PASS] %s | Core%0d addr=0x%08h data=0x%08h",
                     test_name, core, addr, got);
        end
    endtask

    // =========================================================================
    // Main stimulus
    // =========================================================================
    logic [ADDR_WIDTH-1:0] addr_A, addr_evict;
    logic [DATA_WIDTH-1:0] wdata;

    initial begin
        lfsr_stim = 32'hCAFE_0001;
        rst_n     = 1'b0;
        for (int i = 0; i < NUM_CORES; i++) begin
            cpu_req_addr [i]  = '0;
            cpu_req_datain[i] = '0;
            cpu_req_wstrb [i] = '0;
            cpu_req_rw   [i]  = '0;
            cpu_req_valid[i]  = '0;
        end
        total_ops    = 0;
        check_errors = 0;
        total_reads  = 0;
        total_writes = 0;

        repeat(4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        $display("[TB] Reset released at %0t ns", $time);
        repeat(2) @(posedge clk);

        // ── TEST 1: Cold miss → EXCLUSIVE ─────────────────────────────────────
        $display("\n--- TEST 1: Cold miss / Exclusive ---");
        addr_A = 32'h0000_4000;
        check_read(0, addr_A, "T1:ColdMiss");

        // ── TEST 2: False sharing → both SHARED ───────────────────────────────
        $display("\n--- TEST 2: False sharing / Shared ---");
        check_read(1, addr_A, "T2:FalseShare");

        // ── TEST 3: Write invalidation ─────────────────────────────────────────
        $display("\n--- TEST 3: Write invalidation ---");
        wdata = 32'hDEAD_BEEF;
        shadow_write_word(addr_A, wdata, 4'hF);
        do_op(0, addr_A, 1'b1, wdata, 4'hF);
        total_writes++;
        $display("[INFO] T3: Core0 wrote 0x%08h to 0x%08h", wdata, addr_A);
        check_read(1, addr_A, "T3:PostInvalidate");

        // ── TEST 4: M → S downgrade / C2C transfer ────────────────────────────
        $display("\n--- TEST 4: M->S downgrade / C2C transfer ---");
        check_read(2, addr_A, "T4:C2CTransfer");
        check_read(0, addr_A, "T4:Core0PostDowngrade");

        // ── TEST 5: Dirty eviction ─────────────────────────────────────────────
        $display("\n--- TEST 5: Dirty eviction ---");
        wdata = 32'hC0DE_CAFE;
        shadow_write_word(addr_A, wdata, 4'hF);
        do_op(0, addr_A, 1'b1, wdata, 4'hF);
        total_writes++;
        // Access aliasing address (same index, different tag) to force eviction
        addr_evict = addr_A + (1 << (2 + $clog2(BLOCK_SIZE) + $clog2(NUM_LINES)));
        check_read(0, addr_evict, "T5:DirtyEvict");
        check_read(3, addr_A,     "T5:PostEvictRead");

        // ── TEST 6: Random stress ─────────────────────────────────────────────
        $display("\n--- TEST 6: Random stress (%0d ops) ---", NUM_STRESS);
        begin
            logic [ADDR_WIDTH-1:0] stress_pool [0:15];
            int   core_sel;
            logic [ADDR_WIDTH-1:0] s_addr;
            logic                  s_rw;
            logic [DATA_WIDTH-1:0] s_data;
            logic [DATA_WIDTH/8-1:0] s_strb;

            for (int p = 0; p < 16; p++)
                stress_pool[p] = 32'h0000_1000 + (p * 32'h40);

            for (int s = 0; s < NUM_STRESS; s++) begin
                lfsr_stim = lfsr_step(lfsr_stim);
                core_sel  = int'(lfsr_stim[1:0]);
                lfsr_stim = lfsr_step(lfsr_stim);
                s_addr    = stress_pool[lfsr_stim[3:0]];
                lfsr_stim = lfsr_step(lfsr_stim);
                s_addr    = s_addr | ((lfsr_stim[1:0]) << 2);
                lfsr_stim = lfsr_step(lfsr_stim);
                s_rw      = (lfsr_stim[6:0] < 38);

                if (s_rw) begin
                    lfsr_stim = lfsr_step(lfsr_stim);
                    s_data    = lfsr_stim;
                    lfsr_stim = lfsr_step(lfsr_stim);
                    s_strb    = lfsr_stim[3:0] | 4'h1;
                    shadow_write_word(s_addr, s_data, s_strb);
                    do_op(core_sel, s_addr, 1'b1, s_data, s_strb);
                    total_writes++;
                end else begin
                    check_read(core_sel, s_addr, "T6:Stress");
                end
                total_ops++;
            end
        end

        repeat(30) @(posedge clk);

        $display("\n================================================================");
        $display("  MULTI-CORE COHERENCE TEST REPORT");
        $display("================================================================");
        $display("  Total operations : %0d", total_ops);
        $display("  Reads            : %0d", total_reads);
        $display("  Writes           : %0d", total_writes);
        $display("  Check errors     : %0d", check_errors);
        if (check_errors == 0)
            $display("  Result           : ** PASS - all coherence checks passed **");
        else
            $display("  Result           : ** FAIL - %0d coherence violations **",
                     check_errors);
        $display("================================================================\n");
        $finish;
    end

endmodule