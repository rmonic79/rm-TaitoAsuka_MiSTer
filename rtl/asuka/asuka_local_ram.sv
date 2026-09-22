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

// asuka_local_ram — BRAM single-port con byte enable.
// Split HI/LO per inference pulita M10K con byte enable.
// Usata per main RAM, sprite RAM locale e altre RAM single-client.

module asuka_local_ram
#(
	parameter integer ADDR_WIDTH = 11,
	parameter integer SS_IDX     = -1   // [SS] indice sul bus savestate
)
(
	input  wire                  clk,
	input  wire                  rd,
	input  wire                  wr,
	input  wire [1:0]            be,    // byte enable: be[1]=write HI, be[0]=write LO
	input  wire [ADDR_WIDTH-1:0] addr,
	input  wire [15:0]           wdata,
	output wire [15:0]           rdata,

	// [SS] porta savestate: trasparente in gioco, dirotta addr/dato durante save/restore
	ssbus_if.slave               ss
);

// [SS] adaptor: in gioco passa i segnali del client; durante il savestate
// sostituisce indirizzo/dato/we con quelli del ssbus. q_in = rdata registrato
// a 1 clock, che e' la temporizzazione attesa.
wire                  ss_we_lo, ss_we_hi;
wire [ADDR_WIDTH-1:0] ss_addr;
wire [15:0]           ss_wdata;
ss_ram16_adaptor #(.WIDTHAD(ADDR_WIDTH), .SS_IDX(SS_IDX)) u_ss_ram (
	.clk(clk),
	.we_lo_in (wr & be[0]),
	.we_hi_in (wr & be[1]),
	.addr_in  (addr),
	.wdata_in (wdata),
	.we_lo_out(ss_we_lo), .we_hi_out(ss_we_hi),
	.addr_out (ss_addr),  .wdata_out(ss_wdata),
	.q_in     (rdata),
	.ssbus    (ss)
);

// Split into two 8-bit RAMs for proper M10K byte-enable inference.
// "no_rw_check" tells Quartus read-during-write to same addr is don't-care,
// which enables proper M10K placement instead of fallback to LUTRAM when
// M10K blocks are tight. Without this, Quartus may emit LUT-based altsyncram
// with decode_8la/mux_ofb which has different write/read timing and causes
// memtest failures on real hardware.
(* ramstyle = "M10K,no_rw_check" *) reg [7:0] ram_hi [0:(1 << ADDR_WIDTH)-1];
(* ramstyle = "M10K,no_rw_check" *) reg [7:0] ram_lo [0:(1 << ADDR_WIDTH)-1];
reg [7:0] rdata_hi, rdata_lo;

// synthesis translate_off
initial begin : init_ram
	integer i;
	for (i = 0; i < (1 << ADDR_WIDTH); i = i + 1) begin
		ram_hi[i] = 8'h00;
		ram_lo[i] = 8'h00;
	end
end
// synthesis translate_on

// M10K single-port inference: write gated by wr+be, read UNCONDITIONAL.
// Unconditional read avoids any chance of stale rdata when rd pulse is narrow.
// The memory map FSM samples bus_rdata 2 cycles after asserting rd, which
// matches the 1-cycle BRAM registered output (addr@N → rdata@N+1).
always @(posedge clk) begin
	if (ss_we_hi) ram_hi[ss_addr] <= ss_wdata[15:8];
	if (ss_we_lo) ram_lo[ss_addr] <= ss_wdata[7:0];
	rdata_hi <= ram_hi[ss_addr];
	rdata_lo <= ram_lo[ss_addr];
end

assign rdata = {rdata_hi, rdata_lo};

endmodule
