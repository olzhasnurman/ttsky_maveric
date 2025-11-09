/* Copyright (c) 2024 Maveric NU. All rights reserved. */

// -------------------------------------------------------------------
// This is a data cache implemented using 2-way set associative cache.
// -------------------------------------------------------------------

module data_cache
#(
    parameter SET_COUNT      = 2,
              WORD_SIZE      = 32,
              BLOCK_WIDTH    = 512,
              N              = 2,
              ADDR_WIDTH     = 32,
              OUT_ADDR_WIDTH = 32,
              REG_WIDTH      = 32
)
(
    // Control signals.
    input  logic                          clk,
    input  logic                          arst,
    input  logic                          write_en,
    input  logic                          valid_update,
    input  logic                          lru_update,
    input  logic                          block_write_en,

    // Input Interface.
    input  logic [ ADDR_WIDTH     - 1:0 ] i_data_addr,
    input  logic [ REG_WIDTH      - 1:0 ] i_data,
    input  logic [ BLOCK_WIDTH    - 1:0 ] i_data_block,
    input  logic [                  1:0 ] i_store_type,
    input  logic                          i_addr_control,
    input  logic                          i_start_wb,
    input  logic                          i_done_wb,

    // Output Interface.
    output logic [ REG_WIDTH      - 1:0 ] o_data,
    output logic [ BLOCK_WIDTH    - 1:0 ] o_data_block,
    output logic                          o_hit,
    output logic                          o_dirty,
    output logic [ OUT_ADDR_WIDTH - 1:0 ] o_addr_axi,
    output logic                          o_done_fence,
    output logic                          o_store_addr_ma

);
    //-------------------------
    // Local Parameters.
    //-------------------------
    localparam WORD_COUNT     = BLOCK_WIDTH/WORD_SIZE; // 16 bits.

    localparam WORD_OFFSET_W  = $clog2( WORD_COUNT  ); // 4 bits.
    localparam BLOCK_NUMBER_W = $clog2( SET_COUNT );   // 1 bits.
    localparam BYTE_OFFSET_W  = $clog2( WORD_SIZE/8 ); // 2 bits.

    localparam TAG_MSB         = ADDR_WIDTH - 1;                                 // 63.
    localparam TAG_LSB         = BLOCK_NUMBER_W + WORD_OFFSET_W + BYTE_OFFSET_W; // 7.
    localparam TAG_WIDTH       = TAG_MSB - TAG_LSB + 1;                          // 57
    localparam INDEX_MSB       = TAG_LSB - 1;                                    // 6.
    localparam INDEX_LSB       = WORD_OFFSET_W + BYTE_OFFSET_W;                  // 6.
    localparam WORD_OFFSET_MSB = INDEX_LSB - 1;                                  // 5.
    localparam WORD_OFFSET_LSB = BYTE_OFFSET_W;                                  // 2.



    //------------------------
    // Internal signals.
    //------------------------
    logic [ TAG_MSB         - TAG_LSB        :0 ] s_tag_in;
    logic [ INDEX_MSB       - INDEX_LSB      :0 ] s_index;
    logic [ WORD_OFFSET_MSB - WORD_OFFSET_LSB:0 ] s_word_offset;
    logic [                                 1:0 ] s_byte_offset;

    logic [ $clog2( N ) - 1:0 ] s_lru;
    logic [           N - 1:0 ] s_lru_found;
    logic [           N - 1:0 ] s_hit;

    logic [ OUT_ADDR_WIDTH - 1:0 ] s_addr_wb;
    logic [ OUT_ADDR_WIDTH - 1:0 ] s_addr;
    logic [ OUT_ADDR_WIDTH - 1:0 ] s_addr_axi;

    // Store misalignment signals.
    logic s_store_addr_ma_sh;
    logic s_store_addr_ma_sw;
    logic s_store_addr_ma_sd;



    //-------------------------
    // Continious assignments.
    //-------------------------
    assign s_tag_in      = i_data_addr[ TAG_MSB        :TAG_LSB         ];
    assign s_index       = i_data_addr[ INDEX_MSB      :INDEX_LSB       ];
    assign s_word_offset = i_data_addr[ WORD_OFFSET_MSB:WORD_OFFSET_LSB ];
    assign s_byte_offset = i_data_addr[               1:0               ];


    assign s_store_addr_ma_sh = s_byte_offset[0];
    assign s_store_addr_ma_sw = | s_byte_offset;
    assign s_store_addr_ma_sd = s_store_addr_ma_sw | s_word_offset[0];


    //----------------------------------------
    // Store address misaligned calculation.
    //----------------------------------------
    always_comb begin
        case ( i_store_type )
            2'b11: o_store_addr_ma = s_store_addr_ma_sd; // SD instruction.
            2'b10: o_store_addr_ma = s_store_addr_ma_sw; // SW instruction.
            2'b01: o_store_addr_ma = s_store_addr_ma_sh; // SH instruction.
            2'b00: o_store_addr_ma = 1'b0;               // SB instruction.
            default: o_store_addr_ma = 1'b0;
        endcase
    end



    //-------------------------------------
    // Memory
    //-------------------------------------

    // Tag memory.
    logic [ TAG_WIDTH - 1:0 ] tag_mem [ SET_COUNT - 1:0 ][ N - 1:0 ];

    // Valid & Dirty & LRU memories.
    logic [ SET_COUNT   - 1:0 ] valid_mem [ N - 1:0 ];
    logic [ SET_COUNT   - 1:0 ] dirty_mem [ N - 1:0 ];
    logic [ $clog2( N ) - 1:0 ] lru_mem   [ N - 1:0 ][ SET_COUNT - 1:0 ];
    logic [ SET_COUNT   - 1:0 ] lru_set;

    // Data memory.
    logic [ BLOCK_WIDTH - 1:0 ] data_mem [ SET_COUNT - 1:0 ][ N - 1:0 ];



    //------------------------------
    // Check
    //------------------------------

    // Check for hit.
    logic [ $clog2 (N) - 1:0 ] s_match;
    always_comb begin
        s_hit[0] = valid_mem[ 0 ][ s_index ] & ( tag_mem [ s_index ][ 0 ] == s_tag_in );
        s_hit[1] = valid_mem[ 1 ][ s_index ] & ( tag_mem [ s_index ][ 1 ] == s_tag_in );

        o_hit = | s_hit;

        if ( o_hit ) begin
            casez ( s_hit )
                2'bz1: s_match = 1'b0;
                2'b10: s_match = 1'b1;
                default: s_match = 1'b0;
            endcase

        end
        else s_match = s_lru;
    end

    // Find LRU.
    always_comb begin
        s_lru_found[0] = lru_mem[0][ s_index ] == 1'b0;
        s_lru_found[1] = lru_mem[1][ s_index ] == 1'b0;

        casez ( s_lru_found )
            2'bz1: s_lru = 1'b0;
            2'b10: s_lru = 1'b1;
            default: s_lru = 1'b0;
        endcase
    end


    //-------------------------
    // Write logic.
    //-------------------------

    // Write data logic.
    always_ff @( posedge clk, posedge arst ) begin
        if ( arst ) begin
            data_mem [ 0 ][ 0 ] <= '0;
            data_mem [ 0 ][ 1 ] <= '0;
            data_mem [ 1 ][ 0 ] <= '0;
            data_mem [ 1 ][ 1 ] <= '0;
            tag_mem  [ 0 ][ 0 ] <= '0;
            tag_mem  [ 0 ][ 1 ] <= '0;
            tag_mem  [ 1 ][ 0 ] <= '0;
            tag_mem  [ 1 ][ 1 ] <= '0;
        end
        else if (write_en) begin
            case (i_store_type)
            /* verilator lint_off WIDTH */
                2'b10: data_mem[s_index][s_match][(( s_word_offset                       + 1) * 32 - 1) -: 32] <= i_data[31:0]; // SW Instruction.
                2'b01: data_mem[s_index][s_match][(({s_word_offset, s_byte_offset [1]}   + 1) * 16 - 1) -: 16] <= i_data[15:0]; // SH Instruction.
                2'b00: data_mem[s_index][s_match][(({s_word_offset, s_byte_offset      } + 1) * 8  - 1) -: 8 ] <= i_data[ 7:0]; // SB Instruction.
                default: data_mem[s_index][s_match] <= data_mem [s_index][s_match];
            endcase
        end
        else if ( block_write_en ) begin
            data_mem[ s_index ][ s_lru ] <= i_data_block;
            tag_mem [ s_index ][ s_lru ] <= s_tag_in;
        end
    end

    // Modify dirty bit.
    always_ff @( posedge clk, posedge arst ) begin
        if ( arst ) begin
            // For 2-way set associative cache.
            dirty_mem [ 0 ] <= '0;
            dirty_mem [ 1 ] <= '0;
        end
        else if ( write_en       ) dirty_mem[ s_match    ][ s_index    ] <= 1'b1;
        else if ( block_write_en ) dirty_mem[ s_lru      ][ s_index    ] <= 1'b0;
        else if ( i_done_wb      ) dirty_mem[ s_count[1] ][ s_count[0] ] <= 1'b0;
    end

    // Write valid bit.
    always_ff @( posedge clk, posedge arst ) begin
        if ( arst ) begin
            // For 2-way set associative cache.
            valid_mem [ 0 ] <= '0;
            valid_mem [ 1 ] <= '0;
        end
        else if ( valid_update ) begin
            valid_mem[ s_lru ][ s_index ] <= 1'b1;
        end
    end

    // Write LRU set.
    always_ff @( posedge clk, posedge arst ) begin
        if ( arst ) begin
            lru_set <= '0;
        end
        else if ( lru_update ) begin
            lru_set[ s_index ] <= 1'b1;
        end
    end

    // Write LRU.
    integer j;
    always_ff @( posedge clk, posedge arst ) begin
        if ( arst ) begin
            lru_mem [ 0 ][ 0 ] <= 1'b0;
            lru_mem [ 1 ][ 0 ] <= 1'b1;
            lru_mem [ 0 ][ 1 ] <= 1'b0;
            lru_mem [ 1 ][ 1 ] <= 1'b1;
        end
        else if ( lru_update ) begin
                lru_mem[ s_match ][ s_index ] <= 1'b1;
                for ( j = 0; j < N; j++ ) begin
                    if ( lru_mem[ j ][ s_index ] > lru_mem[ s_match ][ s_index ] ) begin
                        lru_mem[ j ][ s_index ] <= lru_mem[ j ][ s_index ] - 1'b1;
                    end
                end
        end
        else if ( ~ lru_set[ s_index ] ) begin
            // For 4-way set associative cache.
            lru_mem [ 0 ][ s_index ] <= 1'b0;
            lru_mem [ 1 ][ s_index ] <= 1'b1;
        end
    end



    //------------------------
    // Read logic.
    //------------------------

    // Read word.
    always_comb begin
        case ( s_word_offset )
            4'b0000: o_data = data_mem[ s_index ][ s_match ][ 31 :0   ];
            4'b0001: o_data = data_mem[ s_index ][ s_match ][ 63 :32  ];
            4'b0010: o_data = data_mem[ s_index ][ s_match ][ 95 :64  ];
            4'b0011: o_data = data_mem[ s_index ][ s_match ][ 127:96  ];
            4'b0100: o_data = data_mem[ s_index ][ s_match ][ 159:128 ];
            4'b0101: o_data = data_mem[ s_index ][ s_match ][ 191:160 ];
            4'b0110: o_data = data_mem[ s_index ][ s_match ][ 223:192 ];
            4'b0111: o_data = data_mem[ s_index ][ s_match ][ 255:224 ];
            4'b1000: o_data = data_mem[ s_index ][ s_match ][ 287:256 ];
            4'b1001: o_data = data_mem[ s_index ][ s_match ][ 319:288 ];
            4'b1010: o_data = data_mem[ s_index ][ s_match ][ 351:320 ];
            4'b1011: o_data = data_mem[ s_index ][ s_match ][ 383:352 ];
            4'b1100: o_data = data_mem[ s_index ][ s_match ][ 415:384 ];
            4'b1101: o_data = data_mem[ s_index ][ s_match ][ 447:416 ];
            4'b1110: o_data = data_mem[ s_index ][ s_match ][ 479:448 ];
            4'b1111: o_data = data_mem[ s_index ][ s_match ][ 511:480 ];
            default: o_data = '0;
        endcase
    end

    //Read dirty bit.
    assign o_dirty      = i_start_wb ? dirty_mem[ s_count[1] ][ s_count[0] ] : dirty_mem[ s_lru ][ s_index ];
    assign o_data_block = i_start_wb ? data_mem[ s_count[0] ][ s_count[1] ]  : data_mem[ s_index ][ s_lru ];
    assign s_addr_wb    = { tag_mem[ s_index ][ s_lru ][ OUT_ADDR_WIDTH - 8:0 ], s_index, 6'b0 };
    assign s_addr       = { i_data_addr[ OUT_ADDR_WIDTH - 1:INDEX_LSB ], 6'b0 };
    assign s_addr_axi   = i_addr_control ? s_addr : s_addr_wb;
    assign o_addr_axi   = i_start_wb ? { tag_mem[ s_count[0] ][ s_count[1] ][ OUT_ADDR_WIDTH - 8:0 ], s_count[0] , 6'b0 } : s_addr_axi;

    logic [ 1:0 ] s_count;

    always_ff @( posedge clk, posedge arst ) begin
        if      ( arst      ) s_count <= '0;
        else if ( i_done_wb ) s_count <= s_count + 2'b1;
    end

    assign o_done_fence = i_done_wb & ( s_count == 2'b11 );

endmodule
