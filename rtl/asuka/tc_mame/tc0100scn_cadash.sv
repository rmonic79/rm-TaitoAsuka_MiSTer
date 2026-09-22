// tc0100scn_cadash.sv — TC0100SCN Cadash dedicated, MAME-faithful.
//
// Reference: MAME tc0100scn.cpp (Nicola Salmoria) + asuka.cpp (Cadash setup).
//
// Cadash hardware:
//   - Single-width tilemaps (no dual width)
//   - 8x8x4 packed_msb BG tiles from external ROM
//   - 2bpp FG text chars from internal VRAM word $3000-$37FF
//   - VRAM layout (single):
//       $0000-$1FFF BG0 tilemap (64×64 tile, 2 word/tile: attr+code)
//       $2000-$2FFF FG0 tilemap (64×64, 1 word/tile)
//       $3000-$37FF FG0 char gfx (256 char × 16 byte = 2K word)
//       $4000-$5FFF BG1 tilemap (64×64, 2 word/tile)
//       $6000-$61FF BG0 rowscroll (256 word)
//       $6200-$63FF BG1 rowscroll (256 word)
//       $7000-$707F BG1 colscroll (128 word)
//   - x_offset=1, y_offset=0, cliprect.top=16 (asuka.cpp:1248, 1260)
//   - SCROLLDX = -1 - 16 = -17 (MAME standard)
//   - SCROLLDY = 8 (MAME yd) - 16 (cliprect.top) = -8
//   - Tile ROM mask 0x3FFF (Cadash 512KB = 16384 tile)
//
// MAME tile_info (tc0100scn.cpp:400-401):
//   code = m_ram[(2*tile_index) + 1 + Offset]  ← word DISPARI
//   attr = m_ram[(2*tile_index) + Offset]       ← word PARI
//
// FSM pipeline (single chip, no multi-chip serialization):
//   IDLE → RS (rowscroll) → AT (attr) → CD (code) → ROM (gfx fetch) → PIX (8 pix decode)
//   → next tile or BG1 → ... → FG → DONE → IDLE
//
// VRAM read latency: vram_b_addr emit → +2 clk → vram_b_rdata valid
// (Port B mirror BRAM in asuka_top: 2-stage registered read)
//
// Tile ROM toggle protocol:
//   rom_addr emit + rom_req toggle → wait rom_req == rom_ack → rom_data valid

module tc0100scn_cadash #(
	parameter integer SS_IDX_RSLOG = -1
) (
	input  wire        clk,
	input  wire        reset,
	// 1 = la scheda usa set_offsets(1,0) (Cadash); 0 = default (0,0)
	input  wire        scn_x_off1,

	// CPU interface (Cadash $C00000-$C0FFFF VRAM, $C20000-$C2000F CTRL)
	input  wire [17:0] cpu_addr,        // [17]=ctrl, [16:1]=word_addr
	input  wire [15:0] cpu_din,
	output reg  [15:0] cpu_dout,
	input  wire        cpu_rnw,
	input  wire [1:0]  cpu_dsn,         // {UDSn, LDSn}
	input  wire        cpu_cs,
	output reg         cpu_dtack_n,

	// VRAM Port A — CPU (external dual-port BRAM)
	output wire [15:0] vram_a_addr,
	output wire [15:0] vram_a_wdata,
	output wire [1:0]  vram_a_we,       // {hi, lo} active-high
	input  wire [15:0] vram_a_rdata,

	// VRAM Port B — renderer (read only)
	output reg  [15:0] vram_b_addr,
	input  wire [15:0] vram_b_rdata,

	// Tile ROM (toggle protocol, 32-bit fetch)
	output reg  [20:0] rom_addr,
	input  wire [31:0] rom_data,
	output reg         rom_req,
	input  wire        rom_ack,

	// Video output (15-bit: {prio[14:13], 0, color[7:0], pixel[3:0]})
	output reg  [14:0] SC,

	// Timing
	input  wire [9:0]  render_x,
	input  wire [8:0]  render_y,
	// Ultima riga del quadro (V_TOTAL-1), dal compositor: serve solo a sapere
	// dove render_y ripiega a 0.
	input  wire [8:0]  last_line,

	// Fotografia del quadro (modo MAME). `snap` e' UN impulso di un clock, lo
	// stesso filo che nel top alza l'IRQ di vblank e fa partire la copia della
	// sprite RAM: non c'e' una seconda formula dell'istante da nessuna parte.
	// A quel clock si fermano gli otto registri e parte la copia delle tabelle
	// di rowscroll e colscroll; tutto il quadro dopo si disegna da li'.
	// snap_busy = copia delle tabelle non ancora finita: finche' e' alto il top
	// non lascia entrare scritture della CPU in VRAM, quindi la copia e' lo
	// stato della VRAM al clock di snap anche se dura 20 us.
	input  wire        snap,
	input  wire        scroll_frame_latch,   // 1 = MAME (fotografia), 0 = PCB (vivo)
	output wire        snap_busy,

	input  wire        go,              // 1-pulse: start scanline (hblank rise)
	output reg         done,

	// OSD layer enable [0]=BG0, [1]=BG1, [2]=FG0
	input  wire [2:0]  osd_layer_en,

	// Per-layer OSD offset
	input  wire signed [9:0] bg0_xoff_ext, bg0_yoff_ext,
	input  wire signed [9:0] bg1_xoff_ext, bg1_yoff_ext,
	input  wire signed [9:0] fg0_xoff_ext, fg0_yoff_ext,

	// [SS] registri di controllo esposti per il savestate/dump video.
	// Solo lettura: nessun effetto sul rendering.
	output wire [127:0] ctrl_flat,

	// [DBG] log del rowscroll EFFETTIVAMENTE letto dal renderer, per scanline.
	// [0..255] = BG0, [256..511] = BG1. Finisce nel savestate: dice cosa e' arrivato
	// al calcolo di line_sx su ogni riga, non cosa c'e' in memoria.
	ssbus_if.slave      ss_rslog
);

(* ramstyle = "M10K,no_rw_check" *) reg [7:0] rslog_hi [0:511];
(* ramstyle = "M10K,no_rw_check" *) reg [7:0] rslog_lo [0:511];
reg  [8:0] rslog_a;
reg [15:0] rslog_d;
reg        rslog_we;
wire        rsl_we_lo, rsl_we_hi;
wire  [8:0] rsl_addr;
wire [15:0] rsl_wdata;
reg  [15:0] rsl_q;
ss_ram16_adaptor #(.WIDTHAD(9), .SS_IDX(SS_IDX_RSLOG)) u_ss_rslog (
	.clk(clk),
	.we_lo_in(rslog_we), .we_hi_in(rslog_we),
	.addr_in(rslog_a), .wdata_in(rslog_d),
	.we_lo_out(rsl_we_lo), .we_hi_out(rsl_we_hi),
	.addr_out(rsl_addr),   .wdata_out(rsl_wdata),
	.q_in(rsl_q), .ssbus(ss_rslog)
);
always @(posedge clk) begin
	if (rsl_we_hi) rslog_hi[rsl_addr] <= rsl_wdata[15:8];
	rsl_q[15:8] <= rslog_hi[rsl_addr];
end
always @(posedge clk) begin
	if (rsl_we_lo) rslog_lo[rsl_addr] <= rsl_wdata[7:0];
	rsl_q[7:0]  <= rslog_lo[rsl_addr];
end

// =====================================================================
// Offset del chip — dipendono dalla SCHEDA, non dal chip
// =====================================================================
// MAME: Cadash fa set_offsets(1, 0) (asuka.cpp:1260); la famiglia asuka
// (Asuka & Asuka, Galmedes, Earth Joker, Maze of Flott) lascia il default
// (0, 0). Quindi cambia SOLO la X: Y_OFFSET e' zero per tutti e SCROLLDY
// resta costante.
localparam signed [15:0] Y_OFFSET = 16'sd0;
localparam signed [15:0] CLIPRECT_TOP = 16'sd16;  // asuka.cpp:1248 visarea(0,319,16,255)

localparam signed [15:0] YD       = 16'sd8 - Y_OFFSET;                      // = 8
// MAME tc0100scn.cpp:273-274: set_scrolldx(xd-16, ...), set_scrolldy(yd, ...)
// m_dx = xd-16 = -17. m_dy = yd = 8. Cliprect NON entra (clip render, non scroll).
// XD = -X_OFFSET, SCROLLDX = XD - 16: Cadash -17, famiglia asuka -16.
wire signed [15:0] SCROLLDX = scn_x_off1 ? -16'sd17 : -16'sd16;
localparam signed [15:0] SCROLLDY = YD;                                      // = 8

// VRAM bases (single-width, MAME tc0100scn.cpp:249-256, 442-444, 306)
localparam [15:0] BG0_BASE = 16'h0000;
localparam [15:0] FG0_MAP  = 16'h2000;
localparam [15:0] FG0_GFX  = 16'h3000;
localparam [15:0] BG1_BASE = 16'h4000;
localparam [15:0] BG0_RS   = 16'h6000;
localparam [15:0] BG1_RS   = 16'h6200;
localparam [15:0] BG1_CS   = 16'h7000;

// =====================================================================
// Control registers (8 word, $C20000-$C2000F)
// MAME tc0100scn.cpp:454-472 (restore_scroll):
//   ctrl[0] = BG0 scrollx, ctrl[1] = BG1 scrollx, ctrl[2] = FG0 scrollx
//   ctrl[3] = BG0 scrolly, ctrl[4] = BG1 scrolly, ctrl[5] = FG0 scrolly
//   ctrl[6] = layer disable + flip + bg_prio + wide
//   ctrl[7][0] = flip screen
// =====================================================================
reg [15:0] ctrl [0:7];
assign ctrl_flat = {ctrl[7],ctrl[6],ctrl[5],ctrl[4],ctrl[3],ctrl[2],ctrl[1],ctrl[0]};  // [SS]
// Fermo degli otto registri al clock di snap (solo modo MAME). Una scrittura
// della CPU che entra nello stesso fronte in cui si ferma resta FUORI, come
// le scritture di sprite RAM e VRAM che il top trattiene da quel clock: il
// taglio e' lo stesso per tutto.
reg [15:0] ctrl_l [0:7];
integer cli;
initial for (cli = 0; cli < 8; cli = cli + 1) ctrl_l[cli] = 16'd0;
always @(posedge clk)
	if (snap && scroll_frame_latch)
		for (cli = 0; cli < 8; cli = cli + 1) ctrl_l[cli] <= ctrl[cli];

wire [15:0] cr0 = scroll_frame_latch ? ctrl_l[0] : ctrl[0];
wire [15:0] cr1 = scroll_frame_latch ? ctrl_l[1] : ctrl[1];
wire [15:0] cr2 = scroll_frame_latch ? ctrl_l[2] : ctrl[2];
wire [15:0] cr3 = scroll_frame_latch ? ctrl_l[3] : ctrl[3];
wire [15:0] cr4 = scroll_frame_latch ? ctrl_l[4] : ctrl[4];
wire [15:0] cr5 = scroll_frame_latch ? ctrl_l[5] : ctrl[5];
wire [15:0] cr6 = scroll_frame_latch ? ctrl_l[6] : ctrl[6];
wire [15:0] cr7 = scroll_frame_latch ? ctrl_l[7] : ctrl[7];

wire        flip    = cr7[0];
wire        bg0_dis = cr6[0];
wire        bg1_dis = cr6[1];
wire        fg0_dis = cr6[2];
wire        bg_prio = cr6[3];  // bottomlayer: 0=BG1 bottom, 1=BG0 bottom

wire signed [15:0] bg0_sx = -$signed(cr0);
wire signed [15:0] bg1_sx = -$signed(cr1);
wire signed [15:0] fg0_sx = -$signed(cr2);
wire signed [15:0] bg0_sy = -$signed(cr3);
wire signed [15:0] bg1_sy = -$signed(cr4);
wire signed [15:0] fg0_sy = -$signed(cr5);

// Parte del conto dello scroll orizzontale che NON viene dalla VRAM:
//   line_sx = (scroll - SCROLLDX + offset OSD) - rowscroll
// La si tiene pronta in un registro, cosi' dopo la lettura della tabella resta
// una sola sottrazione. Prima erano quattro catene di sommatori in fila dietro
// l'uscita della RAM, ed erano il cammino piu' lento rimasto nel core.
reg signed [15:0] bg0_base, bg1_base;
always @(posedge clk) begin
	bg0_base <= bg0_sx - SCROLLDX + $signed({6'd0, bg0_xoff_ext});
	bg1_base <= bg1_sx - SCROLLDX + $signed({6'd0, bg1_xoff_ext});
end

// Fotografia delle tabelle: rowscroll BG0 ($6000) e BG1 ($6200), 256 parole
// ciascuna (l'indice di riga arriva al massimo a 239+8), e colscroll BG1
// ($7000), 128 parole. Le legge la macchina di disegno dalla porta B, che al
// clock di snap e' ferma: l'ultima riga del quadro e' gia' fatta e la prima
// del quadro dopo parte venti righe piu' tardi.
(* ramstyle = "M10K,no_rw_check" *) reg [15:0] rs_snap [0:511];
(* ramstyle = "M10K,no_rw_check" *) reg [15:0] cs_snap [0:127];
reg  [9:0] snap_idx;
reg        snap_req;
reg [15:0] rs_q, cs_q;
reg  [8:0] rs_rd;
reg  [6:0] cs_rd;
initial begin snap_req = 1'b0; snap_idx = 10'd0; rs_rd = 9'd0; cs_rd = 7'd0; end
// Contenuto iniziale a zero, dichiarato: e' quello che fa la M10K all'accensione,
// e prima della prima fotografia la macchina di disegno legge gia' da qui.
integer sni;
initial begin
	for (sni = 0; sni < 512; sni = sni + 1) rs_snap[sni] = 16'd0;
	for (sni = 0; sni < 128; sni = sni + 1) cs_snap[sni] = 16'd0;
end
always @(posedge clk) begin
	rs_q <= rs_snap[rs_rd];
	cs_q <= cs_snap[cs_rd];
end

// =====================================================================
// CPU interface
// =====================================================================
reg prev_cs, vram_rd_pend;

assign vram_a_addr  = cpu_addr[16:1];
assign vram_a_wdata = cpu_din;
assign vram_a_we[1] = cpu_cs & ~cpu_addr[17] & ~cpu_rnw & ~cpu_dsn[1];
assign vram_a_we[0] = cpu_cs & ~cpu_addr[17] & ~cpu_rnw & ~cpu_dsn[0];

always @(posedge clk) begin
	if (reset) begin
		cpu_dtack_n  <= 1'b1;
		prev_cs      <= 1'b0;
		vram_rd_pend <= 1'b0;
		ctrl[0] <= 0; ctrl[1] <= 0; ctrl[2] <= 0; ctrl[3] <= 0;
		ctrl[4] <= 0; ctrl[5] <= 0; ctrl[6] <= 0; ctrl[7] <= 0;
	end else begin
		prev_cs <= cpu_cs;
		if (cpu_cs & ~prev_cs) begin
			if (cpu_addr[17]) begin  // ctrl access
				if (cpu_rnw) cpu_dout <= ctrl[cpu_addr[3:1]];
				else begin
					if (~cpu_dsn[1]) ctrl[cpu_addr[3:1]][15:8] <= cpu_din[15:8];
					if (~cpu_dsn[0]) ctrl[cpu_addr[3:1]][7:0]  <= cpu_din[7:0];
				end
				cpu_dtack_n <= 1'b0;
			end else if (~cpu_rnw)
				cpu_dtack_n <= 1'b0;
			else
				vram_rd_pend <= 1'b1;
		end
		if (vram_rd_pend) begin
			cpu_dout     <= vram_a_rdata;
			cpu_dtack_n  <= 1'b0;
			vram_rd_pend <= 1'b0;
		end
		if (~cpu_cs) begin
			cpu_dtack_n  <= 1'b1;
			vram_rd_pend <= 1'b0;
		end
	end
end

// =====================================================================
// Line buffers: double-buffered ping-pong (320 px × 12 bit per layer)
// FSM writes to wr_buf, display reads from ~wr_buf.
// =====================================================================
(* ramstyle = "M10K,no_rw_check" *) reg [11:0] lb_bg0_0 [0:319];
(* ramstyle = "M10K,no_rw_check" *) reg [11:0] lb_bg0_1 [0:319];
(* ramstyle = "M10K,no_rw_check" *) reg [11:0] lb_bg1_0 [0:319];
(* ramstyle = "M10K,no_rw_check" *) reg [11:0] lb_bg1_1 [0:319];
(* ramstyle = "M10K,no_rw_check" *) reg [11:0] lb_fg0_0 [0:319];
(* ramstyle = "M10K,no_rw_check" *) reg [11:0] lb_fg0_1 [0:319];
reg wr_buf;

// =====================================================================
// go_latch + render_y_latch: lookahead 1 scanline.
// Display mostra scanline N, FSM rende scanline N+1 sul wr_buf.
// =====================================================================
reg        go_latch;
reg [8:0]  render_y_latch;
always @(posedge clk) begin
	if (reset) begin
		go_latch       <= 1'b0;
		render_y_latch <= 9'd0;
		wr_buf         <= 1'b0;
	end else begin
		if (go) begin
			go_latch <= 1'b1;
			// Lookahead: scanline N+1
			// Giro di quadro: render_y arriva al massimo a V_TOTAL-1 e la riga dopo
			// e' la 0. Il numero NON si scrive qui: era 263 di Darius (quadro da 264
			// righe) e con un raster diverso il confronto non scatta piu', quindi in
			// cima allo schermo escono le righe del fondo. Ora lo dice il compositor.
			render_y_latch <= (render_y == last_line) ? 9'd0 : render_y + 9'd1;
		end else if (st == S_IDLE && go_latch) begin
			go_latch <= 1'b0;
			wr_buf   <= ~wr_buf;
		end
	end
end

// =====================================================================
// [FLIP] Schermo capovolto (ctrl[7] bit 0, tc0100scn.cpp:466).
//
// Sul cabinato il flip e' il monitor montato al contrario: l'immagine e' la
// stessa, ruotata di 180 gradi. Qui si ottiene in due punti soli, e la regola
// arriva dai core Raiden (Raiden_tile_layer.sv:155-165, e il blocco "NIENTE
// mirror della vpos" di Raiden2.sv:940-950):
//
//   - si specchia il CONTENUTO, cioe' quale riga di gioco finisce nel buffer,
//     MAI il tempo. render_y_latch continua a dire QUANDO si disegna, e tutte
//     le condizioni di tempo (la finestra < 240, la fotografia delle tabelle,
//     il giro dei buffer) restano sui suoi valori veri. Specchiando il tempo,
//     su Raiden, il fermo dello scroll cadeva in un istante diverso dalla copia
//     della sprite RAM: sfondo e sprite si desincronizzavano.
//   - si specchia l'indirizzo di LETTURA del buffer di riga, non la scrittura:
//     la macchina di disegno resta identica, cambia solo da che capo si legge.
// =====================================================================
wire [8:0] ryl_c = flip ? (9'd239 - render_y_latch) : render_y_latch;

// =====================================================================
// Renderer FSM
// Per BG: 1 rowscroll fetch (read latency 2) → per tile: attr fetch (2)
//   + code fetch (2) + ROM fetch (toggle) + 8 pix decode.
// Per BG1: aggiunge colscroll per-tile.
// Per FG: 1 attr+code fetch (1 word) + gfx fetch (2bpp da VRAM) + 8 pix decode.
// =====================================================================
localparam [5:0]
	S_INIT       = 6'd60,  // clear LB post reset
	S_IDLE       = 6'd0,

	// BG0 spike filter: fetch j-1, j+1, j sequence
	// BG0
	S_B0_RS0     = 6'd1,
	S_B0_RS1     = 6'd2,
	S_B0_RS2     = 6'd3,
	S_B0_AT0     = 6'd4,
	S_B0_AT1     = 6'd5,
	S_B0_AT2     = 6'd6,
	S_B0_AT3     = 6'd36,   // EXTRA WAIT mirror pipeline 2-stage
	S_B0_CD0     = 6'd7,
	S_B0_CD1     = 6'd8,
	S_B0_CD2     = 6'd9,    // EXTRA WAIT to ensure vram_b_rdata stable for code
	S_B0_ROM0    = 6'd10,
	S_B0_ROM1    = 6'd11,
	S_B0_PIX     = 6'd12,
	// BG1
	S_B1_RS0     = 6'd13,
	S_B1_RS1     = 6'd14,
	S_B1_RS2     = 6'd15,
	S_B1_CS0     = 6'd16,
	S_B1_CS1     = 6'd17,
	S_B1_CS2     = 6'd18,
	S_B1_CS3     = 6'd37,   // EXTRA WAIT mirror pipeline 2-stage
	S_B1_AT0     = 6'd19,
	S_B1_AT1     = 6'd20,
	S_B1_AT2     = 6'd21,
	S_B1_AT3     = 6'd38,   // EXTRA WAIT mirror pipeline 2-stage
	S_B1_CD0     = 6'd22,
	S_B1_CD1     = 6'd23,
	S_B1_CD2     = 6'd24,
	S_B1_ROM0    = 6'd25,
	S_B1_ROM1    = 6'd26,
	S_B1_PIX     = 6'd27,
	// FG0 (no extra wait — già 3 cicli dopo emit: AT0→AT1→AT2→GX0/GX0→GX1→GX2→PIX)
	S_FG_AT0     = 6'd28,
	S_FG_AT1     = 6'd29,
	S_FG_AT2     = 6'd30,
	S_FG_GX0     = 6'd31,
	S_FG_GX1     = 6'd32,
	S_FG_GX2     = 6'd33,
	S_FG_PIX     = 6'd34,
	S_DONE       = 6'd35,
	S_SNAP_A     = 6'd39,   // fotografia tabelle: indirizzo emesso
	S_SNAP_B     = 6'd40,   // attesa VRAM
	S_SNAP_C     = 6'd41;   // memorizza e avanza

reg [5:0]  st;
reg [8:0]  rline;
reg [8:0]  rpx;
reg [2:0]  subpx;
reg [15:0] lat_attr, lat_code;
reg [31:0] lat_gfx32;
reg signed [15:0] line_sx;
reg signed [15:0] line_sy;
reg signed [15:0] bg1_tile_sy;

// Richiesta di fotografia delle tabelle: si alza al clock di snap (modo MAME),
// si abbassa quando la macchina entra nella copia. snap_busy copre tutto il
// tratto, dalla richiesta all'ultima parola: il top tiene ferme le scritture
// CPU in VRAM finche' e' alto.
always @(posedge clk) begin
	if (reset)                           snap_req <= 1'b0;
	else if (snap && scroll_frame_latch) snap_req <= 1'b1;
	else if (st == S_SNAP_A)             snap_req <= 1'b0;
end
assign snap_busy = snap_req | (st == S_SNAP_A) | (st == S_SNAP_B) | (st == S_SNAP_C);
// BG0 rowscroll spike filter

always @(posedge clk) begin
	if (reset) begin
		st       <= S_INIT;
		rpx      <= 0;
		rom_req  <= 1'b0;
		done     <= 1'b0;
	end else if (st == S_INIT) begin
		// Clear 320 entry × 6 banks
		lb_bg0_0[rpx[8:0]] <= 12'd0;
		lb_bg0_1[rpx[8:0]] <= 12'd0;
		lb_bg1_0[rpx[8:0]] <= 12'd0;
		lb_bg1_1[rpx[8:0]] <= 12'd0;
		lb_fg0_0[rpx[8:0]] <= 12'd0;
		lb_fg0_1[rpx[8:0]] <= 12'd0;
		if (rpx == 9'd319) begin
			rpx <= 0;
			st  <= S_IDLE;
		end else
			rpx <= rpx + 9'd1;
	end else begin
		done <= 1'b0;
		rslog_we <= 1'b0;
		case (st)
		// =============================================================
		S_IDLE: begin
			if (snap_req) begin
				snap_idx    <= 10'd0;
				vram_b_addr <= BG0_RS;
				st <= S_SNAP_A;
			end else if (go_latch && render_y_latch < 9'd240) begin
				// La condizione qui sopra e' TEMPO: resta su render_y_latch vero.
				// Da qui in giu' si lavora sul CONTENUTO, quindi ryl_c.
				rline <= ryl_c;
				rs_rd <= (($signed({7'd0, ryl_c}) + SCROLLDY) & 16'h00ff);
				rpx   <= 0;
				subpx <= 0;
				// MAME tilemap library standard (BG0): set_scrollx((j + bgscrolly) & 0x1ff, ...).
				// j = render_y + SCROLLDY (con SCROLLDY=8).
				vram_b_addr <= BG0_RS + (($signed({7'd0, ryl_c}) + SCROLLDY) & 16'h01ff);
				st <= S_B0_RS0;
			end
		end

		// ── fotografia: 0..255 rowscroll BG0, 256..511 rowscroll BG1,
		//    512..639 colscroll BG1. Tre clock a parola (VRAM a 2 di latenza).
		S_SNAP_A: st <= S_SNAP_B;
		S_SNAP_B: st <= S_SNAP_C;
		S_SNAP_C: begin
			if (snap_idx < 10'd512) rs_snap[snap_idx[8:0]] <= vram_b_rdata;
			else                    cs_snap[snap_idx[6:0]] <= vram_b_rdata;
			if (snap_idx == 10'd639) st <= S_IDLE;
			else begin
				snap_idx    <= snap_idx + 10'd1;
				vram_b_addr <= (snap_idx < 10'd255) ? (BG0_RS + {6'd0, snap_idx} + 16'd1)
				             : (snap_idx < 10'd511) ? (BG1_RS + {6'd0, snap_idx} + 16'd1 - 16'd256)
				             :                        (BG1_CS + {6'd0, snap_idx} + 16'd1 - 16'd512);
				st <= S_SNAP_A;
			end
		end

		// ── BG0 ──────────────────────────────────────────────────────
		S_B0_RS0: st <= S_B0_RS1;
		S_B0_RS1: st <= S_B0_RS2;
		S_B0_RS2: begin
			line_sx <= bg0_base - $signed(scroll_frame_latch ? rs_q : vram_b_rdata);
			rslog_a <= {1'b0, rline[7:0]}; rslog_d <= vram_b_rdata; rslog_we <= 1'b1;
			// BG0 tilemap library standard: source_y = (render_y + cliprect.top) - m_dy + bgscrolly
			//                              = render_y + (cliprect.top - SCROLLDY) + bgscrolly
			// Per Cadash cliprect.top=16, SCROLLDY=8 → source_y = render_y + 8 + bg0_sy = render_y + bg0_sy + SCROLLDY.
			line_sy <= $signed({7'd0, rline}) + bg0_sy + SCROLLDY + $signed({6'd0, bg0_yoff_ext});
			st <= S_B0_AT0;
		end

		S_B0_AT0: begin
			begin
				automatic reg signed [15:0] sx = line_sx + $signed({7'd0, rpx});
				automatic reg [5:0]  tc = sx[8:3] & 6'h3F;   // 64 col mask
				automatic reg [5:0]  tr = line_sy[8:3] & 6'h3F;
				vram_b_addr <= BG0_BASE + {3'b0, tr, tc, 1'b0};   // tr*128 + tc*2 (attr, even)
			end
			st <= S_B0_AT1;
		end
		S_B0_AT1: st <= S_B0_AT2;
		S_B0_AT2: st <= S_B0_AT3;  // EXTRA WAIT: mirror pipeline 2-stage = 3 clk total
		S_B0_AT3: begin
			lat_attr    <= vram_b_rdata;
			vram_b_addr <= vram_b_addr + 16'd1;   // code addr (odd)
			st <= S_B0_CD0;
		end
		S_B0_CD0: st <= S_B0_CD1;
		S_B0_CD1: st <= S_B0_CD2;                  // EXTRA WAIT: 3 clk dopo +1 invece di 2
		S_B0_CD2: begin
			lat_code <= vram_b_rdata;
			st <= S_B0_ROM0;
		end
		S_B0_ROM0: begin
			begin
				automatic reg [2:0] py = lat_attr[15] ? (3'd7 - line_sy[2:0]) : line_sy[2:0];
				// Cadash tile ROM mask 0x3FFF (16384 tile × 32 byte = 512KB)
				rom_addr <= {lat_code[15:0] & 16'h3FFF, py, 2'b00};
			end
			rom_req <= ~rom_req;
			st <= S_B0_ROM1;
		end
		S_B0_ROM1: begin
			if (rom_req == rom_ack) begin
				lat_gfx32 <= rom_data;
				subpx <= (rpx == 9'd0) ? line_sx[2:0] : 3'd0;
				st <= S_B0_PIX;
			end
		end
		S_B0_PIX: begin
			begin
				automatic reg [2:0] pxidx = lat_attr[14] ? (3'd7 - subpx) : subpx;
				// gfx_8x8x4_packed_msb con ROM_LOAD16_WORD_SWAP: byte order swapped in word.
// mem.byte(N) = ROM[N XOR 1]. Per pix col x: byte_idx = x/2, HI nibble se x even, LO se odd.
// gfx32 = {SDRAM[1], SDRAM[0]} = {ROM[2],ROM[3],ROM[0],ROM[1]} (HI..LO).
// pix0(x=0) = byte0 HI = ROM[1] HI = gfx32[7:4].
automatic reg [4:0] base  = {pxidx[2], pxidx[1], ~pxidx[0], 2'b00};
				automatic reg [3:0] pix   = lat_gfx32[base +: 4];
				if (rpx < 9'd320) begin
					if (wr_buf) lb_bg0_1[rpx] <= {lat_attr[7:0], pix};
					else        lb_bg0_0[rpx] <= {lat_attr[7:0], pix};
				end
			end
			rpx   <= rpx + 1'd1;
			subpx <= subpx + 1'd1;
			if (subpx == 3'd7) begin
				if (rpx >= 9'd319) begin
					rpx <= 0; subpx <= 0;
					// MAME BG1 path = tilemap_draw_fg custom, rowscroll j = (y_abs + scrolly_delta) & 0x1ff
					// = (render_y + cliprect.top - m_dy) = render_y + 16 - 8 = render_y + 8 = render_y + SCROLLDY.
					vram_b_addr <= BG1_RS + (($signed({7'd0, rline}) + SCROLLDY) & 16'h01ff);
					rs_rd       <= 9'd256 + (($signed({7'd0, rline}) + SCROLLDY) & 16'h00ff);
					st <= S_B1_RS0;
				end else
					st <= S_B0_AT0;
			end
		end

		// ── BG1 ──────────────────────────────────────────────────────
		// BG1 path = tilemap_draw_fg (custom, NON tilemap library standard).
		// MAME tc0100scn.cpp:639-649: src_y_initial = fgscrolly + scrolly_delta + cliprect.top,
		// scrolly_delta = -m_dy. Per Cadash: src_y = -ctrl[4] - 8 + 16 = -ctrl[4] + 8 = + bg1_sy + SCROLLDY.
		// Rowscroll j_BG1 = (y_abs + scrolly_delta) = (render_y + 16 - 8) = render_y + 8 = render_y + SCROLLDY.
		// Differente da BG0 (tilemap library: line_sy = render_y + bg0_sy - SCROLLDY).
		S_B1_RS0: st <= S_B1_RS1;
		S_B1_RS1: st <= S_B1_RS2;
		S_B1_RS2: begin
			line_sx <= bg1_base - $signed(scroll_frame_latch ? rs_q : vram_b_rdata);
			rslog_a <= {1'b1, rline[7:0]}; rslog_d <= vram_b_rdata; rslog_we <= 1'b1;
			line_sy <= $signed({7'd0, rline}) + bg1_sy + SCROLLDY + $signed({6'd0, bg1_yoff_ext});
			st <= S_B1_CS0;
		end

		// Col scroll per-tile (MAME tc0100scn.cpp:656)
		S_B1_CS0: begin
			begin
				automatic reg signed [15:0] sx = line_sx + $signed({7'd0, rpx});
				automatic reg [6:0]  tc = sx[9:3] & 7'h7F;
				vram_b_addr <= BG1_CS + {9'd0, tc};
				cs_rd       <= tc;
			end
			st <= S_B1_CS1;
		end
		S_B1_CS1: st <= S_B1_CS2;
		S_B1_CS2: st <= S_B1_CS3;  // EXTRA WAIT mirror pipeline 2-stage
		S_B1_CS3: begin
			bg1_tile_sy <= line_sy - $signed(scroll_frame_latch ? cs_q : vram_b_rdata);
			st <= S_B1_AT0;
		end

		S_B1_AT0: begin
			begin
				automatic reg signed [15:0] sx = line_sx + $signed({7'd0, rpx});
				automatic reg [5:0]  tc = sx[8:3] & 6'h3F;
				automatic reg [5:0]  tr = bg1_tile_sy[8:3] & 6'h3F;
				vram_b_addr <= BG1_BASE + {3'b0, tr, tc, 1'b0};
			end
			st <= S_B1_AT1;
		end
		S_B1_AT1: st <= S_B1_AT2;
		S_B1_AT2: st <= S_B1_AT3;  // EXTRA WAIT mirror pipeline 2-stage
		S_B1_AT3: begin
			lat_attr    <= vram_b_rdata;
			vram_b_addr <= vram_b_addr + 16'd1;
			st <= S_B1_CD0;
		end
		S_B1_CD0: st <= S_B1_CD1;
		S_B1_CD1: st <= S_B1_CD2;
		S_B1_CD2: begin
			lat_code <= vram_b_rdata;
			st <= S_B1_ROM0;
		end
		S_B1_ROM0: begin
			begin
				automatic reg [2:0] py = lat_attr[15] ? (3'd7 - bg1_tile_sy[2:0]) : bg1_tile_sy[2:0];
				rom_addr <= {lat_code[15:0] & 16'h3FFF, py, 2'b00};
			end
			rom_req <= ~rom_req;
			st <= S_B1_ROM1;
		end
		S_B1_ROM1: begin
			if (rom_req == rom_ack) begin
				lat_gfx32 <= rom_data;
				subpx <= (rpx == 9'd0) ? line_sx[2:0] : 3'd0;
				st <= S_B1_PIX;
			end
		end
		S_B1_PIX: begin
			begin
				automatic reg [2:0] pxidx = lat_attr[14] ? (3'd7 - subpx) : subpx;
				// gfx_8x8x4_packed_msb con ROM_LOAD16_WORD_SWAP: byte order swapped in word.
// mem.byte(N) = ROM[N XOR 1]. Per pix col x: byte_idx = x/2, HI nibble se x even, LO se odd.
// gfx32 = {SDRAM[1], SDRAM[0]} = {ROM[2],ROM[3],ROM[0],ROM[1]} (HI..LO).
// pix0(x=0) = byte0 HI = ROM[1] HI = gfx32[7:4].
automatic reg [4:0] base  = {pxidx[2], pxidx[1], ~pxidx[0], 2'b00};
				automatic reg [3:0] pix   = lat_gfx32[base +: 4];
				if (rpx < 9'd320) begin
					if (wr_buf) lb_bg1_1[rpx] <= {lat_attr[7:0], pix};
					else        lb_bg1_0[rpx] <= {lat_attr[7:0], pix};
				end
			end
			rpx   <= rpx + 1'd1;
			subpx <= subpx + 1'd1;
			if (subpx == 3'd7) begin
				if (rpx >= 9'd319) begin
					rpx <= 0; subpx <= 0;
					// FG (text) = layer 2 tilemap library standard. source_y = render_y + cliprect.top - m_dy + fgscrolly.
					// = render_y + 16 - 8 + fg0_sy = render_y + fg0_sy + SCROLLDY.
					line_sy <= $signed({7'd0, rline}) + fg0_sy + SCROLLDY + $signed({6'd0, fg0_yoff_ext});
					st <= S_FG_AT0;
				end else
					st <= S_B1_CS0;
			end
		end

		// ── FG0 (text, 2bpp from VRAM, 1 word/tile) ────────────────
		S_FG_AT0: begin
			begin
				automatic reg signed [15:0] sx = fg0_sx - SCROLLDX
				                                 + $signed({6'd0, fg0_xoff_ext})
				                                 + $signed({7'd0, rpx});
				automatic reg [5:0]  tc = sx[8:3] & 6'h3F;
				automatic reg [5:0]  tr = line_sy[8:3] & 6'h3F;
				vram_b_addr <= FG0_MAP + {4'd0, tr, tc};
			end
			if (rpx == 9'd0)
				line_sx <= fg0_sx - SCROLLDX + $signed({6'd0, fg0_xoff_ext});
			st <= S_FG_AT1;
		end
		S_FG_AT1: st <= S_FG_AT2;
		S_FG_AT2: st <= S_FG_GX0;
		S_FG_GX0: begin
			lat_attr <= vram_b_rdata;
			begin
				automatic reg [7:0] code = vram_b_rdata[7:0];
				automatic reg [2:0] py = vram_b_rdata[15] ? (3'd7 - line_sy[2:0]) : line_sy[2:0];
				vram_b_addr <= FG0_GFX + {5'd0, code, py};
			end
			subpx <= (rpx == 9'd0) ? line_sx[2:0] : 3'd0;
			st <= S_FG_GX1;
		end
		S_FG_GX1: st <= S_FG_GX2;
		S_FG_GX2: st <= S_FG_PIX;
		S_FG_PIX: begin
			begin
				automatic reg [2:0] bp = lat_attr[14] ? subpx : (3'd7 - subpx);
				automatic reg [3:0] pix = {2'b00, vram_b_rdata[8+bp], vram_b_rdata[0+bp]};
				if (rpx < 9'd320) begin
					if (wr_buf) lb_fg0_1[rpx] <= {{2'b00, lat_attr[13:8]}, pix};
					else        lb_fg0_0[rpx] <= {{2'b00, lat_attr[13:8]}, pix};
				end
			end
			rpx   <= rpx + 1'd1;
			subpx <= subpx + 1'd1;
			if (subpx == 3'd7) begin
				if (rpx >= 9'd319)
					st <= S_DONE;
				else
					st <= S_FG_AT0;
			end
		end

		S_DONE: begin
			done <= 1'b1;
			st <= S_IDLE;
		end
		default: st <= S_IDLE;
		endcase
	end
end

// =====================================================================
// SC output from line buffers
// MAME tilemap_draw: bottom layer opaque, then top BG, then FG.
// SC[14:13] encoding: 01=FG, 11=BG_top, 10=BG_bottom, 00=empty
// =====================================================================
// render_y dal compositor ha lookahead +1: range valido 1..V_ACTIVE (NON < 240).
wire render_window = (render_x < 10'd320) && (render_y <= 9'd240) && (render_y != 9'd0);
wire [8:0] ox = render_x[8:0];
// [FLIP] l'altra meta' del capovolgimento: la riga si legge dall'altro capo.
// La finestra resta sulla ox vera, perche' quella e' tempo; a specchiarsi e'
// solo l'indirizzo del contenuto. Qui non serve la correzione di un pixel che
// c'e' su Raiden (hpos_for_read - 1): la' il buffer si legge in avanti di uno
// (linebuf[hpos+1] registrato) e lo specchio raddoppiava quel passo; qui la
// lettura e' a indirizzo pieno e il registro sotto non sposta il pixel, perche'
// render_x resta fermo per tutti i quattordici clock che durano un pixel.
wire [8:0] ox_rd = flip ? (9'd319 - ox) : ox;

reg [11:0] lb_bg0_0_q, lb_bg0_1_q;
reg [11:0] lb_bg1_0_q, lb_bg1_1_q;
reg [11:0] lb_fg0_0_q, lb_fg0_1_q;
reg        rd_win;
always @(posedge clk) begin
	lb_bg0_0_q <= lb_bg0_0[ox_rd];
	lb_bg0_1_q <= lb_bg0_1[ox_rd];
	lb_bg1_0_q <= lb_bg1_0[ox_rd];
	lb_bg1_1_q <= lb_bg1_1[ox_rd];
	lb_fg0_0_q <= lb_fg0_0[ox_rd];
	lb_fg0_1_q <= lb_fg0_1[ox_rd];
	rd_win     <= render_window && (ox < 9'd320);
end

wire [11:0] o_bg0 = rd_win ? (wr_buf ? lb_bg0_0_q : lb_bg0_1_q) : 12'd0;
wire [11:0] o_bg1 = rd_win ? (wr_buf ? lb_bg1_0_q : lb_bg1_1_q) : 12'd0;
wire [11:0] o_fg0 = rd_win ? (wr_buf ? lb_fg0_0_q : lb_fg0_1_q) : 12'd0;

wire f_op  = |o_fg0[3:0] & ~fg0_dis & osd_layer_en[2];
wire b0_op = |o_bg0[3:0] & ~bg0_dis & osd_layer_en[0];
wire b1_op = |o_bg1[3:0] & ~bg1_dis & osd_layer_en[1];

always @(posedge clk) begin
	if (render_window) begin
		if (f_op)
			SC <= {3'b010, o_fg0};
		else if (bg_prio) begin
			// ctrl[6][3]=1: BG1 is bottom, BG0 is top
			if (b0_op)      SC <= {3'b110, o_bg0};
			else if (b1_op) SC <= {3'b100, o_bg1};
			else            SC <= 15'd0;
		end else begin
			// MAME default (ctrl[6][3]=0): BG0 is bottom (bottomlayer=0), BG1 is top
			if (b1_op)      SC <= {3'b110, o_bg1};
			else if (b0_op) SC <= {3'b100, o_bg0};
			else            SC <= 15'd0;
		end
	end else
		SC <= 15'd0;
end

endmodule
