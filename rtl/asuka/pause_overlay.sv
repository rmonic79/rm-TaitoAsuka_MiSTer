/*  This file is part of Arcade_TaitoAsuka_MiSTer.

    Arcade_TaitoAsuka_MiSTer is free software: you can redistribute it
    and/or modify it under the terms of the GNU General Public License as
    published by the Free Software Foundation, either version 3 of the
    License, or (at your option) any later version.

    Arcade_TaitoAsuka_MiSTer is distributed in the hope that it will be
    useful, but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with Arcade_TaitoAsuka_MiSTer.
    If not, see <http://www.gnu.org/licenses/>.

    Author: Umberto Parisi (rmonic79)
    Version: 1.0
    Date: 2026
*/

// pause_overlay.sv — overlay pausa: dim + logo + header "PATREON" +
// lista dei patron scorrevole.
//
// Layout 864×224:
//   - Header "PATREON" giallo top-sx (X≈16, Y≈8)
//   - Patron scroll bottom→top, sx del logo (X=16..344, Y=40..184)
//   - Logo 48×48 ×3 = 144×144 al centro (X=360..504, Y=40..184)
//   - Links statici a destra (X=520..848, Y=40..184)
//
// Orientamento (tate): i set del driver asuka non sono tutti orizzontali
// (MAME asuka.cpp: Cadash e' ROT0, Asuka & Asuka e' ROT270). Con tate=1
// l'overlay viene ruotato 90 CCW come in Guardian/Raiden, e il riquadro utile
// diventa 240 largo × 320 alto: le posizioni sono rifatte per quel riquadro.
// Con tate=0 nulla cambia rispetto a prima.

module pause_overlay (
	input  wire        clk,
	input  wire        pause,
	input  wire        clean,    // OSD: bypass overlay (no dim, no logo, no addon)

	// 1 = set verticale (TATE, es. Asuka & Asuka): overlay ruotato 90 CCW.
	// 0 = set orizzontale (Cadash): overlay dritto, identico a prima.
	input  wire        tate,

	input  wire [9:0]  render_x_in,
	input  wire [8:0]  render_y_in,

	input  wire [7:0]  rgb_r_in,
	input  wire [7:0]  rgb_g_in,
	input  wire [7:0]  rgb_b_in,

	output wire [7:0]  rgb_r_out,
	output wire [7:0]  rgb_g_out,
	output wire [7:0]  rgb_b_out
);

// Effective overlay: pause attiva ma clean disattivato.
wire overlay_on = pause & ~clean;

// Misure del riquadro su cui si disegna. Da qui in giu' le posizioni si
// calcolano da queste due, non da numeri scritti a mano.
//   tate=0 -> schermo 320x240      tate=1 -> riquadro ruotato 240x320
wire [9:0] SCR_W = tate ? 10'd240 : 10'd320;
wire [9:0] SCR_H = tate ? 10'd320 : 10'd240;

// =====================================================================
// Trasformazione coordinate per l'orientamento del set.
// Frame Asuka: 320 attivi × 240 righe (render_x_in 0..319, render_y_in 0..239).
//
// tate=1 → rotazione 90 CCW: x' = y, y' = (W-1) - x con W=320.
//   Il riquadro utile diventa 240 largo (x' = render_y_in) × 320 alto.
// tate=0 → identita': il percorso resta bit-identico a prima.
//
// Fuori dall'area attiva Template.sv tiene render_x_in = 900: y_ccw va allora
// a 443 (wrap a 10 bit di 319-900), fuori da ogni riquadro → niente disegno.
// =====================================================================
wire [9:0] x_ccw = {1'b0, render_y_in};        // 0..239
wire [9:0] y_ccw = 10'd319 - render_x_in;      // 0..319

wire [9:0] render_x   = tate ? x_ccw : render_x_in;
wire [9:0] render_y10 = tate ? y_ccw : {1'b0, render_y_in};
wire [8:0] render_y   = render_y10[8:0];       // 0..319 sta in 9 bit

// VBlank pulse: sul raster VERO (render_y_in), non su quello ruotato, perche'
// serve a scandire i frame per lo scroll.
// Pulse di 1 ciclo quando render_y_in passa da 239 a 240.
reg [8:0] render_y_d;
always @(posedge clk) render_y_d <= render_y_in;
wire vblank_pulse = (render_y_in == 9'd240) && (render_y_d == 9'd239);

// =====================================================================
// Logo 48x48 sorgente, x2 = 96x96, AL CENTRO del riquadro, come in tutti gli
// altri core (Guardian/Raiden: 96x96 centrato, rtl/video/pause_overlay.sv).
// Il modulo arriva da Darius 2, largo 864 px su tre monitor: la' era x3
// (144x144) a X=360, e qui cadeva fuori dai 320 px veri.
//   tate=0, schermo 320x240 : X = (320-96)/2 = 112, Y = (240-96)/2 = 72
//   tate=1, riquadro 240x320: X = (240-96)/2 =  72, Y = (320-96)/2 = 112
// x2 e' uno scorrimento di bit: sparisce il moltiplicatore che serviva al x3.
wire [9:0] LOGO_SIDE = 10'd96;
wire [9:0] LOGO_X    = (SCR_W - LOGO_SIDE) >> 1;   // centrato in larghezza
wire [8:0] LOGO_Y    = (SCR_H - LOGO_SIDE) >> 1;   // centrato in altezza
wire [9:0] LOGO_XEND = LOGO_X + LOGO_SIDE;
wire [9:0] LOGO_YEND = {1'b0, LOGO_Y} + LOGO_SIDE;

// Read-ahead: per il pixel corrente serve l'address sul ck precedente.
wire [9:0] x_ahead = render_x + 10'd1;
wire [9:0] dx_screen = x_ahead - LOGO_X;          // 0..LOGO_SIDE-1
wire [9:0] dy_screen = {1'b0, render_y} - {1'b0, LOGO_Y};

wire in_logo_ahead = overlay_on &&
	(x_ahead        >= LOGO_X) && (x_ahead        < LOGO_XEND) &&
	({1'b0,render_y} >= {1'b0,LOGO_Y}) && ({1'b0,render_y} < LOGO_YEND);

// Scala del logo: uno scorrimento di bit, niente moltiplicatore.
// Prima il x3 si faceva con (v*0x55+0x55)>>8, che Quartus rendeva con un
// moltiplicatore DSP: 2,8 ns lui solo, ed era il cammino piu' lento del core
// (400 cammini in violazione, Fmax 75 MHz contro i 96 richiesti).
// pixel sorgente = dx_screen/2 (0..47 sui 96 px a schermo)
wire [5:0] dx = dx_screen[6:1];
wire [5:0] dy = dy_screen[6:1];
// addr = dy*48 + dx = (dy<<5) + (dy<<4) + dx, max=47*48+47=2303
wire [11:0] logo_addr = {1'b0, dy, 5'd0} + {2'b0, dy, 4'd0} + {6'd0, dx};

// =====================================================================
// Logo BRAM 2304x2 init da logo/logo.mem
// =====================================================================
reg [1:0] logo_rom [0:2303] /* synthesis ramstyle = "M10K" */;
initial $readmemb("logo/logo.mem", logo_rom);
reg [1:0] logo_pix;
reg       in_logo_now;
always @(posedge clk) begin
	logo_pix    <= logo_rom[logo_addr];
	in_logo_now <= in_logo_ahead;
end

// Palette logo: pal0=nero (trasparente), pal1=magenta, pal2=cyan, pal3=bianco
reg [7:0] lr, lg, lb;
always @(*) case (logo_pix)
	2'd0: {lr, lg, lb} = 24'h000000;
	2'd1: {lr, lg, lb} = 24'hFF00FF;
	2'd2: {lr, lg, lb} = 24'h00E6E4;
	2'd3: {lr, lg, lb} = 24'hFFFFFF;
endcase

wire logo_opaque = 1'b1;  // Logo tutto opaco (nero=palette[0] visibile come bordo)

// =====================================================================
// Header "SUPPORTERS" — centrato nel monitor sx (sopra patron scroll).
// 10 char × 8 = 80 px → ORIGIN_X = 0 + (288-80)/2 = 104
// =====================================================================
wire       header_on;
wire [1:0] header_tier;
pause_text #(
	.W_CHARS      (10),
	.H_CHARS      (1),
	.MSG_ROWS     (1),
	.SCROLL_EN    (0),
	.FONT_FILE    ("logo/font_darius.hex"),
	.MSG_FILE     ("logo/header.mem")
) u_header (
	.clk          (clk),
	.active       (overlay_on),
	.vblank_pulse (vblank_pulse),
	// tate: 10 char = 80 px centrati nei 240 del riquadro ruotato → (240-80)/2 = 80
	// 10 caratteri = 80 px, centrati; Y=16 come negli altri core
	.origin_x     ((SCR_W - 10'd80) >> 1),    // 10 caratteri = 80 px
	.origin_y     (9'd16),
	.render_x     (render_x),
	.render_y     (render_y),
	.pixel_on     (header_on),
	.pixel_tier   (header_tier)
);

// =====================================================================
// Patron scroll — centrati nel monitor sx (X=0..288, 288 px).
// 30 char × 8 = 240 px → ORIGIN_X = 0 + (288-240)/2 = 24
// Y=40..184 (18 righe), MSG_ROWS=32 (scroll loop)
// =====================================================================
wire       patron_on;
wire [1:0] patron_tier;
pause_text #(
	.W_CHARS       (30),
	// 36 righe = 288 px: la finestra arriva al fondo del riquadro verticale
	// (32+288 = 320). In orizzontale la chiude lo schermo a 240, non noi: prima
	// con 24 righe la lista si fermava a 224 e sotto restava spazio sprecato.
	.H_CHARS       (36),
	.MSG_ROWS      (73),   // lista nuova: 73 righe da 30 caratteri
	.SCROLL_EN     (1),
	.SCROLL_PERIOD (3),
	.FONT_FILE     ("logo/font_darius.hex"),
	.MSG_FILE      ("logo/patrons.mem")
) u_patron (
	.clk          (clk),
	.active       (overlay_on),
	.vblank_pulse (vblank_pulse),
	// tate: 30 char = 240 px = esattamente la larghezza del riquadro → X=0.
	// Y=32 (sotto l'header), 18 righe = 144 px → 32..176, sopra il logo.
	// 30 caratteri = 240 px; Y=32, subito sotto l'intestazione
	.origin_x     ((SCR_W - 10'd240) >> 1),   // 30 caratteri = 240 px
	.origin_y     (9'd32),
	.render_x     (render_x),
	.render_y     (render_y),
	.pixel_on     (patron_on),
	.pixel_tier   (patron_tier)
);

// Palette tier per i patron (4 livelli):
//   tier 0 = bianco  (default, nessun tier)
//   tier 1 = bronzo  ($3 — base supporters)
//   tier 2 = argento ($7 — silver supporters)
//   tier 3 = oro     (futuro gold supporters)
function [23:0] tier_color;
	input [1:0] tier;
	begin
		case (tier)
			2'd0: tier_color = 24'hFFFFFF;  // bianco (etichette tier + honorable + URL link)
			2'd1: tier_color = 24'h00E6E4;  // azzurrino/cyan (bronze + label link)
			2'd2: tier_color = 24'hFF00FF;  // magenta (silver, tier medio)
			2'd3: tier_color = 24'hFFD700;  // oro (gold, tier alto)
		endcase
	end
endfunction

// Colori testi:
//   header   = giallo/oro (FFD700) — stile Taito
//   patron   = colore tier (palette sopra)
wire [23:0] header_rgb = 24'hFFD700;
wire [23:0] patron_rgb = tier_color(patron_tier);

// Priorita': il testo (intestazione, poi lista) davanti al logo, poi l'immagine
// oscurata. Il blocco dei link non c'e' piu': era di Darius 2, largo 256 px e
// piazzato a X=592, quindi su uno schermo da 320 non compariva mai.
wire text_on = header_on | patron_on;
wire [23:0] text_rgb = header_on ? header_rgb : patron_rgb;

// =====================================================================
// Output mux combinatoriale puro (no shift sul path video!)
// =====================================================================
wire [7:0] dim_r = {1'b0, rgb_r_in[7:1]};
wire [7:0] dim_g = {1'b0, rgb_g_in[7:1]};
wire [7:0] dim_b = {1'b0, rgb_b_in[7:1]};

// Il TESTO sta DAVANTI al logo, come negli altri core (Guardian e Raiden).
// Con l'ordine invertito il logo, che e' tutto opaco, copriva la lista con il
// suo quadrato nero e sembrava che stesse sopra a tutto.
assign rgb_r_out = !overlay_on             ? rgb_r_in :
                   text_on                  ? text_rgb[23:16] :
                   in_logo_now & logo_opaque ? lr        :
                                              dim_r;
assign rgb_g_out = !overlay_on             ? rgb_g_in :
                   text_on                  ? text_rgb[15:8]  :
                   in_logo_now & logo_opaque ? lg        :
                                              dim_g;
assign rgb_b_out = !overlay_on             ? rgb_b_in :
                   text_on                  ? text_rgb[7:0]   :
                   in_logo_now & logo_opaque ? lb        :
                                              dim_b;

endmodule
