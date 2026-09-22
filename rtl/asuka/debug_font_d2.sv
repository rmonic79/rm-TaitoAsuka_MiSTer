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

// debug_font_d2.sv — 4x7 pixel font for debug overlay.
// Supports full hex 0-F plus label letters needed for boot debug.
// code 0-15: hex digits 0-F
// code 16: space
// code 17: colon ':'
// code 18-31: A,B,C,D,E,F (duplicate for labels), G,H,I,K,L,M,N,O
// code 32-41: P,Q,R,S,T,U,V,W,X,Y

module debug_font_d2 (
	input  wire [5:0] code,
	input  wire [2:0] row,
	output reg  [3:0] pixels
);

always @(*) begin
	case ({code, row})
		// 0
		9'h000: pixels = 4'b0110; 9'h001: pixels = 4'b1001; 9'h002: pixels = 4'b1001;
		9'h003: pixels = 4'b1001; 9'h004: pixels = 4'b1001; 9'h005: pixels = 4'b1001;
		9'h006: pixels = 4'b0110;
		// 1
		9'h008: pixels = 4'b0010; 9'h009: pixels = 4'b0110; 9'h00A: pixels = 4'b0010;
		9'h00B: pixels = 4'b0010; 9'h00C: pixels = 4'b0010; 9'h00D: pixels = 4'b0010;
		9'h00E: pixels = 4'b0111;
		// 2
		9'h010: pixels = 4'b0110; 9'h011: pixels = 4'b1001; 9'h012: pixels = 4'b0001;
		9'h013: pixels = 4'b0010; 9'h014: pixels = 4'b0100; 9'h015: pixels = 4'b1000;
		9'h016: pixels = 4'b1111;
		// 3
		9'h018: pixels = 4'b1110; 9'h019: pixels = 4'b0001; 9'h01A: pixels = 4'b0001;
		9'h01B: pixels = 4'b0110; 9'h01C: pixels = 4'b0001; 9'h01D: pixels = 4'b0001;
		9'h01E: pixels = 4'b1110;
		// 4
		9'h020: pixels = 4'b1001; 9'h021: pixels = 4'b1001; 9'h022: pixels = 4'b1001;
		9'h023: pixels = 4'b1111; 9'h024: pixels = 4'b0001; 9'h025: pixels = 4'b0001;
		9'h026: pixels = 4'b0001;
		// 5
		9'h028: pixels = 4'b1111; 9'h029: pixels = 4'b1000; 9'h02A: pixels = 4'b1000;
		9'h02B: pixels = 4'b1110; 9'h02C: pixels = 4'b0001; 9'h02D: pixels = 4'b0001;
		9'h02E: pixels = 4'b1110;
		// 6
		9'h030: pixels = 4'b0110; 9'h031: pixels = 4'b1000; 9'h032: pixels = 4'b1000;
		9'h033: pixels = 4'b1110; 9'h034: pixels = 4'b1001; 9'h035: pixels = 4'b1001;
		9'h036: pixels = 4'b0110;
		// 7
		9'h038: pixels = 4'b1111; 9'h039: pixels = 4'b0001; 9'h03A: pixels = 4'b0010;
		9'h03B: pixels = 4'b0010; 9'h03C: pixels = 4'b0100; 9'h03D: pixels = 4'b0100;
		9'h03E: pixels = 4'b0100;
		// 8
		9'h040: pixels = 4'b0110; 9'h041: pixels = 4'b1001; 9'h042: pixels = 4'b1001;
		9'h043: pixels = 4'b0110; 9'h044: pixels = 4'b1001; 9'h045: pixels = 4'b1001;
		9'h046: pixels = 4'b0110;
		// 9
		9'h048: pixels = 4'b0110; 9'h049: pixels = 4'b1001; 9'h04A: pixels = 4'b1001;
		9'h04B: pixels = 4'b0111; 9'h04C: pixels = 4'b0001; 9'h04D: pixels = 4'b0001;
		9'h04E: pixels = 4'b0110;
		// A (code 10)
		9'h050: pixels = 4'b0110; 9'h051: pixels = 4'b1001; 9'h052: pixels = 4'b1001;
		9'h053: pixels = 4'b1111; 9'h054: pixels = 4'b1001; 9'h055: pixels = 4'b1001;
		9'h056: pixels = 4'b1001;
		// B (code 11)
		9'h058: pixels = 4'b1110; 9'h059: pixels = 4'b1001; 9'h05A: pixels = 4'b1001;
		9'h05B: pixels = 4'b1110; 9'h05C: pixels = 4'b1001; 9'h05D: pixels = 4'b1001;
		9'h05E: pixels = 4'b1110;
		// C (code 12)
		9'h060: pixels = 4'b0110; 9'h061: pixels = 4'b1001; 9'h062: pixels = 4'b1000;
		9'h063: pixels = 4'b1000; 9'h064: pixels = 4'b1000; 9'h065: pixels = 4'b1001;
		9'h066: pixels = 4'b0110;
		// D (code 13)
		9'h068: pixels = 4'b1110; 9'h069: pixels = 4'b1001; 9'h06A: pixels = 4'b1001;
		9'h06B: pixels = 4'b1001; 9'h06C: pixels = 4'b1001; 9'h06D: pixels = 4'b1001;
		9'h06E: pixels = 4'b1110;
		// E (code 14)
		9'h070: pixels = 4'b1111; 9'h071: pixels = 4'b1000; 9'h072: pixels = 4'b1000;
		9'h073: pixels = 4'b1110; 9'h074: pixels = 4'b1000; 9'h075: pixels = 4'b1000;
		9'h076: pixels = 4'b1111;
		// F (code 15)
		9'h078: pixels = 4'b1111; 9'h079: pixels = 4'b1000; 9'h07A: pixels = 4'b1000;
		9'h07B: pixels = 4'b1110; 9'h07C: pixels = 4'b1000; 9'h07D: pixels = 4'b1000;
		9'h07E: pixels = 4'b1000;

		// space (code 16)
		9'h080: pixels = 4'b0000; 9'h081: pixels = 4'b0000; 9'h082: pixels = 4'b0000;
		9'h083: pixels = 4'b0000; 9'h084: pixels = 4'b0000; 9'h085: pixels = 4'b0000;
		9'h086: pixels = 4'b0000;
		// : (code 17)
		9'h088: pixels = 4'b0000; 9'h089: pixels = 4'b0110; 9'h08A: pixels = 4'b0110;
		9'h08B: pixels = 4'b0000; 9'h08C: pixels = 4'b0110; 9'h08D: pixels = 4'b0110;
		9'h08E: pixels = 4'b0000;

		// === Label letters (code 18+) ===
		// A (code 18) — duplicate for labels
		9'h090: pixels = 4'b0110; 9'h091: pixels = 4'b1001; 9'h092: pixels = 4'b1001;
		9'h093: pixels = 4'b1111; 9'h094: pixels = 4'b1001; 9'h095: pixels = 4'b1001;
		9'h096: pixels = 4'b1001;
		// B (code 19)
		9'h098: pixels = 4'b1110; 9'h099: pixels = 4'b1001; 9'h09A: pixels = 4'b1001;
		9'h09B: pixels = 4'b1110; 9'h09C: pixels = 4'b1001; 9'h09D: pixels = 4'b1001;
		9'h09E: pixels = 4'b1110;
		// C (code 20)
		9'h0A0: pixels = 4'b0110; 9'h0A1: pixels = 4'b1001; 9'h0A2: pixels = 4'b1000;
		9'h0A3: pixels = 4'b1000; 9'h0A4: pixels = 4'b1000; 9'h0A5: pixels = 4'b1001;
		9'h0A6: pixels = 4'b0110;
		// D (code 21)
		9'h0A8: pixels = 4'b1110; 9'h0A9: pixels = 4'b1001; 9'h0AA: pixels = 4'b1001;
		9'h0AB: pixels = 4'b1001; 9'h0AC: pixels = 4'b1001; 9'h0AD: pixels = 4'b1001;
		9'h0AE: pixels = 4'b1110;
		// E (code 22)
		9'h0B0: pixels = 4'b1111; 9'h0B1: pixels = 4'b1000; 9'h0B2: pixels = 4'b1000;
		9'h0B3: pixels = 4'b1110; 9'h0B4: pixels = 4'b1000; 9'h0B5: pixels = 4'b1000;
		9'h0B6: pixels = 4'b1111;
		// F (code 23)
		9'h0B8: pixels = 4'b1111; 9'h0B9: pixels = 4'b1000; 9'h0BA: pixels = 4'b1000;
		9'h0BB: pixels = 4'b1110; 9'h0BC: pixels = 4'b1000; 9'h0BD: pixels = 4'b1000;
		9'h0BE: pixels = 4'b1000;
		// G (code 24)
		9'h0C0: pixels = 4'b0110; 9'h0C1: pixels = 4'b1001; 9'h0C2: pixels = 4'b1000;
		9'h0C3: pixels = 4'b1011; 9'h0C4: pixels = 4'b1001; 9'h0C5: pixels = 4'b1001;
		9'h0C6: pixels = 4'b0110;
		// H (code 25)
		9'h0C8: pixels = 4'b1001; 9'h0C9: pixels = 4'b1001; 9'h0CA: pixels = 4'b1001;
		9'h0CB: pixels = 4'b1111; 9'h0CC: pixels = 4'b1001; 9'h0CD: pixels = 4'b1001;
		9'h0CE: pixels = 4'b1001;
		// I (code 26)
		9'h0D0: pixels = 4'b1110; 9'h0D1: pixels = 4'b0100; 9'h0D2: pixels = 4'b0100;
		9'h0D3: pixels = 4'b0100; 9'h0D4: pixels = 4'b0100; 9'h0D5: pixels = 4'b0100;
		9'h0D6: pixels = 4'b1110;
		// K (code 27)
		9'h0D8: pixels = 4'b1001; 9'h0D9: pixels = 4'b1010; 9'h0DA: pixels = 4'b1100;
		9'h0DB: pixels = 4'b1000; 9'h0DC: pixels = 4'b1100; 9'h0DD: pixels = 4'b1010;
		9'h0DE: pixels = 4'b1001;
		// L (code 28)
		9'h0E0: pixels = 4'b1000; 9'h0E1: pixels = 4'b1000; 9'h0E2: pixels = 4'b1000;
		9'h0E3: pixels = 4'b1000; 9'h0E4: pixels = 4'b1000; 9'h0E5: pixels = 4'b1000;
		9'h0E6: pixels = 4'b1111;
		// M (code 29)
		9'h0E8: pixels = 4'b1001; 9'h0E9: pixels = 4'b1111; 9'h0EA: pixels = 4'b1111;
		9'h0EB: pixels = 4'b1001; 9'h0EC: pixels = 4'b1001; 9'h0ED: pixels = 4'b1001;
		9'h0EE: pixels = 4'b1001;
		// N (code 30)
		9'h0F0: pixels = 4'b1001; 9'h0F1: pixels = 4'b1101; 9'h0F2: pixels = 4'b1101;
		9'h0F3: pixels = 4'b1011; 9'h0F4: pixels = 4'b1011; 9'h0F5: pixels = 4'b1001;
		9'h0F6: pixels = 4'b1001;
		// O (code 31)
		9'h0F8: pixels = 4'b0110; 9'h0F9: pixels = 4'b1001; 9'h0FA: pixels = 4'b1001;
		9'h0FB: pixels = 4'b1001; 9'h0FC: pixels = 4'b1001; 9'h0FD: pixels = 4'b1001;
		9'h0FE: pixels = 4'b0110;

		// P (code 32)
		9'h100: pixels = 4'b1110; 9'h101: pixels = 4'b1001; 9'h102: pixels = 4'b1001;
		9'h103: pixels = 4'b1110; 9'h104: pixels = 4'b1000; 9'h105: pixels = 4'b1000;
		9'h106: pixels = 4'b1000;
		// Q (code 33)
		9'h108: pixels = 4'b0110; 9'h109: pixels = 4'b1001; 9'h10A: pixels = 4'b1001;
		9'h10B: pixels = 4'b1001; 9'h10C: pixels = 4'b1011; 9'h10D: pixels = 4'b1010;
		9'h10E: pixels = 4'b0101;
		// R (code 34)
		9'h110: pixels = 4'b1110; 9'h111: pixels = 4'b1001; 9'h112: pixels = 4'b1001;
		9'h113: pixels = 4'b1110; 9'h114: pixels = 4'b1010; 9'h115: pixels = 4'b1001;
		9'h116: pixels = 4'b1001;
		// S (code 35)
		9'h118: pixels = 4'b0111; 9'h119: pixels = 4'b1000; 9'h11A: pixels = 4'b1000;
		9'h11B: pixels = 4'b0110; 9'h11C: pixels = 4'b0001; 9'h11D: pixels = 4'b0001;
		9'h11E: pixels = 4'b1110;
		// T (code 36)
		9'h120: pixels = 4'b1111; 9'h121: pixels = 4'b0110; 9'h122: pixels = 4'b0110;
		9'h123: pixels = 4'b0110; 9'h124: pixels = 4'b0110; 9'h125: pixels = 4'b0110;
		9'h126: pixels = 4'b0110;
		// U (code 37)
		9'h128: pixels = 4'b1001; 9'h129: pixels = 4'b1001; 9'h12A: pixels = 4'b1001;
		9'h12B: pixels = 4'b1001; 9'h12C: pixels = 4'b1001; 9'h12D: pixels = 4'b1001;
		9'h12E: pixels = 4'b0110;
		// V (code 38)
		9'h130: pixels = 4'b1001; 9'h131: pixels = 4'b1001; 9'h132: pixels = 4'b1001;
		9'h133: pixels = 4'b1001; 9'h134: pixels = 4'b1001; 9'h135: pixels = 4'b0110;
		9'h136: pixels = 4'b0010;
		// W (code 39)
		9'h138: pixels = 4'b1001; 9'h139: pixels = 4'b1001; 9'h13A: pixels = 4'b1001;
		9'h13B: pixels = 4'b1001; 9'h13C: pixels = 4'b1111; 9'h13D: pixels = 4'b1111;
		9'h13E: pixels = 4'b1001;
		// X (code 40)
		9'h140: pixels = 4'b1001; 9'h141: pixels = 4'b1001; 9'h142: pixels = 4'b0110;
		9'h143: pixels = 4'b0110; 9'h144: pixels = 4'b0110; 9'h145: pixels = 4'b1001;
		9'h146: pixels = 4'b1001;
		// Y (code 41)
		9'h148: pixels = 4'b1001; 9'h149: pixels = 4'b1001; 9'h14A: pixels = 4'b0110;
		9'h14B: pixels = 4'b0010; 9'h14C: pixels = 4'b0010; 9'h14D: pixels = 4'b0010;
		9'h14E: pixels = 4'b0010;

		default: pixels = 4'b0000;
	endcase
end

endmodule
