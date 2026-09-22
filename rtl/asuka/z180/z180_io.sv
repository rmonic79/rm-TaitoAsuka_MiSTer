/*  This file is part of Arcade_TaitoAsuka_MiSTer.
    GPL-3.
    Author: Umberto Parisi (rmonic79), 2026.
*/

//============================================================================
//  z180_io — spazio I/O interno dello Z8018x / HD64180.
//
//  Sul chip vero i registri interni stanno agli indirizzi I/O $00-$3F (con ICR
//  che puo' rilocarli; qui si resta al default). La CPU li raggiunge con
//  IN0/OUT0, che scattano solo quando A15..A8 = 0 -> quindi la decodifica
//  guarda l'indirizzo basso e richiede che quello alto sia nullo.
//
//  Cosa e' implementato, e perche' solo questo: la ROM del link di Cadash
//  (c21-07.57, 32 KB) e' stata scandita opcode per opcode e tocca ESATTAMENTE
//  questi registri, niente altro:
//
//      IN0  : CNTLB0 $02 (x5)   STAT0 $04 (x2)   RDR0 $08 (x2)
//      OUT0 : CNTLA0 $00 (x6)   CNTLB0 $02 (x1)  STAT0 $04 (x1)  TDR0 $06 (x1)
//             DMODE $32 (x1, valore $40)   RCR $36 (x1, valore $00)
//
//  Niente MMU, niente timer, niente DMA attivo, niente ASCI1, niente ITC.
//  Gli altri registri esistono come RAM (si scrivono e si rileggono) cosi' il
//  giorno che si completa lo Z180 non cambia nulla di quello che c'e' gia'.
//============================================================================

`timescale 1ns / 1ps

module z180_io #(
	parameter integer PHI_DIV = 1
) (
	input  wire        clk,
	input  wire        reset,
	input  wire        ce,

	// --- lato CPU (IN0/OUT0 del T80 con Z180=1) ---
	input  wire [15:0] addr,        // indirizzo I/O completo
	input  wire        iorq,
	input  wire        rd,
	input  wire        wr,
	input  wire [7:0]  din,
	output reg  [7:0]  dout,
	output wire        sel,         // 1 = l'accesso e' per un registro interno

	// --- seriale, verso la porta user del MiSTer ---
	input  wire        rxd,
	output wire        txd,
	input  wire        cts_n,
	output wire        rts_n,
	output wire        re_attivo,
	output wire        te_attivo,
	input  wire        dcd_n,

	output wire        irq
);

// Registri interni: A15..A8 = 0 e indirizzo basso entro $00-$3F.
// (ICR puo' spostare la finestra sul chip vero; il link non lo usa.)
wire [7:0] a = addr[7:0];
assign sel = (addr[15:8] == 8'h00) && (a <= 8'h3F);

// --- ASCI canale 0: registri $00,$02,$04,$06,$08 ---
wire asci0_hit = sel && (a == 8'h00 || a == 8'h02 || a == 8'h04 ||
                         a == 8'h06 || a == 8'h08);

// mappa l'indirizzo I/O sull'indice interno del modulo ASCI
reg [2:0] asci_idx;
always @(*) begin
	case (a)
	8'h00:   asci_idx = 3'd0;   // CNTLA0
	8'h02:   asci_idx = 3'd1;   // CNTLB0
	8'h04:   asci_idx = 3'd2;   // STAT0
	8'h06:   asci_idx = 3'd3;   // TDR0
	8'h08:   asci_idx = 3'd4;   // RDR0
	default: asci_idx = 3'd0;
	endcase
end

wire [7:0] asci0_dout;

z180_asci #(.PHI_DIV(PHI_DIV)) u_asci0 (
	.clk(clk), .reset(reset), .ce(ce),
	.io_addr(asci_idx),
	.io_rd(rd & iorq & asci0_hit),
	.io_wr(wr & iorq & asci0_hit),
	.io_din(din),
	.io_dout(asci0_dout),
	.rxd(rxd), .txd(txd),
	.cts_n(cts_n), .rts_n(rts_n), .dcd_n(dcd_n),
	.re_attivo(re_attivo), .te_attivo(te_attivo),
	.irq(irq)
);

// --- gli altri registri interni: RAM semplice ---
// DMODE ($32) e RCR ($36) sono scritti una volta sola all'avvio e mai riletti:
// accettarli e conservarli e' sufficiente e fedele. Gli altri stanno qui per
// non far sparire scritture che un domani potrebbero servire.
reg [7:0] regs [0:63];
integer k;
always @(posedge clk) begin
	if (reset) begin
		for (k = 0; k < 64; k = k + 1) regs[k] <= 8'h00;
		// valori di reset documentati (manuale UM005004)
		regs[6'h32] <= 8'h00;   // DMODE
		regs[6'h33] <= 8'hF0;   // DCNTL
		regs[6'h36] <= 8'hFC;   // RCR
		regs[6'h3A] <= 8'hF0;   // CBAR
		regs[6'h3F] <= 8'h00;   // ICR
	end else if (wr && iorq && sel && !asci0_hit) begin
		regs[a[5:0]] <= din;
	end
end

always @(*) begin
	if (asci0_hit) dout = asci0_dout;
	else if (sel)  dout = regs[a[5:0]];
	else           dout = 8'hFF;
end

endmodule
