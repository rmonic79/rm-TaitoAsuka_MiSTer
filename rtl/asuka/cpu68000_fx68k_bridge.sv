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

// cpu68000_fx68k_bridge — Bridge FX68K verso bus esterno.
// Traduce segnali DS/AS/DTACK dell'FX68K (core di Jorge Cwik) nel bus
// sincrono del core Darius. Gestisce dtack_cen e IRQ level.

module cpu68000_fx68k_bridge
#(
	parameter [0:0] CPU_ID = 1'b0
)
(
	input  wire        clk,
	input  wire        reset,
	input  wire        ce_cpu,       // phi1 clock enable from dtack_cen
	input  wire        ce_cpub,      // phi2 clock enable from dtack_cen
	input  wire [15:0] bus_rdata,
	input  wire        bus_dtackn,   // DTACK from jtframe_68kdtack_cen
	input  wire [2:0]  irq_level,

	output reg         active,
	output reg  [31:0] cycles,
	output reg  [23:0] bus_addr,
	output reg         bus_rd,
	output reg         bus_wr,
	output reg  [15:0] bus_wdata,
	output wire [1:0]  bus_dsn_out,
	output wire        fx_asn,       // AS directly from FX68K (for dtack_cen)
	output wire [1:0]  fx_dsn,       // {UDSn, LDSn} directly from FX68K
	output reg  [15:0] last_read,
	output wire [23:0] dbg_pc,
	output wire        iack,
	output wire [2:0]  cpu_fc,      // [SS] function code FC2:FC0 (serve a ss_m68k)
	output wire [31:0] dbg_d6,
	output wire [31:0] dbg_d7,
	output wire [31:0] dbg_d0,
	output wire [31:0] dbg_a0,
	output wire [31:0] dbg_a1
);

// 68000-style external bus signals (active-low controls).
wire [23:1] fx_addr;
wire [15:0] fx_data_out;
reg  [15:0] fx_data_in;
wire        fx_as_n;
wire        fx_uds_n;
wire        fx_lds_n;
wire        fx_rw;
wire [2:0]  fx_ipl_n;
wire        fx_halt_n;
wire        fx_fc0;
wire        fx_fc1;
wire        fx_fc2;

assign fx_halt_n = 1'b1;
assign bus_dsn_out = {fx_uds_n, fx_lds_n};
assign fx_asn = fx_as_n;
assign fx_dsn = {fx_uds_n, fx_lds_n};

// IRQ lines are active low on 68000.
assign fx_ipl_n = ~irq_level;

// IACK detection: FC2:FC0 = 111 during bus cycle = interrupt acknowledge
wire iack_cycle = fx_fc0 & fx_fc1 & fx_fc2;
assign iack = iack_cycle & ~fx_as_n;

wire lane_sel = (~fx_uds_n) | (~fx_lds_n);
wire bus_req  = (~fx_as_n) & lane_sel;
wire bus_rd_w = bus_req & fx_rw & ~iack_cycle;
wire bus_wr_w = bus_req & ~fx_rw & ~iack_cycle;
wire [2:0] fx_fc = {fx_fc2, fx_fc1, fx_fc0};
assign cpu_fc = fx_fc;   // [SS] esposto al driver savestate
wire prog_fetch_w = bus_rd_w && ((fx_fc == 3'b010) || (fx_fc == 3'b110));
reg  [23:0] dbg_pc_reg;

always @(*) begin
	bus_addr  = {fx_addr, 1'b0};
	bus_rd    = bus_rd_w;
	bus_wr    = bus_wr_w;
	bus_wdata = fx_data_out;
end

always @(posedge clk) begin
	if(reset) begin
		cycles     <= 32'd0;
		active     <= 1'b0;
		last_read  <= 16'd0;
		dbg_pc_reg <= 24'd0;
		fx_data_in <= 16'd0;
	end else begin
		if(ce_cpu) begin
			active <= 1'b1;
			cycles <= cycles + 32'd1;
		end

		// Latch data when DTACK is asserted (active low)
		if(bus_req && !bus_dtackn && !iack_cycle) begin
			if(prog_fetch_w)
				dbg_pc_reg <= {fx_addr, 1'b0};
			if(bus_rd_w) begin
				fx_data_in <= bus_rdata;
				last_read  <= bus_rdata;
			end
		end
	end
end

`ifdef USE_FX68K_CORE
	wire fx_e;
	wire fx_vma_n;
	wire fx_bg_n;
	wire fx_oreset_n;
	wire fx_ohalted_n;
	wire [31:0] fx_dbg_pc;

	fx68k cpu_core
	(
		.clk(clk),
		.HALTn(fx_halt_n),
		.extReset(reset),
		.pwrUp(reset),
		.enPhi1(ce_cpu),        // from jtframe_68kdtack_cen
		.enPhi2(ce_cpub),       // from jtframe_68kdtack_cen
		.eRWn(fx_rw),
		.ASn(fx_as_n),
		.LDSn(fx_lds_n),
		.UDSn(fx_uds_n),
		.E(fx_e),
		.VMAn(fx_vma_n),
		.FC0(fx_fc0),
		.FC1(fx_fc1),
		.FC2(fx_fc2),
		.BGn(fx_bg_n),
		.oRESETn(fx_oreset_n),
		.oHALTEDn(fx_ohalted_n),
		.DTACKn(bus_dtackn),    // from jtframe_68kdtack_cen
		.VPAn(iack_cycle ? 1'b0 : 1'b1),
		.BERRn(1'b1),
		.BRn(1'b1),
		.BGACKn(1'b1),
		.IPL0n(fx_ipl_n[0]),
		.IPL1n(fx_ipl_n[1]),
		.IPL2n(fx_ipl_n[2]),
		.iEdb(fx_data_in),
		.oEdb(fx_data_out),
		.eab(fx_addr),
		.dbgPc(fx_dbg_pc),
		.dbg_d6(dbg_d6),
		.dbg_d7(dbg_d7),
		.dbg_d0(dbg_d0),
		.dbg_a0(dbg_a0),
		.dbg_a1(dbg_a1)
	);
	assign dbg_pc = dbg_pc_reg;
`else
	// Fallback stub
	reg [23:1] fake_addr;
	reg [15:0] fake_data_out;
	reg        fake_as_n, fake_uds_n, fake_lds_n, fake_rw;
	reg        phase;

	always @(posedge clk) begin
		if(reset) begin
			fake_addr     <= 23'd0;
			fake_data_out <= 16'd0;
			fake_as_n     <= 1'b1;
			fake_uds_n    <= 1'b1;
			fake_lds_n    <= 1'b1;
			fake_rw       <= 1'b1;
			phase         <= 1'b0;
		end else begin
			fake_as_n  <= 1'b1;
			fake_uds_n <= 1'b1;
			fake_lds_n <= 1'b1;
			if(ce_cpu) begin
				if(CPU_ID == 1'b0) begin
					fake_rw    <= 1'b1;
					fake_addr  <= phase ? 23'h000001 : 23'h000000;
					fake_as_n  <= 1'b0;
					fake_uds_n <= 1'b0;
					fake_lds_n <= 1'b0;
					if(!bus_dtackn) phase <= ~phase;
				end else begin
					fake_rw       <= 1'b0;
					fake_addr     <= 23'h700810;
					fake_data_out <= {8'h5A, 5'd0, irq_level};
					fake_as_n     <= 1'b0;
					fake_uds_n    <= 1'b0;
					fake_lds_n    <= 1'b0;
				end
			end
		end
	end

	assign fx_addr     = fake_addr;
	assign fx_data_out = fake_data_out;
	assign fx_as_n     = fake_as_n;
	assign fx_uds_n    = fake_uds_n;
	assign fx_lds_n    = fake_lds_n;
	assign fx_rw       = fake_rw;
	assign fx_fc0      = 1'b0;
	assign fx_fc1      = 1'b0;
	assign fx_fc2      = 1'b0;
	assign dbg_pc      = {fx_addr, 1'b0};
	assign dbg_d6      = 32'd0;
	assign dbg_d7      = 32'd0;
	assign dbg_d0      = 32'd0;
	assign dbg_a0      = 32'd0;
	assign dbg_a1      = 32'd0;
`endif

endmodule
