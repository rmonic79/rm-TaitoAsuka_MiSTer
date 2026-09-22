/*  This file is part of Darius_MiSTer.

    Author: Umberto Parisi (rmonic79)
    Date: 2026-04-16
*/

// scn_line_buffer — ping-pong line buffer 13MHz→24MHz per TC0100SCN.
//
// Il chip TC0100SCN gira a ce_13m (13.33 MHz) e produce 320 pixel visibili
// per linea (hcnt_actual 25..344). Il compositor gira a ce_pix (24 MHz) e
// mostra 288 pixel per pannello. I due domini NON sono in fase ratio intero
// (24/13.33 = 1.8), quindi campionare SC live produce gap + tremolio.
//
// Soluzione: 2 line buffer ping-pong. Uno scritto dal chip, l'altro letto
// dal compositor. Swap su "end-of-line" del chip (IHLD rising edge).
//
// Dimensione: 512 word per buffer (overkill ma safe; chip emette max ~345).
// Width: 15-bit SC (priority + color).

module scn_line_buffer (
    input  wire        clk,          // 96 MHz global
    input  wire        reset,

    // Write side — chip domain (ce_13m + chip counter)
    input  wire        wr_ce,        // ce_13m pulse
    input  wire        wr_line_end,  // 1-cycle pulse at end of line (IHLD rising)
    input  wire [8:0]  wr_x,         // pixel index (hcnt_actual)
    input  wire        wr_valid,     // write enable (chip active area)
    input  wire [14:0] wr_sc,        // SC[14:0] from chip

    // Read side — compositor domain
    input  wire        rd_ce,        // ce_pix pulse (unused here, read is combinatorial)
    input  wire [8:0]  rd_x,         // panel-local index 0..287
    output wire [14:0] rd_sc
);

// Two buffers, 512 entry 15-bit. Single-port R/W each, ping-pong by sel.
// Inferred as M10K (512x15 = 7680 bits, fits in one M10K block).
(* ramstyle = "M10K" *) reg [14:0] buf0 [0:511];
(* ramstyle = "M10K" *) reg [14:0] buf1 [0:511];

reg wr_sel;  // which buffer is being written this line
wire rd_sel = ~wr_sel;  // the other one is read

// Registered read outputs from each buffer (M10K inference requires synchronous
// read port, one always block per RAM). Mux the registered outputs combinatorially.
reg [14:0] buf0_rd_r, buf1_rd_r;
reg        rd_sel_r;

assign rd_sc = rd_sel_r ? buf1_rd_r : buf0_rd_r;

// Clear FSM post-reset: 512 cicli azzerano buf0 e buf1.
// Finche' init_done=0 entrambi i buffer sono in "clear mode".
reg [9:0] init_cnt;  // 0..512
wire      init_done = init_cnt[9];  // 1 quando cnt >= 512

always @(posedge clk) begin
    if (reset) begin
        wr_sel   <= 1'b0;
        init_cnt <= 10'd0;
    end else begin
        if (!init_done) init_cnt <= init_cnt + 10'd1;
        if (wr_line_end) wr_sel <= ~wr_sel;
    end
end

// buf0: clear mode scrive 0 su init_cnt[8:0], runtime scrive wr_sc
wire [8:0] buf0_waddr = init_done ? wr_x : init_cnt[8:0];
wire [14:0] buf0_wdata = init_done ? wr_sc : 15'd0;
wire        buf0_we    = init_done ? (wr_ce && wr_valid && ~wr_sel) : 1'b1;
always @(posedge clk) begin
    if (buf0_we) buf0[buf0_waddr] <= buf0_wdata;
    buf0_rd_r <= buf0[rd_x];
end

wire [8:0] buf1_waddr = init_done ? wr_x : init_cnt[8:0];
wire [14:0] buf1_wdata = init_done ? wr_sc : 15'd0;
wire        buf1_we    = init_done ? (wr_ce && wr_valid && wr_sel) : 1'b1;
always @(posedge clk) begin
    if (buf1_we) buf1[buf1_waddr] <= buf1_wdata;
    buf1_rd_r <= buf1[rd_x];
end

// Delay rd_sel by 1 cycle to align with registered read output.
always @(posedge clk) begin
    rd_sel_r <= rd_sel;
end

endmodule
