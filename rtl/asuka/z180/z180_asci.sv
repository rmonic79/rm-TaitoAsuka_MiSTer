/*  This file is part of Arcade_TaitoAsuka_MiSTer.
    GPL-3.
    Author: Umberto Parisi (rmonic79), 2026.
*/

//============================================================================
//  z180_asci — un canale ASCI (Asynchronous Serial Communication Interface)
//  dello Zilog Z8018x / Hitachi HD64180.
//
//  Scritto sul manuale Zilog UM005004 (reference/z180/), registro per registro.
//  Nessun core aperto lo implementa: Y80e su OpenCores ha solo la CPU, e non
//  esiste altro in Verilog. Questo modulo colma quel pezzo.
//
//  A cosa serve qui: su Cadash il link fra cabinati passa di qui. Due schede
//  si parlano cosi':
//      m68k M -> z180 M <-(ASCI)-> z180 S <- m68k S
//  quindi TXA/RXA vanno alla porta user del MiSTer (USER_OUT/USER_IN) e due
//  MiSTer si collegano come due cabinati.
//
//  Registri (indirizzi I/O interni, canale 0 / canale 1):
//      CNTLA0 $00 / CNTLA1 $01     controllo A: abilitazioni e formato
//      CNTLB0 $02 / CNTLB1 $03     controllo B: baud rate e modo
//      STAT0  $04 / STAT1  $05     stato: pieno/vuoto, errori, interrupt
//      TDR0   $06 / TDR1   $07     dato in trasmissione
//      RDR0   $08 / RDR1   $09     dato ricevuto
//
//  Non implementato di proposito (il gioco non lo usa; aggiungibile dopo):
//  modo multiprocessore (MPE/MP/MPBT), modem control oltre CTS/DCD, break.
//============================================================================

`timescale 1ns / 1ps

module z180_asci #(
	// Divisore di sistema prima del prescaler ASCI. Sul Z180 il clock dei
	// baud viene da PHI; qui lo si lascia parametrico perche' il core gira a
	// una frequenza sua e il rapporto va tarato sul clock reale.
	parameter integer PHI_DIV = 1,

	// --- robustezza della linea, solo lato RICEVITORE -----------------------
	// Su SNAC i due Z180 si parlano davvero su rame: le linee della user port
	// sono open-drain con un pull-up debole, quindi la DISCESA e' netta (la
	// tira giu' un transistor) mentre la SALITA e' una carica RC — e su un cavo
	// lungo si allunga parecchio. Il filo non e' pulito come dentro il chip, e
	// basta un byte sporcato per far alzare PE/FE all'ASCI: la ROM del link
	// manda il suo Z180 nel loop infinito di $00C2 e da li' non esce piu'.
	// Questi due parametri sono le due difese, e non toccano il trasmettitore.

	// 1) Deglitch sull'ingresso gia' sincronizzato: un impulso piu' corto di
	//    questo non passa, il livello cambia solo se il nuovo valore PERSISTE.
	//    192 cicli a 96 MHz = 2 us, cioe' un decimo di un tempo di bit a
	//    50 kbaud: taglia i disturbi e non tocca i dati. 0 = filtro spento.
	parameter integer DEGLITCH_CICLI = 192,

	// 2) Dove cade il campione dentro il bit, contato in SEDICESIMI di bit.
	//    8 = meta' bit, cioe' il centraggio classico (ed e' quello che c'era).
	//    10 = un po' piu' avanti: le salite lente arrivano tardi, le discese
	//    no, quindi spostarsi in avanti REGALA margine sulle salite senza
	//    toglierne alle discese. Vale sia con divide ratio /16 che /64.
	parameter integer CAMPIONE_SU_16 = 10
) (
	input  wire       clk,
	input  wire       reset,
	input  wire       ce,          // clock enable = PHI del Z180

	// --- bus I/O interno (IN0/OUT0 della CPU) ---
	input  wire [2:0] io_addr,     // 0=CNTLA 1=CNTLB 2=STAT 3=TDR 4=RDR
	input  wire       io_rd,
	input  wire       io_wr,
	input  wire [7:0] io_din,
	output reg  [7:0] io_dout,

	// --- piedini seriali (alla porta user del MiSTer) ---
	input  wire       rxd,
	output wire       txd,
	input  wire       cts_n,       // attivo basso; 1 = non abilitato a trasmettere
	input  wire       dcd_n,       // attivo basso; solo canale 0 sul chip vero

	// --- interrupt verso la CPU ---
	// RTS0 in uscita (attivo basso). Sul cabinato Cadash NON e' decorativo:
	// e' con RTS/CTS incrociati che i due Z180 si passano il turno sulla linea
	// half-duplex — la ROM lo pilota a ogni cambio di verso.
	output wire       rts_n,
	// Chi ha abbassato RTS lo fa sia per trasmettere ($26) sia per ricevere
	// ($46): senza sapere quale dei due, il "partner" gli manderebbe un byte
	// addosso mentre sta parlando lui. Questi due bit sciolgono l'ambiguita'.
	output wire       re_attivo,
	output wire       te_attivo,

	output wire       irq
);

// ---------------------------------------------------------------------------
// Registri
// ---------------------------------------------------------------------------
// CNTLA: MPE RE TE RTS0 MPBR/EFR MOD2 MOD1 MOD0
reg  [7:0] cntla;
wire       re      = cntla[6];         // ricevitore abilitato
wire       te      = cntla[5];         // trasmettitore abilitato
assign     rts_n     = cntla[4];       // RTS in uscita (attivo basso)
assign     re_attivo = re;
assign     te_attivo = te;
wire       efr     = cntla[3];         // scrivendo 0 azzera i flag d'errore
wire [2:0] mod     = cntla[2:0];       // formato dati

// MOD2 = 8 bit dati (1) o 7 (0); MOD1 = parita' abilitata; MOD0 = 2 stop (1) o 1 (0)
wire       bits8   = mod[2];
wire       par_en  = mod[1];
wire       stop2   = mod[0];

// CNTLB: MPBT MP CTS/PS PE0 DR SS2 SS1 SS0
reg  [7:0] cntlb;
wire       ps      = cntlb[5];         // prescaler: 0 = /10, 1 = /30
wire       peo     = cntlb[4];         // parita': 0 = pari, 1 = dispari
wire       dr      = cntlb[3];         // divide ratio: 0 = /16, 1 = /64
wire [2:0] ss      = cntlb[2:0];       // divisore ulteriore, 7 = clock esterno

// STAT: RDRF OVRN PE FE RIE DCD0 TDRE TIE
reg        rdrf, ovrn, perr, ferr, rie, tie;
reg  [7:0] rdr;                        // dato ricevuto (leggibile)
reg  [7:0] tdr;                        // dato da trasmettere
reg        tdre;                       // 1 = TDR vuoto, si puo' scrivere

wire [7:0] stat = { rdrf, ovrn, perr, ferr, rie, ~dcd_n, tdre, tie };

// Il chip vero azzera RDRF e gli errori quando DCD e' alto (linea caduta).
wire       dcd_alto = dcd_n;

// ---------------------------------------------------------------------------
// Generatore di baud rate
//   PHI -> prescaler (/10 o /30) -> divisore SS (2^ss, 7 = esterno)
//       -> divide ratio (/16 o /64) -> clock di bit
// Si generano due tempi: uno a 16x (campionamento RX) e uno a 1x (bit).
// ---------------------------------------------------------------------------
localparam integer PRE10 = 10, PRE30 = 30;

reg [15:0] pre_cnt;
wire [15:0] pre_top = 16'((ps ? PRE30 : PRE10) * PHI_DIV);
reg        pre_tick;

always @(posedge clk) begin
	if (reset) begin
		pre_cnt  <= 16'd0;
		pre_tick <= 1'b0;
	end else begin
		pre_tick <= 1'b0;
		if (ce) begin
			if (pre_cnt >= pre_top - 1) begin
				pre_cnt  <= 16'd0;
				pre_tick <= 1'b1;
			end else
				pre_cnt <= pre_cnt + 16'd1;
		end
	end
end

// divisore SS: 2^ss, con ss=7 riservato al clock esterno (non gestito qui)
reg [7:0] ss_cnt;
wire [7:0] ss_top = (ss == 3'd7) ? 8'd1 : (8'd1 << ss);
reg       ss_tick;

always @(posedge clk) begin
	if (reset) begin
		ss_cnt  <= 8'd0;
		ss_tick <= 1'b0;
	end else begin
		ss_tick <= 1'b0;
		if (pre_tick) begin
			if (ss_cnt >= ss_top - 1) begin
				ss_cnt  <= 8'd0;
				ss_tick <= 1'b1;   // questo e' il clock a 16x (o 64x)
			end else
				ss_cnt <= ss_cnt + 8'd1;
		end
	end
end

// divide ratio: 16 o 64 campioni per bit
localparam [6:0] DR16 = 7'd16, DR64 = 7'd64;
wire [6:0] samples = dr ? DR64 : DR16;

// Quanti campioni dopo il fronte di start cade il PRIMO controllo (quello sul
// bit di start). Da li' in poi si va di bit intero, quindi spostare questo
// numero sposta di conseguenza TUTTI i campioni dei bit dati: e' l'unico punto
// da toccare. Vedi il ricevitore per il conto per esteso.
//   CAMPIONE_SU_16 = 8  ->  samples/2, il centraggio di prima
//   CAMPIONE_SU_16 = 10 ->  10/16 del bit
localparam integer CS16 = (CAMPIONE_SU_16 < 1)  ? 1  :
                          (CAMPIONE_SU_16 > 15) ? 15 : CAMPIONE_SU_16;
localparam [6:0] CAMP16 = 7'((16 * CS16) / 16);
localparam [6:0] CAMP64 = 7'((64 * CS16) / 16);
wire [6:0] campione = dr ? CAMP64 : CAMP16;

// ---------------------------------------------------------------------------
// Trasmettitore
// ---------------------------------------------------------------------------
localparam [2:0] T_IDLE = 3'd0, T_START = 3'd1, T_DATA = 3'd2, T_PAR = 3'd3, T_STOP = 3'd4;

reg [2:0]  tstate;
reg [7:0]  tsr;             // shift register
reg [3:0]  tbit;
reg [6:0]  tsamp;
reg        tpar;
reg        txd_r;
reg        tstop2;

assign txd = te ? txd_r : 1'b1;

// CTS alto blocca la trasmissione: e' il modo in cui l'altra scheda dice
// "non adesso". Senza questo il turno non si passa e la linea va in collisione.
wire tx_puo = te & ~cts_n;

always @(posedge clk) begin
	if (reset) begin
		tstate <= T_IDLE;
		txd_r  <= 1'b1;
		tdre   <= 1'b1;
		tsamp  <= 7'd0;
		tbit   <= 4'd0;
	end else begin
		if (io_wr && io_addr == 3'd3) begin
			tdr  <= io_din;
			tdre <= 1'b0;            // pieno: parte la trasmissione
		end

		if (ss_tick) begin
			case (tstate)
			T_IDLE: begin
				txd_r <= 1'b1;
				if (~tdre && tx_puo) begin
					tsr    <= tdr;
					tpar   <= peo;    // seme della parita'
					tbit   <= 4'd0;
					tsamp  <= 7'd0;
					txd_r  <= 1'b0;   // start bit
					tstate <= T_START;
				end
			end
			T_START: begin
				if (tsamp >= samples - 1) begin
					tsamp  <= 7'd0;
					txd_r  <= tsr[0];
					tstate <= T_DATA;
				end else
					tsamp <= tsamp + 7'd1;
			end
			T_DATA: begin
				if (tsamp >= samples - 1) begin
					tsamp <= 7'd0;
					tpar  <= tpar ^ tsr[0];
					tsr   <= {1'b0, tsr[7:1]};
					tbit  <= tbit + 4'd1;
					if (tbit == (bits8 ? 4'd7 : 4'd6)) begin
						// La ROM del link di Cadash usa MOD=110: 8 bit + PARITA' + 1 stop,
						// con PEO=1 (dispari). Quindi il bit di parita' serve davvero.
						if (par_en) begin
							txd_r  <= tpar ^ tsr[0];   // ultimo bit incluso nel calcolo
							tstate <= T_PAR;
						end else begin
							txd_r  <= 1'b1;            // stop
							tstop2 <= stop2;
							tstate <= T_STOP;
						end
						tdre <= 1'b1;                  // TDR di nuovo scrivibile
					end else
						txd_r <= tsr[1];
				end else
					tsamp <= tsamp + 7'd1;
			end
			T_PAR: begin
				if (tsamp >= samples - 1) begin
					tsamp  <= 7'd0;
					txd_r  <= 1'b1;                // stop
					tstop2 <= stop2;
					tstate <= T_STOP;
				end else
					tsamp <= tsamp + 7'd1;
			end
			T_STOP: begin
				if (tsamp >= samples - 1) begin
					tsamp <= 7'd0;
					if (tstop2) tstop2 <= 1'b0;
					else        tstate <= T_IDLE;
				end else
					tsamp <= tsamp + 7'd1;
			end
			default: tstate <= T_IDLE;
			endcase
		end
	end
end

// ---------------------------------------------------------------------------
// Ricevitore — campionamento a CAMPIONE_SU_16 sedicesimi di bit
// ---------------------------------------------------------------------------
localparam [2:0] R_IDLE = 3'd0, R_START = 3'd1, R_DATA = 3'd2, R_PAR = 3'd3, R_STOP = 3'd4;

reg [2:0] rstate;
reg       rpar;
reg [7:0] rsr;
reg [3:0] rbit;
reg [6:0] rsamp;
reg       rxd_s1, rxd_s2;      // sincronizzatore: il segnale arriva da fuori

always @(posedge clk) begin
	rxd_s1 <= rxd;
	rxd_s2 <= rxd_s1;
end

// --- deglitch, dopo il sincronizzatore e PRIMA della macchina a stati -------
// Il conteggio va su `clk`, non su `ce` ne' su `ss_tick`: un disturbo dura
// nanosecondi e fra due ss_tick ce ne stanno 120 di cicli di clock — contarlo
// col tick vorrebbe dire non vederlo affatto. Qui il livello "vero" cambia solo
// quando il nuovo valore ha tenuto per DEGLITCH_CICLI cicli di fila; qualunque
// cosa piu' corta lascia la linea dov'era.
//
// Il ritardo che introduce e' UNIFORME (lo stesso su ogni fronte buono), quindi
// non sposta i campioni rispetto ai dati: ritarda insieme il riconoscimento
// dello start e tutti i campionamenti che ne discendono. 2 us su un bit da
// 20 us non spostano niente, spostano tutto insieme.
localparam integer DEG_N = (DEGLITCH_CICLI > 0) ? DEGLITCH_CICLI : 1;
localparam integer DEG_W = $clog2(DEG_N + 1);

reg [DEG_W-1:0] deg_cnt;
reg             rxd_stab;

always @(posedge clk) begin
	if (reset) begin
		deg_cnt  <= {DEG_W{1'b0}};
		rxd_stab <= 1'b1;                       // a riposo la linea sta alta
	end else if (rxd_s2 == rxd_stab) begin
		deg_cnt  <= {DEG_W{1'b0}};              // niente da decidere
	// Confronto per uguaglianza e non ">=": il contatore parte da zero, sale di
	// uno per volta e si azzera sia quando arriva in fondo sia quando la linea
	// torna d'accordo, quindi il valore non lo puo' saltare. Col filtro spento
	// (DEGLITCH_CICLI = 0) il fondo e' zero, e un ">= 0" su un contatore senza
	// segno e' sempre vero: vero uguale, ma il simulatore lo segnala.
	end else if (deg_cnt == DEG_W'(DEG_N - 1)) begin
		rxd_stab <= rxd_s2;                     // ha tenuto: adesso e' vero
		deg_cnt  <= {DEG_W{1'b0}};
	end else
		deg_cnt <= deg_cnt + DEG_W'(1);
end

// Con DEGLITCH_CICLI = 0 il filtro non c'e' proprio: si va dritti al
// sincronizzatore, com'era prima.
wire rxd_ok = (DEGLITCH_CICLI > 0) ? rxd_stab : rxd_s2;

always @(posedge clk) begin
	if (reset) begin
		rstate <= R_IDLE;
		rdrf   <= 1'b0;
		ovrn   <= 1'b0;
		perr   <= 1'b0;
		ferr   <= 1'b0;
	end else begin
		// lettura di RDR: azzera RDRF (comportamento del chip vero)
		if (io_rd && io_addr == 3'd4) rdrf <= 1'b0;
		// EFR: scrivendo 0 sul bit 3 di CNTLA si azzerano gli errori
		if (io_wr && io_addr == 3'd0 && ~io_din[3]) begin
			ovrn <= 1'b0; perr <= 1'b0; ferr <= 1'b0;
		end
		// linea caduta: il chip azzera RDRF e gli errori
		if (dcd_alto) begin
			rdrf <= 1'b0; ovrn <= 1'b0; perr <= 1'b0; ferr <= 1'b0;
		end

		// RE spento = ricevitore DISABILITATO, non "in pausa". Sul chip vero,
		// quando lo si riaccende va a cercare un bit di start da capo. Qui la
		// macchina a stati veniva solo congelata: se al momento dello spegnimento
		// era a meta' di un carattere — basta un fronte spurio raccolto sulla
		// linea — alla riaccensione riprendeva da li', contando i bit di un byte
		// che non esiste piu': un carattere inventato, o l'allineamento perso per
		// quello dopo. Il firmware spegne RE a ogni giro per trasmettere
		// ($26/$36), quindi la finestra c'e' a ogni byte.
		if (!re) rstate <= R_IDLE;
		else if (ss_tick) begin
			case (rstate)
			R_IDLE: begin
				if (~rxd_ok) begin       // fronte di start
					rsamp  <= 7'd0;
					rstate <= R_START;
				end
			end
			R_START: begin
				// DOVE CADONO I CAMPIONI, il conto per esteso (in tick a 16x,
				// contando 0 il tick in cui R_IDLE ha visto il fronte di start):
				//
				//   R_START dura `campione` tick  -> controllo dello start a
				//     `campione`/16 del bit di start;
				//   poi ogni R_DATA dura un bit intero (`samples` tick), quindi
				//     il bit dati k viene campionato al tick
                //         campione + (k+1)*samples
				//     cioe' esattamente a `campione`/16 DENTRO il proprio bit.
				//
				// Con campione = samples/2 (CAMPIONE_SU_16 = 8) tornano gli 8/16
				// di prima; con 10 tutti i campioni — start, dati, parita' e
				// stop — si spostano insieme a 10/16. E' l'unica manopola: non
				// c'e' nessun altro punto in cui il centraggio si decida.
				if (rsamp >= campione - 7'd1) begin
					rsamp <= 7'd0;
					if (~rxd_ok) begin
						rbit   <= 4'd0;
						rpar   <= peo;          // seme della parita'
						rstate <= R_DATA;
					end else
						rstate <= R_IDLE;   // falso start
				end else
					rsamp <= rsamp + 7'd1;
			end
			R_DATA: begin
				if (rsamp >= samples - 1) begin
					rsamp <= 7'd0;
					rsr   <= {rxd_ok, rsr[7:1]};
					rpar  <= rpar ^ rxd_ok;
					rbit  <= rbit + 4'd1;
					if (rbit == (bits8 ? 4'd7 : 4'd6))
						rstate <= par_en ? R_PAR : R_STOP;
				end else
					rsamp <= rsamp + 7'd1;
			end
			R_PAR: begin
				if (rsamp >= samples - 1) begin
					rsamp <= 7'd0;
					// rpar e' gia' seminato con PEO come lo e' in trasmissione, quindi
					// il seme si elide: se il bit ricevuto coincide con rpar la parita'
					// torna, qualunque sia la convenzione pari/dispari.
					if (rpar != rxd_ok) perr <= 1'b1;
					rstate <= R_STOP;
				end else
					rsamp <= rsamp + 7'd1;
			end
			R_STOP: begin
				if (rsamp >= samples - 1) begin
					rsamp <= 7'd0;
					if (~rxd_ok) ferr <= 1'b1;      // stop bit assente = framing error
					if (rdrf)    ovrn <= 1'b1;      // il precedente non e' stato letto
					rdr  <= bits8 ? rsr : {1'b0, rsr[7:1]};
					rdrf <= 1'b1;
					rstate <= R_IDLE;
				end else
					rsamp <= rsamp + 7'd1;
			end
			default: rstate <= R_IDLE;
			endcase
		end
	end
end

// ---------------------------------------------------------------------------
// Interfaccia registri
// ---------------------------------------------------------------------------
always @(*) begin
	case (io_addr)
	3'd0:    io_dout = cntla;
	// In lettura il bit 5 di CNTLB non restituisce PS ma il livello del pin CTS:
	// e' cosi' che il programma sa se puo' trasmettere. La ROM del link lo
	// interroga in polling a ogni cambio di verso ($0050 e $005B).
	3'd1:    io_dout = {cntlb[7:6], cts_n, cntlb[4:0]};
	3'd2:    io_dout = stat;
	3'd3:    io_dout = tdr;
	3'd4:    io_dout = rdr;
	default: io_dout = 8'hFF;
	endcase
end

always @(posedge clk) begin
	if (reset) begin
		cntla <= 8'h10;     // RTS0 = 1 a reset, resto 0
		cntlb <= 8'h07;     // SS = 111 a reset
		rie   <= 1'b0;
		tie   <= 1'b0;
	end else if (io_wr) begin
		case (io_addr)
		3'd0: cntla <= io_din;
		3'd1: cntlb <= io_din;
		3'd2: begin rie <= io_din[3]; tie <= io_din[0]; end  // gli altri bit di STAT sono di sola lettura
		default: ;
		endcase
	end
end

assign irq = (rie & rdrf) | (tie & tdre);

endmodule
