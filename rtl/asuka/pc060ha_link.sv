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

// pc060ha_link — PC060HA Communication Interface Unit.
// Scambio bidirezionale tra Main 68K e Z80 audio tramite pointer register,
// shared RAM 4 slot, flag full/empty e NMI trigger.
// Single-clock rewrite ispirato a jtrastan_pc060 (JTCORES by Jose Tejada),
// implementato secondo la descrizione di pc060ha_device in MAME.
//
// Protocol:
//   Each side (master/slave) has a 4-bit pointer register.
//   Write addr=0: set pointer to data[3:0]
//   Read/Write addr=1:
//     ptr[2]=0: access shared RAM at ptr[1:0], then ptr++
//       ptr=1 write → set "full" flag for other side (triggers NMI on slave)
//       ptr=1 read  → clear own "full" flag
//     ptr[2]=1: read returns status {main_full, snd_full}
//       ptr=5: flag <= 1 (master: sub_reset, slave: nmi_enable)
//       ptr=6: flag <= 0
//
// Signals are latched while CS is high, processed on falling edge of CS.

module pc060ha_link (
	input  wire       clk,
	input  wire       reset,

	// Main 68000 side (C00001 = port, C00003 = comm)
	input  wire       main_cs,
	input  wire       main_addr,    // 0=port, 1=comm
	input  wire       main_wr,
	input  wire       main_rd,
	input  wire [7:0] main_wdata,
	output wire [7:0] main_rdata,

	// Sound Z80 side (B000 = port, B001 = comm)
	input  wire       snd_cs,
	input  wire       snd_addr,     // 0=port, 1=comm
	input  wire       snd_wr,
	input  wire       snd_rd,
	input  wire [7:0] snd_wdata,
	output wire [7:0] snd_rdata,

	// Control outputs
	output wire       snd_nmi_n,    // NMI to Z80 #1 (active low)
	output wire       snd_reset,    // reset to audio Z80s
	// Debug
	output wire [1:0] dbg_snd_full,
	output wire [1:0] dbg_main_full,

	// [SS] handshake salvato e ricaricato dal top, 46 bit:
	// share_ram 8x4 + main_ptr 4 + snd_ptr 4 + snd_full 2 + main_full 2 +
	// main_flag 1 + snd_flag 1. Stesso impianto del PC060HA di Darius 1.
	output wire [45:0] ss_out,
	input  wire        ss_ld,
	input  wire [45:0] ss_in
);

// Pointer registers
reg [3:0] main_ptr, snd_ptr;

// Full flags (named like JTCORES jtrastan_pc060)
// snd_full: data from main waiting for sound (set by main write, cleared by sound read)
// main_full: data from sound waiting for main (set by sound write, cleared by main read)
reg [1:0] snd_full;
reg [1:0] main_full;

// Flags
reg main_flag;  // sub_reset
reg snd_flag;   // nmi_enable

// Shared RAM — 4-bit nibbles (matches real PC060HA chip)
reg [3:0] share_ram [0:7];

// [SS] fotografia dello stato persistente
assign ss_out = {share_ram[7], share_ram[6], share_ram[5], share_ram[4],
                 share_ram[3], share_ram[2], share_ram[1], share_ram[0],
                 main_ptr, snd_ptr, snd_full, main_full, main_flag, snd_flag};

// Status word
wire [3:0] status = {main_full, snd_full};

// NMI and reset outputs
assign snd_nmi_n = snd_flag | (snd_full[1:0] == 2'b00);
assign snd_reset = main_flag;
assign dbg_snd_full = snd_full;
assign dbg_main_full = main_full;

// Read mux: main reads from snd's side of RAM, snd reads from main's side
assign main_rdata = main_ptr[2] ? {4'd0, status} : {4'd0, share_ram[{1'b1, main_ptr[1:0]}]};
assign snd_rdata  = snd_ptr[2]  ? {4'd0, status} : {4'd0, share_ram[{1'b0, snd_ptr[1:0]}]};

// Latch signals while CS is high (captured before falling edge)
reg       main_wr_lat, main_rd_lat, main_addr_lat;
reg [7:0] main_wdata_lat;
reg       snd_wr_lat, snd_rd_lat, snd_addr_lat;
reg [7:0] snd_wdata_lat;

// Edge detection
reg main_cs_prev, snd_cs_prev;
wire main_falling = main_cs_prev & ~main_cs;
wire snd_falling  = snd_cs_prev  & ~snd_cs;

always @(posedge clk) begin
	if (reset) begin
		main_ptr   <= 4'd0;
		snd_ptr    <= 4'd0;
		main_full  <= 2'b00;
		snd_full   <= 2'b00;
		main_flag  <= 1'b0;
		snd_flag   <= 1'b0;
		main_cs_prev <= 1'b0;
		snd_cs_prev  <= 1'b0;
		main_wr_lat <= 0; main_rd_lat <= 0; main_addr_lat <= 0;
		snd_wr_lat  <= 0; snd_rd_lat  <= 0; snd_addr_lat  <= 0;
	end else if (ss_ld) begin
		// [SS] ricarica nello stesso ordine di ss_out, con le CPU ferme
		{share_ram[7], share_ram[6], share_ram[5], share_ram[4],
		 share_ram[3], share_ram[2], share_ram[1], share_ram[0],
		 main_ptr, snd_ptr, snd_full, main_full, main_flag, snd_flag} <= ss_in;
	end else begin
		main_cs_prev <= main_cs;
		snd_cs_prev  <= snd_cs;

		// Latch main signals while CS is active
		if (main_cs) begin
			main_wr_lat    <= main_wr;
			main_rd_lat    <= main_rd;
			main_addr_lat  <= main_addr;
			main_wdata_lat <= main_wdata;
		end

		// Latch sound signals while CS is active
		if (snd_cs) begin
			snd_wr_lat    <= snd_wr;
			snd_rd_lat    <= snd_rd;
			snd_addr_lat  <= snd_addr;
			snd_wdata_lat <= snd_wdata;
		end

		// === Main side — process on falling edge of CS ===
		if (main_falling) begin
			if (main_wr_lat && !main_addr_lat) begin
				// Port write (addr=0): set pointer
				main_ptr <= main_wdata_lat[3:0];
			end else begin
				// Comm access (addr=1) or port read
				if (!main_ptr[2]) main_ptr <= main_ptr + 4'd1;
				// RAM write: all ptr with ptr[2]=0, comm write (like JTCORES ram_we)
				if (main_wr_lat && main_addr_lat && !main_ptr[2])
					share_ram[{1'b0, main_ptr[1:0]}] <= main_wdata_lat[3:0];
				// Flag/full logic per ptr value
				case (main_ptr)
					4'd1: begin
						if (main_wr_lat)
							snd_full[0] <= 1'b1;    // signal TO sound
						else
							main_full[0] <= 1'b0;   // ack FROM sound
					end
					4'd3: begin
						if (main_wr_lat)
							snd_full[1] <= 1'b1;    // signal TO sound
						else
							main_full[1] <= 1'b0;   // ack FROM sound
					end
					4'd4: if (main_wr_lat) main_flag <= main_wdata_lat[0];
					4'd5: main_flag <= 1'b1;
					4'd6: main_flag <= 1'b0;
					default: ;
				endcase
			end
		end

		// === Sound side — process on falling edge of CS ===
		if (snd_falling) begin
			if (snd_wr_lat && !snd_addr_lat) begin
				// Port write (addr=0): set pointer
				snd_ptr <= snd_wdata_lat[3:0];
			end else begin
				if (!snd_ptr[2]) snd_ptr <= snd_ptr + 4'd1;
				// RAM write: all ptr with ptr[2]=0, comm write
				if (snd_wr_lat && snd_addr_lat && !snd_ptr[2])
					share_ram[{1'b1, snd_ptr[1:0]}] <= snd_wdata_lat[3:0];
				// Flag/full logic per ptr value
				case (snd_ptr)
					4'd1: begin
						if (snd_wr_lat)
							main_full[0] <= 1'b1;   // signal TO main
						else
							snd_full[0] <= 1'b0;    // ack FROM main
					end
					4'd3: begin
						if (snd_wr_lat)
							main_full[1] <= 1'b1;   // signal TO main
						else
							snd_full[1] <= 1'b0;    // ack FROM main
					end
					4'd4: if (snd_wr_lat) snd_flag <= snd_wdata_lat[0];
					4'd5: snd_flag <= 1'b1;
					4'd6: snd_flag <= 1'b0;
					default: ;
				endcase
			end
		end
	end
end

endmodule
