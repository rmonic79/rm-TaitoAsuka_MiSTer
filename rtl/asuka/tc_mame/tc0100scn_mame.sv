/*  This file is part of Darius2NinjaWarriors_MiSTer.

    Darius2NinjaWarriors_MiSTer is free software: you can redistribute it
    and/or modify it under the terms of the GNU General Public License as
    published by the Free Software Foundation, either version 3 of the
    License, or (at your option) any later version.

    Darius2NinjaWarriors_MiSTer is distributed in the hope that it will be
    useful, but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with Darius2NinjaWarriors_MiSTer.
    If not, see <http://www.gnu.org/licenses/>.

    Author: Umberto Parisi (rmonic79)
    Version: 1.0
    Date: 2026
*/

// tc0100scn_mame.sv — TC0100SCN, MAME-accurate scanline renderer.
//
// Reference: MAME tc0100scn.cpp + ninjaw.cpp (Darius 2).
// Scroll math, tile lookup, pixel decode follow MAME exactly.
//
// Architecture:
//   - External dual-port BRAM (Port A=CPU immediate, Port B=renderer)
//   - Scanline renderer: prefetch all 3 layers per line into line buffers
//   - Line buffers: 288 px × 12 bits per layer
//   - Tile ROM: toggle-protocol
//
// MAME VRAM layout (wide mode, word offsets):
//   $0000-$3FFF  BG0 attrib+code (128×64 tiles, 2 words/tile)
//   $4000-$7FFF  BG1 attrib+code (128×64 tiles, 2 words/tile)
//   $8000-$81FF  BG0 row scroll (256 words)
//   $8200-$83FF  BG1 row scroll (256 words)
//   $8400-$847F  BG1 col scroll (128 words)
//   $8800-$8FFF  FG0 gfx (256 chars × 8 rows = 2048 words)
//   $9000-$9FFF  FG0 tilemap (128×32 tiles, 1 word/tile)
//
// BG tile: attrib[15:14]=flipYX, attrib[7:0]=color, code[15:0]=tile_code
// FG tile: [15:14]=flipYX, [13:8]=color, [7:0]=char_code
// BG gfx: 4bpp packed MSB from ROM, 32 bits per 8-pixel row
// FG gfx: 2bpp from VRAM, {plane1[7:0], plane0[7:0]} per row
//
// SC[14:0] = {prio[14:13], 0, color[7:0], pixel[3:0]}

module tc0100scn_mame #(
	parameter signed [15:0] P_X_OFFSET       = 22,
	parameter signed [15:0] P_Y_OFFSET       = 0,
	parameter signed [15:0] P_MULTISCR_XOFFS = 0,  // 0/2/4 per chip 0/1/2 (ninjaw/darius2)
	parameter        [0:0]  P_MULTISCR_HACK  = 0   // 0 = primo chip, 1 = chip successivi (flag MAME)
) (
	input  wire        clk,
	input  wire        cen,      // 1 = FSM renderer avanza (stati che usano VRAM).
	                              // Sincrono con arbiter_phase per accessi Port B.
	input  wire        cen_fast, // 1 = FSM avanza a clk pieno (stati che non
	                              // toccano VRAM: PIX, wait, ROM). Porta a 3x
	                              // throughput dei PIX e riduce budget scanline.
	input  wire        reset,

	// CPU interface
	input  wire [17:0] cpu_addr,
	input  wire [15:0] cpu_din,
	output reg  [15:0] cpu_dout,
	input  wire        cpu_rnw,
	input  wire [1:0]  cpu_dsn,       // {UDSn, LDSn}
	input  wire        cpu_cs,
	output reg         cpu_dtack_n,

	// VRAM Port A — CPU (active high write enables)
	output wire [15:0] vram_a_addr,
	output wire [15:0] vram_a_wdata,
	output wire [1:0]  vram_a_we,
	input  wire [15:0] vram_a_rdata,

	// VRAM Port B — renderer (read only)
	output reg  [15:0] vram_b_addr,
	input  wire [15:0] vram_b_rdata,

	// Tile ROM (toggle protocol, same as Donlon interface)
	output reg  [20:0] rom_addr,
	input  wire [31:0] rom_data,
	output reg         rom_req,
	input  wire        rom_ack,

	// Video output
	output reg  [14:0] SC,

	// Timing
	input  wire [9:0]  render_x,
	input  wire [8:0]  render_y,
	// Ultima riga del quadro (V_TOTAL-1), dal compositor: serve solo a sapere
	// dove render_y ripiega a 0.
	input  wire [8:0]  last_line,
	input  wire        hblank,

	// Serializzazione multi-chip:
	// go = 1 per 1 clk → avvia scanline rendering. Chip 0 riceve hblank_rise;
	// chip 1/2 ricevono done del chip precedente.
	input  wire        go,
	output reg         done,
	// active = 1 quando il chip sta facendo fetch/render (non S_IDLE).
	// Usato dal top per mux vram_b_addr condiviso tra i 3 chip.
	output wire        active,

	// OSD layer enable override (default 3'b111 = tutti on). [0]=BG0, [1]=BG1, [2]=FG0
	input  wire [2:0]  osd_layer_en,

	// Per-layer Y/X offset OSD (firmware tune). Default 0 = no shift.
	// Applicato a line_sy/line_sx nel rendering di ciascun layer.
	input  wire signed [9:0] bg0_xoff_ext, bg0_yoff_ext,
	input  wire signed [9:0] bg1_xoff_ext, bg1_yoff_ext,
	input  wire signed [9:0] fg0_xoff_ext, fg0_yoff_ext
);

// =====================================================================
// Constants
// =====================================================================
// Cadash (asuka.cpp). Formula MAME (tc0100scn.cpp:285-286):
//   xd = -m_x_offset - m_multiscrn_xoffs;  → Cadash: x_offset=1 → xd=-1
//   yd = 8 - m_y_offset;                    → Cadash: y_offset=0 → yd=8
// MAME visarea Cadash (asuka.cpp:1248): visarea(0,319,16,255)
// cliprect.top = 16 → src_y += 16, equivale a SCROLLDY = yd - 16 = 8-16 = -8.
localparam signed [15:0] XD = -P_X_OFFSET - P_MULTISCR_XOFFS;
localparam signed [15:0] YD =  16'sd8 - P_Y_OFFSET - 16'sd16;
localparam signed [15:0] SCROLLDX = XD - 16'sd16;
localparam signed [15:0] SCROLLDY = YD;

// =====================================================================
// Control registers
// =====================================================================
reg [15:0] ctrl [0:7];
wire        flip     = ctrl[7][0];
// Cadash sempre single-width (asuka.cpp non chiama set_dblwidth, m_dblwidth=0).
// Forziamo wide=0 anche se CPU scrivesse ctrl[6][4]=1 per errore.
wire        wide     = 1'b0;
wire        bg0_dis  = ctrl[6][0];
wire        bg1_dis  = ctrl[6][1];
wire        fg0_dis  = ctrl[6][2];
wire        bg_prio  = ctrl[6][3];

// =====================================================================
// VRAM bases CADASH SINGLE-WIDTH (MAME tc0100scn.cpp:31-41).
// Layout word offset (m_ram[] u16 array):
//   $0000-$1FFF  BG0 (64×64 tile, 2 word/tile = 8K word)
//   $2000-$3FFF  FG0 tilemap (64×64, 1 word/tile)
//   $3000-$3FFF  FG0 gfx (256 char × 8 row × 2 plane = 4K word) [overlap mapping MAME]
//   $4000-$5FFF  BG1 (64×64, 2 word/tile)
//   $6000-$61FF  BG0 rowscroll (256 word)
//   $6200-$63FF  BG1 rowscroll (256 word)
//   $7000-$707F  BG1 colscroll
// =====================================================================
wire [15:0] BG0_BASE = 16'h0000;
wire [15:0] BG1_BASE = 16'h4000;
wire [15:0] BG0_RS   = 16'h6000;
wire [15:0] BG1_RS   = 16'h6200;
wire [15:0] BG1_CS   = 16'h7000;
wire [15:0] FG0_GFX  = 16'h3000;
wire [15:0] FG0_MAP  = 16'h2000;

wire signed [15:0] bg0_sx = -$signed(ctrl[0]);
wire signed [15:0] bg1_sx = -$signed(ctrl[1]);
wire signed [15:0] fg0_sx = -$signed(ctrl[2]);
wire signed [15:0] bg0_sy = -$signed(ctrl[3]);
wire signed [15:0] bg1_sy = -$signed(ctrl[4]);
wire signed [15:0] fg0_sy = -$signed(ctrl[5]);

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
		cpu_dtack_n <= 1'b1;
		prev_cs <= 1'b0;
		vram_rd_pend <= 1'b0;
		ctrl[0]<=0; ctrl[1]<=0; ctrl[2]<=0; ctrl[3]<=0;
		ctrl[4]<=0; ctrl[5]<=0; ctrl[6]<=0; ctrl[7]<=0;
	end else begin
		prev_cs <= cpu_cs;
		if (cpu_cs & ~prev_cs) begin
			if (cpu_addr[17]) begin
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
			cpu_dout <= vram_a_rdata;
			cpu_dtack_n <= 1'b0;
			vram_rd_pend <= 1'b0;
		end
		if (~cpu_cs) begin
			cpu_dtack_n <= 1'b1;
			vram_rd_pend <= 1'b0;
		end
	end
end

// =====================================================================
// Line buffers — DOUBLE BUFFER ping-pong per evitare overrun hblank
// =====================================================================
// Chip MAME non finisce la scansione dentro hblank window (2652 clk a 96/24).
// Con buffer singolo il display leggerebbe mentre la FSM scrive → artefatti
// "stale" (lava sopra, interlacciato). Fix: 2 buffer per layer, FSM scrive
// su `wr_buf`, display legge `~wr_buf`. Toggle su `go` (inizio nuova linea).
(* ramstyle = "M10K,no_rw_check" *) reg [11:0] lb_bg0_0 [0:319];
(* ramstyle = "M10K,no_rw_check" *) reg [11:0] lb_bg0_1 [0:319];
(* ramstyle = "M10K,no_rw_check" *) reg [11:0] lb_bg1_0 [0:319];
(* ramstyle = "M10K,no_rw_check" *) reg [11:0] lb_bg1_1 [0:319];
(* ramstyle = "M10K,no_rw_check" *) reg [11:0] lb_fg0_0 [0:319];
(* ramstyle = "M10K,no_rw_check" *) reg [11:0] lb_fg0_1 [0:319];
reg        wr_buf;  // 0 = FSM scrive lb_*_0, display legge lb_*_1 (e viceversa)

// =====================================================================
// Renderer FSM
// =====================================================================
// Per-layer rendering: BG0 → BG1 → FG0, serialized.
// Per tile: addr setup (1 clk) → BRAM latency (1 clk) → latch (1 clk).
// BG: 2 VRAM reads + 1 ROM toggle + 8 pixel decode = ~14 clk/tile
// FG: 2 VRAM reads + 8 pixel decode = ~12 clk/tile
// 37 tiles × 14 × 2 layers + 37 × 12 = 1480 clk → ~15µs, fits in a line.

localparam [5:0]
	S_INIT       = 39,  // clear line buffers post-reset
	S_IDLE       = 0,
	// BG0 — pipeline con 2 clk FSM latenza arbiter 3-phase
	S_B0_RS0     = 1,  S_B0_RS1     = 2,   // row scroll read + wait
	S_B0_RS2     = 30,                      // (nuovo) extra wait per line_sx compute
	S_B0_AT0     = 3,  S_B0_AT1     = 4,   // attrib addr → code addr
	S_B0_AT2     = 31,                      // (nuovo) extra wait per latency
	S_B0_CD0     = 5,  S_B0_CD1     = 6,   // latch attr, latch code
	S_B0_ROM0    = 7,  S_B0_ROM1    = 8,   // ROM request + wait
	S_B0_PIX     = 9,                       // decode 8 pixels
	// BG1
	S_B1_RS0     = 10, S_B1_RS1     = 11,
	S_B1_RS2     = 32,                      // (nuovo)
	S_B1_CS0     = 36, S_B1_CS1     = 37,   // col scroll read (per-tile)
	S_B1_CS2     = 38,
	S_B1_AT0     = 12, S_B1_AT1     = 13,
	S_B1_AT2     = 33,                      // (nuovo)
	S_B1_CD0     = 14, S_B1_CD1     = 15,
	S_B1_ROM0    = 16, S_B1_ROM1    = 17,
	S_B1_PIX     = 18,
	// FG0
	S_FG_AT0     = 19, S_FG_AT1     = 20,
	S_FG_AT2     = 34,                      // (nuovo)
	S_FG_GX0     = 21, S_FG_GX1     = 22,
	S_FG_GX2     = 35,                      // (nuovo)
	S_FG_PIX     = 23,
	//
	S_DONE       = 24;

reg [5:0]  st;
// active = 1 quando chip sta renderizzando (non S_IDLE). Per mux esterno.
assign active = (st != S_IDLE);
reg [8:0]  rline;
reg [8:0]  rpx;
reg [2:0]  subpx;
reg [15:0] lat_attr, lat_code, lat_gfx16;
reg [31:0] lat_gfx32;
reg signed [15:0] line_sx;   // effective X scroll for current line
reg signed [15:0] line_sy;   // effective Y in tilemap space
reg signed [15:0] bg1_tile_sy; // BG1 per-tile Y (line_sy - colscroll)

// BUG1/2 fix: go_latch + render_y_latch per non perdere go quando cen=0.
// go pulse dal top può arrivare a qualsiasi phase; qui latchiamo finché
// la FSM (sotto cen gate) può effettivamente consumarlo.
reg        go_latch;
reg [8:0]  render_y_latch;
always @(posedge clk) begin
	if (reset) begin
		go_latch <= 1'b0;
		render_y_latch <= 9'd0;
		wr_buf <= 1'b0;
	end else begin
		if (go) begin
			go_latch <= 1'b1;
			// Ping-pong lookahead: il chip rende la scanline N+1 mentre display
			// mostra N, così al prossimo vc display trova buffer pronto.
			// Giro di quadro: render_y arriva al massimo a V_TOTAL-1 e la riga dopo
			// e' la 0. Il numero NON si scrive qui: era 263 di Darius (quadro da 264
			// righe) e con un raster diverso il confronto non scatta piu', quindi in
			// cima allo schermo escono le righe del fondo. Ora lo dice il compositor.
			render_y_latch <= (render_y == last_line) ? 9'd0 : render_y + 9'd1;
		end else if (cen && st == S_IDLE && go_latch) begin
			// FSM ha accettato il go in questo ciclo cen: clear latch.
			go_latch <= 1'b0;
			// Toggle write buffer all'inizio di ogni scansione. Display
			// continua a leggere dal vecchio buffer (linea precedente)
			// mentre FSM riempie il nuovo. Ping-pong.
			wr_buf <= ~wr_buf;
		end
	end
end

// Selezione cen per-stato.
// Stati che leggono vram_b_rdata o emettono vram_b_addr che deve essere
// latched dall'arbiter phase → usano `cen` (sincrono 1/3 arbiter).
// Stati che NON toccano VRAM (PIX, ROM wait, wait states puri) → usano
// `cen_fast` (clk pieno, 3x più veloce).
wire uses_vram =
	(st == S_IDLE) ||
	(st == S_B0_RS0) || (st == S_B1_RS0) ||
	(st == S_B0_RS2) || (st == S_B1_RS2) ||
	(st == S_B1_CS0) || (st == S_B1_CS2) ||
	(st == S_B0_AT0) || (st == S_B0_AT2) ||
	(st == S_B1_AT0) || (st == S_B1_AT2) ||
	(st == S_FG_AT0) || (st == S_FG_AT2) ||
	(st == S_B0_CD1) || (st == S_B1_CD1) ||
	(st == S_FG_GX0) || (st == S_FG_PIX);
wire eff_cen = uses_vram ? cen : cen_fast;

always @(posedge clk) begin
	if (reset) begin
		st <= S_INIT;
		rpx <= 0;
		rom_req <= 1'b0;
		done <= 1'b0;
	end else if (st == S_INIT) begin
		// Clear 320 entry di tutti 6 line buffer (BG0/BG1/FG0 x 2 ping-pong).
		// Gira ogni ciclo (non gate con eff_cen) per finire velocemente.
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
	end else if (eff_cen) begin
		done <= 1'b0;  // default: pulse low

		case (st)
		// =============================================================
		S_IDLE: begin
			if (go_latch && render_y_latch < 9'd240) begin
				rline <= render_y_latch;
				rpx <= 0;
				subpx <= 0;
				// BUG3 fix: Row scroll index MAME (tc0100scn.cpp:623).
				// MAME mappa j-esimo rowscroll_ram a tilemap row (j + bgscrolly).
				// Per tilemap row R = screen_y - scrolldy + bgscrolly, inverso:
				// j = R - bgscrolly = (screen_y - scrolldy) & 0x1ff.
				// Quindi indice rowscroll = (render_y - SCROLLDY) & 0x1ff.
				vram_b_addr <= BG0_RS + (($signed({7'd0, render_y_latch}) - SCROLLDY) & 16'h01ff);
				st <= S_B0_RS0;
			end
		end

		// ── BG0 ──────────────────────────────────────────────────────
		// Pipeline: emit addr → 2 clk FSM wait → latch dato (latency arbiter 3-phase)
		S_B0_RS0: st <= S_B0_RS1;
		S_B0_RS1: st <= S_B0_RS2;
		S_B0_RS2: begin
			line_sx <= bg0_sx - $signed(vram_b_rdata) - SCROLLDX + $signed({6'd0, bg0_xoff_ext});
			line_sy <= $signed({7'd0, rline}) + bg0_sy - SCROLLDY + $signed({6'd0, bg0_yoff_ext});
			st <= S_B0_AT0;
		end

		// Pipeline riscritta per arbiter-latency:
		// emit attr addr → 2 wait → latch attr → emit code addr → 2 wait → latch code
		S_B0_AT0: begin
			begin
				automatic reg signed [15:0] sx = line_sx + $signed({7'd0, rpx});
				// tc mask 7-bit wide (128 col) / 6-bit single (64 col).
				automatic reg [6:0]  tc = sx[9:3] & (wide ? 7'h7F : 7'h3F);
				automatic reg [5:0]  tr = line_sy[8:3] & 6'h3F;
				// Word offset: tr*256 + tc*2 wide, tr*128 + tc*2 single.
				vram_b_addr <= BG0_BASE + (wide ? {2'b0, tr, tc, 1'b0}
				                                : {3'b0, tr, tc[5:0], 1'b0});
			end
			st <= S_B0_AT1;   // wait 1 FSM
		end
		S_B0_AT1: st <= S_B0_AT2;  // wait 1 FSM
		S_B0_AT2: begin
			// Dato attr ora in scn0_ram_dout_r. Latch e emit addr code.
			lat_attr <= vram_b_rdata;
			vram_b_addr <= vram_b_addr + 16'd1;
			st <= S_B0_CD0;   // wait 1 FSM
		end
		S_B0_CD0: st <= S_B0_CD1;  // wait 1 FSM
		S_B0_CD1: begin
			// Dato code ora pronto, latch.
			lat_code <= vram_b_rdata;
			st <= S_B0_ROM0;
		end
		S_B0_ROM0: begin
			begin
				automatic reg [2:0] py = lat_attr[15] ? (3'd7 - line_sy[2:0]) : line_sy[2:0];
				// Tile ROM 1MB = 32768 tile (0x8000) → wrap code modulo 0x7FFF.
				// MAME lo fa internamente nel gfx_element (drawgfx code % elements()).
				// Cadash tile ROM 512KB = 16384 tile (0x4000) → mask 0x3FFF.
				// (Darius2 1MB era 0x7FFF.)
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
				automatic reg [4:0] base  = {pxidx[2], ~pxidx[1:0], 2'b00};
				automatic reg [3:0] pix   = lat_gfx32[base +: 4];
				if (rpx < 9'd320) begin
					if (wr_buf) lb_bg0_1[rpx] <= {lat_attr[7:0], pix};
					else        lb_bg0_0[rpx] <= {lat_attr[7:0], pix};
				end
			end
			rpx <= rpx + 1'd1;
			subpx <= subpx + 1'd1;
			if (subpx == 3'd7) begin
				if (rpx >= 9'd319) begin
					rpx <= 0; subpx <= 0;
					// BUG3 fix: BG1 rowscroll index = (rline - SCROLLDY) & 0x1ff (MAME).
					// Stessa formula di BG0 (rline = render_y_latch salvato all'S_IDLE).
					vram_b_addr <= BG1_RS + (($signed({7'd0, rline}) - SCROLLDY) & 16'h01ff);
					st <= S_B1_RS0;
				end else
					st <= S_B0_AT0;
			end
		end

		// ── BG1 ──────────────────────────────────────────────────────
		S_B1_RS0: st <= S_B1_RS1;
		S_B1_RS1: st <= S_B1_RS2;
		S_B1_RS2: begin
			line_sx <= bg1_sx - $signed(vram_b_rdata) - SCROLLDX + $signed({6'd0, bg1_xoff_ext});
			line_sy <= $signed({7'd0, rline}) + bg1_sy - SCROLLDY + $signed({6'd0, bg1_yoff_ext});
			st <= S_B1_CS0;
		end

		// Col scroll per-tile (MAME tc0100scn.cpp:656):
		// column_offset = colscroll_ram[src_x/8]; src_y_tile = line_sy - column_offset.
		S_B1_CS0: begin
			begin
				automatic reg signed [15:0] sx = line_sx + $signed({7'd0, rpx});
				automatic reg [6:0]  tc = sx[9:3] & (wide ? 7'h7F : 7'h3F);
				// BG1_CS wide @0x8400 (128 word), single @0x7000.
				vram_b_addr <= BG1_CS + {9'd0, tc};
			end
			st <= S_B1_CS1;
		end
		S_B1_CS1: st <= S_B1_CS2;
		S_B1_CS2: begin
			bg1_tile_sy <= line_sy - $signed(vram_b_rdata);
			st <= S_B1_AT0;
		end

		S_B1_AT0: begin
			begin
				automatic reg signed [15:0] sx = line_sx + $signed({7'd0, rpx});
				automatic reg [6:0]  tc = sx[9:3] & (wide ? 7'h7F : 7'h3F);
				automatic reg [5:0]  tr = bg1_tile_sy[8:3] & 6'h3F;
				vram_b_addr <= BG1_BASE + (wide ? {2'b0, tr, tc, 1'b0}
				                                : {3'b0, tr, tc[5:0], 1'b0});
			end
			st <= S_B1_AT1;
		end
		S_B1_AT1: st <= S_B1_AT2;
		S_B1_AT2: begin
			lat_attr <= vram_b_rdata;
			vram_b_addr <= vram_b_addr + 16'd1;
			st <= S_B1_CD0;
		end
		S_B1_CD0: st <= S_B1_CD1;
		S_B1_CD1: begin lat_code <= vram_b_rdata; st <= S_B1_ROM0; end
		S_B1_ROM0: begin
			begin
				automatic reg [2:0] py = lat_attr[15] ? (3'd7 - bg1_tile_sy[2:0]) : bg1_tile_sy[2:0];
				// Wrap code modulo 0x7FFF (1MB tile ROM). Cfr S_B0_ROM0.
				// Cadash tile ROM 512KB = 16384 tile (0x4000) → mask 0x3FFF.
				// (Darius2 1MB era 0x7FFF.)
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
				automatic reg [4:0] base  = {pxidx[2], ~pxidx[1:0], 2'b00};
				automatic reg [3:0] pix   = lat_gfx32[base +: 4];
				if (rpx < 9'd320) begin
					if (wr_buf) lb_bg1_1[rpx] <= {lat_attr[7:0], pix};
					else        lb_bg1_0[rpx] <= {lat_attr[7:0], pix};
				end
			end
			rpx <= rpx + 1'd1;
			subpx <= subpx + 1'd1;
			if (subpx == 3'd7) begin
				if (rpx >= 9'd319) begin
					rpx <= 0; subpx <= 0;
					line_sy <= $signed({7'd0, rline}) + fg0_sy - SCROLLDY + $signed({6'd0, fg0_yoff_ext});
					st <= S_FG_AT0;
				end else
					st <= S_B1_CS0;  // colscroll next tile
			end
		end

		// ── FG0 (text, 2bpp from VRAM) ───────────────────────────────
		// Wide: 128 col × 32 rows (tc 7-bit, tr 5-bit, addr = tr*128+tc)
		// Single: 64 col × 64 rows (tc 6-bit, tr 6-bit, addr = tr*64+tc)
		S_FG_AT0: begin
			begin
				automatic reg signed [15:0] sx = fg0_sx - SCROLLDX + $signed({6'd0, fg0_xoff_ext}) + $signed({7'd0, rpx});
				automatic reg [6:0]  tc = sx[9:3] & (wide ? 7'h7F : 7'h3F);
				automatic reg [5:0]  tr_s = line_sy[8:3] & 6'h3F;  // single 64 rows
				automatic reg [4:0]  tr_w = line_sy[7:3] & 5'h1F;  // wide 32 rows
				vram_b_addr <= FG0_MAP + (wide ? {4'd0, tr_w, tc}
				                                : {4'd0, tr_s, tc[5:0]});
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
			rpx <= rpx + 1'd1;
			subpx <= subpx + 1'd1;
			if (subpx == 3'd7) begin
				if (rpx >= 9'd319)
					st <= S_DONE;
				else
					st <= S_FG_AT0;
			end
		end

		S_DONE: begin
			done <= 1'b1;  // 1-clk pulse → trigger chip successivo
			st <= S_IDLE;
		end
		default: st <= S_IDLE;
		endcase
	end
end

// =====================================================================
// SC output from line buffers
// =====================================================================
// render_window = 1 quando render_x/y sono dentro la finestra visibile.
// NB: diverso dal port `active` (che è st!=S_IDLE). Questo controlla solo
// se SC va emesso o azzerato.
wire render_window = (render_x < 10'd320) && (render_y < 9'd240);
wire [8:0] ox = render_x[8:0];

// BRAM read puri e registrati (uno per bank, addr identico per entrambi i
// bank di un layer). Questo sostituisce il vecchio stage "o_bg* <= lb[ox]":
// stessa profondità pipeline, ma ora inferisce M10K naturalmente.
reg [11:0] lb_bg0_0_q, lb_bg0_1_q;
reg [11:0] lb_bg1_0_q, lb_bg1_1_q;
reg [11:0] lb_fg0_0_q, lb_fg0_1_q;
reg        rd_win;
always @(posedge clk) begin
	lb_bg0_0_q <= lb_bg0_0[ox];
	lb_bg0_1_q <= lb_bg0_1[ox];
	lb_bg1_0_q <= lb_bg1_0[ox];
	lb_bg1_1_q <= lb_bg1_1[ox];
	lb_fg0_0_q <= lb_fg0_0[ox];
	lb_fg0_1_q <= lb_fg0_1[ox];
	rd_win     <= render_window && (ox < 9'd320);
end

// Mux combinazionale post-read. rd_buf_sel = bank opposto al write bank,
// derivato direttamente da wr_buf (stesso clock dei *_q). Se wr_buf=1 il
// display legge bank 0; se wr_buf=0 legge bank 1.
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
			if (b0_op) SC <= {3'b110, o_bg0};
			else if (b1_op) SC <= {3'b100, o_bg1};
			else SC <= 15'd0;
		end else begin
			if (b1_op) SC <= {3'b110, o_bg1};
			else if (b0_op) SC <= {3'b100, o_bg0};
			else SC <= 15'd0;
		end
	end else
		SC <= 15'd0;
end

endmodule
