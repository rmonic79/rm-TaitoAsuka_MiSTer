/*  This file is part of Arcade_TaitoAsuka_MiSTer.
    GPL-3.
    Author: Umberto Parisi (rmonic79), 2026.
*/

//============================================================================
//  cadash_link_z180 — il sotto-sistema di comunicazione di Cadash.
//
//  Sul cabinato originale ogni scheda ha un HD64180RP8 (Z180) che parla con
//  quello dell'altra scheda via ASCI. Il 68000 non vede la rete: vede una RAM
//  condivisa e scambia messaggi con il proprio Z180.
//
//      m68k M -> z180 M <--(ASCI, seriale)--> z180 S <- m68k S
//
//  Su MiSTer i due Z180 si parlano attraverso la PORTA USER: TXD/RXD sono due
//  delle sette linee, e due macchine si collegano come due cabinati.
//
//  Mappa dello Z180 (MAME asuka.cpp, cadash_state::sub_map):
//      $0000-$7FFF   ROM   (c21-07.57, 32 KB)
//      $8000-$87FF   RAM condivisa col 68000 (2 KB)
//      I/O $00-$3F   registri interni  -> z180_io
//
//  La RAM condivisa vista dai due lati (MAME asuka.cpp:709-723):
//      $8000  'M' (0x4D) = questa scheda e' MASTER, altro = SLAVE
//      $8002  'T' se sta trasmettendo, 'R' se sta ricevendo
//      $8080-$80FF  dati SLAVE   (= $800100 lato 68000)
//      $8100-$817F  dati MASTER  (= $800200 lato 68000)
//
//  Il 68000 la vede a $800000-$800FFF, un byte per word (per questo MAME fa
//  `data & 0xff`): word N del 68000 <-> byte N dello Z180.
//
//  Configurazione della linea, letta dai valori che la ROM scrive:
//      CNTLB0 = $10  -> prescaler /10, SS=0, ratio /16   => baud = PHI/160
//                       PEO=1 -> parita' DISPARI
//      CNTLA0 = $36/$26/$46/$56 -> MOD=110: 8 bit dati, parita', 1 stop
//                       RE e TE non sono MAI attivi insieme: HALF-DUPLEX
//
//  L'half-duplex e' comodo: sulla porta user basta una linea dati per verso, e
//  il verso lo dichiara il gioco stesso col flag 'T'/'R' a $8002.
//============================================================================

`timescale 1ns / 1ps

module cadash_link_z180 #(
	// Trattenere o no la LUNGHEZZA del blocco ricevuto fino a blocco completo.
	//   0 = come la scheda vera: la lunghezza compare col PRIMO byte ($0091
	//       `ld (hl),a`), quindi la IRQ5 trova sempre qualcosa da leggere.
	//   1 = trattenuta fino all'ultimo byte (commit atomico).
	//
	// MISURATO: toglierlo NON cambia il ritmo (33,79 ms identici), ma toglie la
	// protezione contro la lettura di un blocco a meta' riempimento — e con
	// $3404 acceso un checksum sbagliato FERMA la CPU ($0048E6). Su SNAC, dove
	// il blocco impiega quasi un millisecondo, il link parte e si rompe subito.
	// Quindi resta a 1. La causa della meta' velocita' e' un'altra: il comando 7
	// che azzera $3404 non viaggia mai (nessun blocco piu' lungo di 4 byte).
	//
	// Al vblank ($0008EC) il 68000 trasmette SOLO se nel frame precedente ha
	// ricevuto qualcosa: `tst.b $3405(a5) / bne $904 -> jsr $490a`, e $3405 lo
	// accende la routine di lettura ($0048FA) quando trova $800200 non vuoto.
	// Trattenendo la lunghezza, un blocco che finisce di arrivare DOPO la IRQ5
	// non viene letto in quel frame: $3405 resta spento, al vblank dopo non si
	// trasmette, l'altra macchina non riceve e a sua volta non trasmette. Il
	// giro si aggancia a uno scambio ogni due frame e non ne esce piu'.
	// Sulla scheda vera non succede perche' la lunghezza c'e' subito: anche un
	// blocco a meta' viene letto, al limite scartato dal checksum, ma $3405 si
	// accende e la catena non si ferma mai.
	parameter integer COMMIT_ATOMICO = 1,
	// PHI_DIV serve SOLO se `ce` e' piu' veloce del PHI dello Z180 (per esempio
	// tenuto fisso a 1). Se `ce` e' il vero clock enable del PHI — ed e' cosi'
	// nel core — il valore giusto e' 1, e il baud viene PHI/160 da solo.
	parameter integer PHI_DIV = 1,
	// Ogni quanto ritentare l'iniezione del comando 7 quando il link e' lento.
	// 96 M cicli = 1 secondo.
	parameter integer INIEZIONE_OGNI = 96_000_000,
	// Sopra questo periodo fra due blocchi il link e' considerato LENTO.
	// Un frame e' 1.622.016 cicli; qui un frame e mezzo.
	parameter integer SOGLIA_LENTO   = 2_433_024
) (
	input  wire        clk,
	input  wire        reset,
	input  wire        ce,             // clock enable = PHI dello Z180

	// --- ROM del sotto-sistema (c21-07.57), caricata dall'MRA ---
	output wire [14:0] rom_addr,
	input  wire [7:0]  rom_data,

	// --- RAM condivisa ($8000-$87FF), fuori dal modulo ---
	// La memoria non sta qui dentro: e' la Port B di `asuka_shared_ram`, quella
	// che il 68000 vede a $800000-$800FFF dalla Port A. Una sola memoria, due
	// porte, come sul cabinato — e nessun M10K in piu'.
	// sram_rdata deve essere valido UN ciclo dopo sram_addr.
	output wire [10:0] sram_addr,
	output wire        sram_wr,
	output wire [7:0]  sram_wdata,
	input  wire [7:0]  sram_rdata,

	// --- porta user del MiSTer: qui si collega l'altra macchina ---
	// Quattro fili, incrociati come fra due cabinati:
	//   TXD -> RXD dell'altro,  RTS -> CTS dell'altro.
	// RTS/CTS non sono un lusso: la linea e' half-duplex e il turno di parola
	// se lo passano proprio con quelli (la ROM li interroga a ogni inversione).
	input  wire        rxd,
	output wire        txd,
	input  wire        cts_n,      // = RTS dell'altra macchina
	output wire        rts_n,
	output wire        re_attivo,   // lo Z180 e' in ricezione
	output wire        te_attivo,   // lo Z180 e' in trasmissione

	// --- battito del link: un impulso ogni blocco entrato per intero ---------
	// Serve a chi sta fuori per sapere se la linea e' viva. Si alza sul commit
	// atomico, cioe' nell'istante in cui la lunghezza entra in RAM e il blocco
	// ricevuto diventa leggibile dal 68000.
	//
	// Solo la RICEZIONE, e non e' una scorciatoia: la trasmissione da qui non
	// si vede (il TX lo fa lo Z180 dentro l'ASCI, senza passare per la RAM
	// condivisa in un punto riconoscibile), ma non serve vederla. Il protocollo
	// e' un botta e risposta: le due schede si alternano, e nessuna delle due
	// va avanti a spedire se l'altra non le risponde. Ricezione ferma vuol dire
	// link fermo, sempre.
	output wire        blocco_completato,

	// --- diagnostica ---
	output wire [15:0] dbg_pc,
	output wire        dbg_tx_attivo,
	output wire        dbg_rx_attivo
);

// ---------------------------------------------------------------------------
// CPU: T80 con gli opcode Z180 abilitati (IN0/OUT0)
// ---------------------------------------------------------------------------
wire [15:0] cpu_addr;
wire [7:0]  cpu_dout;
reg  [7:0]  cpu_din;
wire        cpu_mreq_n, cpu_iorq_n, cpu_rd_n, cpu_wr_n, cpu_m1_n;
wire [211:0] cpu_reg;   // stato interno del T80: PC = cpu_reg[79:64]
wire        irq_asci;

wire cpu_rd = ~cpu_rd_n;
wire cpu_wr = ~cpu_wr_n;
wire mreq   = ~cpu_mreq_n;
// IORQ insieme a M1 non e' un accesso I/O: e' il ciclo di riconoscimento
// interrupt. Tenerli distinti non e' pignoleria — se il ciclo di INTACK
// venisse servito dallo spazio I/O, la CPU eseguirebbe il contenuto di un
// registro interno al posto del primo opcode.
wire iorq   = ~cpu_iorq_n & cpu_m1_n;

// T80pa_z180 e' T80pa con Z180 => 1 fissato nel VHDL: vedi rtl/t80/T80pa_z180.vhd
// per il motivo (un override del generic dal Verilog non sopravvive alla
// conversione VHDL->Verilog del simulatore).
T80pa_z180 u_cpu (
	.RESET_n (~reset),
	.CLK     (clk),
	.CEN_p   (ce),
	.CEN_n   (1'b1),
	.WAIT_n  (1'b1),
	.INT_n   (~irq_asci),
	.NMI_n   (1'b1),
	.BUSRQ_n (1'b1),
	.M1_n    (cpu_m1_n),
	.MREQ_n  (cpu_mreq_n),
	.IORQ_n  (cpu_iorq_n),
	.RD_n    (cpu_rd_n),
	.WR_n    (cpu_wr_n),
	.RFSH_n  (),
	.HALT_n  (),
	.BUSAK_n (),
	.A       (cpu_addr),
	.DI      (cpu_din),
	.DO      (cpu_dout),
	.REG     (cpu_reg)
);

assign dbg_pc = cpu_reg[79:64];

// ---------------------------------------------------------------------------
// Memoria: ROM $0000-$7FFF, RAM condivisa $8000-$87FF
// ---------------------------------------------------------------------------
// Decodifica di sola posizione, senza MREQ: sulla scheda l'EPROM e la RAM
// hanno il chip select cablato sugli indirizzi e tengono il dato per tutto il
// ciclo. Qualificare il mux con MREQ toglierebbe il dato dal bus prima che il
// T80 lo campioni, e la CPU eseguirebbe aria.
wire sel_rom  = (cpu_addr[15] == 1'b0);
wire sel_sram = (cpu_addr[15:11] == 5'b10000);   // $8000-$87FF
wire sram_we  = sel_sram && mreq && cpu_wr;

assign rom_addr = cpu_addr[14:0];

// Il byte 0 ('M' o 'S') lo scrive il 68000 al boot leggendo il dipswitch
// "Communication Mode" (DSWB bit 7). Verificato nella ROM del gioco:
//   $000B1E  move.w $900002.l, d7      ; DSWB
//   $000B24  btst #7, d7
//   $000B2A  move.w #$4d, $800000.l    ; 'M'
//   $000B34  move.w #$53, $800000.l    ; 'S'
// Qui non si tocca: e' RAM e basta.

// ---------------------------------------------------------------------------
// Commit atomico del blocco ricevuto ($8100-$817F)
// ---------------------------------------------------------------------------
// Il 68000 legge il blocco su IRQ5 usando la PRIMA parola ($800200) come
// lunghezza, mentre lo Z180 scrive un byte ogni ~0,4 ms: la lettura cade
// dentro il riempimento, il checksum non torna e con $3404(a5) a zero il
// blocco viene scartato IN SILENZIO e $800200 azzerato sotto le mani dello
// Z180 ($0048F4). E' cosi' che lo stato di gioco si perde di continuo (10-40%
// dei blocchi, secondo la taglia) e ogni tanto, col flag attivo, la CPU si
// pianta. Nel protocollo NON esiste un segnale di "blocco completo": il gate
// e' la lunghezza stessa.
//
// Quindi il commit si fa qui, sull'unica parola che il 68000 usa come gate:
// la scrittura della lunghezza (primo byte del blocco, $0091) viene trattenuta
// in un registro e iniettata in RAM in UN ciclo, quando lo Z180 ha scritto
// l'ultimo byte (i byte del blocco sono `lunghezza`, gate compreso). Il 68000
// vede lunghezza 0 — blocco assente, lettura di niente — oppure il blocco
// intero e immutabile: mai un pezzo. Latenza aggiunta: zero, la lunghezza
// compare nello stesso istante in cui il blocco esiste completo, che e' il
// primo istante in cui era comunque leggibile in modo valido.
//
// Lo Z180 non se ne accorge: la lunghezza la tiene in C ($0092), non la
// rilegge dalla RAM; $8100 lo interroga solo al blocco successivo ($007C),
// quando l'iniezione e' gia' avvenuta e il valore c'e'. E durante la lettura
// del 68000 lo Z180 e' fermo proprio su quel poll (aspetta lo zero), quindi
// niente scritture concorrenti: anche il `no_rw_check` della RAM condivisa
// smette di essere un rischio.
wire finestra_rx = (cpu_addr[10:7] == 4'b0010);   // $8100-$817F
wire parola_gate = (cpu_addr[10:0] == 11'h100);   // la lunghezza

// Il conteggio va fatto per AVANZAMENTO DI INDIRIZZO, mai a fronti dello
// strobe: il percorso originale era a livello (riscrivere lo stesso byte allo
// stesso indirizzo e' innocuo) e lo strobe del T80 non garantisce un fronte
// solo per ciclo di scrittura. Un contatore a fronti conta doppio, committa a
// meta' blocco e il 68000 legge lunghezza valida su coda non scritta. Qui un
// byte e' "nuovo" solo se tocca un offset diverso dall'ultimo contato — la ROM
// scrive in stretta sequenza (inc hl) — e la parola-gate rilatcha gli stessi
// valori a ogni ripetizione: tutto idempotente per costruzione.
reg  [7:0] blk_len;       // lunghezza trattenuta
reg  [7:0] blk_cnt;       // byte del blocco gia' scritti (gate compreso)
reg  [6:0] ult_off;       // ultimo offset contato dentro la finestra
reg        blk_attivo;
reg        commit_pend;
reg        blocco_fine;   // impulso: l'ultimo byte del blocco e' arrivato

// L'iniezione aspetta un ciclo in cui lo Z180 non tocca la RAM: subito dopo
// l'ultimo byte la CPU sta nelle fetch da ROM, il ciclo libero arriva entro
// un'istruzione.
wire commit_ora = (COMMIT_ATOMICO != 0) && commit_pend && !(sel_sram && mreq);

always @(posedge clk) begin
	blocco_fine <= 1'b0;
	if (reset) begin
		blk_attivo <= 1'b0; commit_pend <= 1'b0;
		blk_len <= 8'd0; blk_cnt <= 8'd0; ult_off <= 7'd0;
	end else begin
		if (sram_we && finestra_rx) begin
			if (parola_gate) begin
				// primo byte = lunghezza: trattenuta, la RAM resta a zero
				if (cpu_dout != 8'd0) begin
					blk_len <= cpu_dout; blk_cnt <= 8'd1;
					ult_off <= 7'd0;    blk_attivo <= 1'b1;
				end
			end else if (blk_attivo && cpu_addr[6:0] != ult_off) begin
				ult_off <= cpu_addr[6:0];
				blk_cnt <= blk_cnt + 8'd1;
				if (blk_cnt + 8'd1 == blk_len) begin   // ultimo byte del blocco
					blk_attivo  <= 1'b0;
					commit_pend <= 1'b1;
					blocco_fine <= 1'b1;               // battito, anche senza commit
				end
			end
		end
		if (commit_ora) commit_pend <= 1'b0;
	end
end

// ---------------------------------------------------------------------------
// Iniezione del comando 7: rimette il link a velocita' piena
// ---------------------------------------------------------------------------
// MISURATO, senza eccezioni:
//     $3404(a5) = 0   -> uno scambio per frame   (17,08 ms)
//     $3404(a5) != 0  -> uno ogni due frame      (33,79 ms)
// Con $3404 a zero il 68000 trasmette a OGNI vblank incondizionatamente
// ($0008F2 `beq $908`); con $3404 acceso trasmette solo se ha letto in quel
// frame ($0008F4 `tst.b $3405`), e il giro costa due frame.
//
// $3404 lo azzera il COMANDO 7 dentro un blocco ricevuto ($4B60
// `move.b #$0,$3404(a5)`). Il gioco lo manda da solo all'avvio ($519E) — e
// nella traccia del ponte si vede passare, cinque byte esatti:
//
//     05 ff ff 07 f6      lunghezza 5, due parole di controlli, comando 7,
//                         checksum (5+ff+ff+07+f6 = $300, byte basso zero)
//
// Poi, quando parte la partita in due, il gioco riaccende il lockstep
// (comando 6) e resta a meta' ritmo finche' non ripassa da uno dei suoi punti
// interni che rimandano il 7 ($5E2C, $78EC, $7CDA) — ed e' il "si e' sbloccato
// da solo dopo venti minuti" visto sull'hardware.
//
// Qui quel blocco viene consegnato al proprio 68000 esattamente come se
// arrivasse dall'altra macchina. NON e' un blocco inventato: e' byte per byte
// quello che il gioco produce e digerisce gia' da solo. Si inietta solo se il
// link e' LENTO e solo quando $8100 e' vuoto (nessun blocco vero in attesa) e
// lo Z180 non sta ricevendo, quindi non puo' sovrascrivere niente.
localparam [7:0] CMD7_0 = 8'h05, CMD7_1 = 8'hFF, CMD7_2 = 8'hFF,
                 CMD7_3 = 8'h07, CMD7_4 = 8'hF6;

reg [26:0] t_lento;      // cicli dall'ultimo blocco ricevuto
reg [26:0] t_ritento;    // per non insistere piu' di una volta al secondo
reg  [2:0] inj;          // 0 = ferma; 1..2 = legge $8100; 3..7 = scrive
reg        inj_armata;

wire ciclo_libero = !(sel_sram && mreq) && !commit_ora;
wire inj_ora     = (inj != 3'd0) && ciclo_libero;

// Un impulso di un ciclo solo: `commit_pend` si spegne nello stesso momento in
// cui `commit_ora` sale, quindi il battito e' gia' stretto per costruzione.
// Il battito del link. Col commit attivo coincide con l'iniezione della
// lunghezza; senza, e' l'arrivo dell'ultimo byte del blocco. In tutti e due i
// casi e' un impulso di un ciclo, uno per blocco ricevuto — ed e' quello che
// il sorvegliante guarda per sapere se la linea e' viva.
assign blocco_completato = (COMMIT_ATOMICO != 0) ? commit_ora : blocco_fine;

// --- misura del ritmo e macchina dell'iniezione ---
always @(posedge clk) begin
	if (reset) begin
		t_lento <= 27'd0; t_ritento <= 27'd0; inj <= 3'd0; inj_armata <= 1'b0;
	end else begin
		// tempo dall'ultimo blocco ricevuto
		if (blocco_completato) t_lento <= 27'd0;
		else if (t_lento != {27{1'b1}}) t_lento <= t_lento + 27'd1;

		// distanza dall'ultimo tentativo
		if (t_ritento != {27{1'b1}}) t_ritento <= t_ritento + 27'd1;

		// il link e' lento e non si ritenta troppo spesso: si arma
		if (!inj_armata && inj == 3'd0 &&
		    t_lento   > SOGLIA_LENTO[26:0] &&
		    t_ritento > INIEZIONE_OGNI[26:0]) begin
			inj_armata <= 1'b1;
			t_ritento  <= 27'd0;
		end

		// parte solo se lo Z180 non sta ricevendo un blocco vero
		if (inj_armata && inj == 3'd0 && !blk_attivo && !commit_pend) begin
			inj_armata <= 1'b0;
			inj        <= 3'd1;
		end

		if (inj_ora) begin
			case (inj)
			3'd1: inj <= 3'd2;                       // indirizzo $100 presentato
			3'd2: inj <= (sram_rdata == 8'd0) ? 3'd3 // vuoto: si puo' iniettare
			                                  : 3'd0; // c'e' gia' un blocco: si lascia stare
			3'd3: inj <= 3'd4;
			3'd4: inj <= 3'd5;
			3'd5: inj <= 3'd6;
			3'd6: inj <= 3'd7;
			3'd7: inj <= 3'd0;                       // la lunghezza per ULTIMA
			default: inj <= 3'd0;
			endcase
		end
	end
end


// L'iniezione usa la porta quando nessuno la sta usando; il commit ha sempre
// la precedenza. La lunghezza ($100) si scrive per ULTIMA: e' lei il segnale
// "c'e' un blocco" per il 68000, e prima di allora il carico dev'esserci gia'.
wire [10:0] inj_addr = (inj == 3'd1 || inj == 3'd2) ? 11'h100 :   // lettura
                       (inj == 3'd3) ? 11'h101 :
                       (inj == 3'd4) ? 11'h102 :
                       (inj == 3'd5) ? 11'h103 :
                       (inj == 3'd6) ? 11'h104 : 11'h100;
wire  [7:0] inj_dato = (inj == 3'd3) ? CMD7_1 :
                       (inj == 3'd4) ? CMD7_2 :
                       (inj == 3'd5) ? CMD7_3 :
                       (inj == 3'd6) ? CMD7_4 : CMD7_0;
wire        inj_scrive = inj_ora && (inj >= 3'd3);

assign sram_addr  = commit_ora ? 11'h100 :
                    inj_ora    ? inj_addr : cpu_addr[10:0];
assign sram_wr    = commit_ora ? 1'b1 :
                    inj_ora    ? inj_scrive :
                    (sram_we && !(parola_gate && COMMIT_ATOMICO != 0));
assign sram_wdata = commit_ora ? blk_len :
                    inj_ora    ? inj_dato : cpu_dout;

// ---------------------------------------------------------------------------
// I/O interno + seriale
// ---------------------------------------------------------------------------
wire [7:0] io_dout;
wire       io_sel;

z180_io #(.PHI_DIV(PHI_DIV)) u_io (
	.clk(clk), .reset(reset), .ce(ce),
	.addr(cpu_addr),
	.iorq(iorq),
	.rd(cpu_rd),
	.wr(cpu_wr),
	.din(cpu_dout),
	.dout(io_dout),
	.sel(io_sel),
	.rxd(rxd), .txd(txd),
	.cts_n(cts_n), .rts_n(rts_n),
	.re_attivo(re_attivo), .te_attivo(te_attivo),
	// DCD sta basso: sul cabinato la portante c'e' sempre, e' un cavo.
	.dcd_n(1'b0),
	.irq(irq_asci)
);

// ---------------------------------------------------------------------------
// Multiplexer del dato verso la CPU
// ---------------------------------------------------------------------------
always @(*) begin
	if (iorq)          cpu_din = io_dout;
	else if (sel_sram) cpu_din = sram_rdata;
	else if (sel_rom)  cpu_din = rom_data;
	else               cpu_din = 8'hFF;
end

// ---------------------------------------------------------------------------
// Diagnostica: dice a colpo d'occhio se la linea sta lavorando
// ---------------------------------------------------------------------------
assign dbg_tx_attivo = ~txd;
assign dbg_rx_attivo = ~rxd;

endmodule
