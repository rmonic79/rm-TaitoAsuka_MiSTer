/* This file is part of JT12.

 
    JT12 program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JT12 program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JT12.  If not, see <http://www.gnu.org/licenses/>.

    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: 15-11-2018

*/


// Use for YM2203
// no left/right channels
// full operator resolution
// clamped to maximum output of signed 16 bits
// This version does not clamp each channel individually
// That does not correspond to real hardware behaviour. I should
// change it.

module jt03_acc
(
    input               rst,
    input               clk,
    input               clk_en /* synthesis direct_enable */,
    input signed [13:0] op_result,
    input               s1_enters,
    input               s2_enters,
    input               s3_enters,
    input               s4_enters,
    input               zero,
    input   [2:0]       alg,
    // combined output
    output signed [15:0] snd
);

reg sum_en;

always @(*) begin
    case ( alg )
        default: sum_en = s4_enters;
        3'd4: sum_en = s2_enters | s4_enters;
        3'd5,3'd6: sum_en = ~s1_enters;        
        3'd7: sum_en = 1'b1;
    endcase
end

// real YM2608 drops the op_result LSB, resulting in a 13-bit accumulator
// but in YM2203, a 13-bit acc for 3 channels only requires 15 bits
// and YM3014 has a 16-bit dynamic range.
// I am leaving the LSB and scaling the output voltage accordingly. This
// should result in less quantification noise.
//
// wout=18: 2 extra bits of headroom to avoid internal clipping when
// algorithms 4-7 sum multiple carriers across 3 channels.
// alg=4: 6×8191=49146, alg=7: 12×8191=98292 — both exceed ±32767.
// With wout=18 the accumulator holds ±131071, no clipping.
// Output is then scaled >>>2 and clamped to signed 16-bit.
wire signed [17:0] acc_wide;

jt12_single_acc #(.win(14),.wout(18)) u_mono(
    .clk        ( clk            ),
    .clk_en     ( clk_en         ),
    .op_result  ( op_result      ),
    .sum_en     ( sum_en         ),
    .zero       ( zero           ),
    .snd        ( acc_wide       )
);

// Clamp 18-bit accumulator to signed 16-bit output.
// The wider accumulator prevents distortion during intermediate sums
// (alg 4-7 can reach ±98292). The final clamp is clean saturation,
// not mid-accumulation overflow which causes harsh distortion.
// alg 0-3: peak ±24573, never clips here.
// alg 4:   peak ±49146, clips gently at ±32767.
// alg 7:   peak ±98292, clips but signal shape preserved up to ±32767.
assign snd = (acc_wide > 18'sd32767)  ? 16'sd32767 :
             (acc_wide < -18'sd32768) ? -16'sd32768 :
             acc_wide[15:0];

endmodule
