/*  This file is part of Arcade_TaitoAsuka_MiSTer.
    GPL-3.
    Author: Umberto Parisi (rmonic79), 2026.
*/

//============================================================================
//  cadash_link_rete — il "cavo" fra due cabinati, fatto passare dalla rete.
//
//  Sul cabinato i due Z180 sono uniti da quattro fili (TXD/RXD + RTS/CTS su
//  transceiver differenziali, vedi LINK_CADASH_Z180.md). Su MiSTer quei fili
//  non sono raggiungibili: la porta user sta su un header interno e sui case
//  chiusi non esce. Quindi il collegamento passa dove i MiSTer sono gia'
//  collegati fra loro: la rete.
//
//      core FPGA --UART interna del SoC--> Linux (HPS) --Ethernet--> altro MiSTer
//
//  La UART interna NON e' un connettore: `cyclonev_hps_interface_peripheral_uart`
//  in sys_top.v collega la UART del processore ARM direttamente al fabric, e nel
//  .qsf non c'e' nessun pin assegnato (solo un set_hps_location_assignment, che
//  e' una coordinata dentro il chip). Non serve nessun cavo particolare: bastano
//  due MiSTer sulla stessa rete.
//
//  Cosa fa questo modulo: sta al posto dell'altro cabinato. Verso lo Z180 locale
//  si comporta come un filo — stesso baud, stesso formato, stessa parita';
//  verso l'HPS parla una UART piu' veloce, con un formato a byte che porta anche
//  lo stato di RTS.
//
//  L'HANDSHAKE RTS/CTS NON ATTRAVERSA LA RETE, e non e' una semplificazione:
//  e' l'unico modo perche' i tempi tornino. Il protocollo fa un giro completo
//  di handshake per OGNI SINGOLO BYTE (dal binario, $004B e $0082):
//
//     master: RTS giu' -> aspetta CTS giu' -> manda il byte -> aspetta CTS su'
//     slave : aspetta CTS giu' -> RE=1, RTS giu' -> riceve -> RTS su'
//
//  Sono quattro attraversamenti di rete per byte. Misurato sui due MiSTer con
//  RTS trasportato: 6 ms a byte, 50 ms per uno scambio da quattro byte. Il
//  gioco ne vuole uno per frame, 16,7 ms, e dopo 5 secondi senza scambi
//  riusciti scrive COMMUNICATION ERROR ($00089C). Fuori di un ordine di
//  grandezza: un solo scambio riusciva, poi il timeout.
//
//  Quindi questo modulo fa da PARTNER al proprio Z180: gli risponde lui sul
//  CTS, alla velocita' del filo, e in rete manda solo i dati. Un attraversamento
//  invece di quattro. L'ordine dei byte lo garantisce TCP, e l'integrita' del
//  blocco il gioco se la controlla da solo con lunghezza e checksum.
//============================================================================

`timescale 1ns / 1ps

module cadash_link_rete #(
	// Divisori di baud, in cicli di clk.
	// Z180: PHI/160 = 8 MHz/160 = 50000 baud  ->  96 MHz / 50000 = 1920.
	parameter integer DIV_Z180 = 1920,
	// HPS: 230400 baud -> 96e6/230400 = 416,67. L'errore dello 0,08% e'
	// ininfluente su un carattere lungo dieci bit.
	// Si sta larghi apposta: questa seriale e' DENTRO il chip, fra il fabric e
	// il processore ARM, senza un centimetro di rame — non ha i rischi di una
	// seriale su cavo, e ogni microsecondo qui e' tolto al giro che deve stare
	// dentro il frame.
	parameter integer DIV_HPS  = 417,
	// Cosa fare delle code quando il gioco e' in pausa.
	//   1 = svuotarle (com'era)
	//   0 = CONGELARLE, e non consegnare niente allo Z180 finche' e' fermo
	// Svuotare sembrava prudente ("un blocco perso il gioco lo ritenta"), ma
	// dal firmware si vede che non e' vero: lo Z180 si congela DENTRO un
	// blocco — ha gia' scritto la lunghezza in $8100 ($0091) e sta contando i
	// byte che mancano. Buttando via la coda, alla ripresa prende come coda di
	// quel blocco i byte del blocco DOPO: la lunghezza finisce in mezzo al
	// carico e il flusso non si riallinea piu'. Non e' un blocco perso, e' il
	// disallineamento definitivo.
	// Congelare invece non perde niente: lo Z180 e' fermo e non consuma, i
	// byte restano in coda, e alla ripresa il blocco continua da dov'era. E la
	// coda non trabocca, perche' anche l'altra macchina si ferma da sola: dopo
	// aver spedito un blocco il suo Z180 aspetta a $007C di riceverne uno.
	parameter integer SVUOTA_IN_PAUSA = 0,
	// Larghezza della finestra in cui lo Z180 deve vedere CTS tornare alto
	// ($00AE). Fra l'alzata di RTS ($00A5) e il primo controllo passano ~3,4 us:
	// sotto quella soglia il fronte si perde e lo Z180 resta piantato a meta'
	// blocco. Un tempo di bit e mezzo (30 us) lascia margine dieci volte tanto.
	parameter integer GUARDIA_CICLI = (1920 * 3) / 2,
	// Quanto a lungo, dopo essere ripartiti da zero, si ignora la REAZIONE al
	// proprio resync (vedi piu' sotto). Tre secondi a 96 MHz: il giro
	// reset -> resync -> reset dell'altro -> resync suo si misura in
	// millisecondi, quindi il margine e' di tre ordini di grandezza.
	parameter integer COOLDOWN_CICLI = 288_000_000,
	// 1 = comportamento VECCHIO: la consegna ha la precedenza incondizionata,
	//     anche se lo Z180 sta chiedendo la linea per trasmettere. Serve solo
	//     al banco, per far vedere il guasto che la correzione toglie.
	// 0 = corretto: il turno lo decide RTS, come nel firmware.
	parameter integer RX_PRECEDE = 0
) (
	input  wire clk,
	input  wire reset,
	// Perche' si e' in reset. 1 = e' il sorvegliante che sta rimettendo in piedi
	// il link da solo; 0 = un reset normale (accensione, cambio di modo).
	// All'uscita il trasporto lo dice all'altro con marcatori DIVERSI, e sono
	// due cose diverse davvero: il resync fa ripartire il gioco del partner, il
	// recupero no — vedi il framing qui sotto.
	input  wire reset_recupero,
	// In pausa il nostro Z180 e' fermo ma l'altra macchina continua a parlare:
	// i byte si accumulerebbero fino a traboccare, e alla ripresa il gioco si
	// ritroverebbe un blocco monco. Il checksum non tornerebbe e la sua CPU si
	// pianta ($0048E6). Quindi durante la pausa si butta via quello che arriva
	// e si riparte puliti: un blocco perso il gioco lo ritenta, uno corrotto no.
	input  wire pausa,

	// --- lato Z180: gli stessi quattro fili del cabinato ---
	input  wire z_txd,        // lo Z180 trasmette
	output wire z_rxd,        // lo Z180 riceve
	input  wire z_rts_n,      // lo Z180 chiede la linea
	input  wire z_re,         // ...per RICEVERE  (CNTLA0 bit 6)
	input  wire z_te,         // ...per TRASMETTERE (CNTLA0 bit 5)
	output reg  z_cts_n,      // l'altra macchina concede la linea

	// --- lato HPS: la UART interna, verso Linux e da li' verso la rete ---
	input  wire hps_rxd,
	output wire hps_txd,

	// Impulso di un ciclo: dall'altra parte il core e' ripartito da zero, e per
	// restare in passo deve ripartire anche questo. Chi si e' appena resettato
	// non lo alza (vedi il raffreddamento), altrimenti i due si resetterebbero
	// a vicenda all'infinito.
	// Lo alza SOLO il resync vero ($FF $02). Il recupero del link ($FF $03)
	// pulisce le code e i crediti esattamente allo stesso modo ma non arriva
	// mai qui: il gioco del partner non si tocca.
	output wire resync_riavvia,

	// --- diagnostica ---
	output wire [7:0] dbg_byte_usciti,
	output wire [7:0] dbg_byte_entrati
);

// Formato della linea dello Z180: la ROM imposta MOD=110 e PEO=1, cioe' 8 bit
// dati + parita' DISPARI + 1 stop. Verso lo Z180 va rispettato alla lettera: un
// bit di parita' sbagliato gli fa alzare PE, e il suo gestore d'errore lo pianta
// in un loop infinito a $00C2.
localparam PAR_ODD = 1'b1;

// ---------------------------------------------------------------------------
//  RX dallo Z180 (50 kbaud, con parita')
// ---------------------------------------------------------------------------
localparam [2:0] R_ATTESA=0, R_START=1, R_DATI=2, R_PARITA=3, R_STOP=4;

reg  [2:0] rz_stato;
reg [15:0] rz_cnt;
reg  [3:0] rz_bit;
reg  [7:0] rz_sr;
reg  [7:0] rz_dato;
reg        rz_pronto;
reg        z_txd_s1, z_txd_s2;

always @(posedge clk) begin z_txd_s1 <= z_txd; z_txd_s2 <= z_txd_s1; end

always @(posedge clk) begin
	rz_pronto <= 1'b0;
	if (reset) begin
		rz_stato <= R_ATTESA; rz_cnt <= 16'd0; rz_bit <= 4'd0;
	end else if (pausa && SVUOTA_IN_PAUSA == 0) begin
		// Congelato insieme allo Z180: se il turno seriale andasse avanti da
		// solo, il byte in volo si perderebbe lo stesso — ed e' proprio il byte
		// perso che disallinea tutto.
	end else case (rz_stato)
		R_ATTESA: if (!z_txd_s2) begin
			rz_cnt <= DIV_Z180/2; rz_stato <= R_START;   // punta a meta' bit
		end
		R_START: if (rz_cnt == 0) begin
			if (!z_txd_s2) begin
				rz_bit <= 4'd0; rz_cnt <= DIV_Z180; rz_stato <= R_DATI;
			end else rz_stato <= R_ATTESA;               // falso start
		end else rz_cnt <= rz_cnt - 16'd1;
		R_DATI: if (rz_cnt == 0) begin
			rz_sr  <= {z_txd_s2, rz_sr[7:1]};
			rz_cnt <= DIV_Z180;
			rz_bit <= rz_bit + 4'd1;
			if (rz_bit == 4'd7) rz_stato <= R_PARITA;
		end else rz_cnt <= rz_cnt - 16'd1;
		// Il bit di parita' si attraversa e basta: chi lo deve controllare e'
		// l'ASCI dello Z180 all'altro capo, e a lui lo rigeneriamo noi.
		R_PARITA: if (rz_cnt == 0) begin
			rz_cnt <= DIV_Z180; rz_stato <= R_STOP;
		end else rz_cnt <= rz_cnt - 16'd1;
		R_STOP: if (rz_cnt == 0) begin
			rz_dato   <= rz_sr;
			rz_pronto <= 1'b1;
			rz_stato  <= R_ATTESA;
		end else rz_cnt <= rz_cnt - 16'd1;
		default: rz_stato <= R_ATTESA;
	endcase
end

// ---------------------------------------------------------------------------
//  TX verso lo Z180 (50 kbaud, con parita' dispari generata)
// ---------------------------------------------------------------------------
localparam [2:0] T_FERMO=0, T_START=1, T_DATI=2, T_PARITA=3, T_STOP=4;

reg  [2:0] tz_stato;
reg [15:0] tz_cnt;
reg  [3:0] tz_bit;
reg  [7:0] tz_sr;
reg        tz_par;
reg        tz_out;
reg  [7:0] tz_dato;
reg        tz_carica;

assign z_rxd = tz_out;

always @(posedge clk) begin
	if (reset) begin
		tz_stato <= T_FERMO; tz_out <= 1'b1;
	end else if (pausa && SVUOTA_IN_PAUSA == 0) begin
		// idem: il byte verso lo Z180 resta a meta' strada, esattamente dov'era
	end else case (tz_stato)
		T_FERMO: begin
			tz_out <= 1'b1;
			if (tz_carica) begin
				tz_sr  <= tz_dato; tz_par <= PAR_ODD; tz_bit <= 4'd0;
				tz_out <= 1'b0;                       // start
				tz_cnt <= DIV_Z180; tz_stato <= T_START;
			end
		end
		T_START: if (tz_cnt == 0) begin
			tz_out <= tz_sr[0]; tz_cnt <= DIV_Z180; tz_stato <= T_DATI;
		end else tz_cnt <= tz_cnt - 16'd1;
		T_DATI: if (tz_cnt == 0) begin
			tz_par <= tz_par ^ tz_sr[0];
			tz_sr  <= {1'b0, tz_sr[7:1]};
			tz_bit <= tz_bit + 4'd1;
			tz_cnt <= DIV_Z180;
			if (tz_bit == 4'd7) begin
				tz_out   <= tz_par ^ tz_sr[0];        // parita', ultimo bit incluso
				tz_stato <= T_PARITA;
			end else tz_out <= tz_sr[1];
		end else tz_cnt <= tz_cnt - 16'd1;
		T_PARITA: if (tz_cnt == 0) begin
			tz_out <= 1'b1; tz_cnt <= DIV_Z180; tz_stato <= T_STOP;
		end else tz_cnt <= tz_cnt - 16'd1;
		T_STOP: if (tz_cnt == 0) tz_stato <= T_FERMO;
		         else tz_cnt <= tz_cnt - 16'd1;
		default: tz_stato <= T_FERMO;
	endcase
end

// ---------------------------------------------------------------------------
//  Lato HPS: UART 8N1 con un framing IN BANDA
// ---------------------------------------------------------------------------
//  Sul filo passano i byte del gioco cosi' come escono dallo Z180, piu' due
//  segnali di servizio che il gioco non conosce e che servono a tenere in riga
//  i due trasporti. Fili in piu' non ce ne sono — il ponte in Linux e' un tubo
//  trasparente e non si tocca — quindi i due segnali viaggiano IN BANDA,
//  dietro a un byte di fuga:
//
//     $FF $FF   un byte di DATI che vale $FF
//     $FF $01   GETTONE  — "il tuo ultimo blocco l'ho consegnato tutto al mio Z180"
//     $FF $02   RESYNC   — "il mio core e' ripartito da zero"
//     $FF $03   RECUPERO — "il mio sorvegliante ha rimesso in piedi il link"
//
//  Il $02 e il $03 fanno la STESSA pulizia — code svuotate, parser riallineati,
//  crediti azzerati — e si distinguono per una cosa sola: il $02 fa ripartire
//  anche il GIOCO di chi lo riceve, il $03 no. Ed e' giusto cosi': il resync
//  nasce da un reset vero del core, dove le due partite sono comunque da
//  ributtare; il recupero nasce da un sorvegliante che ha rianimato un link
//  morto mentre le due partite andavano avanti — resettare quella dell'altro
//  vorrebbe dire, per riparare il filo, buttare via il gioco.
//
//  Il de-escape sta PRIMA della coda di ricezione, cosi' nella coda ci finisce
//  solo roba del gioco; l'escape sta all'ingresso della coda di trasmissione,
//  cosi' chi accoda non deve saperne niente. Le due direzioni sono uguali: lo
//  stesso modulo sta ai due capi.

// --- segnali del framing, dichiarati qui perche' li usano piu' blocchi ---
reg  manda_gettone;      // impulso: il consegnatore ha chiuso un blocco
reg  gettone_ricevuto;   // impulso: e' arrivato $FF $01
reg  resync_ricevuto;    // impulso: e' arrivato $FF $02
reg  recupero_ricevuto;  // impulso: e' arrivato $FF $03

// Quello che i due marcatori hanno in comune: tubi puliti da questa parte.
// Chi deve anche far ripartire il gioco guarda `resync_ricevuto` da solo.
wire ripulisci = resync_ricevuto | recupero_ricevuto;

// L'uscita dal reset del modulo: e' il momento in cui si annuncia all'altro
// che qui si e' ripartiti da zero.
reg  reset_r;
always @(posedge clk) reset_r <= reset;
wire uscita_reset = reset_r & ~reset;

// Perche' si era in reset. Va ricordato DURANTE il reset e non all'uscita:
// `reset_recupero` e' il `sv_reset` del sorvegliante, cioe' proprio uno dei
// segnali che compongono questo reset, e cade nello stesso ciclo. Al momento di
// `uscita_reset` — che e' un ciclo piu' in la' — sarebbe gia' a zero, e ogni
// recupero si annuncerebbe come un resync.
reg  era_recupero;
always @(posedge clk) if (reset) era_recupero <= reset_recupero;

// --- coda verso l'HPS: i byte usciti dallo Z180, con l'escape del framing ---
reg  [7:0] coda_tx [0:255];
reg  [8:0] qt_wr, qt_rd;
wire       qt_vuota = (qt_wr == qt_rd);
wire [8:0] qt_usati = qt_wr - qt_rd;
wire       qt_piena = (qt_usati >= 9'd250);

reg  [1:0] th_stato;
reg [15:0] th_cnt;
reg  [3:0] th_bit;
reg  [7:0] th_sr;
reg        th_out;
assign hps_txd = th_out;

always @(posedge clk) begin
	if (reset) begin
		th_stato <= 2'd0; th_out <= 1'b1; qt_rd <= 9'd0;
	end else case (th_stato)
	2'd0: begin
		th_out <= 1'b1;
		if (!qt_vuota) begin
			th_sr  <= coda_tx[qt_rd[7:0]];
			qt_rd  <= qt_rd + 9'd1;
			th_out <= 1'b0;
			th_cnt <= DIV_HPS; th_bit <= 4'd0; th_stato <= 2'd1;
		end
	end
	2'd1: if (th_cnt == 0) begin
		th_bit <= th_bit + 4'd1; th_cnt <= DIV_HPS;
		if (th_bit == 4'd8) begin th_out <= 1'b1; th_stato <= 2'd2; end
		else begin th_out <= th_sr[0]; th_sr <= {1'b0, th_sr[7:1]}; end
	end else th_cnt <= th_cnt - 16'd1;
	2'd2: if (th_cnt == 0) th_stato <= 2'd0; else th_cnt <= th_cnt - 16'd1;
	default: th_stato <= 2'd0;
	endcase
end

// Ogni accodamento puo' valere DUE byte (un $FF di dati raddoppiato, oppure
// una coppia di servizio), quindi ci vuole un piccolo sequenziatore: uno per
// ciclo, con il secondo tenuto da parte. Gli eventi sono radi — un byte del
// gioco ogni 220 us, un gettone per blocco — e non si accavallano mai davvero,
// ma le richieste restano segnate finche' non sono servite: perderne una
// vorrebbe dire piantare il mittente dall'altra parte.
reg       tx_secondo;        // c'e' il secondo byte di una coppia da mettere
reg [7:0] tx_secondo_v;
reg       gettone_da_mandare;
reg       resync_da_mandare;
reg [7:0] resync_marca;      // $02 = resync, $03 = recupero: deciso all'uscita


always @(posedge clk) begin
	if (reset || (pausa && SVUOTA_IN_PAUSA != 0)) begin
		qt_wr              <= qt_rd;
		tx_secondo         <= 1'b0;
		gettone_da_mandare <= 1'b0;
		resync_da_mandare  <= 1'b0;
	end else begin
		if (tx_secondo) begin
			coda_tx[qt_wr[7:0]] <= tx_secondo_v;
			qt_wr      <= qt_wr + 9'd1;
			tx_secondo <= 1'b0;
		end else if (rz_pronto && !pausa) begin
			coda_tx[qt_wr[7:0]] <= rz_dato;
			qt_wr <= qt_wr + 9'd1;
			if (rz_dato == 8'hFF) begin           // dato $FF -> $FF $FF
				tx_secondo   <= 1'b1;
				tx_secondo_v <= 8'hFF;
			end
		end else if (resync_da_mandare) begin
			coda_tx[qt_wr[7:0]] <= 8'hFF;         // $FF $02 oppure $FF $03
			qt_wr             <= qt_wr + 9'd1;
			tx_secondo        <= 1'b1;
			tx_secondo_v      <= resync_marca;
			resync_da_mandare <= 1'b0;
		end else if (gettone_da_mandare) begin
			coda_tx[qt_wr[7:0]] <= 8'hFF;         // $FF $01
			qt_wr              <= qt_wr + 9'd1;
			tx_secondo         <= 1'b1;
			tx_secondo_v       <= 8'h01;
			gettone_da_mandare <= 1'b0;
		end
		// Le richieste si segnano DOPO la catena: se una arriva nello stesso
		// ciclo in cui se ne sta servendo un'altra, resta li' per il giro dopo
		// invece di sparire.
		if (manda_gettone) gettone_da_mandare <= 1'b1;
		if (uscita_reset) begin
			resync_da_mandare <= 1'b1;
			resync_marca      <= era_recupero ? 8'h03 : 8'h02;
		end
	end
end

// --- RX dall'HPS ---
reg  [1:0] rh_stato;
reg [15:0] rh_cnt;
reg  [3:0] rh_bit;
reg  [7:0] rh_sr;
reg  [7:0] rh_dato;
reg        rh_pronto;
reg        hps_rxd_s1, hps_rxd_s2;

always @(posedge clk) begin hps_rxd_s1 <= hps_rxd; hps_rxd_s2 <= hps_rxd_s1; end

always @(posedge clk) begin
	rh_pronto <= 1'b0;
	if (reset) rh_stato <= 2'd0;
	else case (rh_stato)
	2'd0: if (!hps_rxd_s2) begin rh_cnt <= DIV_HPS/2; rh_stato <= 2'd1; end
	2'd1: if (rh_cnt == 0) begin
		if (!hps_rxd_s2) begin rh_bit <= 4'd0; rh_cnt <= DIV_HPS; rh_stato <= 2'd2; end
		else rh_stato <= 2'd0;
	end else rh_cnt <= rh_cnt - 16'd1;
	2'd2: if (rh_cnt == 0) begin
		rh_sr  <= {hps_rxd_s2, rh_sr[7:1]};
		rh_bit <= rh_bit + 4'd1; rh_cnt <= DIV_HPS;
		if (rh_bit == 4'd7) rh_stato <= 2'd3;
	end else rh_cnt <= rh_cnt - 16'd1;
	2'd3: if (rh_cnt == 0) begin
		rh_dato <= rh_sr; rh_pronto <= 1'b1; rh_stato <= 2'd0;
	end else rh_cnt <= rh_cnt - 16'd1;
	default: rh_stato <= 2'd0;
	endcase
end

// --- coda dei byte che arrivano dalla rete, da consegnare allo Z180 ---
reg  [7:0] coda_rx [0:255];
reg  [8:0] qr_wr, qr_rd;
wire       qr_vuota = (qr_wr == qr_rd);
// Quanti byte sono in attesa. Serve per NON sovrascriverli quando la coda e'
// piena: senza questo controllo qr_wr avanza comunque e si mangia byte non
// ancora consegnati — il blocco arriva monco, il checksum non torna e la CPU
// del gioco si pianta ($0048E6). E' un guasto che arriva "dopo un po'", perche'
// serve prima un accumulo: lo Z180 consegna a 50 kbaud e se per un momento
// resta indietro la coda cresce.
wire [8:0] qr_usati = qr_wr - qr_rd;
wire       qr_piena = (qr_usati >= 9'd250);
// il prossimo byte da consegnare: serve al consegnatore e al suo parser
wire [7:0] qr_testa = coda_rx[qr_rd[7:0]];

// Il de-escape sta QUI, prima della coda: dentro la coda ci va solo roba del
// gioco, cosi' il consegnatore e il parser dei blocchi non devono sapere
// niente del framing.
reg pausa_r;
reg rx_fuga;                 // il byte prima era $FF: questo dice cos'era
always @(posedge clk) begin
	gettone_ricevuto  <= 1'b0;
	resync_ricevuto   <= 1'b0;
	recupero_ricevuto <= 1'b0;
	pausa_r <= pausa;
	if (reset) begin
		qr_wr <= 9'd0; rx_fuga <= 1'b0;
	end else if (ripulisci) begin
		// L'altro e' ripartito da zero (resync) o il suo sorvegliante ha appena
		// rimesso in piedi il link (recupero): in tutti e due i casi quello che
		// resta in coda appartiene a un flusso che non esiste piu'. Si azzerano
		// ENTRAMBI i puntatori — qr_rd lo fa il blocco del partner, nello stesso
		// ciclo e sullo stesso impulso: spostare solo qr_wr mentre il
		// consegnatore avanza qr_rd lascerebbe la coda con 511 byte fantasma da
		// riversare sullo Z180.
		qr_wr <= 9'd0;
	end else if (pausa && SVUOTA_IN_PAUSA != 0) qr_wr <= qr_rd;
	else if (rh_pronto) begin
		if (rx_fuga) begin
			rx_fuga <= 1'b0;
			case (rh_dato)
			// `qr_piena` c'era gia' ma non era collegata a niente: senza, qr_wr
			// avanza lo stesso e si mangia byte non ancora consegnati.
			8'hFF: if (!qr_piena) begin           // $FF $FF -> un dato $FF
				coda_rx[qr_wr[7:0]] <= 8'hFF;
				qr_wr <= qr_wr + 9'd1;
			end
			8'h01: gettone_ricevuto   <= 1'b1;    // $FF $01 -> gettone
			8'h02: resync_ricevuto    <= 1'b1;    // $FF $02 -> resync (riparte il gioco)
			8'h03: recupero_ricevuto  <= 1'b1;    // $FF $03 -> recupero (gioco intatto)
			default: ;   // coppia che non conosciamo: si scartano tutti e due
			endcase
		end else if (rh_dato == 8'hFF) begin
			rx_fuga <= 1'b1;                      // il significato lo dice il prossimo
		end else if (!qr_piena) begin
			coda_rx[qr_wr[7:0]] <= rh_dato;
			qr_wr <= qr_wr + 9'd1;
		end
	end
end

// ---------------------------------------------------------------------------
//  Il gettone: un blocco per volta sul filo
// ---------------------------------------------------------------------------
//  Sul cabinato il mittente e' frenato dal ricevente byte per byte: finche'
//  l'altro non e' pronto il CTS non scende, e lui non spedisce. Facendo
//  rispondere il CTS in locale quel freno sparisce, e il mittente puo'
//  riempire la coda del trasporto di blocchi che l'altro non ha ancora
//  consumato. Il gettone lo rimette, ma a BLOCCHI invece che a byte: chi ha
//  appena spedito un blocco non ha piu' via libera finche' l'altro non gli
//  dice di averlo consegnato tutto al proprio Z180.
//
//  Lo Z180 resta fermo nell'attesa del CTS ($0050 del firmware): non e' un
//  guasto, e' lo stesso stallo che il gioco si aspetta dal PCB.
//
//  Qui si conta il flusso in USCITA, quello che il nostro Z180 emette: primo
//  byte = lunghezza N, poi N-1 byte. Lunghezza 0 non e' un blocco e si ignora.
//
//  I crediti sono DUE, non uno, ed e' la differenza fra velocita' piena e
//  meta': con un credito solo il mittente parte a spedire il blocco successivo
//  soltanto DOPO il consumo remoto (giro del gettone compreso), i suoi ~1,6 ms
//  di seriale scavalcano l'IRQ5 del ricevente e la cadenza si pianta a due
//  frame — misurato sull'hardware, costante. Con due, il blocco successivo
//  viaggia e aspetta gia' pronto nella coda remota mentre il primo attende il
//  gettone: al momento del consumo parte all'istante, come faceva la coda
//  libera — ma la coda resta limitata a due blocchi, e resync e riallineamento
//  non cambiano.
reg [7:0] pt_resta;      // byte che mancano al blocco che sta uscendo
reg       pt_dentro;     // 0 = il prossimo byte e' una lunghezza
reg [1:0] in_volo;       // blocchi partiti e non ancora consegnati (0..2)

// il blocco in uscita si chiude con questo byte
wire pt_chiude = rz_pronto && !pausa &&
                 ( (!pt_dentro && rz_dato == 8'd1) ||     // blocco di un byte solo
                   ( pt_dentro && pt_resta == 8'd1) );

always @(posedge clk) begin
	if (reset) begin
		pt_resta <= 8'd0; pt_dentro <= 1'b0; in_volo <= 2'd0;
	end else if (ripulisci || uscita_reset) begin
		// Da una parte o dall'altra si riparte da zero: il parser si riallinea
		// sulla prima lunghezza che passera', e i blocchi in volo non ci sono piu'.
		pt_resta <= 8'd0; pt_dentro <= 1'b0; in_volo <= 2'd0;
	end else begin
		// +1 a blocco chiuso, -1 a gettone; se coincidono si elidono da soli
		case ({pt_chiude, gettone_ricevuto})
			2'b10: if (in_volo != 2'd2) in_volo <= in_volo + 2'd1;
			2'b01: if (in_volo != 2'd0) in_volo <= in_volo - 2'd1;
			default: ;
		endcase
		if (rz_pronto && !pausa) begin
			if (!pt_dentro) begin
				if (rz_dato != 8'd0 && rz_dato != 8'd1) begin
					pt_resta  <= rz_dato - 8'd1;
					pt_dentro <= 1'b1;
				end
				// lunghezza 0: non e' un blocco; lunghezza 1: chiuso qui sopra
			end else if (pt_resta == 8'd1)
				pt_dentro <= 1'b0;
			else
				pt_resta <= pt_resta - 8'd1;
		end
	end
end

// ---------------------------------------------------------------------------
//  RESYNC: i due core ripartono insieme
// ---------------------------------------------------------------------------
//  Resettandone una sola, i due flussi restano sfasati per sempre: il suo Z180
//  ricomincia da capo, l'altro no, e i blocchi non si riallineano piu'. Quindi
//  all'uscita dal reset il trasporto lo dice all'altro ($FF $02), e chi lo
//  riceve resetta il proprio core: si riparte in due, con i tubi puliti.
//
//  Il raffreddamento serve a non rimbalzare: chi si e' appena resettato ignora
//  la REAZIONE al proprio resync (il resync che l'altro manda ripartendo), ma
//  svuota comunque le code. Tre secondi contro un giro che dura millisecondi.
//
//  Il recupero ($FF $03) qui non entra proprio: le code le ha gia' svuotate
//  `ripulisci`, e il gioco dell'altro non si tocca. E' l'unica differenza fra i
//  due marcatori, ed e' tutta in questa riga.
reg [28:0] cnt_freddo;
wire       in_freddo = (cnt_freddo != 29'd0);

always @(posedge clk) begin
	if (reset)          cnt_freddo <= COOLDOWN_CICLI[28:0];
	else if (in_freddo) cnt_freddo <= cnt_freddo - 29'd1;
end

assign resync_riavvia = resync_ricevuto & ~in_freddo;

// ---------------------------------------------------------------------------
//  Il partner: e' questo che fa la differenza
// ---------------------------------------------------------------------------
//  Risponde al proprio Z180 sul CTS alla velocita' del filo, senza aspettare
//  l'altra macchina. Due situazioni, e la macchina a stati le copre entrambe
//  senza sapere se il gioco e' master o slave — glielo dice lo Z180 stesso, con
//  RTS e con l'avere o meno un byte da mandare:
//
//   il nostro Z180 vuole TRASMETTERE: mette RTS giu' e aspetta CTS giu'.
//      -> gli concediamo subito, prendiamo il byte, e appena e' arrivato
//         alziamo CTS: e' il segnale che per lui vuol dire "ricevuto, vai col
//         prossimo" ($005B aspetta proprio CTS su').
//
//   dobbiamo CONSEGNARGLI un byte arrivato dalla rete: lui aspetta CTS giu'
//      ($0082), poi accende RE e lo riceve.
//      -> abbassiamo CTS quando il byte e' pronto, lo mandiamo, e appena e'
//         uscito rialziamo CTS ($00AF aspetta CTS su').
//
//  In tutti e due i casi si torna a riposo solo dopo che lo Z180 ha rialzato
//  RTS: e' lui a chiudere il giro, e aspettarlo evita di partire col byte
//  successivo mentre lui e' ancora indietro.
localparam [2:0] P_RIPOSO=0, P_PRENDO=1, P_DO=2, P_RILASCIO=3, P_PAUSA=4;

reg [2:0]  pstato;
// Quanto tenere CTS alto prima di riabbassarlo. Lo Z180 lo legge in polling
// ($00AF: IN0/AND/JR, una manciata di microsecondi a giro): se lo si rialza e
// riabbassa subito, lui non lo vede mai e resta fermo ad aspettare un fronte
// gia' passato. Un tempo di bit e mezzo e' abbondante e non pesa: sono 30 us
// contro i 220 che dura un byte.
localparam integer GUARDIA = GUARDIA_CICLI;
reg [15:0] cnt_guardia;

// Parser dei blocchi CONSEGNATI: e' identico a quello in uscita, ma conta il
// flusso che lo Z180 riceve davvero, un byte per giro di consegna. Serve a
// sapere quando dire all'altro "l'ho preso tutto".
reg [7:0] pd_resta;
reg       pd_dentro;
reg       pd_chiude;     // il byte in consegna e' l'ultimo del suo blocco

always @(posedge clk) begin
	tz_carica     <= 1'b0;
	manda_gettone <= 1'b0;
	if (reset) begin
		pstato <= P_RIPOSO; z_cts_n <= 1'b1; cnt_guardia <= 16'd0;
		// qr_rd va azzerato insieme a qr_wr, altrimenti dopo un reset che non
		// sia l'accensione i due puntatori partono sfasati e la coda sembra
		// piena di centinaia di byte da riversare sullo Z180.
		qr_rd <= 9'd0;
		pd_resta <= 8'd0; pd_dentro <= 1'b0; pd_chiude <= 1'b0;
	end else if (ripulisci) begin
		// Coda svuotata: qui si azzera il puntatore di lettura, nello stesso
		// ciclo e sullo stesso impulso con cui l'altro blocco azzera quello di
		// scrittura, e il parser riparte dalla prossima lunghezza.
		qr_rd <= 9'd0;
		pd_resta <= 8'd0; pd_dentro <= 1'b0; pd_chiude <= 1'b0;
	end else if (pausa) begin
		// In pausa lo Z180 e' fermo: non gli si consegna niente e non gli si
		// da' via libera. Lo stato NON si azzera, cosi' alla ripresa si
		// riprende esattamente da dov'era.
		z_cts_n <= 1'b1;
		if (SVUOTA_IN_PAUSA != 0) begin
			pstato <= P_RIPOSO; cnt_guardia <= 16'd0;
			// la coda si butta via: anche il parser deve ripartire da capo
			pd_resta <= 8'd0; pd_dentro <= 1'b0; pd_chiude <= 1'b0;
		end
	end else case (pstato)
	P_RIPOSO: begin
		z_cts_n <= 1'b1;
		// La linea e' half-duplex: parla uno per volta, e chi ha il turno lo
		// dice RTS — ma bisogna leggerlo come lo scrive il firmware:
		//
		//   TRASMETTE: $004B mette CNTLA0=$26, cioe' abbassa RTS PRIMA di
		//              mettersi ad aspettare il CTS ($0050). RTS giu' = "ho da
		//              parlare io".
		//   RICEVE   : $0082 aspetta il CTS con CNTLA0 ancora $36, cioe' RTS
		//              ALTO, e lo abbassa solo dopo ($0089, $46, con RE=1).
		//
		// Dare la precedenza alla coda senza guardare RTS vuol dire abbassargli
		// il CTS mentre lui lo stava aspettando per TRASMETTERE: lui parte a
		// parlare, noi gli spingiamo dentro un byte che con RE spento non
		// raccoglie, e quel byte esce dalla coda perso. Il blocco resta monco,
		// non si completa mai, la lunghezza non viene mai iniettata: al 68000
		// quel frame non arriva niente. Non un checksum sbagliato — un blocco
		// in meno, un giro si' e uno no. E' la meta' velocita' misurata.
		if (RX_PRECEDE != 0 && !qr_vuota) begin
			z_cts_n <= 1'b0;
			pstato  <= P_DO;
		end else if (!z_rts_n && in_volo != 2'd2) begin
			// Via libera finche' c'e' un credito: al massimo due blocchi partiti
			// senza gettone di ritorno. Col terzo, lo Z180 resta
			// fermo nell'attesa del CTS ($0050) — lo stallo del PCB, non un
			// guasto.
			z_cts_n <= 1'b0;
			pstato  <= P_PRENDO;
		end else if (!qr_vuota) begin
			// lo Z180 non sta chiedendo la linea: e' fermo ad aspettare il CTS
			// per ricevere ($0082, RTS alto). Adesso si', gli si consegna.
			z_cts_n <= 1'b0;
			pstato  <= P_DO;
		end
	end
	P_PRENDO: begin
		// qui l'attesa e' naturale: rz_pronto arriva solo a byte completo, cioe'
		// dopo 220 us, e lui il CTS l'ha gia' visto per forza
		z_cts_n <= 1'b0;
		if (rz_pronto) begin
			z_cts_n <= 1'b1;
			pstato  <= P_RILASCIO;
		end
	end
	P_DO: begin
		// Si aspetta che lui REAGISCA, non basta abbassare CTS e tirare dritto.
		// Lo Z180 va a 8 MHz e legge il CTS con un'istruzione lunga microsecondi:
		// un impulso di pochi cicli di clock non lo vede proprio. Il segnale che
		// ha visto e' il suo RTS che scende ($0089: CNTLA0=$46, accende RE e
		// abbassa RTS). Solo allora ha senso mandargli il byte.
		z_cts_n <= 1'b0;
		if (RX_PRECEDE == 0 && !z_rts_n && !z_re) begin
			// Ha abbassato RTS senza accendere il ricevitore: non e' la
			// risposta a noi, e' $004B — vuole TRASMETTERE. La consegna si
			// ritira e gli si lascia il turno; il byte resta in coda, intatto.
			z_cts_n <= 1'b1;
			pstato  <= P_RIPOSO;
		end else if (!z_rts_n && (z_re || RX_PRECEDE != 0) && tz_stato == T_FERMO && !tz_carica) begin
			tz_dato   <= qr_testa;
			qr_rd     <= qr_rd + 9'd1;
			tz_carica <= 1'b1;
			pstato    <= P_RILASCIO;
			// avanza il parser sul flusso consegnato
			pd_chiude <= 1'b0;
			if (!pd_dentro) begin
				if (qr_testa == 8'd1)      pd_chiude <= 1'b1;   // blocco di un byte
				else if (qr_testa != 8'd0) begin
					pd_resta  <= qr_testa - 8'd1;
					pd_dentro <= 1'b1;
				end
			end else if (pd_resta == 8'd1) begin
				pd_dentro <= 1'b0;
				pd_chiude <= 1'b1;                              // ultimo del blocco
			end else
				pd_resta <= pd_resta - 8'd1;
		end
	end
	P_RILASCIO: begin
		// il byte in consegna deve essere uscito tutto prima di alzare CTS,
		// altrimenti lui crederebbe finito un byte ancora a meta'
		if (tz_stato == T_FERMO && !tz_carica) begin
			z_cts_n <= 1'b1;
			// e si passa oltre solo quando ha rialzato RTS: e' lui a chiudere il
			// giro, e partire prima vorrebbe dire riabbassargli il CTS mentre sta
			// ancora finendo il byte precedente
			if (z_rts_n) begin
				cnt_guardia <= GUARDIA[15:0];
				pstato      <= P_PAUSA;
				// Il giro e' chiuso: se quello era l'ultimo byte del blocco, il
				// blocco e' DAVVERO dentro il suo Z180, e solo adesso ha senso
				// dirlo all'altro. Prima sarebbe una promessa, non un fatto.
				if (pd_chiude) begin
					manda_gettone <= 1'b1;
					pd_chiude     <= 1'b0;
				end
			end
		end
	end
	P_PAUSA: begin
		// CTS resta alto per un momento, il tempo che lui lo veda davvero
		z_cts_n <= 1'b1;
		if (cnt_guardia == 0) pstato <= P_RIPOSO;
		else cnt_guardia <= cnt_guardia - 16'd1;
	end
	default: pstato <= P_RIPOSO;
	endcase
end

// ---------------------------------------------------------------------------
//  Diagnostica: due contatori, per vedere a colpo d'occhio se passa traffico
// ---------------------------------------------------------------------------
reg [7:0] n_out, n_in;
always @(posedge clk) begin
	if (reset) begin n_out <= 8'd0; n_in <= 8'd0; end
	else begin
		if (rz_pronto) n_out <= n_out + 8'd1;
		if (rh_pronto) n_in  <= n_in  + 8'd1;
	end
end
assign dbg_byte_usciti  = n_out;
assign dbg_byte_entrati = n_in;

endmodule
