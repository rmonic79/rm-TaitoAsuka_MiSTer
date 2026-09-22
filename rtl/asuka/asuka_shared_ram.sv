/*  This file is part of Darius_MiSTer.

    Darius_MiSTer is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    Darius_MiSTer is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with Darius_MiSTer.  If not, see <http://www.gnu.org/licenses/>.

    Author: Umberto Parisi (rmonic79)
    Version: 1.0
    Date: 2026

*/

// asuka_shared_ram — BRAM True Dual-Port con byte enable.
// Main CPU su Port A, Sub CPU su Port B. Entrambi possono leggere/scrivere
// simultaneamente senza conflict. Split HI/LO byte RAMs per byte-enable.
// Base di shared RAM, sprite RAM, FG RAM, FG palette.

module asuka_shared_ram
#(
	parameter ADDR_WIDTH = 11,
	parameter integer SS_IDX = -1   // [SS] indice sul bus savestate
)
(
	input  wire        clk,

	// Port A — Main CPU
	input  wire        main_rd,
	input  wire        main_wr,
	input  wire [1:0]  main_be,    // byte enable: [1]=HI, [0]=LO
	input  wire [ADDR_WIDTH-1:0] main_addr,
	input  wire [15:0] main_wdata,
	output wire [15:0] main_rdata,
	output reg         main_ready,

	// Port B — Sub CPU
	input  wire        sub_rd,
	input  wire        sub_wr,
	input  wire [1:0]  sub_be,     // byte enable: [1]=HI, [0]=LO
	input  wire [ADDR_WIDTH-1:0] sub_addr,
	input  wire [15:0] sub_wdata,
	output wire [15:0] sub_rdata,
	output reg         sub_ready,

	// [SS] porta savestate sulla Port A (la Port B e' ferma: sub-CPU rimossa)
	ssbus_if.slave     ss
);

// [SS] adaptor su Port A: trasparente in gioco, dirotta durante save/restore.
wire                  ssr_we_lo, ssr_we_hi;
wire [ADDR_WIDTH-1:0] ssr_addr;
wire [15:0]           ssr_wdata;
ss_ram16_adaptor #(.WIDTHAD(ADDR_WIDTH), .SS_IDX(SS_IDX)) u_ss_ram (
	.clk(clk),
	.we_lo_in (main_wr & main_be[0]),
	.we_hi_in (main_wr & main_be[1]),
	.addr_in  (main_addr),
	.wdata_in (main_wdata),
	.we_lo_out(ssr_we_lo), .we_hi_out(ssr_we_hi),
	.addr_out (ssr_addr),  .wdata_out(ssr_wdata),
	.q_in     (main_rdata),
	.ssbus    (ss)
);

// Split into HI and LO byte RAMs for proper M10K inference with byte enable
// Each RAM is true dual-port (Port A = Main, Port B = Sub)

(* ramstyle = "no_rw_check" *) reg [7:0] mem_hi [0:(2**ADDR_WIDTH)-1];
(* ramstyle = "no_rw_check" *) reg [7:0] mem_lo [0:(2**ADDR_WIDTH)-1];

reg [7:0] main_rdata_hi, main_rdata_lo;
reg [7:0] sub_rdata_hi, sub_rdata_lo;

// Port A: Main CPU
always @(posedge clk) begin
	if (ssr_we_hi) mem_hi[ssr_addr] <= ssr_wdata[15:8];
	if (ssr_we_lo) mem_lo[ssr_addr] <= ssr_wdata[7:0];
	main_rdata_hi <= mem_hi[ssr_addr];
	main_rdata_lo <= mem_lo[ssr_addr];
	main_ready <= main_rd | main_wr;
end

// Port B: Sub CPU
always @(posedge clk) begin
	if (sub_wr && sub_be[1]) mem_hi[sub_addr] <= sub_wdata[15:8];
	if (sub_wr && sub_be[0]) mem_lo[sub_addr] <= sub_wdata[7:0];
	sub_rdata_hi <= mem_hi[sub_addr];
	sub_rdata_lo <= mem_lo[sub_addr];
	sub_ready <= sub_rd | sub_wr;
end

assign main_rdata = {main_rdata_hi, main_rdata_lo};
assign sub_rdata = {sub_rdata_hi, sub_rdata_lo};

endmodule
