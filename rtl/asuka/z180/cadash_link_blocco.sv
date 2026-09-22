/*  Cadash link — il blocco ricevuto si mostra al 68000 solo quando e' intero.
    GPL-3.  Author: Umberto Parisi (rmonic79), 2026.
*/

//============================================================================
//  cadash_link_blocco
//
//  Lo Z180, appena riceve il primo byte di un blocco, lo scrive a $800200:
//  quel byte E' LA LUNGHEZZA ($0091 `ld (hl),a`, poi `ld c,a` per contare).
//  Da quell'istante $800200 e' diverso da zero, ma del blocco c'e' un byte
//  solo. Il resto arriva a 50 kbaud, 0,245 ms per byte.
//
//  Il 68000 legge il blocco su IRQ5, una volta per frame ($000810 -> $0048A0),
//  e decide di leggerlo proprio perche' $800200 non e' zero. Somma `lunghezza`
//  parole e pretende zero nel byte basso — ma il checksum e' l'ULTIMA parola
//  del blocco ($00498C `neg.w d5`). Se IRQ5 casca durante il riempimento, il
//  68000 somma una coda vecchia: checksum sbagliato, e a $0048E6 la CPU si
//  ferma per sempre (`ori #$700,sr` + `bra` su se stesso). Nel firmware non
//  esiste nessun segnale di "blocco completo": cercato, non c'e'.
//
//  Misurato sull'hardware, traccia presa dai due ponti insieme: blocchi da 4 e
//  6 byte (1-1,5 ms di riempimento su un frame da 16,7) passano lisci otto
//  volte di fila; al primo blocco da 27 byte — 6,6 ms, il 40% del frame — il
//  gioco muore. Sul filo tutti i byte sono integri e tutti i checksum tornano:
//  la corsa e' fra chi scrive e chi legge, non sul canale. Per questo non la
//  sistemano ne' la guardia sul CTS ne' la velocita' del ponte: le abbiamo
//  provate tutte e due e non cambiano niente.
//
//  Qui la scrittura della LUNGHEZZA viene trattenuta e consegnata solo quando
//  l'ultimo byte del blocco e' in RAM. Il 68000 o non vede niente, o vede il
//  blocco intero. Non dipende piu' da fase, velocita' o latenza.
//
//  Se il blocco non si completa (link caduto a meta'), la lunghezza non arriva
//  mai: il gioco semplicemente non riceve quel blocco — e ha il suo timeout —
//  invece di piantarsi su un checksum sbagliato.
//
//  BYPASS=1 lo disattiva: serve al banco per far vedere il guasto, perche' un
//  banco che non sa fallire non dimostra niente quando passa.
//============================================================================

`timescale 1ns / 1ps

module cadash_link_blocco #(
	parameter [10:0] ADDR_LEN = 11'h100,   // $800200: lunghezza del blocco RX
	parameter integer BYPASS  = 0
) (
	input  wire        clk,
	input  wire        reset,

	// dal lato Z180
	input  wire        z_wr,
	input  wire [10:0] z_addr,
	input  wire [7:0]  z_dato,

	// verso la RAM condivisa
	output wire        wr,
	output wire [10:0] addr,
	output wire [7:0]  dato
);

reg  [7:0]  lung_sospesa;
reg  [10:0] fine_blocco;
reg         tieni;
reg         consegna;

// Primo byte di un blocco nuovo: e' la lunghezza, e la si trattiene.
// Vale ANCHE se ne stavamo gia' aspettando uno: se il blocco precedente non
// si e' mai completato — avvio, aggancio a meta', un core riavviato — quella
// attesa resterebbe appesa per sempre, e la lunghezza del blocco dopo
// passerebbe dritta al 68000, che leggerebbe un blocco monco. E' il guasto
// che si vede come instabilita' all'avvio: una volta parte, una volta da'
// checksum error, una volta schermo nero. Una lunghezza nuova riarma sempre.
wire prende_lung = z_wr & (z_addr == ADDR_LEN) & (z_dato != 8'h00) & ~tieni;

// Il blocco e' intero quando arriva la scrittura all'ULTIMO suo indirizzo.
// Ci si aggancia all'INDIRIZZO, non a un conteggio di scritture: durante la
// ricezione lo Z180 scrive anche altrove ($8002-$8005, $87FE-$87FF, il suo
// stato) e contare quelle farebbe uscire la lunghezza prima che il blocco sia
// finito — cioe' rimetterebbe in piedi esattamente la corsa che si vuole
// togliere. Da fermo quasi non si nota; appena si gioca, quelle scritture di
// servizio aumentano e il guasto torna subito.
wire ultimo = z_wr & tieni & (z_addr == fine_blocco);

always @(posedge clk) begin
	consegna <= ultimo;
	if (reset) begin
		tieni <= 1'b0;
	end else if (prende_lung) begin
		lung_sospesa <= z_dato;
		fine_blocco  <= ADDR_LEN + {3'd0, z_dato} - 11'd1;
		tieni        <= 1'b1;
	end else if (ultimo) begin
		tieni <= 1'b0;
	end
end

// L'ultimo byte del carico si scrive normalmente; la lunghezza va al ciclo
// dopo. L'ordine e' tutto: la lunghezza deve arrivare per ULTIMA, perche' e'
// lei che dice al 68000 "c'e' un blocco da leggere".
assign wr   = BYPASS ? z_wr   : ((z_wr & ~prende_lung) | consegna);
assign addr = BYPASS ? z_addr : (consegna ? ADDR_LEN : z_addr);
assign dato = BYPASS ? z_dato : (consegna ? lung_sospesa : z_dato);

endmodule
