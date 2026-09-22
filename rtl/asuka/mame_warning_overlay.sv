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

// mame_warning_overlay.sv — testo statico "DON'T BREAK YOUR WOOFER!" che
// appare per ~3 secondi quando l'utente attiva PSG=MAME nell'OSD audio mixer.
//
// Trigger: edge rising di `mame_psg_active` (= status[95] OSD).
// Timer: 24-bit counter al rate `tick` (= 1 colpo per frame VBlank).
// Display: testo gialloin alto al centro (pixel coords su render_x/y).
//
// Font 1bpp 8x8 — 16 char custom hardcoded (A B D E F K N O R T U W Y + ' ! sp).
// Light: ~150 righe, niente BRAM esterna, solo `case` interno (LE).

module mame_warning_overlay (
	input  wire        clk,
	input  wire        reset,
	input  wire        tick,            // 1 colpo per frame (VBlank rising)
	input  wire        mame_psg_active, // OSD bit (status[95])

	input  wire [9:0]  render_x,
	input  wire [8:0]  render_y,

	// Output: pixel attivo del testo
	output wire        text_on
);

// =====================================================================
// Edge detect + timer
// =====================================================================
reg mame_psg_active_d;
reg [7:0] timer;  // ~180 frame = 3s a 60Hz

always @(posedge clk) begin
	if (reset) begin
		mame_psg_active_d <= 1'b0;
		timer             <= 8'd0;
	end else begin
		mame_psg_active_d <= mame_psg_active;
		// Edge rising → carica timer
		if (mame_psg_active && !mame_psg_active_d) begin
			timer <= 8'd180;  // 180 frame * 16.67ms = ~3s
		end else if (tick && timer != 8'd0) begin
			timer <= timer - 8'd1;
		end
	end
end

wire timer_active = (timer != 8'd0);

// =====================================================================
// Testo: "DON'T BREAK YOUR WOOFER!"
// 24 char × 8 px = 192 px wide, 8 px tall
// Posizione: top-center. Schermo virtuale Darius2 = 864x224 (3 pannelli).
// X_BASE = (864-192)/2 = 336
// Y_BASE = 16  (pochi pixel sotto top edge)
// =====================================================================
// Bottom-left: OSD MiSTer occupa la metà superiore, qui resta visibile.
// Schermo 864x224 → Y_BASE = 200 (8 px sopra il bordo basso), X_BASE=8.
localparam [9:0] X_BASE = 10'd8;
localparam [8:0] Y_BASE = 9'd200;
localparam [9:0] X_END  = X_BASE + 10'd192;  // 192 px = 24 char
localparam [8:0] Y_END  = Y_BASE + 9'd8;

wire in_text_box = timer_active &&
	(render_x >= X_BASE) && (render_x < X_END) &&
	(render_y >= Y_BASE) && (render_y < Y_END);

// Char index 0..23 e pixel x dentro char
wire [4:0] char_idx = in_text_box ? (render_x[7:3] - X_BASE[7:3]) : 5'd0;
wire [2:0] pix_x    = render_x[2:0];
wire [2:0] pix_y    = render_y[2:0];

// =====================================================================
// String ROM: 24 char (codice 0..15 per font lookup)
// Layout " DON'T BREAK YOUR WOOFER!"  (con spazio iniziale per centratura)
// Codifica char: 0=spazio, 1=', 2=!, 3=A, 4=B, 5=D, 6=E, 7=F, 8=K,
//                9=N, 10=O, 11=R, 12=T, 13=U, 14=W, 15=Y
// =====================================================================
function [3:0] string_lookup;
	input [4:0] idx;
	case (idx)
		// "DON'T BREAK YOUR WOOFER!"  (24 char)
		5'd0:  string_lookup = 4'd5;   // D
		5'd1:  string_lookup = 4'd10;  // O
		5'd2:  string_lookup = 4'd9;   // N
		5'd3:  string_lookup = 4'd1;   // '
		5'd4:  string_lookup = 4'd12;  // T
		5'd5:  string_lookup = 4'd0;   // sp
		5'd6:  string_lookup = 4'd4;   // B
		5'd7:  string_lookup = 4'd11;  // R
		5'd8:  string_lookup = 4'd6;   // E
		5'd9:  string_lookup = 4'd3;   // A
		5'd10: string_lookup = 4'd8;   // K
		5'd11: string_lookup = 4'd0;   // sp
		5'd12: string_lookup = 4'd15;  // Y
		5'd13: string_lookup = 4'd10;  // O
		5'd14: string_lookup = 4'd13;  // U
		5'd15: string_lookup = 4'd11;  // R
		5'd16: string_lookup = 4'd0;   // sp
		5'd17: string_lookup = 4'd14;  // W
		5'd18: string_lookup = 4'd10;  // O
		5'd19: string_lookup = 4'd10;  // O
		5'd20: string_lookup = 4'd7;   // F
		5'd21: string_lookup = 4'd6;   // E
		5'd22: string_lookup = 4'd11;  // R
		5'd23: string_lookup = 4'd2;   // !
		default: string_lookup = 4'd0;
	endcase
endfunction

wire [3:0] char_code = string_lookup(char_idx);

// =====================================================================
// Font 8x8 (1bpp). 16 char hardcoded.
// MSB = pixel sinistro, LSB = pixel destro.
// =====================================================================
function [7:0] font_row;
	input [3:0] code;
	input [2:0] row;
	case ({code, row})
		// 0 = spazio
		7'b0000_000: font_row = 8'b00000000;
		7'b0000_001: font_row = 8'b00000000;
		7'b0000_010: font_row = 8'b00000000;
		7'b0000_011: font_row = 8'b00000000;
		7'b0000_100: font_row = 8'b00000000;
		7'b0000_101: font_row = 8'b00000000;
		7'b0000_110: font_row = 8'b00000000;
		7'b0000_111: font_row = 8'b00000000;
		// 1 = '
		7'b0001_000: font_row = 8'b00110000;
		7'b0001_001: font_row = 8'b00110000;
		7'b0001_010: font_row = 8'b01100000;
		7'b0001_011: font_row = 8'b00000000;
		7'b0001_100: font_row = 8'b00000000;
		7'b0001_101: font_row = 8'b00000000;
		7'b0001_110: font_row = 8'b00000000;
		7'b0001_111: font_row = 8'b00000000;
		// 2 = !
		7'b0010_000: font_row = 8'b00011000;
		7'b0010_001: font_row = 8'b00011000;
		7'b0010_010: font_row = 8'b00011000;
		7'b0010_011: font_row = 8'b00011000;
		7'b0010_100: font_row = 8'b00011000;
		7'b0010_101: font_row = 8'b00000000;
		7'b0010_110: font_row = 8'b00011000;
		7'b0010_111: font_row = 8'b00000000;
		// 3 = A
		7'b0011_000: font_row = 8'b00111100;
		7'b0011_001: font_row = 8'b01100110;
		7'b0011_010: font_row = 8'b11000011;
		7'b0011_011: font_row = 8'b11000011;
		7'b0011_100: font_row = 8'b11111111;
		7'b0011_101: font_row = 8'b11000011;
		7'b0011_110: font_row = 8'b11000011;
		7'b0011_111: font_row = 8'b00000000;
		// 4 = B
		7'b0100_000: font_row = 8'b11111100;
		7'b0100_001: font_row = 8'b11000110;
		7'b0100_010: font_row = 8'b11000110;
		7'b0100_011: font_row = 8'b11111100;
		7'b0100_100: font_row = 8'b11000110;
		7'b0100_101: font_row = 8'b11000110;
		7'b0100_110: font_row = 8'b11111100;
		7'b0100_111: font_row = 8'b00000000;
		// 5 = D
		7'b0101_000: font_row = 8'b11111100;
		7'b0101_001: font_row = 8'b11000110;
		7'b0101_010: font_row = 8'b11000110;
		7'b0101_011: font_row = 8'b11000110;
		7'b0101_100: font_row = 8'b11000110;
		7'b0101_101: font_row = 8'b11000110;
		7'b0101_110: font_row = 8'b11111100;
		7'b0101_111: font_row = 8'b00000000;
		// 6 = E
		7'b0110_000: font_row = 8'b11111110;
		7'b0110_001: font_row = 8'b11000000;
		7'b0110_010: font_row = 8'b11000000;
		7'b0110_011: font_row = 8'b11111100;
		7'b0110_100: font_row = 8'b11000000;
		7'b0110_101: font_row = 8'b11000000;
		7'b0110_110: font_row = 8'b11111110;
		7'b0110_111: font_row = 8'b00000000;
		// 7 = F
		7'b0111_000: font_row = 8'b11111110;
		7'b0111_001: font_row = 8'b11000000;
		7'b0111_010: font_row = 8'b11000000;
		7'b0111_011: font_row = 8'b11111100;
		7'b0111_100: font_row = 8'b11000000;
		7'b0111_101: font_row = 8'b11000000;
		7'b0111_110: font_row = 8'b11000000;
		7'b0111_111: font_row = 8'b00000000;
		// 8 = K
		7'b1000_000: font_row = 8'b11000110;
		7'b1000_001: font_row = 8'b11001100;
		7'b1000_010: font_row = 8'b11011000;
		7'b1000_011: font_row = 8'b11110000;
		7'b1000_100: font_row = 8'b11011000;
		7'b1000_101: font_row = 8'b11001100;
		7'b1000_110: font_row = 8'b11000110;
		7'b1000_111: font_row = 8'b00000000;
		// 9 = N
		7'b1001_000: font_row = 8'b11000011;
		7'b1001_001: font_row = 8'b11100011;
		7'b1001_010: font_row = 8'b11110011;
		7'b1001_011: font_row = 8'b11011011;
		7'b1001_100: font_row = 8'b11001111;
		7'b1001_101: font_row = 8'b11000111;
		7'b1001_110: font_row = 8'b11000011;
		7'b1001_111: font_row = 8'b00000000;
		// 10 = O
		7'b1010_000: font_row = 8'b01111110;
		7'b1010_001: font_row = 8'b11000011;
		7'b1010_010: font_row = 8'b11000011;
		7'b1010_011: font_row = 8'b11000011;
		7'b1010_100: font_row = 8'b11000011;
		7'b1010_101: font_row = 8'b11000011;
		7'b1010_110: font_row = 8'b01111110;
		7'b1010_111: font_row = 8'b00000000;
		// 11 = R
		7'b1011_000: font_row = 8'b11111100;
		7'b1011_001: font_row = 8'b11000110;
		7'b1011_010: font_row = 8'b11000110;
		7'b1011_011: font_row = 8'b11111100;
		7'b1011_100: font_row = 8'b11011000;
		7'b1011_101: font_row = 8'b11001100;
		7'b1011_110: font_row = 8'b11000110;
		7'b1011_111: font_row = 8'b00000000;
		// 12 = T
		7'b1100_000: font_row = 8'b11111111;
		7'b1100_001: font_row = 8'b00011000;
		7'b1100_010: font_row = 8'b00011000;
		7'b1100_011: font_row = 8'b00011000;
		7'b1100_100: font_row = 8'b00011000;
		7'b1100_101: font_row = 8'b00011000;
		7'b1100_110: font_row = 8'b00011000;
		7'b1100_111: font_row = 8'b00000000;
		// 13 = U
		7'b1101_000: font_row = 8'b11000011;
		7'b1101_001: font_row = 8'b11000011;
		7'b1101_010: font_row = 8'b11000011;
		7'b1101_011: font_row = 8'b11000011;
		7'b1101_100: font_row = 8'b11000011;
		7'b1101_101: font_row = 8'b11000011;
		7'b1101_110: font_row = 8'b01111110;
		7'b1101_111: font_row = 8'b00000000;
		// 14 = W
		7'b1110_000: font_row = 8'b11000011;
		7'b1110_001: font_row = 8'b11000011;
		7'b1110_010: font_row = 8'b11000011;
		7'b1110_011: font_row = 8'b11011011;
		7'b1110_100: font_row = 8'b11011011;
		7'b1110_101: font_row = 8'b11111111;
		7'b1110_110: font_row = 8'b01100110;
		7'b1110_111: font_row = 8'b00000000;
		// 15 = Y
		7'b1111_000: font_row = 8'b11000011;
		7'b1111_001: font_row = 8'b11000011;
		7'b1111_010: font_row = 8'b01100110;
		7'b1111_011: font_row = 8'b00111100;
		7'b1111_100: font_row = 8'b00011000;
		7'b1111_101: font_row = 8'b00011000;
		7'b1111_110: font_row = 8'b00011000;
		7'b1111_111: font_row = 8'b00000000;
	endcase
endfunction

wire [7:0] cur_row = font_row(char_code, pix_y);
wire       pixel   = cur_row[7 - pix_x];

assign text_on = in_text_box & pixel;

endmodule
