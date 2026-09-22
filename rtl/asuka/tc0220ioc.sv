/*  This file is part of TaitoAsuka_MiSTer.

    Author: Umberto Parisi (rmonic79)
    Version: 1.0
    Date: 2026
*/

// tc0220ioc — Taito I/O controller (80-pin flat package).
// Differente da TC0040IOC: address DIRECT (8 bytes), no port register.
// MAME (taitoio.cpp:14-29):
//   $00 R IN00-07 (DSWA)
//   $00 W watchdog reset
//   $01 R IN08-15 (DSWB)
//   $02 R 1P inputs
//   $02 W init / unknown
//   $03 R 2P inputs
//   $04 RW coin counters/lockout
//   $05 W unknown
//   $06 W unknown
//   $07 R coin inputs
//
// CPU access: word-wide $900000-$90000F, umask16(0x00ff) = byte EVEN (UDS).
// addr[3:1] seleziona registro 0..7.

module tc0220ioc
(
	input  wire        clk,
	input  wire        reset,

	// CPU bus
	input  wire        cs,          // sel_ioc dal memory map
	input  wire        rnw,
	input  wire  [2:0] addr,        // bus_addr[3:1] — selettore registro 0..7
	input  wire  [7:0] wdata,
	output wire  [7:0] rdata,

	// Board inputs (active-low convention seguita dal core)
	input  wire  [7:0] p1_input,
	input  wire  [7:0] p2_input,
	input  wire  [7:0] coin_input,
	input  wire  [7:0] dswa_input,
	input  wire  [7:0] dswb_input
);

reg [7:0] coin_reg;  // $04

// Read decode
function [7:0] ioc_read_fn;
	input [2:0] a;
	begin
		case (a)
			3'd0: ioc_read_fn = dswa_input;
			3'd1: ioc_read_fn = dswb_input;
			3'd2: ioc_read_fn = p1_input;
			3'd3: ioc_read_fn = p2_input;
			3'd4: ioc_read_fn = coin_reg;
			3'd7: ioc_read_fn = coin_input;
			default: ioc_read_fn = 8'hFF;
		endcase
	end
endfunction

assign rdata = ioc_read_fn(addr);

// Write decode
always @(posedge clk) begin
	if (reset) begin
		coin_reg <= 8'd0;
	end else if (cs & ~rnw) begin
		case (addr)
			3'd4: coin_reg <= wdata;  // coin counters/lockout
			default: ; // $00 watchdog, $02/$05/$06 unknown — ignored
		endcase
	end
end

endmodule
