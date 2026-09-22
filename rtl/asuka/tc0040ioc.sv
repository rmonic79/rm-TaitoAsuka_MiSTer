/*  This file is part of Darius_MiSTer.

    Darius_MiSTer is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    Author: Umberto Parisi (rmonic79)
    Version: 1.0
    Date: 2026
*/

// tc0040ioc — I/O controller SHARATO Main + Sub.
// In MAME è un singolo chip con un solo m_port register. Main e Sub accedono
// allo stesso chip fisico via $200000-$200003. Se Main scrive ioc_port=2
// (per leggere IN0), anche il Sub leggendo $200001 vede IN0 (non DSWA).
//
// Protocollo: write $200003 = ioc_port register, write $200001 = ioc_regs[ioc_port],
//             read $200001 = ioc_read(ioc_port), read $200003 = watchdog (0).

module tc0040ioc
(
	input  wire        clk,
	input  wire        reset,

	// Main CPU access (word-wide requests from memory map)
	input  wire        main_cs,         // main memory map in sel_ioc phase
	input  wire        main_rnw,
	input  wire        main_addr1,      // bus_addr[1] — 0=data/$200001, 1=port/$200003
	input  wire  [7:0] main_wdata,

	// Sub CPU access
	input  wire        sub_cs,
	input  wire        sub_rnw,
	input  wire        sub_addr1,
	input  wire  [7:0] sub_wdata,

	// Read data (combinational — same cycle as cs)
	output wire  [7:0] main_rdata,
	output wire  [7:0] sub_rdata,

	// Board inputs
	input  wire  [7:0] p1_input,
	input  wire  [7:0] p2_input,
	input  wire  [7:0] system_input,
	input  wire [15:0] dsw_input
);

// Shared state: ioc_port register and 8 writable register slots
reg [7:0] ioc_port;
reg [7:0] ioc_regs [0:7];

// Combinational read of selected port
function [7:0] ioc_read_fn;
	input [7:0] port;
	begin
		case (port)
			8'h00: ioc_read_fn = dsw_input[7:0];
			8'h01: ioc_read_fn = dsw_input[15:8];
			8'h02: ioc_read_fn = p1_input;
			8'h03: ioc_read_fn = p2_input;
			8'h04: ioc_read_fn = ioc_regs[4];
			8'h07: ioc_read_fn = system_input;
			default: ioc_read_fn = 8'hFF;
		endcase
	end
endfunction

// Read data: addr1=0 → data port (portreg_r), addr1=1 → watchdog (0)
assign main_rdata = main_addr1 ? 8'h00 : ioc_read_fn(ioc_port);
assign sub_rdata  = sub_addr1  ? 8'h00 : ioc_read_fn(ioc_port);

// Shared write state. Main prioritized over Sub if simultaneous (not expected).
always @(posedge clk) begin
	if (reset) begin
		ioc_port    <= 8'd0;
		ioc_regs[0] <= 8'd0; ioc_regs[1] <= 8'd0;
		ioc_regs[2] <= 8'd0; ioc_regs[3] <= 8'd0;
		ioc_regs[4] <= 8'd0; ioc_regs[5] <= 8'd0;
		ioc_regs[6] <= 8'd0; ioc_regs[7] <= 8'd0;
	end else begin
		// Main write takes priority
		if (main_cs & ~main_rnw) begin
			if (main_addr1) begin
				ioc_port <= main_wdata;
			end else begin
				if (ioc_port < 8'd8)
					ioc_regs[ioc_port] <= main_wdata;
			end
		end else if (sub_cs & ~sub_rnw) begin
			if (sub_addr1) begin
				ioc_port <= sub_wdata;
			end else begin
				if (ioc_port < 8'd8)
					ioc_regs[ioc_port] <= sub_wdata;
			end
		end
	end
end

endmodule
