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

// asuka_cpu_node — Wrapper 68000 unificato.
// IDENTICO a darius_core/rtl/darius/darius_cpu_node.sv — NON modificare.
// Se servono debug signals o ext_dtack, gestirli FUORI dal cpu_node.

module asuka_cpu_node
#(
	parameter [0:0] CPU_ID = 1'b0,
	parameter [1:0] CORE_IMPL = 2'd1
)
(
	input  wire        clk,
	input  wire        reset,
	input  wire        soft_reset,
	input  wire        halt_n,
	input  wire  [6:0] clk_num,
	input  wire  [7:0] clk_den,
	input  wire [2:0]  ipl_n,
	input  wire [15:0] bus_din,
	input  wire        bus_cs,
	input  wire        bus_busy,
	input  wire        dev_br,
	output wire [23:0] bus_addr,
	output wire        bus_asn,
	output wire        bus_rnw,
	output wire [1:0]  bus_dsn,
	output wire [15:0] bus_dout,
	output wire [23:0] dbg_pc,
	output wire [2:0]  dbg_fc,
	output wire        dbg_dtackn,
	output wire [15:0] dbg_fave,
	output wire [15:0] dbg_fworst,
	output wire        iack,
	// Debug taps — pass-through dal bridge, zero logica, zero effetto funzionale
	output wire [31:0] dbg_d6,
	output wire [31:0] dbg_d7,
	output wire [31:0] dbg_d0,
	output wire [31:0] dbg_a0,
	output wire [31:0] dbg_a1
);

// jtframe_68kdtack_cen generates cpu_cen/cpu_cenb at 8MHz average
// with cycle recovery for SDRAM stalls
wire        cpu_cen, cpu_cenb;
wire        dtack_n;
wire        cpu_active;
wire [31:0] cpu_cycles;
wire [23:0] cpu_bus_addr;
wire        cpu_bus_rd;
wire        cpu_bus_wr;
wire [15:0] cpu_bus_wdata;
wire [15:0] cpu_last_read_unused;
wire [23:0] cpu_dbg_pc;
wire        cpu_iack;
wire [2:0]  cpu_fc_w;    // [SS] FC2:FC0 dal bridge
wire [1:0]  cpu_dsn_out;
wire [2:0]  irq_level = ~ipl_n;

// FX68K signals needed by dtack module
wire        fx_asn;
wire [1:0]  fx_dsn;

// bus_ready is not used anymore — dtack_cen handles it internally
// bus_cs and bus_busy go directly to dtack_cen

jtframe_68kdtack_cen #(.W(8), .RECOVERY(1)) u_dtack (
	.rst        ( reset | soft_reset ),
	.clk        ( clk               ),
	.cpu_cen    ( cpu_cen            ),
	.cpu_cenb   ( cpu_cenb           ),
	.bus_cs     ( bus_cs             ),
	.bus_busy   ( bus_busy           ),
	.bus_legit  ( 1'b0              ),  // no legit waits in our design
	.bus_ack    ( 1'b0              ),  // no bus arbitration
	.ASn        ( fx_asn             ),
	.DSn        ( fx_dsn             ),
	.num        ( clk_num           ),
	.den        ( clk_den           ),
	.wait2      ( 1'b0              ),
	.wait3      ( 1'b0              ),
	.DTACKn     ( dtack_n           ),
	.fave       ( dbg_fave          ),
	.fworst     ( dbg_fworst        )
);

// Pause: gate cpu_cen/cpu_cenb when halt_n=0 → CPU smette di avanzare
wire cpu_cen_g  = cpu_cen  & halt_n;
wire cpu_cenb_g = cpu_cenb & halt_n;

cpu68000_fx68k_bridge #(.CPU_ID(CPU_ID)) u_bridge (
	.clk(clk),
	.reset(reset | soft_reset),
	.ce_cpu(cpu_cen_g),
	.ce_cpub(cpu_cenb_g),
	.bus_rdata(bus_din),
	.bus_dtackn(dtack_n),
	.irq_level(irq_level),
	.active(cpu_active),
	.cycles(cpu_cycles),
	.bus_addr(cpu_bus_addr),
	.bus_rd(cpu_bus_rd),
	.bus_wr(cpu_bus_wr),
	.bus_wdata(cpu_bus_wdata),
	.bus_dsn_out(cpu_dsn_out),
	.fx_asn(fx_asn),
	.fx_dsn(fx_dsn),
	.last_read(cpu_last_read_unused),
	.dbg_pc(cpu_dbg_pc),
	.iack(cpu_iack),
	.cpu_fc(cpu_fc_w),
	.dbg_d6(dbg_d6),
	.dbg_d7(dbg_d7),
	.dbg_d0(dbg_d0),
	.dbg_a0(dbg_a0),
	.dbg_a1(dbg_a1)
);

assign bus_addr    = cpu_bus_addr;
assign bus_asn     = fx_asn;
assign bus_rnw     = cpu_bus_rd;
assign bus_dsn     = cpu_dsn_out;
assign bus_dout    = cpu_bus_wdata;
assign dbg_pc      = cpu_dbg_pc;
assign dbg_fc      = cpu_fc_w;   // [SS] function code reale dal bridge
assign dbg_dtackn  = dtack_n;
assign iack        = cpu_iack;

endmodule
