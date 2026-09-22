/*  This file is part of Arcade_TaitoAsuka_MiSTer.
    GPL-3.
    Author: Umberto Parisi (rmonic79), 2026.
*/

//============================================================================
//  cadash_link_rom — la ROM del sotto-sistema di comunicazione, c21-07.57.
//
//  32 KB in BRAM, riempiti durante il download dell'MRA. Nel flusso la ROM sta
//  gia' al suo posto da sempre:
//
//      <!-- Sub CPU Z180 (32 KB) -->  0x0C0000-0x0C7FFF
//      <part name="c21-07.57" crc="f02292bd"/>
//
//  Perche' BRAM e non SDRAM, visto che il canale `sub_rom_*` esisterebbe gia':
//  se il canale seriale sbaglia anche un solo byte, il gioco scrive a video
//  COMMUNICATION CHECKSUM ERROR e BLOCCA il 68000 con ori #$700,sr e un loop
//  infinito. Una ROM in BRAM ha latenza fissa e nessuna contesa con la grafica;
//  in SDRAM la latenza dipenderebbe da quanto lavora il video. Per 32 M10K non
//  vale la pena rischiare un blocco della CPU.
//============================================================================

`timescale 1ns / 1ps

module cadash_link_rom (
	input  wire        clk,

	// --- riempimento dall'MRA ---
	input  wire        ioctl_download,
	input  wire        ioctl_wr,
	input  wire [26:0] ioctl_addr,
	input  wire [15:0] ioctl_dout,
	input  wire [15:0] ioctl_index,

	// --- lettura, un byte per volta. Registrata: il dato esce UN ciclo dopo
	//     l'indirizzo. Non e' un problema perche' il PHI dello Z180 e' un
	//     dodicesimo del clock di sistema: l'indirizzo e' fermo da un pezzo.
	input  wire [14:0] addr,
	output wire [7:0]  data
);

localparam [26:0] BASE = 27'h0C0000;   // dove la MRA mette c21-07.57
localparam [26:0] FINE = 27'h0C8000;

wire nostro = ioctl_download && (ioctl_index == 16'd0)
              && (ioctl_addr >= BASE) && (ioctl_addr < FINE);

// Ogni scrittura ioctl porta una word: due byte consecutivi della ROM.
// Il byte PARI arriva nella meta' BASSA della word, il dispari nell'alta.
// Non e' una deduzione dal formato dell'MRA: e' misurato in simulazione, con
// la CPU in reset e l'indirizzo a zero la ROM restituiva $31, cioe' il SECONDO
// byte di "F3 31 00 88..." — quindi l'ordine e' quello opposto.
// ioctl_addr e' in byte e avanza di 2 a ogni word; BASE ha i 15 bit bassi a
// zero, quindi ioctl_addr[14:1] e' gia' l'indice di word dentro la ROM.
wire [13:0] wr_word = ioctl_addr[14:1];

// Un indirizzo solo per porta, altrimenti Quartus non inferisce l'M10K: durante
// il download comanda l'ioctl, a valle comanda la CPU. Non si sovrappongono —
// il gioco sta in reset finche' l'MRA non ha finito di scaricare.
wire [13:0] a = nostro ? wr_word : addr[14:1];
wire        we = nostro & ioctl_wr;

(* ramstyle = "M10K,no_rw_check" *) reg [7:0] mem_pari   [0:16383];
(* ramstyle = "M10K,no_rw_check" *) reg [7:0] mem_dispari[0:16383];

reg [7:0] q_pari, q_dispari;
reg       addr0_r;

always @(posedge clk) begin
	if (we) mem_pari[a] <= ioctl_dout[7:0];
	q_pari <= mem_pari[a];
end

always @(posedge clk) begin
	if (we) mem_dispari[a] <= ioctl_dout[15:8];
	q_dispari <= mem_dispari[a];
end

always @(posedge clk) addr0_r <= addr[0];

assign data = addr0_r ? q_dispari : q_pari;

endmodule
