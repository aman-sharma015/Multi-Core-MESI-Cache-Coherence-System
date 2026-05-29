package mesi_pkg;

    typedef enum logic [1:0] {
        MESI_M = 2'b11,
        MESI_E = 2'b10,
        MESI_S = 2'b01,
        MESI_I = 2'b00
    } mesi_state_t;

    typedef enum logic [2:0] {
        BUS_NONE  = 3'b000,
        BUS_READ  = 3'b001,
        BUS_READX = 3'b010,
        BUS_UPGR  = 3'b011,
        BUS_WB    = 3'b100,
        BUS_FLUSH = 3'b101
    } bus_txn_t;

    typedef enum logic [1:0] {
        SNP_NONE  = 2'b00,
        SNP_ACK   = 2'b01,
        SNP_SHARE = 2'b10,
        SNP_FLUSH = 2'b11
    } snoop_resp_t;

endpackage

import mesi_pkg::*;

module cache_controller #(
    parameter integer ADDR_WIDTH  = 32,
    parameter integer DATA_WIDTH  = 32,
    parameter integer BLOCK_SIZE  = 4,
    parameter integer NUM_LINES   = 1024,
    parameter integer CORE_ID     = 0
) (
    input  logic                             clk,
    input  logic                             rst_n,

    input  logic [ADDR_WIDTH-1:0]            cpu_req_addr,
    input  logic [DATA_WIDTH-1:0]            cpu_req_datain,
    input  logic [DATA_WIDTH/8-1:0]          cpu_req_wstrb,
    input  logic                             cpu_req_rw,
    input  logic                             cpu_req_valid,
    output logic [DATA_WIDTH-1:0]            cpu_req_dataout,
    output logic                             cache_ready,

    output logic [ADDR_WIDTH-1:0]            bus_req_addr,
    output bus_txn_t                         bus_req_type,
    output logic                             bus_req_valid,

    input  logic [ADDR_WIDTH-1:0]            bus_bcast_addr,
    input  bus_txn_t                         bus_bcast_type,
    input  logic                             bus_bcast_valid,
    input  logic [DATA_WIDTH*BLOCK_SIZE-1:0] bus_bcast_data,
    input  logic                             bus_bcast_from_mem,

    output snoop_resp_t                      snoop_resp,
    output logic [DATA_WIDTH*BLOCK_SIZE-1:0] snoop_data,

    input  logic                             my_cache_done
);

    localparam integer LINE_WIDTH      = DATA_WIDTH * BLOCK_SIZE;
    localparam integer WORD_BYTE_BITS  = $clog2(DATA_WIDTH / 8);
    localparam integer BLK_OFFSET_BITS = $clog2(BLOCK_SIZE);
    localparam integer INDEX_BITS      = $clog2(NUM_LINES);
    localparam integer TAG_BITS        = ADDR_WIDTH - INDEX_BITS
                                         - BLK_OFFSET_BITS - WORD_BYTE_BITS;

    localparam integer TM_TAG_LO    = 0;
    localparam integer TM_TAG_HI    = TAG_BITS - 1;
    localparam integer TM_DIRTY     = TAG_BITS;
    localparam integer TM_STATE_LO  = TAG_BITS + 1;
    localparam integer TM_STATE_HI  = TAG_BITS + 2;
    localparam integer TM_VALID     = TAG_BITS + 3;
    localparam integer TAG_MEM_WIDTH = TAG_BITS + 4;

    localparam integer BLK_LO = WORD_BYTE_BITS;
    localparam integer BLK_HI = WORD_BYTE_BITS + BLK_OFFSET_BITS - 1;
    localparam integer IDX_LO = BLK_HI + 1;
    localparam integer IDX_HI = IDX_LO + INDEX_BITS - 1;
    localparam integer TAG_LO = IDX_HI + 1;
    localparam integer TAG_HI = ADDR_WIDTH - 1;

    typedef enum logic [1:0] {
        IDLE        = 2'd0,
        COMPARE_TAG = 2'd1,
        ALLOCATE    = 2'd2,
        WRITE_BACK  = 2'd3
    } state_t;

    logic [TAG_MEM_WIDTH-1:0] tag_mem  [0:NUM_LINES-1];
    logic [LINE_WIDTH-1:0]    data_mem [0:NUM_LINES-1];

    state_t                      present_state;
    logic [ADDR_WIDTH-1:0]       cpu_req_addr_reg;
    logic [DATA_WIDTH-1:0]       cpu_req_datain_reg;
    logic [DATA_WIDTH/8-1:0]     cpu_req_wstrb_reg;
    logic                        cpu_req_rw_reg;

    logic [TAG_BITS-1:0]         cpu_addr_tag;
    logic [INDEX_BITS-1:0]       cpu_addr_index;
    logic [BLK_OFFSET_BITS-1:0]  cpu_addr_blkof;

    assign cpu_addr_tag   = cpu_req_addr_reg[TAG_HI:TAG_LO];
    assign cpu_addr_index = cpu_req_addr_reg[IDX_HI:IDX_LO];
    assign cpu_addr_blkof = cpu_req_addr_reg[BLK_HI:BLK_LO];

    logic [TAG_MEM_WIDTH-1:0]    tag_entry;
    logic [LINE_WIDTH-1:0]       data_entry;
    logic                        tag_valid;
    mesi_state_t                 tag_mesi;
    logic [TAG_BITS-1:0]         tag_stored;
    logic                        hit;

    assign tag_entry  = tag_mem [cpu_addr_index];
    assign data_entry = data_mem[cpu_addr_index];
    assign tag_valid  = tag_entry[TM_VALID];
    assign tag_mesi   = mesi_state_t'(tag_entry[TM_STATE_HI:TM_STATE_LO]);
    assign tag_stored = tag_entry[TM_TAG_HI:TM_TAG_LO];
    assign hit        = tag_valid && (cpu_addr_tag == tag_stored)
                        && (tag_mesi != MESI_I);

    logic [ADDR_WIDTH-1:0] cur_line_addr;
    assign cur_line_addr = { cpu_addr_tag, cpu_addr_index,
                             {(BLK_OFFSET_BITS+WORD_BYTE_BITS){1'b0}} };

    logic [DATA_WIDTH-1:0] cache_read_data;
    assign cache_read_data = data_entry[cpu_addr_blkof * DATA_WIDTH +: DATA_WIDTH];

    function automatic logic [LINE_WIDTH-1:0] apply_wstrb(
        input logic [LINE_WIDTH-1:0]      line_in,
        input logic [DATA_WIDTH-1:0]      wdata,
        input logic [DATA_WIDTH/8-1:0]    wstrb,
        input logic [BLK_OFFSET_BITS-1:0] blk_offset
    );
        logic [LINE_WIDTH-1:0] result;
        result = line_in;
        for (int b = 0; b < DATA_WIDTH/8; b++) begin
            if (wstrb[b])
                result[(blk_offset * DATA_WIDTH) + b*8 +: 8] = wdata[b*8 +: 8];
        end
        return result;
    endfunction

    logic [INDEX_BITS-1:0]    snp_index;
    logic [TAG_BITS-1:0]      snp_tag;
    logic [TAG_MEM_WIDTH-1:0] snp_tag_entry;
    mesi_state_t              snp_mesi;
    logic [TAG_BITS-1:0]      snp_stored_tag;
    logic                     snp_valid;
    logic                     snp_hit;

    assign snp_index      = bus_bcast_addr[IDX_HI:IDX_LO];
    assign snp_tag        = bus_bcast_addr[TAG_HI:TAG_LO];
    assign snp_tag_entry  = tag_mem[snp_index];
    assign snp_mesi       = mesi_state_t'(snp_tag_entry[TM_STATE_HI:TM_STATE_LO]);
    assign snp_stored_tag = snp_tag_entry[TM_TAG_HI:TM_TAG_LO];
    assign snp_valid      = snp_tag_entry[TM_VALID];
    assign snp_hit        = snp_valid && (snp_tag == snp_stored_tag)
                            && (snp_mesi != MESI_I);

    state_t         next_state;
    logic           write_datamem_mem;
    logic           write_datamem_cpu;
    logic [LINE_WIDTH-1:0] cpu_write_line;
    logic           tagmem_enable;
    logic           tagmem_snoop_enable;
    mesi_state_t    next_mesi;
    mesi_state_t    snoop_next_mesi;
    logic [INDEX_BITS-1:0] tagmem_snoop_idx;

    logic [DATA_WIDTH-1:0]   next_cpu_req_dataout;
    logic                    next_cache_ready;
    logic [ADDR_WIDTH-1:0]   next_mem_req_addr;
    logic [LINE_WIDTH-1:0]   next_mem_req_dataout;
    logic                    next_mem_req_rw;
    logic                    next_mem_req_valid;
    logic [ADDR_WIDTH-1:0]   next_cpu_req_addr_reg;
    logic [DATA_WIDTH-1:0]   next_cpu_req_datain_reg;
    logic [DATA_WIDTH/8-1:0] next_cpu_req_wstrb_reg;
    logic                    next_cpu_req_rw_reg;
    logic [ADDR_WIDTH-1:0]   next_bus_req_addr;
    bus_txn_t                next_bus_req_type;
    logic                    next_bus_req_valid;

    logic [ADDR_WIDTH-1:0]   mem_req_addr_r;
    logic [LINE_WIDTH-1:0]   mem_req_dataout_r;
    logic                    mem_req_rw_r;
    logic                    mem_req_valid_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_LINES; i++)
                tag_mem[i] <= '0;
            present_state      <= IDLE;
            cpu_req_dataout    <= '0;
            cache_ready        <= 1'b1;
            mem_req_addr_r     <= '0;
            mem_req_rw_r       <= 1'b0;
            mem_req_valid_r    <= 1'b0;
            mem_req_dataout_r  <= '0;
            cpu_req_addr_reg   <= '0;
            cpu_req_datain_reg <= '0;
            cpu_req_wstrb_reg  <= '0;
            cpu_req_rw_reg     <= 1'b0;
            bus_req_addr       <= '0;
            bus_req_type       <= BUS_NONE;
            bus_req_valid      <= 1'b0;
        end else begin
            if (tagmem_enable)
                tag_mem[cpu_addr_index] <= {
                    1'b1,
                    next_mesi,
                    (next_mesi == MESI_M),
                    cpu_addr_tag
                };

            if (tagmem_snoop_enable && !(tagmem_enable &&
                    (tagmem_snoop_idx == cpu_addr_index)))
                tag_mem[tagmem_snoop_idx] <= {
                    (snoop_next_mesi != MESI_I),
                    snoop_next_mesi,
                    (snoop_next_mesi == MESI_M),
                    snp_tag
                };

            if (write_datamem_mem)
                data_mem[cpu_addr_index] <= bus_bcast_data;
            else if (write_datamem_cpu)
                data_mem[cpu_addr_index] <= cpu_write_line;

            present_state      <= next_state;
            cpu_req_dataout    <= next_cpu_req_dataout;
            cache_ready        <= next_cache_ready;
            mem_req_addr_r     <= next_mem_req_addr;
            mem_req_rw_r       <= next_mem_req_rw;
            mem_req_valid_r    <= next_mem_req_valid;
            mem_req_dataout_r  <= next_mem_req_dataout;
            cpu_req_addr_reg   <= next_cpu_req_addr_reg;
            cpu_req_datain_reg <= next_cpu_req_datain_reg;
            cpu_req_wstrb_reg  <= next_cpu_req_wstrb_reg;
            cpu_req_rw_reg     <= next_cpu_req_rw_reg;
            bus_req_addr       <= next_bus_req_addr;
            bus_req_type       <= next_bus_req_type;
            bus_req_valid      <= next_bus_req_valid;
        end
    end

    always_comb begin
        write_datamem_mem     = 1'b0;
        write_datamem_cpu     = 1'b0;
        cpu_write_line        = data_entry;
        tagmem_enable         = 1'b0;
        tagmem_snoop_enable   = 1'b0;
        next_mesi             = MESI_I;
        snoop_next_mesi       = MESI_I;
        tagmem_snoop_idx      = snp_index;

        next_state            = present_state;
        next_cpu_req_dataout  = cpu_req_dataout;
        next_cache_ready      = 1'b0;

        next_mem_req_addr     = mem_req_addr_r;
        next_mem_req_rw       = mem_req_rw_r;
        next_mem_req_valid    = mem_req_valid_r;
        next_mem_req_dataout  = mem_req_dataout_r;

        next_cpu_req_addr_reg   = cpu_req_addr_reg;
        next_cpu_req_datain_reg = cpu_req_datain_reg;
        next_cpu_req_wstrb_reg  = cpu_req_wstrb_reg;
        next_cpu_req_rw_reg     = cpu_req_rw_reg;

        next_bus_req_addr  = bus_req_addr;
        next_bus_req_type  = BUS_NONE;
        next_bus_req_valid = 1'b0;

        snoop_resp = SNP_NONE;
        snoop_data = '0;

        if (bus_bcast_valid &&
            !(present_state == WRITE_BACK && bus_req_type != BUS_UPGR))
        begin
            case (bus_bcast_type)
                BUS_READ: begin
                    if (snp_hit) begin
                        case (snp_mesi)
                            MESI_M: begin
                                snoop_resp          = SNP_FLUSH;
                                snoop_data          = data_mem[snp_index];
                                snoop_next_mesi     = MESI_S;
                                tagmem_snoop_enable = 1'b1;
                            end
                            MESI_E: begin
                                snoop_resp          = SNP_SHARE;
                                snoop_next_mesi     = MESI_S;
                                tagmem_snoop_enable = 1'b1;
                            end
                            MESI_S: begin
                                snoop_resp = SNP_SHARE;
                            end
                            default: ;
                        endcase
                    end
                end

                BUS_READX: begin
                    if (snp_hit) begin
                        case (snp_mesi)
                            MESI_M: begin
                                snoop_resp          = SNP_FLUSH;
                                snoop_data          = data_mem[snp_index];
                                snoop_next_mesi     = MESI_I;
                                tagmem_snoop_enable = 1'b1;
                            end
                            MESI_E, MESI_S: begin
                                snoop_resp          = SNP_ACK;
                                snoop_next_mesi     = MESI_I;
                                tagmem_snoop_enable = 1'b1;
                            end
                            default: ;
                        endcase
                    end
                end

                BUS_UPGR: begin
                    if (snp_hit && snp_mesi == MESI_S) begin
                        snoop_resp          = SNP_ACK;
                        snoop_next_mesi     = MESI_I;
                        tagmem_snoop_enable = 1'b1;
                    end
                end

                BUS_WB: begin
                    if (snp_hit) begin
                        case (snp_mesi)
                            MESI_M: begin
                                snoop_resp          = SNP_FLUSH;
                                snoop_data          = data_mem[snp_index];
                                snoop_next_mesi     = MESI_I;
                                tagmem_snoop_enable = 1'b1;
                            end
                            MESI_E, MESI_S: begin
                                snoop_next_mesi     = MESI_I;
                                tagmem_snoop_enable = 1'b1;
                            end
                            default: ;
                        endcase
                    end
                end

                default: ;
            endcase
        end

        case (present_state)
            IDLE: begin
                next_cache_ready = 1'b1;
                if (cpu_req_valid) begin
                    next_cpu_req_addr_reg   = cpu_req_addr;
                    next_cpu_req_datain_reg = cpu_req_datain;
                    next_cpu_req_wstrb_reg  = cpu_req_wstrb;
                    next_cpu_req_rw_reg     = cpu_req_rw;
                    next_cache_ready        = 1'b0;
                    next_state              = COMPARE_TAG;
                end
            end

            COMPARE_TAG: begin
                if (hit) begin
                    if (!cpu_req_rw_reg) begin
                        next_cpu_req_dataout = cache_read_data;
                        next_cache_ready     = 1'b1;
                        next_state           = IDLE;
                    end else begin
                        case (tag_mesi)
                            MESI_M: begin
                                cpu_write_line    = apply_wstrb(data_entry,
                                                        cpu_req_datain_reg,
                                                        cpu_req_wstrb_reg,
                                                        cpu_addr_blkof);
                                write_datamem_cpu = 1'b1;
                                tagmem_enable     = 1'b1;
                                next_mesi         = MESI_M;
                                next_cache_ready  = 1'b1;
                                next_state        = IDLE;
                            end

                            MESI_E: begin
                                if (tagmem_snoop_enable &&
                                        (tagmem_snoop_idx == cpu_addr_index)) begin
                                    next_bus_req_addr  = cur_line_addr;
                                    next_bus_req_type  = BUS_UPGR;
                                    next_bus_req_valid = 1'b1;
                                    next_state         = WRITE_BACK;
                                end else begin
                                    cpu_write_line    = apply_wstrb(data_entry,
                                                            cpu_req_datain_reg,
                                                            cpu_req_wstrb_reg,
                                                            cpu_addr_blkof);
                                    write_datamem_cpu = 1'b1;
                                    tagmem_enable     = 1'b1;
                                    next_mesi         = MESI_M;
                                    next_cache_ready  = 1'b1;
                                    next_state        = IDLE;
                                end
                            end

                            MESI_S: begin
                                next_bus_req_addr  = cur_line_addr;
                                next_bus_req_type  = BUS_UPGR;
                                next_bus_req_valid = 1'b1;
                                next_state         = WRITE_BACK;
                            end
                            default: ;
                        endcase
                    end
                end else begin
                    begin
                        logic [ADDR_WIDTH-1:0] evict_addr_loc;
                        evict_addr_loc = { tag_stored, cpu_addr_index,
                                           {(BLK_OFFSET_BITS+WORD_BYTE_BITS){1'b0}} };

                        if (tag_valid && (tag_mesi == MESI_M)) begin
                            next_bus_req_addr    = evict_addr_loc;
                            next_bus_req_type    = BUS_WB;
                            next_bus_req_valid   = 1'b1;
                            next_mem_req_valid   = 1'b0;
                            next_state           = WRITE_BACK;
                        end else begin
                            next_bus_req_addr  = cur_line_addr;
                            next_bus_req_type  = cpu_req_rw_reg ? BUS_READX : BUS_READ;
                            next_bus_req_valid = 1'b1;
                            next_mem_req_addr  = cur_line_addr;
                            next_mem_req_rw    = 1'b0;
                            next_mem_req_valid = 1'b1;
                            next_state         = ALLOCATE;
                        end
                    end
                end
            end

            WRITE_BACK: begin
                if (bus_req_type == BUS_UPGR) begin
                    if (my_cache_done) begin
                        next_bus_req_addr  = '0;
                        next_bus_req_type  = BUS_NONE;
                        next_bus_req_valid = 1'b0;
                        cpu_write_line    = apply_wstrb(data_entry,
                                                cpu_req_datain_reg,
                                                cpu_req_wstrb_reg,
                                                cpu_addr_blkof);
                        write_datamem_cpu = 1'b1;
                        tagmem_enable     = 1'b1;
                        next_mesi         = MESI_M;
                        next_cache_ready  = 1'b1;
                        next_state        = IDLE;
                    end
                end else begin
                    if (my_cache_done) begin
                        next_bus_req_addr  = cur_line_addr;
                        next_bus_req_type  = cpu_req_rw_reg ? BUS_READX : BUS_READ;
                        next_bus_req_valid = 1'b1;
                        next_mem_req_valid = 1'b0;
                        next_mem_req_addr  = cur_line_addr;
                        next_mem_req_rw    = 1'b0;
                        next_state         = ALLOCATE;
                    end
                end
            end

            ALLOCATE: begin
                if (!mem_req_valid_r) begin
                    next_mem_req_addr  = cur_line_addr;
                    next_mem_req_rw    = 1'b0;
                    next_mem_req_valid = 1'b1;
                end else if (my_cache_done) begin
                    next_mem_req_valid  = 1'b0;
                    next_bus_req_valid  = 1'b0;
                    next_bus_req_type   = BUS_NONE;
                    next_bus_req_addr   = '0;
                    write_datamem_mem   = 1'b1;
                    tagmem_enable       = 1'b1;
                    if (cpu_req_rw_reg)
                        next_mesi = MESI_M;
                    else
                        next_mesi = bus_bcast_from_mem ? MESI_E : MESI_S;
                    next_state = COMPARE_TAG;
                end
            end

            default: next_state = IDLE;
        endcase
    end

endmodule

module bus_controller #(
    parameter integer NUM_CORES   = 4,
    parameter integer ADDR_WIDTH  = 32,
    parameter integer DATA_WIDTH  = 32,
    parameter integer BLOCK_SIZE  = 4
) (
    input  logic clk,
    input  logic rst_n,

    input  logic [ADDR_WIDTH-1:0]            bus_req_addr  [0:NUM_CORES-1],
    input  mesi_pkg::bus_txn_t               bus_req_type  [0:NUM_CORES-1],
    input  logic                             bus_req_valid [0:NUM_CORES-1],

    input  mesi_pkg::snoop_resp_t            snoop_resp    [0:NUM_CORES-1],
    input  logic [DATA_WIDTH*BLOCK_SIZE-1:0] snoop_data    [0:NUM_CORES-1],

    output logic [ADDR_WIDTH-1:0]            bus_bcast_addr,
    output mesi_pkg::bus_txn_t               bus_bcast_type,
    output logic                             bus_bcast_valid,
    output logic [DATA_WIDTH*BLOCK_SIZE-1:0] bus_bcast_data,
    output logic                             bus_bcast_from_mem,

    output logic                             cache_done    [0:NUM_CORES-1],

    output logic [ADDR_WIDTH-1:0]            mem_req_addr,
    output logic [DATA_WIDTH*BLOCK_SIZE-1:0] mem_req_dataout,
    output logic                             mem_req_rw,
    output logic                             mem_req_valid,
    input  logic [DATA_WIDTH*BLOCK_SIZE-1:0] mem_req_datain,
    input  logic                             mem_req_done
);
    import mesi_pkg::*;

    localparam integer LINE_WIDTH = DATA_WIDTH * BLOCK_SIZE;
    localparam integer CORE_BITS  = $clog2(NUM_CORES);

    typedef enum logic [2:0] {
        ARB_IDLE       = 3'b000,
        ARB_SNOOP      = 3'b001,
        ARB_SNOOP_WAIT = 3'b010,
        ARB_MEM        = 3'b011,
        ARB_MEM_DONE   = 3'b100
    } arb_state_t;

    arb_state_t               arb_state;
    logic [CORE_BITS-1:0]     rr_ptr;
    logic [CORE_BITS-1:0]     winner;
    logic                     winner_valid;
    logic [CORE_BITS-1:0]     active_core;

    logic any_flush, any_share;
    logic [CORE_BITS-1:0] flush_src;
    logic flush_src_valid;

    always_comb begin
        winner       = '0;
        winner_valid = 1'b0;
        for (int i = 0; i < NUM_CORES; i++) begin
            int idx;
            idx = (rr_ptr + i) % NUM_CORES;
            if (bus_req_valid[idx] && !winner_valid) begin
                winner       = idx[CORE_BITS-1:0];
                winner_valid = 1'b1;
            end
        end
    end

    always_comb begin
        any_flush       = 1'b0;
        any_share       = 1'b0;
        flush_src       = '0;
        flush_src_valid = 1'b0;
        for (int i = 0; i < NUM_CORES; i++) begin
            if (snoop_resp[i] == SNP_FLUSH) begin
                any_flush       = 1'b1;
                flush_src       = i[CORE_BITS-1:0];
                flush_src_valid = 1'b1;
            end
            if (snoop_resp[i] == SNP_SHARE) any_share = 1'b1;
        end
    end

    logic [LINE_WIDTH-1:0] bcast_data_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            arb_state          <= ARB_IDLE;
            rr_ptr             <= '0;
            active_core        <= '0;
            bus_bcast_addr     <= '0;
            bus_bcast_type     <= BUS_NONE;
            bus_bcast_valid    <= 1'b0;
            bus_bcast_data     <= '0;
            bcast_data_reg     <= '0;
            bus_bcast_from_mem <= 1'b1;
            for (int i = 0; i < NUM_CORES; i++)
                cache_done[i]  <= 1'b0;
            mem_req_addr       <= '0;
            mem_req_dataout    <= '0;
            mem_req_rw         <= 1'b0;
            mem_req_valid      <= 1'b0;
        end else begin
            for (int i = 0; i < NUM_CORES; i++)
                cache_done[i] <= 1'b0;

            case (arb_state)
                ARB_IDLE: begin
                    bus_bcast_valid <= 1'b0;
                    if (winner_valid) begin
                        active_core        <= winner;
                        bus_bcast_addr     <= bus_req_addr[winner];
                        bus_bcast_type     <= bus_req_type[winner];
                        bus_bcast_valid    <= 1'b1;
                        bus_bcast_from_mem <= 1'b1;
                        bus_bcast_data     <= '0;
                        arb_state          <= ARB_SNOOP;
                        rr_ptr             <= (winner + 1) % NUM_CORES;
                    end
                end

                ARB_SNOOP: begin
                    case (bus_bcast_type)
                        BUS_UPGR: begin
                            bus_bcast_valid <= 1'b0;
                            arb_state       <= ARB_SNOOP_WAIT;
                        end

                        BUS_WB: begin
                            if (any_flush && flush_src_valid) begin
                                mem_req_addr    <= bus_bcast_addr;
                                mem_req_dataout <= snoop_data[flush_src];
                                mem_req_rw      <= 1'b1;
                                mem_req_valid   <= 1'b1;
                                arb_state       <= ARB_MEM;
                            end else begin
                                cache_done[active_core] <= 1'b1;
                                bus_bcast_valid         <= 1'b0;
                                arb_state               <= ARB_IDLE;
                            end
                        end

                        BUS_READ, BUS_READX: begin
                            if (any_flush && flush_src_valid) begin
                                bcast_data_reg     <= snoop_data[flush_src];
                                bus_bcast_data     <= snoop_data[flush_src];
                                bus_bcast_from_mem <= 1'b0;
                                mem_req_addr    <= bus_bcast_addr;
                                mem_req_dataout <= snoop_data[flush_src];
                                mem_req_rw      <= 1'b1;
                                mem_req_valid   <= 1'b1;
                                arb_state       <= ARB_MEM;
                            end else begin
                                mem_req_addr    <= bus_bcast_addr;
                                mem_req_rw      <= 1'b0;
                                mem_req_valid   <= 1'b1;
                                arb_state       <= ARB_MEM;
                            end
                        end

                        default: begin
                            bus_bcast_valid <= 1'b0;
                            arb_state       <= ARB_IDLE;
                        end
                    endcase
                end

                ARB_SNOOP_WAIT: begin
                    cache_done[active_core] <= 1'b1;
                    arb_state               <= ARB_IDLE;
                end

                ARB_MEM: begin
                    if (mem_req_done) begin
                        mem_req_valid <= 1'b0;
                        if (!mem_req_rw) begin
                            bcast_data_reg     <= mem_req_datain;
                            bus_bcast_data     <= mem_req_datain;
                            bus_bcast_from_mem <= 1'b1;
                            bus_bcast_valid    <= 1'b0;
                            arb_state          <= ARB_MEM_DONE;
                        end else begin
                            bus_bcast_valid         <= 1'b0;
                            cache_done[active_core] <= 1'b1;
                            arb_state               <= ARB_IDLE;
                        end
                    end
                end

                ARB_MEM_DONE: begin
                    cache_done[active_core] <= 1'b1;
                    arb_state               <= ARB_IDLE;
                end

                default: arb_state <= ARB_IDLE;
            endcase
        end
    end

endmodule

module multicore_top #(
    parameter integer NUM_CORES  = 4,
    parameter integer ADDR_WIDTH = 32,
    parameter integer DATA_WIDTH = 32,
    parameter integer BLOCK_SIZE = 4,
    parameter integer NUM_LINES  = 1024
) (
    input  logic clk,
    input  logic rst_n,

    input  logic [ADDR_WIDTH-1:0]            cpu_req_addr   [0:NUM_CORES-1],
    input  logic [DATA_WIDTH-1:0]            cpu_req_datain [0:NUM_CORES-1],
    input  logic [DATA_WIDTH/8-1:0]          cpu_req_wstrb  [0:NUM_CORES-1],
    input  logic                             cpu_req_rw     [0:NUM_CORES-1],
    input  logic                             cpu_req_valid  [0:NUM_CORES-1],
    output logic [DATA_WIDTH-1:0]            cpu_req_dataout[0:NUM_CORES-1],
    output logic                             cache_ready    [0:NUM_CORES-1],

    output logic [ADDR_WIDTH-1:0]            mem_req_addr,
    output logic [DATA_WIDTH*BLOCK_SIZE-1:0] mem_req_dataout,
    output logic                             mem_req_rw,
    output logic                             mem_req_valid,
    input  logic [DATA_WIDTH*BLOCK_SIZE-1:0] mem_req_datain,
    input  logic                             mem_req_done
);
    import mesi_pkg::*;

    localparam integer LINE_WIDTH = DATA_WIDTH * BLOCK_SIZE;

    logic [ADDR_WIDTH-1:0]  bus_req_addr  [0:NUM_CORES-1];
    bus_txn_t               bus_req_type  [0:NUM_CORES-1];
    logic                   bus_req_valid [0:NUM_CORES-1];
    snoop_resp_t            snoop_resp    [0:NUM_CORES-1];
    logic [LINE_WIDTH-1:0]  snoop_data    [0:NUM_CORES-1];

    logic [ADDR_WIDTH-1:0]  bus_bcast_addr;
    bus_txn_t               bus_bcast_type;
    logic                   bus_bcast_valid;
    logic [LINE_WIDTH-1:0]  bus_bcast_data;
    logic                   bus_bcast_from_mem;

    logic                   cache_done    [0:NUM_CORES-1];

    generate
        for (genvar g = 0; g < NUM_CORES; g++) begin : gen_cache
            cache_controller #(
                .ADDR_WIDTH (ADDR_WIDTH),
                .DATA_WIDTH (DATA_WIDTH),
                .BLOCK_SIZE (BLOCK_SIZE),
                .NUM_LINES  (NUM_LINES),
                .CORE_ID    (g)
            ) u_cache (
                .clk                 (clk),
                .rst_n               (rst_n),
                .cpu_req_addr        (cpu_req_addr   [g]),
                .cpu_req_datain      (cpu_req_datain [g]),
                .cpu_req_wstrb       (cpu_req_wstrb  [g]),
                .cpu_req_rw          (cpu_req_rw     [g]),
                .cpu_req_valid       (cpu_req_valid  [g]),
                .cpu_req_dataout     (cpu_req_dataout[g]),
                .cache_ready         (cache_ready    [g]),
                .bus_req_addr        (bus_req_addr   [g]),
                .bus_req_type        (bus_req_type   [g]),
                .bus_req_valid       (bus_req_valid  [g]),
                .bus_bcast_addr      (bus_bcast_addr),
                .bus_bcast_type      (bus_bcast_type),
                .bus_bcast_valid     (bus_bcast_valid),
                .bus_bcast_data      (bus_bcast_data),
                .bus_bcast_from_mem  (bus_bcast_from_mem),
                .snoop_resp          (snoop_resp     [g]),
                .snoop_data          (snoop_data     [g]),
                .my_cache_done       (cache_done     [g])
            );
        end
    endgenerate

    bus_controller #(
        .NUM_CORES  (NUM_CORES),
        .ADDR_WIDTH (ADDR_WIDTH),
        .DATA_WIDTH (DATA_WIDTH),
        .BLOCK_SIZE (BLOCK_SIZE)
    ) u_bus_ctrl (
        .clk                 (clk),
        .rst_n               (rst_n),
        .bus_req_addr        (bus_req_addr),
        .bus_req_type        (bus_req_type),
        .bus_req_valid       (bus_req_valid),
        .snoop_resp          (snoop_resp),
        .snoop_data          (snoop_data),
        .bus_bcast_addr      (bus_bcast_addr),
        .bus_bcast_type      (bus_bcast_type),
        .bus_bcast_valid     (bus_bcast_valid),
        .bus_bcast_data      (bus_bcast_data),
        .bus_bcast_from_mem  (bus_bcast_from_mem),
        .cache_done          (cache_done),
        .mem_req_addr        (mem_req_addr),
        .mem_req_dataout     (mem_req_dataout),
        .mem_req_rw          (mem_req_rw),
        .mem_req_valid       (mem_req_valid),
        .mem_req_datain      (mem_req_datain),
        .mem_req_done        (mem_req_done)
    );

endmodule