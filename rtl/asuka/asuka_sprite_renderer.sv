/*  This file is part of Darius_MiSTer.

    Darius_MiSTer is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    Darius_MiSTer is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with Darius_MiSTer.  If not, see <http://www.gnu.org/licenses/>.

    Author: Umberto Parisi (rmonic79)
    Version: 1.0
    Date: 2026

*/

// asuka_sprite_renderer — Sprite renderer.
// Legge entry sprite da local RAM (snooped dal CPU bus), fetch pixel dalla
// sprite ROM via SDRAM, disegna in line buffer. Supporta flip X/Y, priority,
// tiles 16x16 4bpp.
//
// Sprite RAM format (MAME, 4 words per entry at $E00100):
// Darius 2 sprite format (ninjaw.cpp):
//   word[0]: X position → sx = (data - 32) & 0x3FF
//   word[1]: Y position → sy = data & 0x1FF
//   word[2]: tile code[14:0] (0 = skip)
//   word[3]: flipX[0], flipY[1], priority[2], color[14:8]
//
// Sprite tiles: 16x16, 4bpp, 128 bytes each (32 SDRAM words)
// Layout: 4 quadrants (TL, TR, BL, BR), each 8x8, 4 planes
// SDRAM word = {plane3[7:0], plane2[7:0], plane1[7:0], plane0[7:0]}
// draw_sprites called with x_offs=xoffs (scroll-dependent), y_offs=-8

module asuka_sprite_renderer (
	input  wire        clk,
	input  wire        reset,
	input  wire  [9:0] render_x,
	input  wire  [8:0] render_y,
	input  wire  [8:0] frame_last_line,
	// 0 = MAME : fotografia al filo `snap` del top, lo stesso clock in cui
	//            parte l'IRQ di vblank e il chip dei tile ferma scroll e
	//            tabelle -> niente scivolamento.
	// 1 = PCB  : fotografia all'ULTIMA riga del quadro, che e' il verso di
	//            scivolamento della scheda (scroll in basso, sprite in alto).
	input  wire        spr_pcb_timing,
	// Impulso di un clock dal top: in modo MAME fa partire la copia.
	input  wire        snap,
	// 1 = il PC090OJ di questa scheda ha il buffer (MAME set_usebuffer(true):
	//     config cadash e asuka). MAME disegna il quadro N con lo scroll di N
	//     e gli sprite copiati al vblank N-1: il renderer legge la copia del
	//     vblank precedente, la cascata di Raiden (raiden_sprite_mainbus.sv).
	// 0 = niente buffer (mofflott, eto, bonzeadv): sprite dello stesso istante.
	input  wire        spr_buffered,
	// Alto dal clock della partenza fino alla fine della copia: il top non
	// lascia entrare scritture CPU nella sprite RAM, cosi' la copia e' lo stato
	// di quel clock anche se dura 1024 clock.
	output wire        spr_copy_hold,


	// X offset (scroll-dependent, from MAME draw_sprites x_offs parameter)
	input  wire  [9:0] x_offset,

	// Sprite RAM writes qualificati dalla main memory map (stessa semantica
	// di u_sprite_ram autorevole → shadow sempre sincronizzata).
	input  wire        main_sprite_wr,
	input  wire [12:0] main_sprite_addr,
	input  wire [15:0] main_sprite_wdata,
	input  wire  [1:0] main_sprite_be,

	// Sprite RAM writes qualificati dalla sub memory map.
	input  wire        sub_sprite_wr,
	input  wire [12:0] sub_sprite_addr,
	input  wire [15:0] sub_sprite_wdata,
	input  wire  [1:0] sub_sprite_be,

	// Sprite ROM via SDRAM (32-bit reads)
	input  wire [31:0] spriterom_data,
	input  wire        spriterom_valid,
	output reg  [23:0] spriterom_addr,
	output reg         spriterom_req,

	// Palette lookup (shared with tile palette)
	input  wire [15:0] pal_data,       // xBGR555 from palette RAM
	output reg  [10:0] pal_lookup_addr, // {color[6:0], pixel[3:0]}

	// Pixel output
	// OSD adjustable offsets
	input  wire signed [9:0] spr_xoff, spr_yoff,

	// PC090OJ sprite_colbank ($080000 write, MAME asuka.cpp:475):
	// sprite_colbank = (sprite_ctrl & 0x3C) << 2 = top 4 bit di color 8-bit
	input  wire        [7:0] sprite_colbank,

	// [FLIP] Schermo capovolto per gli sprite. Non e' il registro del
	// TC0100SCN: il PC090OJ ha il suo, la parola 0xdff della sprite RAM, ed e'
	// attivo quando il bit 0 vale ZERO (pc090oj.cpp:199). Il top lo estrae e lo
	// consegna gia' raddrizzato: qui 1 = capovolto.
	input  wire              flip_screen,

	output wire [23:0] sprite_rgb,
	output wire  [1:0] sprite_prio,
	output wire        sprite_opaque,
	// OB 15-bit: {hit[14], prio[13], 2'b00, color[7:0], pixel[3:0]}.
	// OB[11:0] = {color, pixel} = indirizzo palette sprite.
	// OB[14]=1 quando pixel sprite non-zero (usato dal bypass palette nel top).
	output wire [14:0] sprite_ob,
	output wire [12:0] dbg_disp_word,

	// [ARCH] La shadow spr_ram locale e' eliminata (pattern Darius2NW Rework):
	// la copy-to-frozen legge u_sprite_ram su Port B, che qui e' libera perche'
	// la sub-CPU non esiste. Al restore savestate u_sprite_ram viene ripristinata
	// e il primo vblank ricostruisce frozen dal dato restaurato.
	output wire [12:0] usprite_copy_addr,   // = copy_idx verso u_sprite_ram Port B
	output wire        usprite_copy_en,     // copy in corso
	input  wire [15:0] usprite_copy_data,   // u_sprite_ram[copy_idx], 1 ck dopo addr
	input  wire        usprite_copy_grant   // 1 = dato valido, avanza copy_idx
);

localparam H_ACTIVE = 10'd320;
localparam V_ACTIVE = 9'd240;
localparam Y_OFFSET = 9'd32;  // y_offs = -8 from MAME + north adjust

// =====================================================================
// Sprite RAM shadow — FIFO serializer per preservare main+sub writes.
// =====================================================================
// Main/sub writes stesso clk: main va sempre, sub entra in FIFO 16-deep
// se main scrive E sub scrive. FIFO drenata quando main idle. Zero perdita
// anche su conflitti lunghi o back-to-back sub writes.
// no_rw_check rimosso: con read-during-write same addr, Quartus garantisce
// il dato "old" (read-before-write) che e' coerente. Con no_rw_check era
// undefined → corruzione sporadica di 1 byte rilevata in sim (50 collisioni
// su 10 frame gameplay).
// Double buffer: copia "frozen" letta dal renderer. Sub/main scrivono
// nella primaria (live), copia atomica al vblank → niente race mid-frame.
// Due banchi da 1024 parole (il PC090OJ attivo ne usa 1024, max_idx_used <= 255).
//   frozen  = fotografia di questo filo (scritta dalla copia)
//   frozen2 = quello che legge SEMPRE il renderer:
//             buffer acceso (MAME) -> il vecchio contenuto di frozen, cioe' la
//                                     fotografia del filo precedente (cascata);
//             altrimenti           -> lo stesso dato fresco di frozen.
// Ogni banco ha due soli accessi, una scrittura e una lettura: frozen e'
// scritto dalla copia e letto dalla cascata, frozen2 scritto dalla copia e
// letto dal renderer.
(* ramstyle = "M10K" *) reg [7:0] spr_ram_hi_frozen [0:1023];
(* ramstyle = "M10K" *) reg [7:0] spr_ram_lo_frozen [0:1023];
(* ramstyle = "M10K,no_rw_check" *) reg [7:0] spr_ram_hi_frozen2 [0:1023];
(* ramstyle = "M10K,no_rw_check" *) reg [7:0] spr_ram_lo_frozen2 [0:1023];
reg  [7:0] spr_rdata_hi, spr_rdata_lo;
reg [12:0] spr_rd_addr;
wire [15:0] spr_rdata = {spr_rdata_hi, spr_rdata_lo};

// Sub-write FIFO 16-deep (reg-based, zero M10K).
// Entry: addr[12:0] + data[15:0] + be[1:0] = 31 bit
localparam SUB_FIFO_DEPTH = 64;
reg [30:0] sub_fifo [0:SUB_FIFO_DEPTH-1];
reg  [6:0] sub_fifo_wptr, sub_fifo_rptr;  // 7 bit per full/empty disambig
wire [5:0] sub_fifo_wix = sub_fifo_wptr[5:0];
wire [5:0] sub_fifo_rix = sub_fifo_rptr[5:0];
wire sub_fifo_empty = (sub_fifo_wptr == sub_fifo_rptr);
wire sub_fifo_full  = (sub_fifo_wptr[5:0] == sub_fifo_rptr[5:0]) &&
                      (sub_fifo_wptr[6]   != sub_fifo_rptr[6]);

// Push sub write in FIFO quando sub attivo E (main scrive OR fifo non-empty):
// se main idle E fifo empty, applica sub direttamente (bypass).
wire sub_bypass = sub_sprite_wr && !main_sprite_wr && sub_fifo_empty;
wire sub_push   = sub_sprite_wr && !sub_bypass && !sub_fifo_full;

// Pop sub FIFO quando main idle E fifo non-empty
wire sub_pop = !main_sprite_wr && !sub_fifo_empty;

// Unpack front of FIFO
wire [12:0] sub_fifo_front_addr = sub_fifo[sub_fifo_rix][30:18];
wire [15:0] sub_fifo_front_data = sub_fifo[sub_fifo_rix][17:2];
wire  [1:0] sub_fifo_front_be   = sub_fifo[sub_fifo_rix][1:0];

always @(posedge clk) begin
	if (reset) begin
		sub_fifo_wptr <= 7'd0;
		sub_fifo_rptr <= 7'd0;
	end else begin
		if (sub_push) begin
			sub_fifo[sub_fifo_wix] <= {sub_sprite_addr, sub_sprite_wdata, sub_sprite_be};
			sub_fifo_wptr <= sub_fifo_wptr + 7'd1;
		end
		if (sub_pop) begin
			sub_fifo_rptr <= sub_fifo_rptr + 7'd1;
		end
	end
end

// Effective sub: bypass (direct) OR front of FIFO (during pop)
wire        sub_apply_now = sub_bypass || sub_pop;
wire [12:0] sub_eff_addr  = sub_bypass ? sub_sprite_addr  : sub_fifo_front_addr;
wire [15:0] sub_eff_data  = sub_bypass ? sub_sprite_wdata : sub_fifo_front_data;
wire  [1:0] sub_eff_be    = sub_bypass ? sub_sprite_be    : sub_fifo_front_be;

// Write unificata: main se attivo, altrimenti sub-eff
wire        wr_act  = main_sprite_wr || sub_apply_now;
wire [12:0] wr_addr = main_sprite_wr ? main_sprite_addr  : sub_eff_addr;
wire [15:0] wr_data = main_sprite_wr ? main_sprite_wdata : sub_eff_data;
wire  [1:0] wr_be   = main_sprite_wr ? main_sprite_be    : sub_eff_be;

// [ARCH] Write snoop verso la shadow rimosso: la shadow non esiste piu'.
// wr_act/wr_addr restano solo per max_idx_used (nessuna BRAM).

// Copy live → frozen durante vblank (render_y >= V_ACTIVE).
// Iter 0..8191 con counter; al rientro in active si freeza.
// Al reset copy_done=0 forza prima copia completa prima di partire active.
reg [12:0] copy_idx;
reg        copy_done;
// Copia partita da copy_start e non ancora arrivata all'ultima parola. NON
// dipende dal vblank: se la copia si fermasse a meta' (vblank caduto) la
// tenuta resta alta lo stesso, altrimenti la CPU scriverebbe dentro una
// fotografia incompleta.
reg        copy_run;
reg  [8:0] prev_render_y_copy;
// vblank con lookahead +1: render_y > V_ACTIVE (= screen >= V_ACTIVE) OR render_y==0 (= screen V_TOTAL-1)
wire vblank = (render_y > V_ACTIVE) || (render_y == 9'd0);
// Fronte di salita del vblank calcolato con LA STESSA formula. Con
// `prev_render_y_copy >= V_ACTIVE` il confronto era gia' vero a render_y=240
// (lookahead +1) mentre vblank era ancora falso: alla riga dopo la copia non
// ripartiva e il buffer restava fermo al quadro N-2. Da li' gli sprite in
// ritardo, che si vedono SOLO mentre la scena scorre.
wire vblank_prev = (prev_render_y_copy > V_ACTIVE) || (prev_render_y_copy == 9'd0);
wire vblank_rise = vblank && !vblank_prev;

// L'istante della fotografia e' quello che decide il verso dello
// scivolamento, ed e' un fatto misurato sul ferro.
wire copy_start = spr_pcb_timing
	? ((render_y == frame_last_line) && (prev_render_y_copy != frame_last_line))
	: snap;
always @(posedge clk) begin
	if (reset) begin
		copy_idx <= 13'd0;
		copy_done <= 1'b0;
		copy_run  <= 1'b0;
		prev_render_y_copy <= 9'h1FF;
	end else begin
		prev_render_y_copy <= render_y;
		// La fotografia della sprite RAM: 1024 parole, una per clock, 10,67 us
		// contro 63,58 us di riga. Il momento lo sceglie copy_start (sopra).
		if (copy_start) begin
			copy_idx  <= 13'd0;
			copy_done <= 1'b0;
			copy_run  <= 1'b1;
		end
		// Copia in corso: avanza l'indice, finisce a 1023.
		// Avanza SOLO su grant: pipeline latenza-1 verso u_sprite_ram Port B.
		if (!copy_done && vblank && usprite_copy_grant) begin
			if (copy_idx == 13'd1023) begin
				copy_done <= 1'b1;
				copy_run  <= 1'b0;   // l'ultima parola si legge a questo fronte
			end else                   copy_idx  <= copy_idx + 13'd1;
		end
	end
end

// La porta B della sprite RAM serve solo alla copia, in tutti e due i modi:
// il renderer legge sempre la fotografia (frozen2).
assign usprite_copy_addr = copy_idx;
assign usprite_copy_en   = ~copy_done & vblank;
// Il clock della partenza compreso: una scrittura che entrerebbe nello stesso
// fronte in cui la copia riparte resta fuori, come per i registri del chip
// dei tile. Poi finche' la copia non e' arrivata all'ultima parola.
assign spr_copy_hold    = copy_start | copy_run;

// Pipeline latenza-1: al ck T presento copy_idx, il dato torna a T+1.
reg [12:0] copy_idx_d1;
reg        copy_wr_d1;
always @(posedge clk) begin
	if (reset) begin
		copy_idx_d1 <= 13'd0;
		copy_wr_d1  <= 1'b0;
	end else begin
		copy_idx_d1 <= copy_idx;
		copy_wr_d1  <= (~copy_done & vblank & usprite_copy_grant);
	end
end

// Un solo buffer. La cascata a due buffer e' di Raiden, dove serve a pareggiare
// la pipeline dei tile di quel core; qui aggiungerebbe un quadro di ritardo che
// non deve esserci, e infatti in modo PCB lo scivolamento risultava doppio.
// Cascata: si legge frozen all'indice copy_idx UN CICLO PRIMA di riscriverlo
// (la scrittura va a copy_idx_d1), quindi casc_* e' il contenuto del filo
// precedente e arriva proprio nel ciclo in cui si scrive quell'indice.
reg [7:0] casc_hi, casc_lo;
wire casc_on = spr_buffered & ~spr_pcb_timing;
always @(posedge clk) begin
	if (copy_wr_d1) spr_ram_hi_frozen[copy_idx_d1[9:0]] <= usprite_copy_data[15:8];
	casc_hi <= spr_ram_hi_frozen[copy_idx[9:0]];
end
always @(posedge clk) begin
	if (copy_wr_d1) spr_ram_lo_frozen[copy_idx_d1[9:0]] <= usprite_copy_data[7:0];
	casc_lo <= spr_ram_lo_frozen[copy_idx[9:0]];
end
always @(posedge clk) begin
	if (copy_wr_d1) spr_ram_hi_frozen2[copy_idx_d1[9:0]] <= casc_on ? casc_hi : usprite_copy_data[15:8];
	spr_rdata_hi <= spr_ram_hi_frozen2[spr_rd_addr[9:0]];
end
always @(posedge clk) begin
	if (copy_wr_d1) spr_ram_lo_frozen2[copy_idx_d1[9:0]] <= casc_on ? casc_lo : usprite_copy_data[7:0];
	spr_rdata_lo <= spr_ram_lo_frozen2[spr_rd_addr[9:0]];
end

// Cadash PC090OJ: solo primi 256 sprite (PC090OJ_ACTIVE_RAM_SIZE=0x800 byte
// = 1024 word = 256 sprite × 4 word). Track massimo idx scritto da CPU
// MA con cap a 255 (Darius2 era senza cap).
reg [10:0] max_idx_used;
always @(posedge clk) begin
	if (reset) max_idx_used <= 11'd0;
	else if (wr_act) begin
		// Cap a 255 (Cadash PC090OJ active sprite count)
		if (wr_addr[12:2] > max_idx_used && wr_addr[12:2] <= 11'd255)
			max_idx_used <= wr_addr[12:2];
	end
end

// =====================================================================
// Sprite line buffer (double-buffered, ping-pong)
// =====================================================================
// Entry: {boost[1], prio[1], color[6:0], pixel[3:0]} = 13 bits + 1 bit boost = 14 bits
// bit[13]=boost (priority override da attr[3])
// bit[12:11]=prio
// bit[10:4]=color
// bit[3:0]=pixel (0 = transparent)
(* ramstyle = "no_rw_check" *) reg [13:0] spr_lb0 [0:1023];
(* ramstyle = "no_rw_check" *) reg [13:0] spr_lb1 [0:1023];
reg [13:0] spr_lb0_q, spr_lb1_q;

// Valid mask first-write-wins: 1 bit/pixel, distributed LUT RAM (no M10K).
// Lettura combinatoria zero-latency, scrittura sincrona.
(* ramstyle = "logic" *) reg valid_lb0 [0:1023];
(* ramstyle = "logic" *) reg valid_lb1 [0:1023];

// Priority mask MAME bit3 attr "unknown priority":
// pixel scritto da sprite con attr[3]=1 → prio_lb=1, vince anche su pixel
// gia' scritti da sprite con attr[3]=0.
(* ramstyle = "logic" *) reg prio_lb0 [0:1023];
(* ramstyle = "logic" *) reg prio_lb1 [0:1023];

reg        spr_disp_sel;     // which buffer is being displayed
reg [13:0] spr_disp_word;
reg  [9:0] spr_disp_addr;

always @(posedge clk) begin
	spr_lb0_q <= spr_lb0[spr_disp_addr];
	spr_lb1_q <= spr_lb1[spr_disp_addr];
end

// Line buffer write � due sorgenti: scan (clear) e render (draw).
// Non concorrenti nella pipeline.
reg        scan_lb_we;
reg  [9:0] scan_lb_waddr;
reg [13:0] scan_lb_wdata;
reg        rend_lb_we;
reg  [9:0] rend_lb_waddr;
reg [13:0] rend_lb_wdata;
reg        lb_buf_sel;

// new_line / in_active (anticipati qui per usarli in lb_we mask BUG #5 fix)
// render_y dal compositor ha lookahead +1: screen_y N -> render_y N+1.
// Range valido: 1..V_ACTIVE (NON < V_ACTIVE, che escluderebbe ultima scanline).
wire in_active_early = (render_x < H_ACTIVE) && (render_y <= V_ACTIVE) && (render_y != 0);
reg  [8:0] prev_render_y;
// Fix shift X scanline 0: oltre al new_line normale (transition render_y in active),
// scatta un trigger anche al rising edge di copy_done durante vblank, cosi' la
// scanline 0 viene preparata DOPO la copia live->frozen (con dati frame corrente)
// invece che a render_y=223 del frame precedente (con frozen ancora vecchio).
// Bug HW visibile: sprite top-edge mostra X di 1 frame indietro su sline 0
// (shift X = velocita' sprite px/frame). Pause CPU stabilizza (live invariato).
reg copy_done_d;
always @(posedge clk) begin
    if (reset) copy_done_d <= 1'b0;
    else copy_done_d <= copy_done;
end
wire copy_done_rise = copy_done && !copy_done_d;
wire new_line = (in_active_early && (render_y != prev_render_y))
              || (copy_done_rise && vblank);

// Clear post-reset: 1024 cicli azzerano spr_lb0 e spr_lb1
reg [10:0] spr_lb_init_cnt;
wire       spr_lb_init_done = spr_lb_init_cnt[10];
always @(posedge clk) begin
	if (reset) spr_lb_init_cnt <= 11'd0;
	else if (!spr_lb_init_done) spr_lb_init_cnt <= spr_lb_init_cnt + 11'd1;
end

wire        lb_we_rt    = scan_lb_we | rend_lb_we;
wire [9:0]  lb_waddr_rt = rend_lb_we ? rend_lb_waddr : scan_lb_waddr;
wire [13:0] lb_wdata_rt = rend_lb_we ? rend_lb_wdata : scan_lb_wdata;

// BUG #5 fix: blocca scritture runtime al boundary di linea.
wire        lb_we    = spr_lb_init_done ? (lb_we_rt & ~new_line) : 1'b1;
wire [9:0]  lb_waddr = spr_lb_init_done ? lb_waddr_rt : spr_lb_init_cnt[9:0];
wire [13:0] lb_wdata = spr_lb_init_done ? lb_wdata_rt : 14'd0;

always @(posedge clk) begin
	if (!spr_lb_init_done) begin
		spr_lb0[lb_waddr] <= 14'd0;
		spr_lb1[lb_waddr] <= 14'd0;
	end else if (lb_we) begin
		if (lb_buf_sel) spr_lb1[lb_waddr] <= lb_wdata;
		else            spr_lb0[lb_waddr] <= lb_wdata;
	end
end

// Write valid mask: 0 durante clear (scan o init), 1 durante render.
// Stessa logica gate di lb_we (mask new_line, init done).
wire valid_wdata_rt = rend_lb_we;  // 1 se render, 0 se solo scan clear
// Priority mask write data: rd_prio_hi quando render, 0 quando clear.
wire prio_wdata_rt  = rend_lb_we ? rd_prio_hi : 1'b0;

always @(posedge clk) begin
	if (!spr_lb_init_done) begin
		valid_lb0[lb_waddr] <= 1'b0;
		valid_lb1[lb_waddr] <= 1'b0;
		prio_lb0 [lb_waddr] <= 1'b0;
		prio_lb1 [lb_waddr] <= 1'b0;
	end else if (lb_we) begin
		if (lb_buf_sel) begin
			valid_lb1[lb_waddr] <= valid_wdata_rt;
			prio_lb1 [lb_waddr] <= prio_wdata_rt;
		end else begin
			valid_lb0[lb_waddr] <= valid_wdata_rt;
			prio_lb0 [lb_waddr] <= prio_wdata_rt;
		end
	end
end

// Display read: spr_disp_addr = render_x (no offset).
// Pipeline 2-stage (addr reg + BRAM output reg) produce sprite_ob[T+2] = data
// at addr[T] = render_x[T-1] = render_x[T+2] - 2.
// scn_sc[T+2] = pixel render_x[T] = render_x[T+2] - 2 (chip MAME stessa pipeline).
// Entrambi indietro di 2 → allineati pixel-per-pixel nel bypass palette.
wire in_active = in_active_early;
// Lookahead 0 = identico al BG di riferimento (tc0100scn_cadash.sv: ox =
// render_x diretto, 2 stage register). render_x e' 10-bit (0..319): va usato
// PIENO. Troncarlo a render_x[8:0] (9-bit) faceva aliasare 256..319 su 0..63,
// quindi la 319 (e tutta la fascia destra) non veniva mai letta → colonna
// destra sempre vuota. addr=render_x pieno legge la 319 reale, allineato al BG.
always @(posedge clk) begin
	spr_disp_addr <= render_x;
end
// Display: singolo buffer ping-pong
always @(*) begin
	if (!in_active)
		spr_disp_word = 14'd0;
	else if (spr_disp_sel)
		spr_disp_word = spr_lb1_q;
	else
		spr_disp_word = spr_lb0_q;
end

// =====================================================================
// Pixel extraction — Cadash PC090OJ gfx_16x16x4_packed_msb.
// Layout identico a TC0100SCN tile decoder (MAME gfx_8x8x4_packed_msb su
// half-row 4 byte). rom_data[31:0] = 4 byte di una metà di riga sprite:
//   byte_mem[0]=rom_data[7:0], byte_mem[1]=rom_data[15:8],
//   byte_mem[2]=rom_data[23:16], byte_mem[3]=rom_data[31:24]
// (byte ordering del bridge identico a TC0100SCN, verificato Darius2).
// Pixel[i] = byte_mem[i>>1] nibble high (i pari) o low (i dispari).
// Formula uguale al chip tile MAME: lat_gfx32 con byte-pair swap, base
// con bit scramble.
function automatic [3:0] spr_get_pixel;
	input [31:0] row_data;
	input        hflip;     // unused: flip applicato esternamente via draw_x
	input  [2:0] pix_idx;
	reg [31:0] lat_gfx32;
	reg [4:0]  base;
	begin
		lat_gfx32 = {row_data[23:16], row_data[31:24],
		             row_data[7:0],   row_data[15:8]};
		// NIENTE flip qui: draw_x esterno applica gia' (15 - pix_absolute) se rd_flipx.
		base  = {pix_idx[2], ~pix_idx[1:0], 2'b00};
		spr_get_pixel = lat_gfx32[base +: 4];
	end
endfunction

// =====================================================================
// Pipeline: SCAN FSM + RENDER FSM + FIFO
// =====================================================================
// prev_render_y + new_line gia' dichiarati sopra (per BUG #5 fix lb_we mask)

// === SCAN FSM states ===
localparam SC_IDLE       = 4'd0;
localparam SC_CLEAR      = 4'd1;
localparam SC_READ_CODE  = 4'd2;
localparam SC_LATCH_CODE = 4'd3;
localparam SC_READ_Y     = 4'd4;
localparam SC_WAIT_Y     = 4'd5;
localparam SC_LATCH_Y    = 4'd6;
localparam SC_READ_X     = 4'd7;
localparam SC_LATCH_X    = 4'd8;
localparam SC_READ_ATTR  = 4'd9;
localparam SC_PUSH       = 4'd10;
localparam SC_WAIT_FIFO  = 4'd11;

reg [3:0]  scan_state;
reg [10:0] scan_idx;
reg [9:0]  clear_addr;
reg [8:0]  prep_line_y;

// [FLIP] Le costanti della posizione, gia' sommate fra loro.
//
// La X e la Y dello sprite si calcolano dentro la scansione, e da quel conto
// dipende SUBITO l'indirizzo della lettura dopo: e' il tratto piu' lungo del
// renderer. Sommando i termini in fila (offset del chip, bordo dello schermo,
// registrazione dell'OSD, capovolgimento) il tratto si allunga e il progetto
// perde il tempo: misurato, -0,677 ns contro +0,397 di prima.
//
// Qui i termini stanno in due registri, uno per il dritto e uno per il
// capovolto, e cambiano solo quando si tocca l'OSD. Nel conto resta UNA
// somma sola:   dritto = grezzo + off_norm    capovolto = off_flip - grezzo.
//
// I numeri: dritto  y = grezzo + 8 - 16 + yoff      = grezzo - 8 + yoff
//           capovolto y = (256 - grezzo - 16 + 2) + 8 - 16 - yoff
//                       = 234 - grezzo - yoff
// dove il 256-16 e' pc090oj.cpp, il +2 e' la riga che si sta preparando (una
// avanti), e yoff cambia segno perche' e' correzione nostra, non del chip.
reg signed [10:0] off_y_norm, off_y_flip, off_x_norm, off_x_flip;
always @(posedge clk) begin
	off_y_norm <= -11'sd8  + {{2{spr_yoff[8]}}, spr_yoff[8:0]};
	off_y_flip <=  11'sd234 - {{2{spr_yoff[8]}}, spr_yoff[8:0]};
	off_x_norm <= -{1'b0, x_offset} + {{2{spr_xoff[8]}}, spr_xoff[8:0]};
	off_x_flip <=  11'sd304 - {1'b0, x_offset} - {{2{spr_xoff[8]}}, spr_xoff[8:0]};
end

// Attributi durante scan
reg signed [10:0] sc_sx;
reg [14:0] sc_code;
reg [3:0]  sc_row_hit;

// FIFO sprite ready-to-render (FF-based, combinatorio read)
localparam FIFO_DEPTH = 64;
localparam FIFO_IDX_W = 6;
// FIFO sprite scan→render: ramstyle MLAB obbligatorio per evitare race
// read-during-write same-address. M10K (default Quartus) ha semantica
// "old data" su rd=wr: il pre_pop in render legge dato vecchio se scan
// PUSH stesso ck stesso slot → "shift X prima scanline" sprite (bug
// che spariva con pause perche' senza CPU il sprite RAM non cambiava
// → FIFO scan stabile entry-by-entry → niente race scan-render).
(* ramstyle = "MLAB,no_rw_check" *) reg signed [10:0] fifo_sx       [0:FIFO_DEPTH-1];
(* ramstyle = "MLAB,no_rw_check" *) reg [14:0]        fifo_code     [0:FIFO_DEPTH-1];
(* ramstyle = "MLAB,no_rw_check" *) reg               fifo_flipx    [0:FIFO_DEPTH-1];
(* ramstyle = "MLAB,no_rw_check" *) reg               fifo_flipy    [0:FIFO_DEPTH-1];
(* ramstyle = "MLAB,no_rw_check" *) reg               fifo_prio     [0:FIFO_DEPTH-1];
(* ramstyle = "MLAB,no_rw_check" *) reg               fifo_prio_hi  [0:FIFO_DEPTH-1];
(* ramstyle = "MLAB,no_rw_check" *) reg [6:0]         fifo_color    [0:FIFO_DEPTH-1];
(* ramstyle = "MLAB,no_rw_check" *) reg [3:0]         fifo_row      [0:FIFO_DEPTH-1];
reg [FIFO_IDX_W:0] fifo_wptr, fifo_rptr;
wire [FIFO_IDX_W-1:0] fifo_wix = fifo_wptr[FIFO_IDX_W-1:0];
wire [FIFO_IDX_W-1:0] fifo_rix = fifo_rptr[FIFO_IDX_W-1:0];
wire fifo_empty = (fifo_wptr == fifo_rptr);
wire fifo_full  = (fifo_wptr[FIFO_IDX_W-1:0] == fifo_rptr[FIFO_IDX_W-1:0]) &&
                  (fifo_wptr[FIFO_IDX_W] != fifo_rptr[FIFO_IDX_W]);

// === RENDER FSM states ===
localparam RD_IDLE       = 3'd0;
localparam RD_POP        = 3'd1;
localparam RD_POP_LATCH  = 3'd5;   // aspetta BRAM output valido
localparam RD_FETCH_ROM  = 3'd2;
localparam RD_WAIT_ROM   = 3'd3;
localparam RD_DRAW       = 3'd4;

reg [2:0]  rend_state;
reg signed [10:0] rd_sx;
reg [14:0] rd_code;
reg        rd_flipx, rd_flipy, rd_prio, rd_prio_hi;
reg [6:0]  rd_color;
reg [3:0]  rd_row;
reg [3:0]  draw_pix;
reg [31:0] cur_romdata;
reg        rd_half;  // 0 = left, 1 = right
// Pipeline stage per spezzare path critico rd_flipx → rend_lb_waddr/wdata.
// Stage 1 (RD_DRAW corrente): registra draw_x e attributi
// Stage 2 (ciclo successivo): legge LB, scrive se OK
reg signed [10:0] draw_x_q;
reg [3:0]  pixel_q;
reg [6:0]  rd_color_q;
reg        rd_prio_q;
reg        rd_prio_hi_q;
reg        write_pending_q;
// Prefetch second-half: lanciato a draw_pix=1 del primo half. Quando arriva
// spriterom_valid si memorizza qui. A fine primo half si usa direttamente,
// saltando RD_FETCH/RD_WAIT del secondo half.
reg [31:0] next_romdata;
reg        next_data_ready;
reg        prefetch_pending;  // 1 = req second-half lanciata, in attesa valid

// Pre-pop next sprite: fondiamo RD_POP con la fine RD_DRAW del sprite
// precedente. Lo sprite successivo viene letto dalla FIFO durante l'ultimo
// pixel del second-half corrente, cosi' a fine sprite siamo gia' pronti
// per andare a RD_WAIT_ROM senza passare per RD_POP.
reg signed [10:0] pre_sx;
reg [14:0] pre_code;
reg        pre_flipx, pre_flipy, pre_prio, pre_prio_hi;
reg [6:0]  pre_color;
reg [3:0]  pre_row;
reg        pre_loaded;     // 1 = next sprite gia' letto dalla FIFO

// === SCAN FSM ===
always @(posedge clk) begin
    scan_lb_we <= 1'b0;
    if (reset) begin
        scan_state <= SC_IDLE;
        scan_idx   <= 11'd0;  // partenza da max_idx_used (=0 a reset)
        clear_addr <= 0;
        prep_line_y <= 0;
        fifo_wptr  <= 0;
        prev_render_y <= 9'h1FF;
        spr_disp_sel <= 0;
        lb_buf_sel   <= 1;
    end else begin
        if (new_line) begin
            prev_render_y <= render_y;
            spr_disp_sel  <= lb_buf_sel;
            lb_buf_sel    <= ~lb_buf_sel;
            // Riga 0 preparata DOPO la copia, come Raiden (target_y = vpos==225
            // ? 0 : vpos+1): altrimenti esce da un buffer piu' vecchio delle altre.
            prep_line_y   <= (copy_done_rise && vblank) ? 9'd0
                           : (render_y >= V_ACTIVE)     ? 9'd0
                           : render_y + 9'd1;
            clear_addr    <= 0;
            scan_idx      <= 11'd0;  // DIRETTO da 0
            fifo_wptr     <= 0;
            scan_state    <= SC_CLEAR;
        end else begin
            case (scan_state)
                SC_IDLE: begin
                    // attende new_line
                end

                SC_CLEAR: begin
                    scan_lb_we    <= 1'b1;
                    scan_lb_waddr <= clear_addr;
                    scan_lb_wdata <= 14'd0;
                    if (clear_addr == H_ACTIVE - 10'd1) begin
                        // Scan diretto: parte da 0, increment fino a max_idx_used.
                        spr_rd_addr <= {11'd0, 2'b10};
                        scan_state  <= SC_READ_CODE;
                    end else
                        clear_addr <= clear_addr + 10'd1;
                end

                SC_READ_CODE: scan_state <= SC_LATCH_CODE;

                SC_LATCH_CODE: begin
                    // Cadash PC090OJ: code maschera 0x1FFF (8K sprite tile)
                    sc_code <= {2'd0, spr_rdata[12:0]};
                    if (spr_rdata[12:0] == 13'd0) begin
                        // Skip sprite con tile=0
                        if (scan_idx == max_idx_used) begin
                            scan_state <= SC_IDLE;
                        end else begin
                            scan_idx   <= scan_idx + 11'd1;
                            spr_rd_addr <= {scan_idx + 11'd1, 2'b10};
                            scan_state <= SC_READ_CODE;
                        end
                    end else begin
                        // Tile valido: leggi Y (skip SC_READ_Y, addr settato qui).
                        spr_rd_addr <= {scan_idx, 2'b01};
                        scan_state  <= SC_WAIT_Y;
                    end
                end

                SC_READ_Y: scan_state <= SC_WAIT_Y;  // dead path, kept per safety
                SC_WAIT_Y: scan_state <= SC_LATCH_Y;

                SC_LATCH_Y: begin
                    // Cadash PC090OJ (pc090oj.cpp:193-208):
                    //   y = m_ram_buffered[offs+1] & 0x1FF
                    //   if (y > 0x140) y -= 0x200   // signed convert
                    //   y += m_y_offset (=8 per Cadash, set_offsets(0,8))
                    // cliprect.top = 16 (asuka.cpp:1248 visarea Y=16..255)
                    //   → MAME render_y screen = y + 16 effectively in nostro frame
                    //   → equivalent: row_match prep_line_y - (y + 8 - 16) = prep_y - (y - 8)
                    reg [8:0] sy_calc;
                    reg [8:0] row_diff;
                    reg signed [10:0] sy_signed;
                    sy_signed = {2'b00, spr_rdata[8:0]};
                    if (sy_signed > 11'sd320) sy_signed = sy_signed - 11'sd512;
                    // [FLIP] pc090oj.cpp:201-204: capovolto, y = 256 - y - 16,
                    // prima degli offset del chip. Tutto il resto sta nelle due
                    // costanti gia' sommate (off_y_norm / off_y_flip) dichiarate
                    // in cima, comprese le due righe del lookahead e il segno
                    // rovesciato di spr_yoff: qui resta una somma sola, perche'
                    // da questo conto dipende subito la lettura dopo.
                    sy_signed = flip_screen ? (off_y_flip - sy_signed)
                                            : (sy_signed + off_y_norm);
                    sy_calc = sy_signed[8:0];
                    row_diff = (prep_line_y - sy_calc) & 9'h1FF;
                    if (row_diff < 9'd16) begin
                        sc_row_hit  <= row_diff[3:0];
                        // Cadash: X = word[3], attr = word[0] (PC090OJ layout)
                        spr_rd_addr <= {scan_idx, 2'b11};   // word[3] = X
                        scan_state  <= SC_READ_X;
                    end else if (scan_idx == max_idx_used) begin
                        scan_state <= SC_IDLE;
                    end else begin
                        scan_idx   <= scan_idx + 11'd1;
                        spr_rd_addr <= {scan_idx + 11'd1, 2'b10};
                        scan_state <= SC_READ_CODE;
                    end
                end

                SC_READ_X: scan_state <= SC_LATCH_X;

                SC_LATCH_X: begin
                    // Cadash PC090OJ (pc090oj.cpp:192-207):
                    //   x = m_ram_buffered[offs+3] & 0x1FF
                    //   if (x > 0x140) x -= 0x200   // signed convert
                    //   x += m_x_offset (=0 per Cadash)
                    reg signed [10:0] sx_raw;
                    sx_raw = {2'b00, spr_rdata[8:0]};
                    if (sx_raw > 11'sd320) sx_raw = sx_raw - 11'sd512;
                    // [FLIP] pc090oj.cpp:201-204: capovolto, x = 320 - x - 16.
                    // Come per la Y, il resto sta nelle costanti gia' sommate
                    // (off_x_norm / off_x_flip), spr_xoff compreso col segno
                    // rovesciato: qui resta una somma sola.
                    sx_raw = flip_screen ? (off_x_flip - sx_raw)
                                         : (sx_raw + off_x_norm);
                    sc_sx <= sx_raw;
                    // Attr = word[0]
                    spr_rd_addr <= {scan_idx, 2'b00};
                    scan_state  <= SC_READ_ATTR;
                end

                SC_READ_ATTR: scan_state <= SC_PUSH;

                SC_PUSH: begin
                    if (!fifo_full) begin
                        // Cadash PC090OJ attr: [15]=flipY, [14]=flipX, [3:0]=color
                        fifo_sx     [fifo_wix] <= sc_sx;
                        fifo_code   [fifo_wix] <= sc_code[14:0];
                        // [FLIP] pc090oj.cpp:203-204: capovolto lo schermo, i
                        // flip del singolo sprite si rovesciano.
                        fifo_flipx  [fifo_wix] <= spr_rdata[14] ^ flip_screen;
                        fifo_flipy  [fifo_wix] <= spr_rdata[15] ^ flip_screen;
                        fifo_prio   [fifo_wix] <= 1'b0;            // priority via colpri_cb
                        fifo_prio_hi[fifo_wix] <= 1'b0;
                        // MAME color = (attr & 0x0F) | sprite_colbank
                        // sprite_colbank = (ctrl & 0x3C) << 2 = bits[7:4] del color 8-bit
                        // fifo_color e' 7-bit → uso colbank[6:4] hi + attr[3:0] lo
                        fifo_color  [fifo_wix] <= {sprite_colbank[6:4], spr_rdata[3:0]};  // color[3:0] + colbank (TODO)
                        // [FLIP] la riga dentro lo sprite segue il flipy gia' rovesciato
                        fifo_row    [fifo_wix] <= (spr_rdata[15] ^ flip_screen) ? (4'd15 - sc_row_hit) : sc_row_hit;
                        fifo_wptr <= fifo_wptr + 1'b1;
                        if (scan_idx == max_idx_used) begin
                            scan_state <= SC_IDLE;
                        end else begin
                            scan_idx   <= scan_idx + 11'd1;
                            spr_rd_addr <= {scan_idx + 11'd1, 2'b10};
                            scan_state <= SC_READ_CODE;
                        end
                    end else begin
                        scan_state <= SC_WAIT_FIFO;
                    end
                end

                SC_WAIT_FIFO: begin
                    if (!fifo_full) begin
                        // Cadash PC090OJ attr layout
                        fifo_sx     [fifo_wix] <= sc_sx;
                        fifo_code   [fifo_wix] <= sc_code[14:0];
                        // [FLIP] pc090oj.cpp:203-204: capovolto lo schermo, i
                        // flip del singolo sprite si rovesciano.
                        fifo_flipx  [fifo_wix] <= spr_rdata[14] ^ flip_screen;
                        fifo_flipy  [fifo_wix] <= spr_rdata[15] ^ flip_screen;
                        fifo_prio   [fifo_wix] <= 1'b0;
                        fifo_prio_hi[fifo_wix] <= 1'b0;
                        // MAME color = (attr & 0x0F) | sprite_colbank
                        // sprite_colbank = (ctrl & 0x3C) << 2 = bits[7:4] del color 8-bit
                        // fifo_color e' 7-bit → uso colbank[6:4] hi + attr[3:0] lo
                        fifo_color  [fifo_wix] <= {sprite_colbank[6:4], spr_rdata[3:0]};
                        // [FLIP] la riga dentro lo sprite segue il flipy gia' rovesciato
                        fifo_row    [fifo_wix] <= (spr_rdata[15] ^ flip_screen) ? (4'd15 - sc_row_hit) : sc_row_hit;
                        fifo_wptr <= fifo_wptr + 1'b1;
                        if (scan_idx == max_idx_used) begin
                            scan_state <= SC_IDLE;
                        end else begin
                            scan_idx   <= scan_idx + 11'd1;
                            spr_rd_addr <= {scan_idx + 11'd1, 2'b10};
                            scan_state <= SC_READ_CODE;
                        end
                    end
                end

                default: scan_state <= SC_IDLE;
            endcase
        end
    end
end

// === RENDER FSM ===
always @(posedge clk) begin
    rend_lb_we    <= 1'b0;
    spriterom_req <= 1'b0;
    if (reset) begin
        rend_state <= RD_IDLE;
        fifo_rptr  <= 0;
        draw_pix   <= 0;
        rd_half    <= 0;
        next_data_ready  <= 1'b0;
        prefetch_pending <= 1'b0;
        pre_loaded       <= 1'b0;
    end else begin
        // Prefetch capture: arriva spriterom_valid mentre prefetch_pending → second-half data
        if (prefetch_pending && spriterom_valid) begin
            next_romdata     <= spriterom_data;
            next_data_ready  <= 1'b1;
            prefetch_pending <= 1'b0;
        end
        if (new_line) begin
            rend_state <= RD_IDLE;
            fifo_rptr  <= 0;
            next_data_ready  <= 1'b0;
            prefetch_pending <= 1'b0;
            pre_loaded       <= 1'b0;
        end else begin
            case (rend_state)
                RD_IDLE: begin
                    if (!fifo_empty) rend_state <= RD_POP;
                end
                RD_POP: begin
                    // Lancia req ROM direttamente in RD_POP (mask 14-bit MAME drawgfx)
                    rd_sx      <= fifo_sx     [fifo_rix];
                    rd_code    <= fifo_code   [fifo_rix];
                    rd_flipx   <= fifo_flipx  [fifo_rix];
                    rd_flipy   <= fifo_flipy  [fifo_rix];
                    rd_prio    <= fifo_prio   [fifo_rix];
                    rd_prio_hi <= fifo_prio_hi[fifo_rix];
                    rd_color   <= fifo_color  [fifo_rix];
                    rd_row     <= fifo_row    [fifo_rix];
                    fifo_rptr  <= fifo_rptr + 1'b1;
                    rd_half    <= 0;
                    draw_pix   <= 0;
                    // Cadash PC090OJ gfx_16x16x4_packed_msb: 128 byte/tile.
                    // addr = code*128 + row*8 + half*4
                    spriterom_addr <= {3'd0, fifo_code[fifo_rix][13:0], fifo_row[fifo_rix][3:0], 1'b0, 2'b00};
                    spriterom_req  <= 1'b1;
                    rend_state     <= RD_WAIT_ROM;
                end
                RD_FETCH_ROM: begin
                    // Solo per second-half: addr second half (rd_half=1)
                    // Cadash PC090OJ: addr = code*128 + row*8 + half*4 (half=1 second half)
                    spriterom_addr <= {3'd0, rd_code[13:0], rd_row[3:0], 1'b1, 2'b00};
                    spriterom_req  <= 1'b1;
                    rend_state     <= RD_WAIT_ROM;
                end
                RD_WAIT_ROM: begin
                    // Caso second-half (rd_half=1): se prefetch arrivato, leggi next_romdata
                    if (rd_half == 1'b1 && next_data_ready) begin
                        cur_romdata     <= next_romdata;
                        next_data_ready <= 1'b0;
                        rend_state      <= RD_DRAW;
                    end else if (rd_half == 1'b0 && spriterom_valid) begin
                        cur_romdata <= spriterom_data;
                        rend_state  <= RD_DRAW;
                    end
                end
                RD_DRAW: begin
                    reg [3:0] pixel;
                    reg signed [10:0] draw_x;
                    reg [3:0] pix_absolute;
                    reg already_written;
                    reg current_prio_hi;
                    reg can_write;
                    pix_absolute = rd_half ? (4'd8 + draw_pix) : draw_pix;
                    pixel = spr_get_pixel(cur_romdata, rd_flipx, draw_pix[2:0]);
                    draw_x = rd_flipx ? (rd_sx + (11'sd15 - {7'd0, pix_absolute})) : (rd_sx + {7'd0, pix_absolute});
                    // Stage 1: registra draw_x/pixel/attributi per usarli nel ciclo successivo.
                    // Path rd_flipx → draw_x_q ora più corto (no LB read, no can_write).
                    // draw_pix==8 (solo second-half) e' il ciclo di drain: NON calcola un
                    // nuovo pixel (col 16 non esiste) ma lascia girare lo Stage 2 della
                    // col 15, che altrimenti non verrebbe mai scritta (uscita FSM a ==7).
                    draw_x_q        <= draw_x;
                    pixel_q         <= pixel;
                    rd_color_q      <= rd_color;
                    rd_prio_q       <= rd_prio;
                    rd_prio_hi_q    <= rd_prio_hi;
                    write_pending_q <= (draw_pix != 4'd8) &&
                                       (pixel != 4'd0 && draw_x >= 0 && draw_x < $signed({1'b0, H_ACTIVE}));
                    // Stage 2: ciclo successivo usa draw_x_q (10-bit) per leggere LB e scrivere.
                    // valid_lb/prio_lb read avviene qui sui draw_x_q dello sprite precedente.
                    if (write_pending_q) begin
                        already_written = lb_buf_sel ? valid_lb1[draw_x_q[9:0]] : valid_lb0[draw_x_q[9:0]];
                        current_prio_hi = lb_buf_sel ? prio_lb1 [draw_x_q[9:0]] : prio_lb0 [draw_x_q[9:0]];
                        can_write = !already_written || (rd_prio_hi_q && !current_prio_hi);
                        if (can_write) begin
                            rend_lb_we    <= 1'b1;
                            rend_lb_waddr <= draw_x_q[9:0];
                            rend_lb_wdata <= {1'b0, 1'b0, rd_prio_q, rd_color_q, pixel_q};
                        end
                    end
                    // Prefetch second-half a draw_pix=1 del primo half
                    if (draw_pix == 4'd1 && rd_half == 1'b0 && !prefetch_pending && !next_data_ready) begin
                        // Cadash PC090OJ prefetch second-half
                        spriterom_addr   <= {3'd0, rd_code[13:0], rd_row[3:0], 1'b1, 2'b00};
                        spriterom_req    <= 1'b1;
                        prefetch_pending <= 1'b1;
                    end
                    // Pre-pop next sprite a draw_pix=6 del second-half (1 ck prima della fine)
                    if (draw_pix == 4'd6 && rd_half == 1'b1 && !fifo_empty && !pre_loaded) begin
                        pre_sx      <= fifo_sx     [fifo_rix];
                        pre_code    <= fifo_code   [fifo_rix];
                        pre_flipx   <= fifo_flipx  [fifo_rix];
                        pre_flipy   <= fifo_flipy  [fifo_rix];
                        pre_prio    <= fifo_prio   [fifo_rix];
                        pre_prio_hi <= fifo_prio_hi[fifo_rix];
                        pre_color   <= fifo_color  [fifo_rix];
                        pre_row     <= fifo_row    [fifo_rix];
                        fifo_rptr   <= fifo_rptr + 1'b1;
                        pre_loaded  <= 1'b1;
                    end
                    // First-half: fine a draw_pix==7. Second-half: fine a draw_pix==8
                    // (1 ciclo extra di drain per scrivere la col 15, vedi Stage 1).
                    if ((rd_half == 1'b0 && draw_pix == 4'd7) ||
                        (rd_half == 1'b1 && draw_pix == 4'd8)) begin
                        if (rd_half == 1'b0) begin
                            rd_half  <= 1'b1;
                            draw_pix <= 0;
                            if (next_data_ready) begin
                                cur_romdata     <= next_romdata;
                                next_data_ready <= 1'b0;
                                rend_state      <= RD_DRAW;
                            end else begin
                                rend_state <= RD_WAIT_ROM;
                            end
                        end else begin
                            // Fine second-half: se pre_loaded, swap pre_*→rd_* e lancia req
                            if (pre_loaded) begin
                                rd_sx      <= pre_sx;
                                rd_code    <= pre_code;
                                rd_flipx   <= pre_flipx;
                                rd_flipy   <= pre_flipy;
                                rd_prio    <= pre_prio;
                                rd_prio_hi <= pre_prio_hi;
                                rd_color   <= pre_color;
                                rd_row     <= pre_row;
                                rd_half    <= 0;
                                draw_pix   <= 0;
                                pre_loaded <= 1'b0;
                                // Cadash PC090OJ: addr = code*128 + row*8 + half*4
                                spriterom_addr <= {3'd0, pre_code[13:0], pre_row[3:0], 1'b0, 2'b00};
                                spriterom_req  <= 1'b1;
                                rend_state     <= RD_WAIT_ROM;
                            end else begin
                                rend_state <= fifo_empty ? RD_IDLE : RD_POP;
                            end
                        end
                    end else begin
                        draw_pix <= draw_pix + 4'd1;
                    end
                end
                default: rend_state <= RD_IDLE;
            endcase
        end
    end
end


// =====================================================================
// Output: line buffer → palette → RGB
// =====================================================================
wire [3:0] disp_pixel = spr_disp_word[3:0];
wire [6:0] disp_color = spr_disp_word[10:4];
wire       disp_prio  = spr_disp_word[11];
wire       disp_hit   = (disp_pixel != 4'd0) && in_active;

// Register palette address (1 cycle latency)
always @(posedge clk) begin
	pal_lookup_addr <= {disp_color, disp_pixel};
end

// Delay opaque/prio by 2 clocks to align with pal_data:
//   Cycle N:   spr_disp_word available (combinatorial)
//   Cycle N+1: pal_lookup_addr registered here
//   Cycle N+2: sprite_pal_data registered in darius_dual68k_top.sv
// So opaque/prio need 2 stages, not 1.
reg        disp_hit_d,  disp_hit_dd;
reg        disp_prio_d, disp_prio_dd;
always @(posedge clk) begin
	disp_hit_d   <= disp_hit;
	disp_prio_d  <= disp_prio;
	disp_hit_dd  <= disp_hit_d;
	disp_prio_dd <= disp_prio_d;
end

// Cadash xBGR444 → RGB888 (MAME color_xbgr444 asuka.cpp:484)
// R = data[3:0], G = data[7:4], B = data[11:8]
wire [7:0] out_r = {pal_data[3:0],  pal_data[3:0]};
wire [7:0] out_g = {pal_data[7:4],  pal_data[7:4]};
wire [7:0] out_b = {pal_data[11:8], pal_data[11:8]};

assign sprite_rgb    = {out_r, out_g, out_b};
assign sprite_prio   = {1'b0, disp_prio_dd};
assign sprite_opaque = disp_hit_dd;

// OB path al bypass palette del top: NO delay extra.
// sprite_ob combinatorio da spr_disp_word (già registrato 1 clk da line buffer),
// allineato a scn_sc (anche registrato 1 clk dal chip MAME). Prima c'erano 2
// stadi extra per pal_data 2-cycle latency, non più in uso (audit 2026-04-20).
// 15-bit: [14]=hit [13]=prio [12]=0 [11]=color[7]=0 [10:4]=color[6:0] [3:0]=pixel
assign sprite_ob = disp_hit ?
    {1'b1, disp_prio, 2'b00, disp_color[6:0], disp_pixel[3:0]} :
    15'd0;

assign dbg_disp_word = spr_disp_word;

endmodule
