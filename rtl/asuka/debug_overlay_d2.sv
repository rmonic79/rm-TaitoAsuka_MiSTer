/*  This file is part of Darius2NinjaWarriors_MiSTer.

    Darius2NinjaWarriors_MiSTer is free software: you can redistribute it
    and/or modify it under the terms of the GNU General Public License as
    published by the Free Software Foundation, either version 3 of the
    License, or (at your option) any later version.

    Darius2NinjaWarriors_MiSTer is distributed in the hope that it will be
    useful, but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with Darius2NinjaWarriors_MiSTer.
    If not, see <http://www.gnu.org/licenses/>.

    Author: Umberto Parisi (rmonic79)
    Version: 1.0
    Date: 2026
*/

// debug_overlay_d2.sv — Boot debug overlay for Darius 2.
// Standalone module, zero coupling to game logic.
// All inputs are simple wires — caller connects them.
// Displays latched values (readable at 60Hz).
//
// Layout (2x scaled, 6 rows):
//   Row 0: PC:xxxxxx  AD:xxxxxx   — CPU program counter + current bus address
//   Row 1: ST:x BZ:x DK:xx       — txn_state, bus_busy, dtack_n+ext_dtack_n
//   Row 2: RD:xxxx                — first ROM word read from SDRAM
//   Row 3: RQ:x AK:x PN:x        — sdram req1/ack1/pending (toggle protocol)
//   Row 4: DL:x RY:x RC:x        — download_active, sdram_ready, rom_cache state
//   Row 5: RS:x                   — reset signal state

module debug_overlay_d2 (
	input  wire [9:0]  render_x,
	input  wire [8:0]  render_y,
	input  wire        clk,
	input  wire        reset,

	// Debug inputs — active signals, latched internally
	input  wire [23:0] dbg_pc,
	input  wire [23:0] dbg_bus_addr,
	input  wire [3:0]  dbg_txn_state,
	input  wire        dbg_bus_busy,
	input  wire        dbg_dtack_n,
	input  wire        dbg_ext_dtack_n,
	input  wire [15:0] dbg_rom_word,      // first ROM word from SDRAM
	input  wire        dbg_rom_word_valid, // pulse when first ROM word arrives
	input  wire        dbg_sdram_req1,
	input  wire        dbg_sdram_ack1,
	input  wire        dbg_main_pending,
	input  wire        dbg_download_active,
	input  wire        dbg_sdram_ready,
	input  wire [1:0]  dbg_cache_state,
	input  wire        dbg_reset,
	// Video debug
	input  wire [14:0] dbg_scn0_sc,
	input  wire        dbg_scn0_sc_seen,
	input  wire        dbg_tilerom_req_seen,
	input  wire [15:0] dbg_scn0_wr_cnt,
	input  wire [15:0] dbg_peek_val,
	input  wire        dbg_peek_match,
	// CPU register taps (D6/D7 for DBRA delay-loop diagnosis, D0/A0 for RAM test)
	input  wire [31:0] dbg_d6,
	input  wire [31:0] dbg_d7,
	input  wire [31:0] dbg_d0,
	input  wire [31:0] dbg_a0,
	input  wire [31:0] dbg_a1,
	// Main RAM diag: write count + value read at $0C0000 (first read only)
	input  wire [15:0] dbg_ram_wr_cnt,
	input  wire [15:0] dbg_ram_rd_val,
	// Sub CPU PC
	input  wire [23:0] dbg_sub_pc,

	// Output
	output wire        pixel_on,
	output wire        bg_on
);

// Font character codes
localparam [5:0]
	CH_0=0, CH_1=1, CH_2=2, CH_3=3, CH_4=4, CH_5=5, CH_6=6, CH_7=7,
	CH_8=8, CH_9=9, CH_A=10, CH_B=11, CH_C=12, CH_D=13, CH_E=14, CH_F=15,
	CH_SPC=16, CH_COL=17,
	// Labels (code 18+): A B C D E F G H I K L M N O
	CH_LA=18, CH_LB=19, CH_LC=20, CH_LD=21, CH_LE=22, CH_LF=23,
	CH_LG=24, CH_LH=25, CH_LI=26, CH_LK=27, CH_LL=28, CH_LM=29, CH_LN=30, CH_LO=31,
	// code 32+: P Q R S T U V W X Y
	CH_LP=32, CH_LQ=33, CH_LR=34, CH_LS=35, CH_LT=36, CH_LU=37, CH_LV=38, CH_LW=39, CH_LX=40, CH_LY=41;

// --- Latch values for readability ---
// Update once per frame (at vblank start) so display is stable
reg [23:0] lat_pc, lat_addr;
reg [3:0]  lat_txn;
reg        lat_busy, lat_dtack, lat_ext_dtack;
reg [15:0] lat_rom_word;
reg        lat_rom_captured;
reg        lat_req1, lat_ack1, lat_pending;
reg        lat_dl_active, lat_ready;
reg [1:0]  lat_cache_st;
reg        lat_reset;
reg [14:0] lat_scn0_sc;
reg        lat_sc_seen, lat_trom_seen;
reg [15:0] lat_scn0_wr_cnt;
reg [15:0] lat_peek_val;
reg        lat_peek_match;
reg [31:0] lat_d6, lat_d7, lat_d0, lat_a0, lat_a1;
reg [15:0] lat_ram_wr_cnt, lat_ram_rd_val;
reg [23:0] lat_sub_pc;
reg [23:0] lat_first_pc;
reg        first_pc_captured;
// Latch A1 at first entry into rescue routine ($012BC2-$012CFF) — freezes the
// address of the failing RAM location before the rescue overwrites A1.
reg [31:0] lat_fail_addr;
reg        fail_captured;

wire vblank_start = (render_y == 9'd240) && (render_x == 10'd0);

always @(posedge clk) begin
	if (reset) begin
		lat_pc          <= 24'd0;
		lat_addr        <= 24'd0;
		lat_txn         <= 4'd0;
		lat_busy        <= 0;
		lat_dtack       <= 1;
		lat_ext_dtack   <= 1;
		lat_rom_word    <= 16'hDEAD;
		lat_rom_captured <= 0;
		lat_req1        <= 0;
		lat_ack1        <= 0;
		lat_pending     <= 0;
		lat_dl_active   <= 0;
		lat_ready       <= 0;
		lat_cache_st    <= 0;
		lat_reset       <= 1;
		lat_scn0_sc     <= 15'd0;
		lat_sc_seen     <= 0;
		lat_trom_seen   <= 0;
		lat_scn0_wr_cnt <= 16'd0;
		lat_peek_val    <= 16'd0;
		lat_peek_match  <= 1'b0;
		lat_d6          <= 32'd0;
		lat_d7          <= 32'd0;
		lat_d0          <= 32'd0;
		lat_a0          <= 32'd0;
		lat_a1          <= 32'd0;
		lat_ram_wr_cnt  <= 16'd0;
		lat_ram_rd_val  <= 16'd0;
		lat_sub_pc      <= 24'd0;
		lat_first_pc      <= 24'd0;
		first_pc_captured <= 1'b0;
		lat_fail_addr     <= 32'd0;
		fail_captured     <= 1'b0;
	end else begin
		// Latch first PC seen that's not 0 — ideally $0EB6 (reset vector)
		if (!first_pc_captured && dbg_pc != 24'd0) begin
			lat_first_pc      <= dbg_pc;
			first_pc_captured <= 1'b1;
		end
		// Track last A0 seen while PC was still inside the memtest loop
		// ($012B00..$012BC1). A0 is the LIVE pointer being tested (post-increment),
		// so at fail it shows which chip/area was under test.
		// When PC crosses into rescue ($012BC2+), freeze the last-seen A0.
		if (!fail_captured) begin
			if (dbg_pc >= 24'h012B00 && dbg_pc <= 24'h012BC1) begin
				lat_fail_addr <= dbg_a0;  // live test pointer
			end else if (dbg_pc >= 24'h012BC2 && dbg_pc <= 24'h012CFF) begin
				fail_captured <= 1'b1;
			end
		end
		// Capture first ROM word ever read (one-shot)
		if (dbg_rom_word_valid && !lat_rom_captured) begin
			lat_rom_word     <= dbg_rom_word;
			lat_rom_captured <= 1;
		end

		// Update all other values at vblank
		if (vblank_start) begin
			lat_pc        <= dbg_pc;
			lat_addr      <= dbg_bus_addr;
			lat_txn       <= dbg_txn_state;
			lat_busy      <= dbg_bus_busy;
			lat_dtack     <= dbg_dtack_n;
			lat_ext_dtack <= dbg_ext_dtack_n;
			lat_req1      <= dbg_sdram_req1;
			lat_ack1      <= dbg_sdram_ack1;
			lat_pending   <= dbg_main_pending;
			lat_dl_active <= dbg_download_active;
			lat_ready     <= dbg_sdram_ready;
			lat_cache_st  <= dbg_cache_state;
			lat_reset     <= dbg_reset;
			lat_scn0_sc   <= dbg_scn0_sc;
			lat_sc_seen   <= dbg_scn0_sc_seen;
			lat_trom_seen <= dbg_tilerom_req_seen;
			lat_scn0_wr_cnt <= dbg_scn0_wr_cnt;
			lat_peek_val    <= dbg_peek_val;
			lat_peek_match  <= dbg_peek_match;
			lat_d6          <= dbg_d6;
			lat_d7          <= dbg_d7;
			lat_d0          <= dbg_d0;
			lat_a0          <= dbg_a0;
			lat_a1          <= dbg_a1;
			lat_ram_wr_cnt  <= dbg_ram_wr_cnt;
			lat_ram_rd_val  <= dbg_ram_rd_val;
			lat_sub_pc      <= dbg_sub_pc;
			// After first frame, allow re-capture of ROM word
			// (keeps updating so we see if it changes)
			if (lat_rom_captured) begin
				lat_rom_word <= dbg_rom_word;
			end
		end
	end
end

// --- Overlay geometry ---
// 6 rows × 16px = 96px tall, starting at Y=8, X=4..260
localparam OVL_X0 = 10'd4;
localparam OVL_X1 = 10'd260;
localparam OVL_Y0 = 9'd8;
localparam ROW_H  = 9'd16;
localparam NUM_ROWS = 4'd13;

wire ovl_area = (render_x >= OVL_X0) && (render_x < OVL_X1) &&
                (render_y >= OVL_Y0) && (render_y < (OVL_Y0 + ROW_H * NUM_ROWS));

// Text row and pixel position
wire [8:0] rel_y = render_y - OVL_Y0;
wire [3:0] text_row = rel_y[7:4];  // /16 (4 bits = up to 16 rows)
wire [2:0] font_row = rel_y[3:1];  // 2x vertical scale

wire [9:0] rel_x = render_x - OVL_X0;
// Each character cell = 10px wide (4px font × 2x + 2px gap)
wire [4:0] char_col = rel_x[8:0] / 5'd10;
wire [3:0] pix_in_char = rel_x[8:0] - ({5'd0, char_col} * 5'd10);
wire [1:0] font_col = pix_in_char[2:1];  // 2x horizontal scale
wire       in_glyph = (pix_in_char < 4'd8) && (rel_y[3:0] < 4'd14);

// --- Character decode ---
reg [5:0] char_code;
reg       char_valid;

// Hex nibble helper
function [5:0] hex4(input [3:0] v);
	hex4 = {2'b00, v};
endfunction

always @(*) begin
	char_code = CH_SPC;
	char_valid = 1'b0;
	case (text_row)
		// Row 0: PC:xxxxxx  AD:xxxxxx
		4'd0: case (char_col)
			5'd0:  begin char_code = CH_LP; char_valid = 1; end   // P
			5'd1:  begin char_code = CH_LC; char_valid = 1; end   // C
			5'd2:  begin char_code = CH_COL; char_valid = 1; end  // :
			5'd3:  begin char_code = hex4(lat_pc[23:20]); char_valid = 1; end
			5'd4:  begin char_code = hex4(lat_pc[19:16]); char_valid = 1; end
			5'd5:  begin char_code = hex4(lat_pc[15:12]); char_valid = 1; end
			5'd6:  begin char_code = hex4(lat_pc[11:8]);  char_valid = 1; end
			5'd7:  begin char_code = hex4(lat_pc[7:4]);   char_valid = 1; end
			5'd8:  begin char_code = hex4(lat_pc[3:0]);   char_valid = 1; end
			5'd10: begin char_code = CH_LA; char_valid = 1; end   // A
			5'd11: begin char_code = CH_LD; char_valid = 1; end   // D
			5'd12: begin char_code = CH_COL; char_valid = 1; end  // :
			5'd13: begin char_code = hex4(lat_addr[23:20]); char_valid = 1; end
			5'd14: begin char_code = hex4(lat_addr[19:16]); char_valid = 1; end
			5'd15: begin char_code = hex4(lat_addr[15:12]); char_valid = 1; end
			5'd16: begin char_code = hex4(lat_addr[11:8]);  char_valid = 1; end
			5'd17: begin char_code = hex4(lat_addr[7:4]);   char_valid = 1; end
			5'd18: begin char_code = hex4(lat_addr[3:0]);   char_valid = 1; end
			default: ;
		endcase

		// Row 1: ST:x BZ:x DK:xx
		4'd1: case (char_col)
			5'd0:  begin char_code = CH_LS; char_valid = 1; end   // S
			5'd1:  begin char_code = CH_LT; char_valid = 1; end   // T
			5'd2:  begin char_code = CH_COL; char_valid = 1; end
			5'd3:  begin char_code = hex4(lat_txn); char_valid = 1; end
			5'd5:  begin char_code = CH_LB; char_valid = 1; end   // B
			5'd6:  begin char_code = CH_LY; char_valid = 1; end   // Y (busy)
			5'd7:  begin char_code = CH_COL; char_valid = 1; end
			5'd8:  begin char_code = hex4({3'd0, lat_busy}); char_valid = 1; end
			5'd10: begin char_code = CH_LD; char_valid = 1; end   // D
			5'd11: begin char_code = CH_LK; char_valid = 1; end   // K (dtack)
			5'd12: begin char_code = CH_COL; char_valid = 1; end
			5'd13: begin char_code = hex4({3'd0, lat_dtack}); char_valid = 1; end
			5'd14: begin char_code = hex4({3'd0, lat_ext_dtack}); char_valid = 1; end
			default: ;
		endcase

		// Row 2: RD:xxxx
		4'd2: case (char_col)
			5'd0:  begin char_code = CH_LR; char_valid = 1; end   // R
			5'd1:  begin char_code = CH_LD; char_valid = 1; end   // D (rom data)
			5'd2:  begin char_code = CH_COL; char_valid = 1; end
			5'd3:  begin char_code = hex4(lat_rom_word[15:12]); char_valid = 1; end
			5'd4:  begin char_code = hex4(lat_rom_word[11:8]);  char_valid = 1; end
			5'd5:  begin char_code = hex4(lat_rom_word[7:4]);   char_valid = 1; end
			5'd6:  begin char_code = hex4(lat_rom_word[3:0]);   char_valid = 1; end
			default: ;
		endcase

		// Row 3: RQ:x AK:x PN:x
		4'd3: case (char_col)
			5'd0:  begin char_code = CH_LR; char_valid = 1; end   // R
			5'd1:  begin char_code = CH_LQ; char_valid = 1; end   // Q (req)
			5'd2:  begin char_code = CH_COL; char_valid = 1; end
			5'd3:  begin char_code = hex4({3'd0, lat_req1}); char_valid = 1; end
			5'd5:  begin char_code = CH_LA; char_valid = 1; end   // A
			5'd6:  begin char_code = CH_LK; char_valid = 1; end   // K (ack)
			5'd7:  begin char_code = CH_COL; char_valid = 1; end
			5'd8:  begin char_code = hex4({3'd0, lat_ack1}); char_valid = 1; end
			5'd10: begin char_code = CH_LP; char_valid = 1; end   // P
			5'd11: begin char_code = CH_LN; char_valid = 1; end   // N (pending)
			5'd12: begin char_code = CH_COL; char_valid = 1; end
			5'd13: begin char_code = hex4({3'd0, lat_pending}); char_valid = 1; end
			default: ;
		endcase

		// Row 4: SC:xxxx SV:x TR:x
		4'd4: case (char_col)
			5'd0:  begin char_code = CH_LS; char_valid = 1; end   // S
			5'd1:  begin char_code = CH_LC; char_valid = 1; end   // C (SC output)
			5'd2:  begin char_code = CH_COL; char_valid = 1; end
			5'd3:  begin char_code = hex4({1'd0, lat_scn0_sc[14:12]}); char_valid = 1; end
			5'd4:  begin char_code = hex4(lat_scn0_sc[11:8]); char_valid = 1; end
			5'd5:  begin char_code = hex4(lat_scn0_sc[7:4]); char_valid = 1; end
			5'd6:  begin char_code = hex4(lat_scn0_sc[3:0]); char_valid = 1; end
			5'd8:  begin char_code = CH_LS; char_valid = 1; end   // S
			5'd9:  begin char_code = CH_LV; char_valid = 1; end   // V (SC seen?)
			5'd10: begin char_code = CH_COL; char_valid = 1; end
			5'd11: begin char_code = hex4({3'd0, lat_sc_seen}); char_valid = 1; end
			5'd13: begin char_code = CH_LT; char_valid = 1; end   // T
			5'd14: begin char_code = CH_LR; char_valid = 1; end   // R (tile rom req seen?)
			5'd15: begin char_code = CH_COL; char_valid = 1; end
			5'd16: begin char_code = hex4({3'd0, lat_trom_seen}); char_valid = 1; end
			default: ;
		endcase

		// Row 5: CW:xxxx (SCN0 CPU write count)
		4'd5: case (char_col)
			5'd0:  begin char_code = CH_LC; char_valid = 1; end   // C
			5'd1:  begin char_code = CH_LW; char_valid = 1; end   // W
			5'd2:  begin char_code = CH_COL; char_valid = 1; end
			5'd3:  begin char_code = hex4(lat_scn0_wr_cnt[15:12]); char_valid = 1; end
			5'd4:  begin char_code = hex4(lat_scn0_wr_cnt[11:8]);  char_valid = 1; end
			5'd5:  begin char_code = hex4(lat_scn0_wr_cnt[7:4]);   char_valid = 1; end
			5'd6:  begin char_code = hex4(lat_scn0_wr_cnt[3:0]);   char_valid = 1; end
			default: ;
		endcase

		// Row 6: PK:xxxx M:x  (SDRAM peek word 0 bank 0 + bank dup match flag)
		4'd6: case (char_col)
			5'd0:  begin char_code = CH_LP; char_valid = 1; end   // P
			5'd1:  begin char_code = CH_LK; char_valid = 1; end   // K
			5'd2:  begin char_code = CH_COL; char_valid = 1; end
			5'd3:  begin char_code = hex4(lat_peek_val[15:12]); char_valid = 1; end
			5'd4:  begin char_code = hex4(lat_peek_val[11:8]);  char_valid = 1; end
			5'd5:  begin char_code = hex4(lat_peek_val[7:4]);   char_valid = 1; end
			5'd6:  begin char_code = hex4(lat_peek_val[3:0]);   char_valid = 1; end
			5'd8:  begin char_code = CH_LM; char_valid = 1; end   // M
			5'd9:  begin char_code = CH_COL; char_valid = 1; end
			5'd10: begin char_code = hex4({3'd0, lat_peek_match}); char_valid = 1; end
			default: ;
		endcase

		// Row 7: FP:xxxxxx  (first PC captured after reset)
		// Expected: $0000EB6 — the Darius 2 reset PC
		4'd7: case (char_col)
			5'd0:  begin char_code = CH_LF; char_valid = 1; end   // F
			5'd1:  begin char_code = CH_LP; char_valid = 1; end   // P
			5'd2:  begin char_code = CH_COL; char_valid = 1; end
			5'd3:  begin char_code = hex4(lat_first_pc[23:20]); char_valid = 1; end
			5'd4:  begin char_code = hex4(lat_first_pc[19:16]); char_valid = 1; end
			5'd5:  begin char_code = hex4(lat_first_pc[15:12]); char_valid = 1; end
			5'd6:  begin char_code = hex4(lat_first_pc[11:8]);  char_valid = 1; end
			5'd7:  begin char_code = hex4(lat_first_pc[7:4]);   char_valid = 1; end
			5'd8:  begin char_code = hex4(lat_first_pc[3:0]);   char_valid = 1; end
			default: ;
		endcase

		// Row 9: D0:xxxxxxxx A0:xxxxxxxx (RAM test count + pointer)
		4'd9: case (char_col)
			5'd0:  begin char_code = CH_LD;  char_valid = 1; end    // D
			5'd1:  begin char_code = CH_0;   char_valid = 1; end    // 0
			5'd2:  begin char_code = CH_COL; char_valid = 1; end
			5'd3:  begin char_code = hex4(lat_d0[31:28]); char_valid = 1; end
			5'd4:  begin char_code = hex4(lat_d0[27:24]); char_valid = 1; end
			5'd5:  begin char_code = hex4(lat_d0[23:20]); char_valid = 1; end
			5'd6:  begin char_code = hex4(lat_d0[19:16]); char_valid = 1; end
			5'd7:  begin char_code = hex4(lat_d0[15:12]); char_valid = 1; end
			5'd8:  begin char_code = hex4(lat_d0[11:8]);  char_valid = 1; end
			5'd9:  begin char_code = hex4(lat_d0[7:4]);   char_valid = 1; end
			5'd10: begin char_code = hex4(lat_d0[3:0]);   char_valid = 1; end
			5'd12: begin char_code = CH_LA;  char_valid = 1; end    // A
			5'd13: begin char_code = CH_0;   char_valid = 1; end    // 0
			5'd14: begin char_code = CH_COL; char_valid = 1; end
			5'd15: begin char_code = hex4(lat_a0[31:28]); char_valid = 1; end
			5'd16: begin char_code = hex4(lat_a0[27:24]); char_valid = 1; end
			5'd17: begin char_code = hex4(lat_a0[23:20]); char_valid = 1; end
			5'd18: begin char_code = hex4(lat_a0[19:16]); char_valid = 1; end
			5'd19: begin char_code = hex4(lat_a0[15:12]); char_valid = 1; end
			5'd20: begin char_code = hex4(lat_a0[11:8]);  char_valid = 1; end
			5'd21: begin char_code = hex4(lat_a0[7:4]);   char_valid = 1; end
			5'd22: begin char_code = hex4(lat_a0[3:0]);   char_valid = 1; end
			default: ;
		endcase

		// Row 8: D6:xxxxxxxx D7:xxxxxxxx (live CPU data registers for DBRA delay-loop check)
		4'd8: case (char_col)
			5'd0:  begin char_code = CH_LD;  char_valid = 1; end    // D
			5'd1:  begin char_code = CH_6;   char_valid = 1; end    // 6
			5'd2:  begin char_code = CH_COL; char_valid = 1; end
			5'd3:  begin char_code = hex4(lat_d6[31:28]); char_valid = 1; end
			5'd4:  begin char_code = hex4(lat_d6[27:24]); char_valid = 1; end
			5'd5:  begin char_code = hex4(lat_d6[23:20]); char_valid = 1; end
			5'd6:  begin char_code = hex4(lat_d6[19:16]); char_valid = 1; end
			5'd7:  begin char_code = hex4(lat_d6[15:12]); char_valid = 1; end
			5'd8:  begin char_code = hex4(lat_d6[11:8]);  char_valid = 1; end
			5'd9:  begin char_code = hex4(lat_d6[7:4]);   char_valid = 1; end
			5'd10: begin char_code = hex4(lat_d6[3:0]);   char_valid = 1; end
			5'd12: begin char_code = CH_LD;  char_valid = 1; end    // D
			5'd13: begin char_code = CH_7;   char_valid = 1; end    // 7
			5'd14: begin char_code = CH_COL; char_valid = 1; end
			5'd15: begin char_code = hex4(lat_d7[31:28]); char_valid = 1; end
			5'd16: begin char_code = hex4(lat_d7[27:24]); char_valid = 1; end
			5'd17: begin char_code = hex4(lat_d7[23:20]); char_valid = 1; end
			5'd18: begin char_code = hex4(lat_d7[19:16]); char_valid = 1; end
			5'd19: begin char_code = hex4(lat_d7[15:12]); char_valid = 1; end
			5'd20: begin char_code = hex4(lat_d7[11:8]);  char_valid = 1; end
			5'd21: begin char_code = hex4(lat_d7[7:4]);   char_valid = 1; end
			5'd22: begin char_code = hex4(lat_d7[3:0]);   char_valid = 1; end
			default: ;
		endcase

		// Row 10: A1:xxxxxxxx (secondary pointer — usually area under memtest)
		4'd10: case (char_col)
			5'd0:  begin char_code = CH_LA;  char_valid = 1; end    // A
			5'd1:  begin char_code = CH_1;   char_valid = 1; end    // 1
			5'd2:  begin char_code = CH_COL; char_valid = 1; end
			5'd3:  begin char_code = hex4(lat_a1[31:28]); char_valid = 1; end
			5'd4:  begin char_code = hex4(lat_a1[27:24]); char_valid = 1; end
			5'd5:  begin char_code = hex4(lat_a1[23:20]); char_valid = 1; end
			5'd6:  begin char_code = hex4(lat_a1[19:16]); char_valid = 1; end
			5'd7:  begin char_code = hex4(lat_a1[15:12]); char_valid = 1; end
			5'd8:  begin char_code = hex4(lat_a1[11:8]);  char_valid = 1; end
			5'd9:  begin char_code = hex4(lat_a1[7:4]);   char_valid = 1; end
			5'd10: begin char_code = hex4(lat_a1[3:0]);   char_valid = 1; end
			default: ;
		endcase

		// Row 11: WC:xxxx RV:xxxx (Main RAM write count + read value at $0C0000)
		4'd11: case (char_col)
			5'd0:  begin char_code = CH_LW;  char_valid = 1; end    // W
			5'd1:  begin char_code = CH_LC;  char_valid = 1; end    // C (write count)
			5'd2:  begin char_code = CH_COL; char_valid = 1; end
			5'd3:  begin char_code = hex4(lat_ram_wr_cnt[15:12]); char_valid = 1; end
			5'd4:  begin char_code = hex4(lat_ram_wr_cnt[11:8]);  char_valid = 1; end
			5'd5:  begin char_code = hex4(lat_ram_wr_cnt[7:4]);   char_valid = 1; end
			5'd6:  begin char_code = hex4(lat_ram_wr_cnt[3:0]);   char_valid = 1; end
			5'd8:  begin char_code = CH_LR;  char_valid = 1; end    // R
			5'd9:  begin char_code = CH_LV;  char_valid = 1; end    // V (read value)
			5'd10: begin char_code = CH_COL; char_valid = 1; end
			5'd11: begin char_code = hex4(lat_ram_rd_val[15:12]); char_valid = 1; end
			5'd12: begin char_code = hex4(lat_ram_rd_val[11:8]);  char_valid = 1; end
			5'd13: begin char_code = hex4(lat_ram_rd_val[7:4]);   char_valid = 1; end
			5'd14: begin char_code = hex4(lat_ram_rd_val[3:0]);   char_valid = 1; end
			default: ;
		endcase

		// Row 12: SP:xxxxxx (Sub CPU PC)
		4'd12: case (char_col)
			5'd0:  begin char_code = CH_LS; char_valid = 1; end   // S
			5'd1:  begin char_code = CH_LP; char_valid = 1; end   // P
			5'd2:  begin char_code = CH_COL; char_valid = 1; end  // :
			5'd3:  begin char_code = hex4(lat_sub_pc[23:20]); char_valid = 1; end
			5'd4:  begin char_code = hex4(lat_sub_pc[19:16]); char_valid = 1; end
			5'd5:  begin char_code = hex4(lat_sub_pc[15:12]); char_valid = 1; end
			5'd6:  begin char_code = hex4(lat_sub_pc[11:8]);  char_valid = 1; end
			5'd7:  begin char_code = hex4(lat_sub_pc[7:4]);   char_valid = 1; end
			5'd8:  begin char_code = hex4(lat_sub_pc[3:0]);   char_valid = 1; end
			default: ;
		endcase

		default: ;
	endcase
end

// Font lookup
wire [3:0] font_pixels;
debug_font_d2 font_inst (
	.code(char_code),
	.row(font_row),
	.pixels(font_pixels)
);

wire font_hit = font_pixels[2'd3 - font_col[1:0]];

assign pixel_on = ovl_area && in_glyph && char_valid && font_hit;
assign bg_on    = ovl_area && !pixel_on;

endmodule
