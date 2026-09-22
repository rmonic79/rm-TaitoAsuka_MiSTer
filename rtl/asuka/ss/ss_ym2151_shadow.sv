/*  This file is part of Arcade_TaitoAsuka_MiSTer.

    Arcade_TaitoAsuka_MiSTer is free software: you can redistribute it
    and/or modify it under the terms of the GNU General Public License as
    published by the Free Software Foundation, either version 3 of the
    License, or (at your option) any later version.

    Arcade_TaitoAsuka_MiSTer is distributed in the hope that it will be
    useful, but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    Author: Umberto Parisi (rmonic79)
*/

//============================================================================
//  ss_ym2151_shadow — savestate del YM2151 SENZA toccare il chip.
//
//  Tecnica presa da Darius 1 (rtl/darius/ss/ss_ym_shadow.sv), mappa dei
//  registri riscritta per il YM2151, che e' un chip diverso dal YM2203 di la':
//
//    1. si INTERCETTANO le scritture del Z80 verso il chip e si tengono in una
//       memoria ombra (256 registri + una casella per canale per il key-on);
//    2. l'ombra si salva e si ricarica come una RAM qualunque;
//    3. al ricaricamento, con le CPU ferme, un iniettore RIGIOCA i registri sul
//       bus normale del chip. Il chip non viene resettato.
//
//  Differenze dal YM2203, e sono il motivo per cui quel file non si poteva
//  usare com'era:
//    - il key-on qui e' il registro 0x08 e porta il canale nei bit [2:0] (otto
//      canali), non 0x28 con quattro;
//    - CT1 e CT2, che su questa scheda scelgono il BANCO della ROM sonora,
//      stanno nel registro 0x1B: rigiocandolo torna a posto anche il banco, che
//      e' esattamente cio' che si rompeva ricaricando su Asuka;
//    - niente PSG, niente registri IOA/IOB.
//
//  Ordine della rigiocata: prima gli operatori, poi i canali, poi i registri
//  globali, infine key-off e key-on per canale. Il key-off prima del key-on
//  serve a dare il fronte di salita, altrimenti un canale gia' acceso prima del
//  salvataggio non riattacca e la nota resta muta.
//============================================================================

module ss_ym2151_shadow #(
	parameter SS_IDX_SH = -1
) (
	input  wire       clk,
	input  wire       reset,
	// tick a cui il chip campiona la scrittura: ogni operazione della rigiocata
	// deve restare sul bus per UN solo tick, come fa lo Z80.
	input  wire       ce_ym,

	// intercettazione dal modulo audio
	input  wire       ym_wr,        // scrittura verso il chip in corso
	input  wire       a0,           // 0 = indirizzo, 1 = dato
	input  wire [7:0] wdata,

	// livello del ricaricamento in corso: la rigiocata parte quando scende
	input  wire       ss_mem_read,
	output wire       replay_busy,

	// iniettore verso il modulo audio
	output wire       rp_active,
	output reg        rp_cs,
	output reg        rp_a0,
	output reg  [7:0] rp_data,
	output reg        rp_wr,

	ssbus_if.slave    ssb
);

// =====================================================================
// Intercettazione
// =====================================================================
reg [7:0] idx;
always @(posedge clk) begin
	if (reset)             idx <= 8'd0;
	else if (ym_wr && !a0) idx <= wdata;
end

// Il key-on (0x08) non si tiene al suo indirizzo ma una casella per canale,
// altrimenti si ricorderebbe solo l'ultimo canale toccato.
wire        is_keyon    = (idx == 8'h08);
wire [8:0]  snoop_addr  = is_keyon ? {6'h40, wdata[2:0]} : {1'b0, idx};
wire        snoop_wren  = ym_wr && a0;

// =====================================================================
// Memoria ombra 512x8: 0x000-0x0FF registri, 0x100-0x107 key-on per canale
// =====================================================================
reg [7:0] sh_ram [0:511];
reg [7:0] sh_q;
wire       sh_we;
wire [8:0] sh_addr;
wire [7:0] sh_wdata;

ss_ram_adaptor #(.WIDTH(8), .WIDTHAD(9), .SS_IDX(SS_IDX_SH)) u_ss_sh (
	.clk(clk),
	.wren_in(snoop_wren), .addr_in(snoop_addr), .wdata_in(wdata),
	.wren_out(sh_we), .addr_out(sh_addr), .wdata_out(sh_wdata),
	.q_in(sh_q),
	.ssbus(ssb)
);

reg [8:0] rp_rd_addr;
always @(posedge clk) begin
	if (sh_we) sh_ram[sh_addr] <= sh_wdata;
	sh_q <= sh_ram[replay_busy ? rp_rd_addr : sh_addr];
end

// =====================================================================
// Sequenza della rigiocata
//   0..191   operatori 0x40-0xFF
//   192..223 canali    0x20-0x3F
//   224..231 globali   0x0F, 0x18, 0x19, 0x1B, 0x10, 0x11, 0x12, 0x14
//   232..239 key-off   canali 0-7   (0x08, dato = solo il numero di canale)
//   240..247 key-on    canali 0-7   (0x08, dato dall'ombra)
// Codifica: bit[8]=0 registro diretto; bit[8]=1 key-entry, bit[4]=1 key-off.
// =====================================================================
localparam [7:0] SEQ_LAST = 8'd247;
function [8:0] seq_reg(input [7:0] i);
	reg [7:0] kch;
	begin
		if      (i <= 8'd191) seq_reg = {1'b0, 8'h40 + i};                 // operatori
		else if (i <= 8'd223) seq_reg = {1'b0, 8'h20 + (i - 8'd192)};      // canali
		else if (i <= 8'd231) case (i - 8'd224)
			0: seq_reg = 9'h00F;  1: seq_reg = 9'h018;
			2: seq_reg = 9'h019;  3: seq_reg = 9'h01B;   // CT1/CT2 = banco ROM
			4: seq_reg = 9'h010;  5: seq_reg = 9'h011;
			6: seq_reg = 9'h012;  default: seq_reg = 9'h014;
		endcase
		else if (i <= 8'd239) begin
			kch = i - 8'd232;
			seq_reg = {1'b1, 3'b001, 1'b0, kch[2:0]};   // key-off del canale
		end
		else if (i <= SEQ_LAST) begin
			kch = i - 8'd240;
			seq_reg = {1'b1, 4'b0000, kch[2:0]};        // key-on del canale
		end
		else seq_reg = 9'h1FF;
	end
endfunction

// Il chip resta occupato dopo una scrittura: si lascia un intervallo ampio.
localparam [13:0] GAP = 14'd16383;

reg  [2:0] rp_state;   // 0 fermo, 1 indirizzo, 2 pausa, 3 lettura ombra, 4 dato, 5 pausa, 6 avanti
reg  [7:0] rp_i;
reg [13:0] rp_gap;
reg        mem_read_d;
reg        rp_run;
reg        rp_seen;    // il chip ha gia' campionato questa operazione

assign replay_busy = rp_run;
assign rp_active   = rp_run;

wire [8:0] cur      = seq_reg(rp_i);
wire       cur_key  = cur[8];
wire       cur_koff = cur[8] & cur[4];
wire [7:0] cur_reg  = cur_key ? 8'h08 : cur[7:0];
// key-off: solo il numero di canale (nessuno slot acceso) -> spegne
wire [7:0] cur_data = cur_koff ? {5'd0, cur[2:0]} : sh_q;

always @(posedge clk) begin
	if (reset) begin
		rp_state <= 3'd0; rp_i <= 8'd0; rp_gap <= 14'd0;
		rp_run <= 1'b0; rp_seen <= 1'b0; mem_read_d <= 1'b0;
		rp_cs <= 1'b0; rp_wr <= 1'b0; rp_a0 <= 1'b0; rp_data <= 8'd0;
		rp_rd_addr <= 9'd0;
	end else begin
		mem_read_d <= ss_mem_read;
		// la rigiocata parte quando il ricaricamento e' finito
		if (mem_read_d && !ss_mem_read && !rp_run) begin
			rp_run <= 1'b1; rp_i <= 8'd0; rp_state <= 3'd1; rp_seen <= 1'b0;
		end

		case (rp_state)
		3'd0: begin rp_cs <= 1'b0; rp_wr <= 1'b0; end

		// indirizzo
		3'd1: begin
			rp_a0 <= 1'b0; rp_data <= cur_reg; rp_cs <= 1'b1; rp_wr <= 1'b1;
			if (ce_ym) begin
				rp_cs <= 1'b0; rp_wr <= 1'b0;
				rp_gap <= GAP; rp_state <= 3'd2;
			end
		end
		3'd2: if (rp_gap == 0) begin
				// l'indirizzo dell'ombra per il dato di questa operazione
				rp_rd_addr <= cur_key ? {6'h40, cur[2:0]} : {1'b0, cur[7:0]};
				rp_state <= 3'd3;
			end else rp_gap <= rp_gap - 14'd1;
		3'd3: rp_state <= 3'd4;   // attesa lettura ombra

		// dato
		3'd4: begin
			rp_a0 <= 1'b1; rp_data <= cur_data; rp_cs <= 1'b1; rp_wr <= 1'b1;
			if (ce_ym) begin
				rp_cs <= 1'b0; rp_wr <= 1'b0;
				rp_gap <= GAP; rp_state <= 3'd5;
			end
		end
		3'd5: if (rp_gap == 0) rp_state <= 3'd6;
			else rp_gap <= rp_gap - 14'd1;

		3'd6: begin
			if (rp_i == SEQ_LAST) begin
				rp_run   <= 1'b0;
				rp_state <= 3'd0;
			end else begin
				rp_i     <= rp_i + 8'd1;
				rp_state <= 3'd1;
			end
		end
		default: rp_state <= 3'd0;
		endcase
	end
end

endmodule
