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

// darius_dual68k_top — Top-level del core Darius.
// Istanzia entrambe le CPU 68000 (main + sub), memory maps, shared/sprite/
// FG/palette RAM, sprite renderer, FG renderer, 3 panel renderer (L/C/R),
// vram arbiter, sdram bridge, audio Z80 subsystem, triple screen composer.

module asuka_top
#(
	parameter [1:0] MAIN_CORE_IMPL    = 2'd1,
	parameter [1:0] SUB_CORE_IMPL     = 2'd1,
	parameter       HOLD_SUB_IN_RESET = 1'b0,
	parameter       ENABLE_C00050_NOP = 1'b1,
	parameter       ENABLE_WATCHDOG   = 1'b1,
	parameter       ENABLE_PC080_CTRL = 1'b1,
	parameter       ENABLE_DC0000     = 1'b1,
	parameter       ENABLE_C00060     = 1'b1,
	parameter       ENABLE_C00020     = 1'b1,
	parameter       ENABLE_C00022     = 1'b1,
	parameter       ENABLE_C00024     = 1'b1,
	parameter       ENABLE_C00030     = 1'b1,
	parameter       ENABLE_C00032     = 1'b1,
	parameter       ENABLE_C00034     = 1'b1,
	parameter       ENABLE_D40000     = 1'b1,
	parameter       ENABLE_D40002     = 1'b1,
	parameter       ENABLE_D20000     = 1'b1,
	parameter       ENABLE_D20002     = 1'b1,
	parameter       ENABLE_C0000C     = 1'b1,
	parameter       ENABLE_C00010     = 1'b1,
	parameter       ENABLE_MAIN_PC060HA_PORT = 1'b1,
	parameter       ENABLE_MAIN_PC060HA_COMM = 1'b1,
	parameter       ENABLE_MAIN_D00000 = 1'b1,
	parameter       ENABLE_MAIN_PALETTE = 1'b1,
	parameter       ENABLE_FG_RAM      = 1'b1,
	parameter       ENABLE_MAIN_CTRL  = 1'b1,
	parameter       ENABLE_MAIN_SHARED = 1'b1,
	parameter       ENABLE_MAIN_SPRITE = 1'b1,
	parameter       ENABLE_MAIN_IO    = 1'b1,
	parameter       ENABLE_MAIN_VIDEO = 1'b1,
	parameter       ENABLE_MAIN_PLAYER_IO = 1'b1,
	parameter       ENABLE_SUB_SHARED = 1'b1,
	parameter       ENABLE_SUB_SPRITE = 1'b1,
	parameter       ENABLE_SUB_PALETTE = 1'b1,
	parameter       ENABLE_SUB_IO     = 1'b1,
	parameter       ENABLE_VBLANK_IRQ = 1'b1,
	// IRQ5 delay: 500 cicli CPU (16 MHz) = 31.25 us = 3000 cicli core (96 MHz).
	parameter [11:0] IRQ5_DELAY_CYCLES = 12'd3000
)
(
	input  wire        clk,
	input  wire        reset,
	input  wire        pause,
	input  wire  [7:0] game_id,       // 0x00=Cadash, 0x01=Asuka, ... (vedi Template.sv)
	input  wire  [2:0] clk_sel,      // Main CPU: 000=8MHz, 001=12MHz, 010=16MHz, 011=24MHz, 100=32MHz*, 101=48MHz*
	input  wire  [2:0] sub_clk_sel,   // Sub CPU: 000=8MHz, 001=12MHz, 010=16MHz, 011=24MHz, 100=32MHz*, 101=48MHz*
	input  wire  [1:0] z80_clk_sel,  // Z80: 00=4MHz, 01=8MHz, 10=2MHz, 11=1MHz
	input  wire  [7:0] p1_input,
	input  wire  [7:0] p2_input,
	input  wire  [7:0] system_input,   // MAME SYSTEM port: {00,start2,start1,tilt,service,coin2,coin1}
	input  wire [15:0] dsw_input,
	// Ingressi del C-Chip (solo Bonze): le tre porte GPIO del uPD78C11 piu'
	// le linee AN, gia' composte in Template.sv come le vuole MAME.
	input  wire  [7:0] cchip_pa,
	input  wire  [7:0] cchip_pb,
	input  wire  [7:0] cchip_pc,
	input  wire  [7:0] cchip_an,
	// 0 = MAME (scroll fermato a ogni quadro), 1 = scheda vera (scroll dal vivo).
	input  wire        spr_pcb_timing,
	input  wire [15:0] main_rom_rdata,
	input  wire        main_rom_ready,
	input  wire [15:0] sub_rom_rdata,
	input  wire        sub_rom_ready,
	input  wire [9:0]  render_x,
	input  wire [8:0]  render_y,
	// Ultima riga del quadro (V_TOTAL-1). Arriva dal compositor invece di
	// essere una costante nel chip: il raster si cambia in un posto solo.
	input  wire [8:0]  frame_last_line,
	input  wire        hblank_in,  // HBlank from compositor (pulses every line, even during vblank)
	input  wire [31:0] tilerom_data,
	input  wire        tilerom_valid,
	// Debug layer disable (OSD): 1=hide layer
	input  wire        dbg_dis_bg0,
	input  wire        dbg_dis_bg1,
	input  wire        dbg_dis_fg0,
	input  wire        dbg_dis_spr,   // OSD: spegne gli sprite (prima la voce non arrivava qui)
	// SCN rate selector rimosso — SCN ora usa ce_13m fisso (13.33 MHz, MAME-accurate).
	output wire [23:0] main_rom_addr,
	output wire        main_rom_req,
	output wire [23:0] sub_rom_addr,
	output wire        sub_rom_req,
	output wire [23:0] tilerom_addr,
	output wire        tilerom_req,
	output wire        tilerom_is_sprite,
	output wire        tilerom_is_text,
	// (sprite ROM port 3 SDRAM rimossa — sprite ora su DDR3 port 4 interno)
	// Audio ROM download (ioctl → BRAM inside audio module)
	input  wire        ioctl_download,
	input  wire        ioctl_wr,
	input  wire [26:0] ioctl_addr,
	input  wire [15:0] ioctl_dout,
	input  wire [15:0] ioctl_index,

	// --- Link fra cabinati (Cadash): sotto-sistema Z180, trasporto via rete ---
	// Il ruolo NON lo sceglie l'OSD: lo decide il dipswitch "Communication Mode"
	// (DSWB bit 6-7), esattamente come sul cabinato. Qui arriva gia' deciso.
	// I quattro fili del cabinato non escono dal case, quindi il "cavo" passa
	// dalla UART interna del SoC e da li' dalla rete: vedi cadash_link_rete.sv.
	input  wire        link_attivo,    // DSWB bit 6 basso = modo comunicazione
	input  wire        link_uart_rxd,  // dalla UART dell'HPS
	output wire        link_uart_txd,  // verso la UART dell'HPS
	// --- connettore SNAC: i quattro fili del cabinato, senza Linux in mezzo ---
	input  wire        link_snac,      // 1 = SNAC, 0 = rete
	input  wire  [2:0] link_snac_cavo, // 0 dritto, 1 incrociato, 2 senza pin 6,
	                                   // 3 tre fili, 4 quattro fili su 0-1-3-4
	input  wire  [6:0] user_in,
	output wire  [6:0] user_out,
	// L'altro cabinato e' ripartito da zero: per restare in passo deve
	// ripartire anche questo. Impulso di un ciclo, va allungato fuori di qui.
	output wire        link_reset_req,
	output wire [15:0] link_dbg_pc,
	// Quante volte il sorvegliante ha dovuto rimettere in piedi il link. A link
	// sano resta a zero per sempre: se sale, il filo sta sporcando i byte.
	output wire  [7:0] link_dbg_recuperi,
	output wire [23:0] fg_rgb,
	output wire        fg_opaque,
	output wire [15:0] xscroll_l0,
	output wire [15:0] xscroll_l1,
	output wire [15:0] yscroll_l0,
	output wire [15:0] yscroll_l1,
	output wire [15:0] ctrl_l0,
	output wire [15:0] ctrl_l1,
	output wire [23:0] tile_rgb,
	output wire [1:0]  tile_prio,
	output wire        tile_opaque,
	output wire [23:0] sprite_rgb,
	output wire  [1:0] sprite_prio,
	output wire        sprite_opaque,
	// OSD layer offsets
	input  wire signed [9:0] l0_xoff, l0_yoff,
	input  wire signed [9:0] l1_xoff, l1_yoff,
	input  wire signed [9:0] spr_xoff, spr_yoff,
	input  wire signed [9:0] fg_xoff, fg_yoff,
	// OSD layer enable (BG0, BG1, FG0). Default 3'b111 = tutti on.
	input  wire [2:0]        osd_tile_layer_en,
	// Text ROM download for FG BRAM
	input  wire        fg_dl_wr,
	input  wire [13:0] fg_dl_addr,
	input  wire [15:0] fg_dl_data,
	// Compositor pixel clock enable (24 MHz from triple_screen_test)
	input  wire        ce_pix,
	// Audio output
	output wire signed [15:0] audio_l,
	output wire signed [15:0] audio_r,
	// ADPCM-A tap (drum/percussion) per beat LED
	output wire signed [15:0] adpcma_tap_l,
	output wire signed [15:0] adpcma_tap_r,
	// FM tap (FM-only, no PSG) per beat LED secondario
	output wire signed [15:0] fm_tap_l,
	output wire signed [15:0] fm_tap_r,
	// Audio mixer OSD volumes (3-bit each)
	input  wire  [2:0] osd_fm_vol,
	input  wire  [2:0] osd_adpcma_vol,
	input  wire  [2:0] osd_adpcmb_vol,
	input  wire  [2:0] osd_psg_vol,
	// DDRAM HPS interface (audio: ROM Z80 + ADPCM A/B via asuka_ddram)
	input  wire        DDRAM_CLK,
	input  wire        DDRAM_BUSY,
	output wire  [7:0] DDRAM_BURSTCNT,
	output wire [28:0] DDRAM_ADDR,
	input  wire [63:0] DDRAM_DOUT,
	input  wire        DDRAM_DOUT_READY,
	output wire        DDRAM_RD,
	output wire [63:0] DDRAM_DIN,
	output wire  [7:0] DDRAM_BE,
	output wire        DDRAM_WE,
	// Write del framebuffer prodotti da screen_rotate (che sta nel top, perche'
	// deve annusare VGA_*). Entrano qui perche' l'arbitraggio del bus DDR3
	// sta qui, insieme a quello del savestate.
	input  wire [28:0] rot_addr,
	input  wire [63:0] rot_data,
	input  wire  [7:0] rot_be,
	input  wire        rot_we,
	output wire        ioctl_wait_audio,
	// Debug overlay
	output wire [23:0] dbg_main_pc,
	output wire [23:0] dbg_bus_addr,
	output wire [3:0]  dbg_txn_state,
	output wire        dbg_bus_busy,
	output wire        dbg_dtack_n,
	output wire        dbg_ext_dtack_n,
	output wire [14:0] dbg_scn0_sc,
	output wire        dbg_scn0_sc_seen,
	output wire        dbg_tilerom_req_seen,
	output wire [15:0] dbg_scn0_wr_cnt,
	output wire        dbg_z80_active,
	output wire        dbg_ym_active,
	output wire        dbg_syt_main_act,
	output wire        dbg_syt_z80_act,
	output wire        dbg_audio_nonzero,
	// Main CPU data registers D6/D7 (for DBRA delay-loop diagnosis)
	output wire [31:0] dbg_d6,
	output wire [31:0] dbg_d7,
	// D0 (RAM test count), A0 (RAM test pointer), A1 (secondary pointer — usually area under test)
	output wire [31:0] dbg_d0,
	output wire [31:0] dbg_a0,
	output wire [31:0] dbg_a1,
	// Main RAM diag
	output reg  [15:0] dbg_ram_wr_cnt,
	output reg  [15:0] dbg_ram_rd_val,
	// Sub CPU PC
	output wire [23:0] dbg_sub_pc,

	// [SS] savestate — pilotato da savestate_ui in Template.sv
	input  wire        ss_save,
	input  wire        ss_load,
	input  wire  [3:0] ss_slot,
	output wire        ss_busy,
	output wire        ss_pause_req
);

// ============================================================================
// [SS] SAVESTATE — savestate COMPLETO (CPU + video)
// Portato da Arcade-Darius2NinjaWarriors_MiSTer_Rework / Darius_MiSTer_Rework.
// Copre VRAM del TC0100SCN (che contiene la tabella rowscroll $6000-$61FF),
// VRAM extra, palette e i registri di scroll del chip.
// La pausa e' quella gia' esistente e frame-aligned (paused_safe, aggiornato
// solo sul rising edge del vblank) -> nessun congelamento a meta' frame.
// ============================================================================
localparam SS_IDX_GLOB   = 0;   // SSP del 68000 (driver ss_m68k)
localparam SS_IDX_MAIN_RAM = 1; // work RAM 32K word — ci vive lo stack della CPU
localparam SS_IDX_SHARED = 2;   // shared RAM di rete 32K word
localparam SS_IDX_SPRITE = 3;   // sprite RAM 8K word
localparam SS_IDX_VRAM   = 4;   // scn0_vram   32K word  (rowscroll incluso)
localparam SS_IDX_VRAMX  = 5;   // scn0_vramx   8K word
localparam SS_IDX_PAL0   = 6;   // pal0_ram     4K word
localparam SS_IDX_CTRL   = 7;   // ctrl[0..7] del TC0100SCN (128 bit)
localparam SS_IDX_RSLOG  = 8;   // [DBG] rowscroll letto dal renderer, per scanline
// Audio, stesso impianto di Darius 2 (che salva esattamente queste quattro cose)
localparam SS_IDX_ZRAM   = 9;   // RAM sonora dello Z80, 8 KB
localparam SS_IDX_Z80    = 10;  // registri interni del tv80s, 358 bit
localparam SS_IDX_AMISC  = 11;  // banco della ROM sonora + stato MSM5205, 32 bit
localparam SS_IDX_SYT    = 12;  // handshake del TC0140SYT, 49 bit
localparam SS_IDX_YMSH   = 13;  // ombra dei registri del YM2151 (512 byte)
localparam SS_IDX_PC060  = 14;  // handshake del PC060HA, 46 bit
localparam SS_NSLAVES    = 15;

ssbus_if ssbus();
ssbus_if ssb[SS_NSLAVES]();

wire [2:0]  main_cpu_fc;   // [SS] FC2:FC0 del 68000
ssbus_if ssb_unused();     // [SS] slave non salvati (SS_IDX=-1)
wire        ss_irq68, ss_reset68, ss_pause68, ss_cpu_exec68;
wire        ss_din_en;
wire [15:0] ss_din_data;
wire        ss_do_save, ss_do_load;



// Forward declarations for ModelSim compatibility
wire        sel_scn0;
wire        sel_scn0_ram;
wire        sel_scn0_ctrl;
wire        sel_pal0;
wire        scn0_dack_n;
wire        pal0_dack_n;
wire [15:0] scn0_dout;
wire [15:0] pal0_dout;
wire        bus_raw_active;

// Forward decl for VRAM read data (used in main_bus_rdata_composite at line ~428,
// driven at line ~814 inside the VRAM dual-port block).
// Quartus accepts backward refs, ModelSim requires forward decl.
reg  [15:0] scn0_a_rdata;

// ── Forward declarations (needed by ModelSim) ────────────────────────────
wire [23:0] main_bus_addr;
wire        main_bus_asn;
wire        main_bus_rnw;
wire [1:0]  main_bus_dsn;
wire [15:0] main_bus_dout;
wire [15:0] main_bus_rdata;
wire        main_bus_cs;
wire        main_bus_busy;
wire  [1:0] main_bus_be;
// Sub-CPU rimossa: Asuka/Cadash hanno single 68000. Tied-off per non rompere
// referenze residue nel codice (pattern warriorb single-CPU adaptation).
wire [23:0] sub_bus_addr  = 24'd0;
wire        sub_bus_asn   = 1'b1;     // inactive (AS=1)
wire        sub_bus_rnw   = 1'b1;
wire [1:0]  sub_bus_dsn   = 2'b11;    // inactive (DSn=11)
wire [15:0] sub_bus_dout  = 16'd0;
wire [15:0] sub_bus_rdata = 16'd0;
wire        sub_bus_cs    = 1'b0;
wire        sub_bus_busy  = 1'b0;
wire  [1:0] sub_bus_be    = 2'b00;

// Main RAM
wire [15:0] main_ram_rdata;
wire        main_ram_rd, main_ram_wr;
wire [14:0] main_ram_addr;
wire [15:0] main_ram_wdata;

// Sub RAM — tied off (single CPU, no sub map)
wire [15:0] sub_ram_rdata;
wire        sub_ram_rd  = 1'b0;
wire        sub_ram_wr  = 1'b0;
wire  [1:0] sub_ram_be  = 2'b00;
wire [14:0] sub_ram_addr  = 15'd0;
wire [15:0] sub_ram_wdata = 16'd0;

// Shared RAM (64 KB, dual-port)
wire [15:0] shared_main_rdata, shared_sub_rdata;
wire        shared_main_ready, shared_sub_ready;
wire        main_shared_rd, main_shared_wr;
wire  [1:0] main_shared_be;  // latched by main map
wire [14:0] main_shared_addr;
wire [15:0] main_shared_wdata;

// Sprite RAM (16 KB, dual-port)
wire [15:0] sprite_main_rdata, sprite_sub_rdata;
wire        sprite_main_ready, sprite_sub_ready;
wire        main_sprite_rd, main_sprite_wr;
wire  [1:0] main_sprite_be;  // latched by main map
wire [12:0] main_sprite_addr;
wire [15:0] main_sprite_wdata;
wire        sub_sprite_rd    = 1'b0;
wire        sub_sprite_wr    = 1'b0;
wire  [1:0] sub_sprite_be    = 2'b00;
wire [12:0] sub_sprite_addr  = 13'd0;
wire [15:0] sub_sprite_wdata = 16'd0;

// CPUA ctrl
wire        cpua_ctrl_wr;
wire [7:0]  cpua_ctrl_data;
reg  [7:0]  cpua_ctrl_reg;

// =====================================================================
// FOTOGRAFIA DEL QUADRO: un solo filo, `vbl_snap`, un clock, all'ingresso
// del vblank vero (vc_s 240 = render_y 241, dove VBlank si alza).
// Da QUESTO filo, e da nessun'altra formula, escono:
//   - l'IRQ di vblank (gen_vblank_irq qui sotto);
//   - in modo MAME: il fermo degli otto registri del TC0100SCN, la copia
//     delle tabelle di rowscroll/colscroll, il fermo del registro sprite;
//   - in modo MAME: la copia della sprite RAM (asuka_sprite_renderer).
// E' Raiden (IRQ, copia sprite e latch dello scroll sullo stesso
// vblank_rising) ed e' MAME, che al vblank disegna tutto il quadro in un
// istante PRIMA che la CPU prenda l'IRQ.
//
// Le copie durano 11-20 us: dal clock del filo fino alla loro fine la CPU non
// puo' scrivere ne' la sprite RAM ne' la VRAM (la scrittura resta in attesa e
// il DTACK non arriva). Cosi' ogni copia e' lo stato del clock del filo, per
// costruzione, qualunque cosa faccia il programma e su qualunque driver.
// Il taglio e' uguale per tutto: entra cio' che si scrive fino al fronte
// PRIMA del filo, resta fuori cio' che arriverebbe dal fronte del filo in poi.
// =====================================================================
wire vbl_line = (render_y > 9'd240);
reg  vbl_line_d = 1'b0;
always @(posedge clk) vbl_line_d <= vbl_line;
wire vbl_snap  = vbl_line & ~vbl_line_d;
wire snap_mame = vbl_snap & ~spr_pcb_timing;
wire spr_copy_hold;   // copia sprite RAM in corso (dallo sprite renderer)
wire scn_snap_busy;   // copia tabelle rowscroll/colscroll in corso (dal TC0100SCN)
// Scrittura sprite della CPU: entra solo fuori dalla copia.
wire main_sprite_wr_g = main_sprite_wr & ~spr_copy_hold;
// Scrittura VRAM della CPU in attesa (vedi scn0_wr_req piu' sotto).
reg  scn0_wr_pend = 1'b0;
wire scn_vram_hold = snap_mame | scn_snap_busy;

// PC090OJ sprite_ctrl ($080000-$080003 Cadash)
wire        spr_ctrl_wr;
wire [15:0] spr_ctrl_data;
reg  [15:0] spr_ctrl_reg;
always @(posedge clk) begin
	if (reset)         spr_ctrl_reg <= 16'd0;
	else if (spr_ctrl_wr) spr_ctrl_reg <= spr_ctrl_data;
end
// In modo MAME anche questo registro (banco colore, priorita') e' fermo al
// filo: MAME lo legge nell'istante in cui disegna.
reg  [15:0] spr_ctrl_l = 16'd0;
always @(posedge clk) if (snap_mame) spr_ctrl_l <= spr_ctrl_reg;
wire [15:0] spr_ctrl_use = spr_pcb_timing ? spr_ctrl_reg : spr_ctrl_l;

// [FLIP] Il PC090OJ ha un SECONDO registro, che non sta sul bus ma dentro la
// sprite RAM: la parola 0xdff (pc090oj.cpp:154, "Bit 0 is flip control").
// E' scritta come una parola qualunque della RAM, percio' si intercetta qui.
// Il bit e' attivo BASSO: sprite capovolti quando vale zero (pc090oj.cpp:199).
// All'accensione MAME parte da zero e il gioco lo scrive subito, e qui si fa
// uguale per non inventare uno stato che sul chip non c'e'.
reg  spr_flip_bit0 = 1'b0;
always @(posedge clk) begin
	if (reset)
		spr_flip_bit0 <= 1'b0;
	else if (main_sprite_wr_g && main_sprite_be[0] && (main_sprite_addr == 13'h0dff))
		spr_flip_bit0 <= main_sprite_wdata[0];
end
// Fermo al filo come tutto il resto in modo MAME: il capovolgimento non puo'
// cambiare a meta' quadro mentre lo sfondo sta gia' disegnando col suo.
reg  spr_flip_l = 1'b0;
always @(posedge clk) if (snap_mame) spr_flip_l <= ~spr_flip_bit0;
wire spr_flip_use = spr_pcb_timing ? ~spr_flip_bit0 : spr_flip_l;
// sprite_colbank = (sprite_ctrl & 0x3C) << 2 (MAME fixed_colpri_cb asuka.cpp:475)
wire [7:0]  sprite_colbank = {spr_ctrl_use[5:2], 4'd0};

// TC0140SYT sound comm (active low signals to chip)
wire        syt_cs_n, syt_wr_n, syt_rd_n, syt_a1;
wire  [3:0] syt_main_dout_w;

// Legacy Darius 1 signals (still referenced by old code, will be removed in full cleanup)
wire        sub_palette_wr = 1'b0;
wire [10:0] sub_palette_addr = 11'd0;
wire [15:0] sub_palette_wdata = 16'd0;
wire        palette_main_ready = 1'b1;
wire [15:0] palette_main_rdata = 16'd0;
wire        palette_sub_ready = 1'b1;
wire [15:0] palette_sub_rdata = 16'd0;
wire [15:0] main_e100_rdata = 16'd0;
wire [15:0] d000_main_rdata = 16'd0;
wire [15:0] fg_main_rdata = 16'd0;
wire [15:0] fg_sub_rdata = 16'd0;
wire        fg_main_ready = 1'b1;
wire        fg_sub_ready = 1'b1;
wire        main_fg_rd, main_fg_wr;
wire [13:0] main_fg_addr;
wire [15:0] main_fg_wdata;
wire        sub_fg_rd, sub_fg_wr;
wire [13:0] sub_fg_addr;
wire [15:0] sub_fg_wdata;
wire        main_e100_rd, main_e100_wr;
wire [10:0] main_e100_addr;
wire [15:0] main_e100_wdata;
wire        main_d000_rd, main_d000_wr;
wire [14:0] main_d000_addr;
wire [15:0] main_d000_wdata;
wire        main_palette_rd, main_palette_wr;
wire [10:0] main_palette_addr;
wire [15:0] main_palette_wdata;
wire  [1:0] main_ram_be;  // latched by memory map (see u_main_map.ram_be_o below)
wire        main_pc060ha_port_wr;
wire [7:0]  main_pc060ha_port_data;
wire        main_pc060ha_comm_wr;
wire [7:0]  main_pc060ha_comm_data;
reg  [7:0]  main_pc060ha_port_reg;
reg  [7:0]  main_pc060ha_comm_reg;
wire        main_iack;
wire        sub_iack;       // tied off (single CPU)
wire [2:0]  main_ipl_n;
wire [2:0]  sub_ipl_n;      // tied off (single CPU)
wire        pc060_snd_cs;
wire        pc060_snd_addr;
wire        pc060_snd_wr;
wire        pc060_snd_rd;
wire  [7:0] pc060_snd_wdata;
wire  [7:0] pc060_snd_rdata;
wire        pc060_snd_nmi_n;
wire        pc060_snd_reset;

// --- VBlank-synced pause (frame-aligned, F2 reference pattern) ---
// pause raw asincrono → paused_safe registrato che cambia SOLO al rising edge
// vblank. Sincronizza pause boundary su tutti i moduli (CPU cen, audio cen).
// Necessario per evitare race a metà bus cycle / scanline / DDR3 transaction.
wire vblank_area_top = (render_y >= 9'd240);
reg  vblank_prev_top;
reg  paused_safe_r;
always @(posedge clk) begin
	if (reset) begin
		vblank_prev_top <= 1'b0;
		paused_safe_r   <= 1'b0;
	end else begin
		vblank_prev_top <= vblank_area_top;
		// Aggiorna paused_safe solo al rising edge vblank (frame boundary)
		if (vblank_area_top && !vblank_prev_top)
			paused_safe_r <= pause;
	end
end
wire paused_safe = paused_safe_r;

// --- VBlank IRQ4 + IRQ5 timer (Cadash: MAME asuka.cpp:522-532) ---
// IRQ4 = immediato a rising-edge VBlank.
// IRQ5 = 500 cicli CPU (16 MHz) dopo IRQ4 = 3000 cicli core (96 MHz).
// IRQ5 priorita' superiore a IRQ4 nel mux IPL.
//
// =====================================================================
// Tabella dei set del driver (MAME asuka.cpp). game_id = byte 0 della
// regione index=1 dell'MRA, caricata prima delle ROM.
//
//   id  set              rot     68k    palette  colpri    SCN off  vblank
//   00  Cadash           ROT0    16MHz  xbgr444  fisso     (1,0)    irq4 + irq5 a 500 cicli
//   01  Asuka & Asuka    ROT270   8MHz  xbgr555  variabile (0,0)    irq5
//   02  Maze of Flott    ROT270   8MHz  xbgr555  variabile (1,0)    irq5
//   03  Galmedes         ROT270   8MHz  xbgr555  variabile (0,0)    irq5   (config 'asuka')
//   04  Eto Monogatari   ROT0     8MHz  xbgr555  variabile (1,0)    irq5   (niente ADPCM)
//   05  Bonze Adventure  ROT0     8MHz  xbgr555  fisso     (0,0)    irq4   (C-Chip, TC0140SYT)
//   06  Earth Joker      ROT270   8MHz  xbgr555  variabile (0,0)    irq5   (config 'asuka')
//
// L'orientamento NON sta in questa tabella: lo dichiara l'MRA con un bit suo
// (vedi board_tate in Template.sv), cosi' aggiungere un set non obbliga a
// rimettere mano a un intervallo di id.
// =====================================================================
localparam [7:0] GID_CADASH   = 8'h00;
localparam [7:0] GID_ASUKA    = 8'h01;
localparam [7:0] GID_MOFFLOTT = 8'h02;
localparam [7:0] GID_GALMEDES = 8'h03;
localparam [7:0] GID_ETO      = 8'h04;
localparam [7:0] GID_BONZEADV = 8'h05;
localparam [7:0] GID_EARTHJKR = 8'h06;

wire cfg_cadash  = (game_id == GID_CADASH);
wire cfg_bonze   = (game_id == GID_BONZEADV);

// tc0110pcr color_callback: xbgr444 solo su cadash, xbgr555 su tutto il resto.
wire cfg_pal444       = cfg_cadash;
// PC090OJ colpri_callback: fixed su cadash e bonzeadv, variable sugli altri.
wire cfg_colpri_fixed = cfg_cadash | cfg_bonze;
// TC0100SCN set_offsets(1,0): lo chiamano cadash, mofflott ed eto. Il config
// 'asuka' (asuka/galmedes/earthjkr) e bonzeadv non lo chiamano -> (0,0).
wire cfg_scn_x_off1   = cfg_cadash | (game_id == GID_MOFFLOTT) | (game_id == GID_ETO);
// 68000: 32MHz/2 su cadash, 16MHz/2 su tutti gli altri.
wire cfg_clk_16mhz    = cfg_cadash;
// PC090OJ con buffer (MAME set_usebuffer(true)): config 'cadash' (asuka.cpp:1255)
// e config 'asuka' (asuka.cpp:1186), cioe' Cadash, Asuka, Galmedes, Earth Joker.
// Mofflott, Eto e Bonze non lo accendono: la sprite RAM si vede subito.
wire cfg_spr_buffer   = cfg_cadash | (game_id == GID_ASUKA)
                     | (game_id == GID_GALMEDES) | (game_id == GID_EARTHJKR);

// VBlank interrupt:
//   cadash_state::interrupt  -> livello 4 + timer 500 cicli -> livello 5
//   bonzeadv_state::interrupt-> livello 4 secco (piu' l'interrupt del C-Chip)
//   tutti gli altri          -> irq5_line_hold, livello 5 secco
wire enable_irq5_timer = cfg_cadash;
wire cfg_vblank_lvl5   = ~cfg_cadash & ~cfg_bonze;

// Mappa di memoria del 68000: msm_state::asuka_map per i set del config
// 'asuka' piu' mofflott. cadash ha la sua; eto e bonzeadv hanno mappe loro,
// non ancora fatte. Elencati uno per uno: la numerazione non e' contigua.
wire cfg_map_asuka = (game_id == GID_ASUKA)    | (game_id == GID_MOFFLOTT)
                   | (game_id == GID_GALMEDES) | (game_id == GID_EARTHJKR);

// Indirizzi che si spostano fra le due mappe, usati anche fuori da
// asuka_maincpu_map (PC060HA e TC0110PCR sono decodificati qui nel top).
// Eto Monogatari: terza mappa, stessi chip a indirizzi tutti diversi.
wire cfg_map_eto = (game_id == GID_ETO);
// Bonze Adventure: quarta mappa. Sound comm e palette stanno dove li ha
// asuka, il resto no; e al posto del TC0220IOC ci sono i DIP diretti e il
// C-Chip, che ancora non c'e'.
wire cfg_map_bonze = cfg_bonze;
wire [23:0] ADR_SYT    = cfg_map_eto ? 24'h4E0000 : (cfg_map_asuka | cfg_map_bonze) ? 24'h3E0000 : 24'h0C0000;
wire [23:0] ADR_PCR    = cfg_map_eto ? 24'h100000 : (cfg_map_asuka | cfg_map_bonze) ? 24'h200000 : 24'hA00000;
wire [23:0] ADR_SCN    = cfg_map_eto ? 24'hD00000 : 24'hC00000;
wire [23:0] ADR_SCNCTL = cfg_map_eto ? 24'hD20000 : 24'hC20000;

wire cfg_has_msm = cfg_map_asuka;   // msm_state = gli stessi set di asuka_map

generate if (ENABLE_VBLANK_IRQ) begin : gen_vblank_irq
	reg  main_irq4_pending;
	reg  main_irq5_pending;
	reg [11:0] irq5_timer;

	// `main_iack` e' un LIVELLO, non un impulso: nel ponte fx68k e'
	// `iack_cycle & ~fx_as_n` (cpu68000_fx68k_bridge.sv), quindi resta alto per
	// tutto il ciclo di bus del riconoscimento — decine di clock di core, visto
	// che questo blocco gira su `clk` e non sul clock enable della CPU.
	// Senza questo rivelatore di fronte lo spegnimento veniva valutato molte
	// volte dentro UN SOLO riconoscimento: al primo colpo spegneva IRQ5, al
	// colpo dopo entrava nel ramo `else if` e spegneva ANCHE IRQ4 — che non era
	// mai stato servito. E l'IRQ4 e' il gestore di vblank, cioe' quello dentro
	// cui il gioco fa girare la logica e la trasmissione del link ($0008EC).
	// Sul 68000 il riconoscimento spegne solo la linea servita: l'altra resta
	// pendente e viene presa dopo (MAME fa lo stesso con HOLD_LINE).
	reg iack_prev;
	always @(posedge clk) begin
		if (reset) begin
			main_irq4_pending <= 1'b0;
			main_irq5_pending <= 1'b0;
			irq5_timer        <= 12'd0;
			iack_prev         <= 1'b0;
		end else begin
			iack_prev <= main_iack;

			// VBlank rising: il livello dipende dal set (vedi cfg_vblank_lvl5).
			// cadash: IRQ4 subito + timer che poi alza IRQ5.
			// bonzeadv: IRQ4 secco. Tutti gli altri: IRQ5 secco.
			// Lo stesso filo della fotografia: prima partiva a render_y 240, una
			// riga PRIMA del vblank, e il gestore di Asuka faceva in tempo a
			// scrivere lo scroll ($0005E2, ~25 us) prima della fotografia.
			if (vbl_snap) begin
				if (cfg_vblank_lvl5) main_irq5_pending <= 1'b1;
				else                 main_irq4_pending <= 1'b1;
				if (enable_irq5_timer) irq5_timer <= IRQ5_DELAY_CYCLES;
			end

			// IRQ5 timer countdown -> assert IRQ5 quando arriva a 1
			if (enable_irq5_timer && |irq5_timer) begin
				irq5_timer <= irq5_timer - 12'd1;
				if (irq5_timer == 12'd1)
					main_irq5_pending <= 1'b1;
			end

			// Un solo spegnimento per riconoscimento, sul fronte: si spegne il
			// livello che il 68000 sta servendo, cioe' quello che l'IPL mux gli
			// sta presentando (IRQ5 se pendente, altrimenti IRQ4).
			if (main_iack && !iack_prev) begin
				if (main_irq5_pending) main_irq5_pending <= 1'b0;
				else if (main_irq4_pending) main_irq4_pending <= 1'b0;
			end
		end
	end

	// IPL mux: IRQ5 > IRQ4 priorita' (68K nesting)
	// 3'b010 = level 5, 3'b011 = level 4, 3'b111 = nessuno
	assign main_ipl_n = main_irq5_pending ? 3'b010 :
	                    main_irq4_pending ? 3'b011 :
	                                        3'b111;
end else begin : gen_no_vblank
	assign main_ipl_n = 3'b111;
end
endgenerate

// Sub-CPU rimossa: ipl_n e iack tied off
assign sub_ipl_n = 3'b111;
assign sub_iack  = 1'b0;

always @(posedge clk) begin
	if (reset)
		cpua_ctrl_reg <= 8'h00;  // Darius 1 pattern: sub CPU HELD in reset, Main releases it by writing $01 to $210000
	else if (cpua_ctrl_wr)
		cpua_ctrl_reg <= cpua_ctrl_data;
end

always @(posedge clk) begin
	if (reset)
		main_pc060ha_port_reg <= 8'h00;
	else if (main_pc060ha_port_wr)
		main_pc060ha_port_reg <= main_pc060ha_port_data;
end

always @(posedge clk) begin
	if (reset)
		main_pc060ha_comm_reg <= 8'h00;
	else if (main_pc060ha_comm_wr)
		main_pc060ha_comm_reg <= main_pc060ha_comm_data;
end

// PC060HA — real protocol handler (jtrastan_pc060 rewrite, single clock)
wire [7:0] pc060ha_main_rdata;

// Main 68K CS PC060HA: $0C0000-$0C0003 su Cadash, $3E0000-$3E0003 su asuka_map
wire pc060_main_cs = ~main_bus_asn & main_bus_cs &
                     (main_bus_addr >= ADR_SYT) & (main_bus_addr <= ADR_SYT + 24'h3);
wire pc060_main_addr = main_bus_addr[1];  // 0=port (...01), 1=comm (...03)
wire pc060_main_wr = pc060_main_cs & ~main_bus_rnw;
wire pc060_main_rd = pc060_main_cs &  main_bus_rnw;

pc060ha_link u_pc060ha (
	.clk(clk),
	.reset(reset),
	// Main 68000 side
	.main_cs(pc060_main_cs),
	.main_addr(pc060_main_addr),
	.main_wr(pc060_main_wr),
	.main_rd(pc060_main_rd),
	.main_wdata(main_bus_dout[7:0]),
	.main_rdata(pc060ha_main_rdata),
	// Sound Z80 side
	.snd_cs(pc060_snd_cs),
	.snd_addr(pc060_snd_addr),
	.snd_wr(pc060_snd_wr),
	.snd_rd(pc060_snd_rd),
	.snd_wdata(pc060_snd_wdata),
	.snd_rdata(pc060_snd_rdata),
	// Control outputs
	.snd_nmi_n(pc060_snd_nmi_n),
	.snd_reset(pc060_snd_reset),
	.dbg_snd_full(),
	.dbg_main_full(),
	.ss_out(ss_pc060_out), .ss_ld(ss_pc060_ld), .ss_in(ss_pc060_in)
);

// Main CPU clock divider (96MHz / den)
// clk_sel = 0 e' AUTOMATICO PER GIOCO: nel driver il 68000 non gira alla stessa
// velocita' su tutte le schede (MAME asuka.cpp).
//   Cadash              XTAL 32 MHz / 2 = 16 MHz   (asuka.cpp:1222)
//   tutte le altre      XTAL 16 MHz / 2 =  8 MHz   (asuka.cpp:1156)
// Gli altri valori di clk_sel restano override manuali e non dipendono dal
// gioco.
reg [7:0] main_clk_den;
always @(*) case (clk_sel)
	3'd0: main_clk_den = cfg_clk_16mhz ? 8'd6         // 96/6  = 16MHz Cadash
	                                        : 8'd12;  // 96/12 =  8MHz resto
	3'd1: main_clk_den = 8'd12;  // 96/12 = 8MHz  (underclock safe)
	3'd2: main_clk_den = 8'd8;   // 96/8  = 12MHz
	3'd3: main_clk_den = 8'd4;   // 96/4  = 24MHz
	3'd4: main_clk_den = 8'd3;   // 96/3  = 32MHz
	3'd5: main_clk_den = 8'd2;   // 96/2  = 48MHz
	default: main_clk_den = 8'd6;
endcase

// Sub-CPU rimossa (single 68000): sub_clk_sel ignorato

// Direct DTACK from SCN/palette chips.
// DACKn: chip not selected → 0, chip selected+busy → 1, chip selected+done → 0.
// When NO external chip is selected, ext_dtack_n must be 1 (inactive) so it
// doesn't interfere with jtframe DTACK for ROM/RAM/etc accesses.
// When any external chip IS selected, OR their DACKn (busy=1 blocks DTACK).
// ext_dtack_n: only the SELECTED chip's DACKn matters.
// Mux instead of OR eliminates risk from non-selected chip DACKn glitches.
wire any_ext_sel = sel_scn0 | sel_pal0;
// When a real chip is selected, use its DACKn.
// When NO chip is selected (gap address in SCN/PAL range), return 0 = instant DTACK
// so the CPU doesn't hang on unmapped addresses like $35FFFC.
// When outside SCN/PAL range entirely, return 1 (inactive, jtframe handles DTACK).
wire scn_pal_range = (main_bus_addr >= 24'h280000) && (main_bus_addr <= 24'h360007) && ~main_bus_asn;
// --- VRAM DTACK generator: 2-cycle delay on Port A reads, 1-cycle on writes ---
// The VRAM BRAM has 1-cycle registered output. Data valid on N+2.
// We assert DTACK on N+1 so CPU samples data on N+2.
reg [2:0] vram_dtack_cnt;
reg scn_ram_active_prev;
wire scn_ram_active = sel_scn0_ram;
always @(posedge clk) begin
    if (reset) begin
        vram_dtack_cnt <= 0;
        scn_ram_active_prev <= 0;
    end else begin
        scn_ram_active_prev <= scn_ram_active;
        if (!scn_ram_active_prev && scn_ram_active) begin
            vram_dtack_cnt <= 3'd2;  // start countdown
        end else if (vram_dtack_cnt != 0) begin
            vram_dtack_cnt <= vram_dtack_cnt - 1'd1;
        end
    end
end
// DTACK only after rising edge propagated (prev=1 guarantees at least 1 cycle elapsed
// since activation → BRAM registered rdata is valid). Prevents early DTACK that made
// CPU sample stale data and fail VRAM memtest.
// Back-pressure: se mirror FIFO full, NON asseriamo DTACK → CPU stalla finche'
// FIFO ha spazio (evita scritture VRAM perse silenziosamente sotto stress).
wire vram_dack_n = (scn_ram_active && scn_ram_active_prev && vram_dtack_cnt == 0 && ~mirror_full && ~mirrorx_full
                    && ~scn0_wr_pend) ? 1'b0 : 1'b1;

// =====================================================================
// C-Chip Taito TC0030CMD (solo Bonze Adventure)
// =====================================================================
// Modulo jttc0030cmd di Andrea Bogazzi (JTCORES, GPL-3) attorno al modello
// del uPD78C11 IKA87AD di Raki (BSD-2). Il chip vero sono quattro die:
// microcontrollore con 4 KB di ROM mascherata, EPROM da 8 KB del gioco,
// 8 KB di SRAM condivisa col 68000 a finestre bancate da 1 KB, e un ASIC.
// Il 68000 lo vede a 800000-800FFF, un byte ogni parola (MAME: umask 0x00ff),
// quindi l'indirizzo del chip e' main_bus_addr[11:1].
wire sel_cchip = bus_raw_active && cfg_map_bonze &&
                 (main_bus_addr >= 24'h800000) && (main_bus_addr <= 24'h800FFF);

// Clock enable a 12 MHz (piedino 20 del uPD78C11): 96/8, esatto.
reg [2:0] cchip_div = 3'd0;
always @(posedge clk) cchip_div <= cchip_div + 3'd1;
wire cchip_cen = (cchip_div == 3'd0);

// Le due ROM restano del core: un'unica regione da 12 KB con la maschera a
// 0x0000 e la EPROM a 0x1000, che e' la seconda forma prevista dal modulo
// (rom_addr/rom_cs). Caricata dall'immagine a partire da 0x640000.
// La BRAM e' a parole: l'ioctl scrive 16 bit per volta, il byte pari sta
// nella meta' bassa.
reg [15:0] cchip_rom [0:6143];
wire is_cchip_dl = ioctl_download && (ioctl_index == 16'd0) &&
                   (ioctl_addr >= 27'h640000) && (ioctl_addr < 27'h643000);
wire [13:0] cchip_rom_addr;
reg  [15:0] cchip_rom_q;
reg  [13:0] cchip_rom_addr_q;
always @(posedge clk) begin
	if (ioctl_wr && is_cchip_dl) cchip_rom[(ioctl_addr[13:1] - 14'h0000)] <= ioctl_dout;
	cchip_rom_q      <= cchip_rom[cchip_rom_addr[13:1]];
	cchip_rom_addr_q <= cchip_rom_addr;
end
wire [7:0] cchip_rom_data = cchip_rom_addr_q[0] ? cchip_rom_q[15:8] : cchip_rom_q[7:0];

wire [7:0] cchip_dout;
wire       cchip_dtack_n;

jttc0030cmd u_cchip (
	.rst     (reset),
	.clk     (clk),
	.cen     (cchip_cen),
	.cs      (sel_cchip),
	.addr    (main_bus_addr[11:1]),
	.din     (main_bus_dout[7:0]),
	.dout    (cchip_dout),
	// le scritture valgono solo col byte basso selezionato; le letture
	// rispondono sul solo cs, come nell'esempio di cablaggio del modulo
	.rnw     (main_bus_rnw | main_bus_dsn[0]),
	.dtack_n (cchip_dtack_n),
	.int1    (vblank_area_top),   // vblank grezzo: il modulo lo condiziona da se'
	.nmi_n   (1'b1),
	.pa_in   (cchip_pa),
	.pb_in   (cchip_pb),
	.pc_in   (cchip_pc),
	.pa_out  (), .pb_out (), .pc_out (),
	.an      (cchip_an),
	.mrom_addr  (), .mrom_data  (cchip_rom_data),
	.eprom_addr (), .eprom_data (cchip_rom_data),
	.rom_addr   (cchip_rom_addr),
	.rom_cs     (),
	.dbg_pc(), .dbg_fetch()
);

// DTACK from TC chips for ctrl; from our VRAM logic for RAM range
wire main_ext_dtack_n = scn_ram_active ? vram_dack_n :
                         sel_cchip ? cchip_dtack_n :
                         sel_scn0 ? scn0_dack_n :
                         sel_pal0 ? pal0_dack_n :
                         scn_pal_range ? 1'b0 :  // gap in SCN/PAL range: instant DTACK
                         1'b1;
// Mux read data: SCN0 RAM reads from CPU port, ctrl reads from chip
wire any_scn_sel = sel_scn0;
wire any_pal_sel = sel_pal0;
wire [15:0] main_bus_rdata_composite = sel_scn0_ram  ? scn0_a_rdata :
                                        sel_scn0_ctrl ? scn0_dout    :
                                        sel_pal0      ? pal0_dout    :
                                        sel_cchip     ? {8'h00, cchip_dout} :
                                        main_bus_rdata;

asuka_cpu_node #(
	.CPU_ID(1'b0),
	.CORE_IMPL(MAIN_CORE_IMPL)
) u_main_cpu (
	.clk(clk),
	.reset(reset),
	.soft_reset(ss_reset68),
	// [SS] durante il save la CPU deve girare anche a gioco in pausa, per eseguire
	// il mini-handler che si salva i registri sul proprio stack.
	.halt_n(~(paused_safe & ~ss_cpu_exec68)),
	.clk_num(7'd1),
	.clk_den(main_clk_den),
	// [SS] IPL7 forzato = interrupt non mascherabile: la CPU FINISCE l'istruzione
	// corrente e solo allora entra nel handler -> mai un congelamento a meta' istruzione.
	.ipl_n(ss_irq68 ? 3'b000 : main_ipl_n),
	.bus_din(ss_din_en ? ss_din_data : main_bus_rdata_composite),
	.bus_cs(main_bus_cs),
	.bus_busy(main_bus_busy),
	.dev_br(1'b0),
	.bus_addr(main_bus_addr),
	.bus_asn(main_bus_asn),
	.bus_rnw(main_bus_rnw),
	.bus_dsn(main_bus_dsn),
	.bus_dout(main_bus_dout),
	.dbg_pc(dbg_main_pc),
	.dbg_fc(main_cpu_fc),          // [SS] function code verso ss_m68k
	.dbg_dtackn(dbg_dtack_n),
	.dbg_fave(),
	.dbg_fworst(),
	.iack(main_iack),
	.dbg_d6(dbg_d6),
	.dbg_d7(dbg_d7),
	.dbg_d0(dbg_d0),
	.dbg_a0(dbg_a0),
	.dbg_a1(dbg_a1)
);

// Sub-CPU rimossa (Asuka/Cadash single 68000)
assign dbg_sub_pc = 24'd0;

asuka_maincpu_map u_main_map (
	.clk(clk), .reset(reset),
	.map_asuka(cfg_map_asuka),
	.map_eto(cfg_map_eto),
	.map_bonze(cfg_map_bonze),
	.dsw_word(dsw_input),
	.bus_addr(main_bus_addr), .bus_asn(main_bus_asn),
	.bus_rnw(main_bus_rnw), .bus_dsn(main_bus_dsn),
	.bus_wdata(main_bus_dout), .bus_rdata(main_bus_rdata),
	.bus_cs(main_bus_cs), .bus_busy(main_bus_busy),
	.bus_be(main_bus_be),
	.rom_addr(main_rom_addr), .rom_req(main_rom_req),
	.rom_rdata(main_rom_rdata), .rom_ready(main_rom_ready),
	.ram_rd(main_ram_rd), .ram_wr(main_ram_wr),
	.ram_be_o(main_ram_be),  // latched byte enable
	.ram_addr_o(main_ram_addr), .ram_wdata(main_ram_wdata),
	.ram_rdata(main_ram_rdata),
	.shared_rd(main_shared_rd), .shared_wr(main_shared_wr),
	.shared_be_o(main_shared_be),
	.shared_addr(main_shared_addr), .shared_wdata(main_shared_wdata),
	.shared_rdata(shared_main_rdata), .shared_ready(shared_main_ready),
	.sprite_rd(main_sprite_rd), .sprite_wr(main_sprite_wr),
	.sprite_be_o(main_sprite_be),
	.sprite_addr(main_sprite_addr), .sprite_wdata(main_sprite_wdata),
	.sprite_rdata(sprite_main_rdata), .sprite_ready(sprite_main_ready),
	.ioc_cs(main_ioc_cs), .ioc_rnw(main_ioc_rnw),
	.ioc_addr(main_ioc_addr), .ioc_wdata(main_ioc_wdata),
	.ioc_rdata(main_ioc_rdata),
	.cpua_ctrl_wr(cpua_ctrl_wr), .cpua_ctrl_data(cpua_ctrl_data),
	.cpua_ctrl_q(cpua_ctrl_reg),
	.spr_ctrl_wr(spr_ctrl_wr), .spr_ctrl_data(spr_ctrl_data),
	.syt_cs_n(syt_cs_n), .syt_wr_n(syt_wr_n),
	.syt_rd_n(syt_rd_n), .syt_a1(syt_a1),
	.syt_main_dout(syt_main_dout_w),
	.vblank(1'b0),
	.ext_dtack_n(main_ext_dtack_n),
	.dbg_txn_state(dbg_txn_state)
);

// Sub-CPU rimossa: Asuka/Cadash hanno single 68000.
// Pattern identico a warriorb: rimuovo istanza, lascio wire sub_* tied a 0
// per non rompere referenze residue nel codice.
// Vedi rtl/darius2/darius2_dual68k_top.sv di Arcade-Darius2WarriorBlade per riferimento.

// --- TC0220IOC (Cadash, asuka.cpp:647 — 8 byte direct address) ---
wire        main_ioc_cs, main_ioc_rnw;
wire  [2:0] main_ioc_addr;
wire  [7:0] main_ioc_wdata, main_ioc_rdata;
tc0220ioc u_tc0220ioc (
	.clk(clk), .reset(reset),
	.cs(main_ioc_cs), .rnw(main_ioc_rnw),
	.addr(main_ioc_addr), .wdata(main_ioc_wdata),
	.rdata(main_ioc_rdata),
	.p1_input(p1_input), .p2_input(p2_input),
	.coin_input(system_input),
	.dswa_input(dsw_input[7:0]),
	.dswb_input(dsw_input[15:8])
);

wire link_on = link_attivo && cfg_cadash;

// --- quando far partire lo Z180 ------------------------------------------
// NON insieme al 68000. Il flag di ruolo ('M' o 'S' a $800000) il 68000 lo
// scrive solo dopo il test della RAM di lavoro da 32 KB: misurato in
// simulazione, frame 56, circa 930 ms dopo il reset. Lo Z180 invece leggerebbe
// $8000 dopo appena 1,4 ms.
//
// Non e' un dettaglio di temporizzazione: e' il protocollo che non regge.
// Leggendo zero, lo Z180 prende il ramo slave ($0074). Con DUE macchine
// collegate le prenderebbero entrambe, entrambe si fermerebbero ad aspettare il
// CTS dell'altra ($0082) e nessuna delle due asserirebbe mai RTS, perche' nel
// ramo slave RTS si abbassa solo DOPO quell'attesa ($0089). Stallo permanente.
// Il gioco puo' funzionare solo se lo Z180 legge il flag quando c'e' gia'.
//
// Quindi lo si tiene in reset finche' il 68000 non lo scrive. Il momento e'
// individuato dal valore, non dal tempo: 'M' (0x4D) o 'S' (0x53) nel byte 0
// della RAM di rete. Non basta "la prima scrittura all'offset 0", perche' il
// 68000 prima azzera tutti i 4 KB ($000B0C) e poi scrive il ruolo ($000B2A /
// $000B34): il primo accesso a quell'indirizzo porta uno zero.
wire flag_ruolo_scritto = main_shared_wr && (main_shared_addr == 15'd0)
                          && main_shared_be[0]
                          && (main_shared_wdata[7:0] == 8'h4D      // 'M'
                           || main_shared_wdata[7:0] == 8'h53);    // 'S'
reg z180_avviato;
always @(posedge clk) begin
	if (reset || !link_on)     z180_avviato <= 1'b0;
	else if (flag_ruolo_scritto) z180_avviato <= 1'b1;
end

// Port B della RAM condivisa: e' lo Z180 del link. Il 68000 la vede dalla
// Port A a $800000-$800FFF, un byte per word (byte nella meta' bassa: MAME fa
// `m_shared_ram[offset] = data & 0xff`), quindi allo Z180 basta la corsia LO.
wire [10:0] z180_sram_addr;
wire        z180_sram_wr;
wire  [7:0] z180_sram_wdata;
wire        sub_shared_rd    = 1'b1;
wire  [1:0] sub_shared_be    = 2'b01;                       // solo byte basso

// Il blocco ricevuto non si mostra al 68000 finche' non e' tutto dentro:
// senza questo il 68000 legge su IRQ5 un blocco a meta' e si pianta sul
// checksum ($0048E6). Il perche', per esteso, sta in cadash_link_blocco.sv.
wire        z180_wr_valido = link_on & ~paused_safe & z180_sram_wr;
wire        blocco_wr;
wire [10:0] blocco_addr;
wire  [7:0] blocco_dato;

// BYPASS: il commit atomico ora sta dentro cadash_link_z180, sulla porta
// stessa dello Z180. Tenerne due in serie vuol dire che il secondo vede una
// lunghezza gia' ritardata dal primo e conta gli indirizzi sbagliati: il
// blocco non viene mai consegnato e il link muore dopo una decina di blocchi.
// Uno solo, e sta a monte.
cadash_link_blocco #(.BYPASS(1)) u_link_blocco (
	.clk(clk), .reset(reset | ~link_on),
	.z_wr(z180_wr_valido), .z_addr(z180_sram_addr), .z_dato(z180_sram_wdata),
	.wr(blocco_wr), .addr(blocco_addr), .dato(blocco_dato)
);

wire        sub_shared_wr    = blocco_wr;
wire [10:0] sub_shared_addr  = blocco_addr;
wire [15:0] sub_shared_wdata = {8'h00, blocco_dato};

// 4 KB, non 64. La finestra vera e' $800000-$800FFF su tutte e due le parti:
// il 68000 la decodifica li' (asuka_maincpu_map) e il trasporto del link usa
// blocco_addr, che e' di 11 bit. I 64 KB erano l'eredita' di Darius 2, dove la
// RAM condivisa era davvero grande: qui erano 60 KB di memoria del chip tenuti
// occupati per niente, ~48 blocchi M10K.
asuka_shared_ram #(
	.ADDR_WIDTH(11),  // $800000-$800FFF = 2048 parole
	.SS_IDX(SS_IDX_SHARED)
) u_shared_ram
(
	.clk(clk),
	.main_rd(main_shared_rd),
	.main_wr(main_shared_wr),
	.main_be(main_shared_be),
	.main_addr(main_shared_addr[10:0]),
	.main_wdata(main_shared_wdata),
	.main_rdata(shared_main_rdata),
	.main_ready(shared_main_ready),
	.sub_rd(sub_shared_rd),
	.sub_wr(sub_shared_wr),
	.sub_be(sub_shared_be),
	.sub_addr(sub_shared_addr),
	.sub_wdata(sub_shared_wdata),
	.sub_rdata(shared_sub_rdata),
	.sub_ready(shared_sub_ready),
	.ss(ssb[SS_IDX_SHARED])
);

// =====================================================================
//  Link fra due cabinati (Cadash) — sotto-sistema Z180
// =====================================================================
// Sul cabinato ogni scheda ha un HD64180RP8 con una ROM propria (c21-07.57) che
// parla via seriale con quello dell'altra scheda. Il 68000 non vede la rete:
// vede la RAM condivisa e ci lascia messaggi. Vedi LINK_CADASH_Z180.md.
//
// Vive solo su Cadash (game_id 0x00) e solo col dipswitch "Communication Mode"
// su Master o Slave: altrimenti resta in reset e non tocca la RAM condivisa,
// che sugli altri giochi della famiglia e' tutt'altra cosa.

// PHI dello Z180 = 8 MHz (MAME: HD64180RP clock=8000000). 96/12 = 8 MHz esatti.
// Baud della linea = PHI/160 = 50 kbaud: un byte (start + 8 + parita' + stop)
// viaggia in 220 us, un messaggio da dieci byte in 2,2 ms. Dentro un frame ci
// sta largo, ed e' il ritmo con cui il gioco scambia i pacchetti.
//
// La pausa vale anche per lui: `paused_safe` copre la pausa dell'OSD E il
// savestate. Se lo Z180 continuasse a scrivere sulla Port B mentre il
// savestate rigira la Port A, il restore uscirebbe corrotto.
reg [3:0] z180_ce_cnt;
reg       z180_ce;
always @(posedge clk) begin
	z180_ce <= 1'b0;
	if (reset || !link_on || paused_safe) begin
		z180_ce_cnt <= 4'd0;
	end else if (z180_ce_cnt == 4'd11) begin
		z180_ce_cnt <= 4'd0;
		z180_ce     <= 1'b1;
	end else
		z180_ce_cnt <= z180_ce_cnt + 4'd1;
end

wire z180_txd, z180_rts_n, z180_re, z180_te;
wire z180_rxd, z180_cts_n;   // scelti fra SNAC e rete piu' sotto
wire [14:0] z180_rom_addr;
wire  [7:0] z180_rom_data;

// ===========================================================================
//  Sorvegliante del link: il guasto che non si vede
// ===========================================================================
//  Misurato sull'hardware, su SNAC: dopo una quarantina di minuti di gioco
//  pulito compare COMMUNICATION ERROR. Il meccanismo, tutto intero:
//
//   1. un byte si sporca sul filo (le linee della user port sono open-drain
//      con pull-up debole: la salita e' una carica RC e su cavo lungo si
//      allunga — vedi i due filtri messi in z180_asci.sv);
//   2. l'ASCI alza PE o FE;
//   3. la ROM del link, a $00E4, salta a $00C2 se trova uno di quei bit — e
//      $00C2 e' un LOOP INFINITO:  ld a,'E' / ld ($8001),a / jr $00C2.
//      Quello Z180 e' morto. Non si riprende: non c'e' nessun timeout, nessun
//      watchdog, niente. La ROM originale non prevedeva che potesse capitare.
//   4. l'altra macchina non riceve piu' niente e dopo 300 frame scrive
//      COMMUNICATION ERROR.
//
//  Il commit atomico (cadash_link_z180) copre il DANNO — un blocco a meta' non
//  arriva mai al 68000 — ma non la MORTE: se lo Z180 e' in quel loop, blocchi
//  non ne arrivano piu' e basta.
//
//  Quindi qui si guarda il battito. `blocco_completato` e' l'unico segnale che
//  dice "il link ha appena fatto qualcosa di vero"; se tace per un secondo con
//  il link acceso, la linea e' morta e si fa il recupero:
//
//    (a) SNAC: si tiene la linea dati verso il partner BASSA per 30 ms. E' un
//        break — piu' lungo di qualunque byte e di qualunque blocco — quindi
//        l'ASCI del partner, appena ascolta, becca framing o parita' e va a
//        $00C2 pure lui. Sembra un dispetto: e' invece l'unico modo di
//        raggiungerlo. Il suo sorvegliante lo vede zitto e lo rialza. Cosi'
//        ripartono in due, che e' l'unico modo per ripartire.
//    (b) RETE: niente break. Basta resettare il trasporto: `cadash_link_rete`
//        all'uscita dal reset manda gia' il suo $FF $02 (resync), e chi lo
//        riceve riparte. Il meccanismo c'e' gia', non se ne aggiunge un altro.
//    (c) in tutti e due i casi: il sotto-sistema link (Z180 + ASCI + commit, e
//        su rete anche il trasporto) sta in reset per qualche microsecondo e
//        poi riparte. Il reset del GIOCO non si tocca MAI: il 68000 va avanti,
//        la partita non si azzera, e al massimo il giocatore vede una pausa
//        nello scambio.
//
//  Poi si ricomincia a contare da zero: se il link e' ancora zitto, fra un
//  secondo si riprova. Non c'e' un numero massimo di tentativi — un link che
//  non torna non fa danno a nessuno, e uno che torna deve poterlo fare anche
//  al decimo tentativo.
//
//  La pausa CONGELA il conteggio: con il gioco fermo (OSD o savestate) lo Z180
//  ha `ce` a zero e non puo' completare niente, e contare quel silenzio
//  vorrebbe dire resettare il link ogni volta che si apre il menu.
//  LA QUIETE DOPO IL RECUPERO. Il recupero da solo non basta, ed e' misurato:
//  i due sorveglianti non scattano insieme — ognuno conta dal PROPRIO ultimo
//  blocco, e fra i due passano un paio di millisecondi. Quindi i due break da
//  30 ms si sovrappongono solo in parte: chi ha fatto il break per primo
//  riparte mentre l'altro tiene ANCORA la linea bassa, il suo ASCI becca
//  subito framing/parita' su quel residuo e torna dritto a $00C2. Il
//  sorvegliante lo ripesca, e la scena si ripete: un loop senza fine, con i
//  recuperi che si contano e il traffico che non riprende mai.
//
//  Quindi dopo il proprio reset non si torna subito a vigilare: si passa per
//  SV_QUIETO, dove lo Z180 e' gia' acceso ma il suo ingresso RX resta forzato
//  a 1 (riposo) — `sv_maschera` — finche' la LINEA VERA non e' rimasta alta,
//  ininterrottamente, per LINK_QUIETE_CICLI. Ogni livello basso azzera il
//  conteggio: il break residuo del partner e' proprio un livello basso lungo,
//  quindi la maschera non cade finche' non e' finito. La maschera vale anche
//  durante il break e il reset propri, cosi' non c'e' un solo ciclo in cui lo
//  Z180 appena ripartito possa vedere spazzatura.
//
//  Ripartire in passo non serve organizzarlo: lo fa l'handshake. Lo Z180 in
//  reset tiene RTS alto, e il master aspetta a $0050 che il CTS scenda — cioe'
//  che l'altro sia davvero su. Non ci vuole nessun altro segnale.
localparam integer LINK_SILENZIO_CICLI = 96_000_000;   // 1 s a 96 MHz
localparam integer LINK_BREAK_CICLI    =  2_880_000;   // 30 ms
localparam integer LINK_RESET_CICLI    =        480;   // 5 us
// La quiete deve chiudersi PRIMA che lo Z180 rinato mandi il primo byte:
// misurati 71.640 cicli (0,75 ms) dal rilascio del reset al bit di start, e
// sono cicli di logica, identici in simulazione e su silicio. Con 2 ms
// l'orecchio si riapriva a byte gia' partito: primo byte perso, mittente
// piantato a $005B, e il giro ricominciava. 0,5 ms = 25 tempi di bit di
// assestamento e 0,25 ms di margine sul vincolo — banco: 5/5 -> 13/13,
// un recupero solo, $00C2 mai piu'.
localparam integer LINK_QUIETE_CICLI   =     48_000;   // 0,5 ms di linea alta

localparam [1:0] SV_VIGILA = 2'd0, SV_BREAK = 2'd1, SV_RESET = 2'd2,
                 SV_QUIETO = 2'd3;

wire       link_blocco_ok;    // impulso: un blocco e' entrato per intero
wire       link_linea_vera;   // il filo RX com'e' davvero, prima della maschera
reg [26:0] sv_silenzio;       // da quanto il link non da' segni di vita
reg [21:0] sv_cnt;            // durata della fase di recupero in corso
reg  [1:0] sv_stato;
reg        sv_break;          // 1 = linea dati verso il partner tenuta bassa
reg        sv_reset;          // 1 = sotto-sistema link in reset
reg  [7:0] sv_recuperi;

always @(posedge clk) begin
	if (reset || !link_on) begin
		sv_silenzio <= 27'd0;
		sv_cnt      <= 22'd0;
		sv_stato    <= SV_VIGILA;
		sv_break    <= 1'b0;
		sv_reset    <= 1'b0;
		sv_recuperi <= 8'd0;
	end else case (sv_stato)
	SV_VIGILA: begin
		sv_break <= 1'b0;
		sv_reset <= 1'b0;
		if (link_blocco_ok)   sv_silenzio <= 27'd0;    // il link respira
		else if (paused_safe) ;                        // fermo col gioco
		else if (sv_silenzio >= LINK_SILENZIO_CICLI[26:0] - 27'd1) begin
			sv_silenzio <= 27'd0;
			sv_recuperi <= sv_recuperi + 8'd1;
			if (link_snac) begin
				sv_break <= 1'b1;
				sv_cnt   <= LINK_BREAK_CICLI[21:0] - 22'd1;
				sv_stato <= SV_BREAK;
			end else begin
				sv_reset <= 1'b1;
				sv_cnt   <= LINK_RESET_CICLI[21:0] - 22'd1;
				sv_stato <= SV_RESET;
			end
		end else
			sv_silenzio <= sv_silenzio + 27'd1;
	end
	SV_BREAK: begin
		// il break va PRIMA del proprio reset: si sveglia il partner mentre si
		// e' ancora accesi, poi si riparte da zero anche qui
		sv_break <= 1'b1;
		if (sv_cnt == 22'd0) begin
			sv_break <= 1'b0;
			sv_reset <= 1'b1;
			sv_cnt   <= LINK_RESET_CICLI[21:0] - 22'd1;
			sv_stato <= SV_RESET;
		end else
			sv_cnt <= sv_cnt - 22'd1;
	end
	SV_RESET: begin
		sv_reset <= 1'b1;
		if (sv_cnt == 22'd0) begin
			// Lo Z180 riparte adesso, ma l'ingresso resta chiuso: si passa per
			// la quiete, e il conteggio parte da capo a ogni livello basso.
			sv_reset <= 1'b0;
			sv_cnt   <= LINK_QUIETE_CICLI[21:0] - 22'd1;
			sv_stato <= SV_QUIETO;
		end else
			sv_cnt <= sv_cnt - 22'd1;
	end
	SV_QUIETO: begin
		sv_reset <= 1'b0;
		if (!link_linea_vera)
			sv_cnt <= LINK_QUIETE_CICLI[21:0] - 22'd1;   // la linea e' ancora sporca
		else if (sv_cnt == 22'd0) begin
			sv_silenzio <= 27'd0;     // backoff: un altro secondo prima di riprovare
			sv_stato    <= SV_VIGILA;
		end else
			sv_cnt <= sv_cnt - 22'd1;
	end
	default: sv_stato <= SV_VIGILA;
	endcase
end

// L'ingresso dello Z180 e' chiuso per tutto il recupero: break, reset e quiete.
// Si torna ad ascoltare solo tornando a vigilare.
wire sv_maschera = (sv_stato != SV_VIGILA);

assign link_dbg_recuperi = sv_recuperi;

// Il gate di avvio dello Z180 (`z180_avviato`) NON viene toccato dal recupero,
// ed e' giusto cosi': si azzera solo sul reset del gioco o quando il link si
// spegne. Il flag di ruolo 'M'/'S' vive in RAM condivisa, ce l'ha scritto il
// 68000 e nessuno lo cancella, quindi allo Z180 che riparte il valore c'e' gia'
// e prende subito il ramo giusto ($0074 o quello del master). Azzerare qui
// `z180_avviato` sarebbe anzi un guasto: aspetterebbe una scrittura del flag
// che non arrivera' mai piu' — il 68000 lo scrive una volta sola, al boot
// ($000B2A/$000B34) — e il link resterebbe spento fino al reset del gioco.

cadash_link_rom u_link_rom (
	.clk(clk),
	.ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_index(ioctl_index),
	.addr(z180_rom_addr), .data(z180_rom_data)
);

cadash_link_z180 u_link_z180 (
	.clk(clk),
	// `sv_reset` e' il recupero del sorvegliante: qualche microsecondo e via.
	// Tocca SOLO questo sotto-sistema — il 68000 e il gioco non se ne accorgono.
	.reset(reset | ~link_on | ~z180_avviato | sv_reset),
	.ce(z180_ce),
	.rom_addr(z180_rom_addr),
	.rom_data(z180_rom_data),
	.sram_addr(z180_sram_addr),
	.sram_wr(z180_sram_wr),
	.sram_wdata(z180_sram_wdata),
	.sram_rdata(shared_sub_rdata[7:0]),
	.rxd(z180_rxd),
	.txd(z180_txd),
	.cts_n(z180_cts_n),
	.rts_n(z180_rts_n),
	.re_attivo(z180_re), .te_attivo(z180_te),
	.blocco_completato(link_blocco_ok),
	.dbg_pc(link_dbg_pc),
	.dbg_tx_attivo(), .dbg_rx_attivo()
);

// ---------------------------------------------------------------------------
//  Due strade per arrivare all'altro cabinato
// ---------------------------------------------------------------------------
//  SNAC: i quattro fili dello schema originale (TXA0, RXA0, RTS0, CTS0) escono
//  dal connettore e vanno dritti all'altra scheda. Niente UART, niente Linux,
//  niente rete: e' il cabinato, con l'handshake vero fra le due macchine. E'
//  l'unica configurazione che nel banco (`DIRETTO=1`) ha chiuso con zero
//  errori, perche' il mittente torna a essere frenato dal ricevente byte per
//  byte — il lockstep che sul percorso di rete si perde.
//
//  RETE: il trasporto che sta sotto, con l'handshake locale e il viaggio via
//  Linux. Resta perche' funziona senza cavi e senza raggiungere il connettore.
//
//  Le linee della user port sono open-drain (`sys_top.v`: si tira a zero o si
//  lascia andare), quindi le due schede non possono farsi male nemmeno se
//  parlano insieme. Le linee 2, 4 e 5 sono condivise con l'audio HDMI e non si
//  toccano: si usano la 0, 1, 3 e 6, e l'incrocio lo fa il cavo.
//  Il cavo e' una prolunga USB3 DRITTA: pin 1 con pin 1. Quindi l'incrocio non
//  puo' farlo il cavo, lo fa il core — e puo' farlo perche' sa gia' chi e':
//  il ruolo glielo dice il dipswitch, ed e' lo stesso che il 68000 scrive a
//  $800000 come 'M' o 'S'. Il master parla sulla linea 0 e ascolta sulla 1, lo
//  slave il contrario; idem per RTS/CTS sulle linee 3 e 6.
//
//  Linee scelte: 0, 1, 3, 6. Le 2, 4 e 5 sono condivise con l'audio HDMI
//  (`SW[1]` in sys_top.v) e non si toccano. La 6 sulla IO board dipende da un
//  ponticello: va messo su "IO" e non su 3,3 V, altrimenti quella linea non
//  porta dati ed e' il CTS a non arrivare.
reg ruolo_master;
always @(posedge clk) begin
	if (reset) ruolo_master <= 1'b1;
	else if (flag_ruolo_scritto) ruolo_master <= (main_shared_wdata[7:0] == 8'h4D);
end

wire snac_on = link_on & link_snac;

// Quale coppia di linee per RTS/CTS. Il pin 6, sulla IO board, dipende da un
// ponticello: puo' essere una linea dati oppure 3,3 V fissi. Se e' 3,3 V il
// CTS non arriverebbe mai, quindi c'e' la scelta di usare la linea 2.
// Attenzione: la 2 e' condivisa con l'audio HDMI (`SW[1]` in sys_top.v).
wire senza_pin6   = (link_snac_cavo == 3'd2);
// QUATTRO FILI VERI, la topologia del cabinato: dati separati per verso e
// handshake separato per verso, senza toccare ne' il pin 6 (che su alcune IO
// board un ponticello inchioda a 3,3 V) ne' la linea 2 (che va all'audio HDMI
// quando SW[1] e' attivo, sys_top.v:1650). Restano libere la 4 e la 5: qui si
// usa la 4. E' l'unica modalita' identica allo schema originale — le altre o
// passano dal pin 6, o dalla linea 2, o mettono i dati su un filo solo.
wire quattro_fili = (link_snac_cavo == 3'd4);
wire [2:0] L_A = 3'd0;                              // dati, verso lo slave
wire [2:0] L_B = 3'd1;                              // dati, verso il master
wire [2:0] L_C = 3'd3;                              // handshake, verso lo slave
wire [2:0] L_D = senza_pin6   ? 3'd2 :
                 quattro_fili ? 3'd4 : 3'd6;       // handshake, verso il master

// Chi parla su quale linea. Con un cavo DRITTO l'incrocio lo fa il core, e lo
// puo' fare perche' sa gia' chi e': il ruolo glielo dice il dipswitch, lo
// stesso che il 68000 scrive a $800000 come 'M' o 'S' — il master usa la prima
// coppia, lo slave la seconda. Se il cavo incrocia gia' di suo, tutti e due
// usano la prima: due incroci si annullerebbero e i due finirebbero a parlare
// sulla stessa linea.
wire usa_prima = (link_snac_cavo == 3'd1) ? 1'b1 : ruolo_master;

// Modo a TRE FILI, per le schede dove il pin 6 e' bloccato su 3,3 V dal
// ponticello e la linea 2 e' presa dall'audio HDMI: restano libere solo la 0,
// la 1 e la 3, che sono tre e i segnali sono quattro.
//
// Si puo' fare perche' il collegamento e' half-duplex: parla uno per volta,
// mai tutti e due insieme. Quindi i dati vanno su un filo solo, condiviso —
// le linee sono open-drain, quindi chi parla la tira giu' e l'altro legge — e
// restano due fili per l'handshake, uno per verso. Chi trasmette non si
// riascolta, perche' lo Z180 in trasmissione tiene RE spento ($26/$36).
wire tre_fili = (link_snac_cavo == 3'd3);

wire [2:0] pin_tx  = tre_fili ? 3'd0 : (usa_prima ? L_A : L_B);
wire [2:0] pin_rx  = tre_fili ? 3'd0 : (usa_prima ? L_B : L_A);
wire [2:0] pin_rts = tre_fili ? (usa_prima ? 3'd1 : 3'd3) : (usa_prima ? L_C : L_D);
wire [2:0] pin_cts = tre_fili ? (usa_prima ? 3'd3 : 3'd1) : (usa_prima ? L_D : L_C);

reg [6:0] snac_out;
always @* begin
	snac_out = 7'b1111111;          // tutto a riposo: open-drain, linea alta
	// Il break del sorvegliante maschera SOLO la linea dati: l'handshake resta
	// quello dello Z180. Tenere bassa la linea per 30 ms vuol dire mandare al
	// partner qualcosa che nessun byte puo' essere — e' il modo di farsi
	// sentire da uno Z180 che sta in un loop infinito.
	snac_out[pin_tx]  = sv_break ? 1'b0 : z180_txd;
	snac_out[pin_rts] = z180_rts_n;
end

// La porta esce dal core solo quando il link passa davvero dal SNAC: altrimenti
// a riposo, che qui vuol dire open-drain, cioe' tutte le linee rilasciate.
assign user_out = snac_on ? snac_out : 7'b1111111;

wire snac_rxd   = user_in[pin_rx];
wire snac_cts_n = user_in[pin_cts];

wire rete_rxd, rete_cts_n, rete_txd;

// Su SNAC la UART verso Linux resta a riposo: il viaggio non passa di li'.
assign link_uart_txd = link_snac ? 1'b1 : rete_txd;

// Via SNAC lo Z180 legge i fili veri; altrimenti quelli del trasporto. La
// linea vera e' anche quella che il sorvegliante guarda per decidere quando
// la quiete e' finita: e' il livello sul filo, non quello che lo Z180 vede.
assign link_linea_vera = snac_on ? snac_rxd : rete_rxd;

// La maschera del recupero sta QUI, sull'ultimo pezzo di filo prima dello
// Z180: durante break, reset e quiete lui vede una linea a riposo e basta —
// il break residuo del partner non lo raggiunge. L'handshake non si tocca.
assign z180_rxd   = sv_maschera ? 1'b1 : link_linea_vera;
assign z180_cts_n = snac_on ? snac_cts_n : rete_cts_n;

wire rete_resync_riavvia;

cadash_link_rete u_link_rete (
	.clk(clk),
	// Il recupero resetta anche il trasporto: e' proprio dall'uscita dal reset
	// che parte il resync $FF $02 verso l'altra macchina. Sul percorso di rete
	// il "break" e' questo, e c'era gia'.
	.reset(reset | ~link_on | link_snac | sv_reset),
	// Perche' si sta resettando: se e' il sorvegliante, all'uscita il trasporto
	// deve annunciare un RECUPERO ($FF $03) e non un resync ($FF $02). La
	// differenza e' tutta li': il $02 fa ripartire il GIOCO dell'altro, e per un
	// recupero automatico del link sarebbe una partita buttata via.
	.reset_recupero(sv_reset),
	.pausa(paused_safe),
	.z_txd(z180_txd), .z_rxd(rete_rxd),
	.z_rts_n(z180_rts_n), .z_cts_n(rete_cts_n),
	.z_re(z180_re), .z_te(z180_te),
	.hps_rxd(link_uart_rxd), .hps_txd(rete_txd),
	.resync_riavvia(rete_resync_riavvia),
	.dbg_byte_usciti(), .dbg_byte_entrati()
);

// Il resync arriva solo dalla rete: il trasporto e' in reset quando il link e'
// spento o passa dal SNAC, ma la condizione si scrive lo stesso — chi legge
// questa porta deve poter vedere da dove viene senza risalire il filo.
assign link_reset_req = rete_resync_riavvia & link_on & ~link_snac;

asuka_shared_ram #(
	.ADDR_WIDTH(13),  // Darius 2: 16 KB sprite RAM (was 4 KB in Darius 1)
	.SS_IDX(SS_IDX_SPRITE)
) u_sprite_ram
(
	.clk(clk),
	.main_rd(main_sprite_rd),
	.main_wr(main_sprite_wr_g),
	.main_be(main_sprite_be),
	.main_addr(main_sprite_addr),
	.main_wdata(main_sprite_wdata),
	.main_rdata(sprite_main_rdata),
	.main_ready(sprite_main_ready),
	// [ARCH] Port B libera (sub-CPU assente) -> usata dalla copy-to-frozen del
	// renderer al posto della shadow spr_ram eliminata.
	.sub_rd(uspr_copy_en),
	.sub_wr(sub_sprite_wr),
	.sub_be(sub_sprite_be),
	.sub_addr(uspr_copy_addr),
	.sub_wdata(sub_sprite_wdata),
	.sub_rdata(sprite_sub_rdata),
	.sub_ready(sprite_sub_ready),
	.ss(ssb[SS_IDX_SPRITE])
);

// Darius 1 legacy removed: FG RAM, FG mirror, FG portb mux (FG is inside TC0100SCN)

asuka_local_ram #(
	.ADDR_WIDTH(15),
	.SS_IDX(SS_IDX_MAIN_RAM)
) u_main_ram (
	.clk(clk),
	.rd(main_ram_rd),
	.wr(main_ram_wr),
	.be(main_ram_be),
	.addr(main_ram_addr),
	.wdata(main_ram_wdata),
	.rdata(main_ram_rdata),
	.ss(ssb[SS_IDX_MAIN_RAM])
);

// --- Debug: Main RAM write counter + first read value at $0C0000 ---
// Counts every write to main RAM (regardless of address). Captures rdata
// the first time CPU reads from $0C0000 (addr==0) right after reset.
reg ram_rd_captured;
always @(posedge clk) begin
    if (reset) begin
        dbg_ram_wr_cnt  <= 16'd0;
        dbg_ram_rd_val  <= 16'hDEAD;
        ram_rd_captured <= 1'b0;
    end else begin
        if (main_ram_wr) dbg_ram_wr_cnt <= dbg_ram_wr_cnt + 16'd1;
        // Capture read value 2 cycles after rd (BRAM output registered with 1 cycle latency + 1 more for stability)
        // Simplest: capture when main_ram_rd and addr==0 (pulse), then hold
        if (main_ram_rd && main_ram_addr == 15'd0 && !ram_rd_captured) begin
            // Wait 2 cycles after rd to sample rdata, but here we just keep overwriting
            // until the first read completes; grab rdata 2 cycles later via pipe
            ram_rd_captured <= 1'b1;
        end
        if (ram_rd_captured && dbg_ram_rd_val == 16'hDEAD) begin
            dbg_ram_rd_val <= main_ram_rdata;
        end
    end
end

// Darius 1 legacy removed: E100 RAM (not in Darius 2 memory map)
// Darius 1 legacy removed: palette_ram (palette is inside TC0110PR)

asuka_local_ram #(
	.ADDR_WIDTH(15)
) u_sub_ram (
	.clk(clk),
	.rd(sub_ram_rd),
	.wr(sub_ram_wr),
	.be(sub_ram_be),
	.addr(sub_ram_addr),
	.wdata(sub_ram_wdata),
	.rdata(sub_ram_rdata),
	// [SS] sub-CPU rimossa su Cadash: RAM non salvata, adaptor inattivo (SS_IDX=-1)
	.ss(ssb_unused)
);

// =====================================================================
// 3× TC0100SCN (tilemap controller) + 3× TC0110PR (palette)
// Replaces Darius 1 PC080SN panel_renderer + vram_arbiter + FG renderer
// =====================================================================
// Each TC0100SCN has its own VRAM (32K×16) and tile ROM interface.
// SCN[0] receives CPU writes and fans them out to all 3 (triple_screen_w).
// SCN[1] and SCN[2] have their own independent CPU write ports.
// Each TC0110PR has its own palette RAM (8K×16).

// --- Savestate bus (dummy — no savestate support yet) ---
ssbus_if scn_ssbus[1]();

// --- CPU → TC0100SCN chip selects ---
// MAME cadash_state::main_map (asuka.cpp:638):
//   $C00000-$C0FFFF → SCN RAM
//   $C20000-$C2000F → SCN ctrl
assign bus_raw_active = ~main_bus_asn && (main_bus_dsn != 2'b11);
// Su eto la finestra e' a D00000-D0FFFF, e in piu' c'e' il mirror in sola
// SCRITTURA a C04000-C0FFFF: sotto i 16 KB c'e' la sprite RAM, che vince.
// L'indirizzo dentro la VRAM viene dai bit bassi, uguali nelle due finestre.
assign sel_scn0_ram  = bus_raw_active &&
                       ( ((main_bus_addr >= ADR_SCN) && (main_bus_addr <= ADR_SCN + 24'hFFFF))
                       | (cfg_map_eto && ~main_bus_rnw &&
                          (main_bus_addr >= 24'hC04000) && (main_bus_addr <= 24'hC0FFFF)) );
assign sel_scn0_ctrl = bus_raw_active && (main_bus_addr >= ADR_SCNCTL) && (main_bus_addr <= ADR_SCNCTL + 24'hF);
assign sel_scn0      = sel_scn0_ram | sel_scn0_ctrl;

// PC060HA sound comm (Cadash, asuka.cpp:643):
//   $0C0001 = master_port_w
//   $0C0003 = master_comm_r/w
// Già gestito da pc060ha_link a $C00000-$C00003 (vecchio Darius2 path C00000),
// ma su Cadash è $0C0000-$0C0003. Aggiustato sotto.
wire sel_syt_main = bus_raw_active && (main_bus_addr >= ADR_SYT) && (main_bus_addr <= ADR_SYT + 24'h3);
wire syt_main_a1  = main_bus_addr[1];   // 0=port, 1=comm

// Single CPU verso SCN[0]
wire [17:0] scn0_va  = main_bus_addr[17:0];
wire [15:0] scn0_din = main_bus_dout;
wire [1:0]  scn0_dsn = main_bus_dsn;
wire        scn0_rnw = main_bus_rnw;
wire        scn0_cs  = sel_scn0;

// Chip CS only for CTRL register access
wire scn0_cs_n = ~sel_scn0_ctrl;

// (DTACK/data signals already forward-declared)

// --- Clock enables ---
// Darius 2 master crystal: 26.686 MHz → TC0100SCN pixel clock = 26.686/2 = 13.343 MHz
// Our system clock: 96 MHz → ce_13m = 96 * 5/36 ≈ 13.33 MHz
// ce_6m = 13.33/2 ≈ 6.67 MHz
wire ce_6m, ce_13m;
jtframe_frac_cen #(.W(2)) u_video_cen (
	.clk(clk),
	.cen_in(1'b1),
	.n(10'd5),
	.m(10'd36),
	.cen({ce_6m, ce_13m}),
	.cenb()
);
// Rate alternativi SCN rimossi (Donlon-legacy). SCN ora usa ce_13m fisso.

// TC0100SCN ce_pixel: usa ce_pix display (6 MHz, Cadash native).
// Darius2 era 13.33 MHz ma display pipeline triple-screen era 24 MHz.
// Cadash single screen display = 6 MHz → palette sample sync con display.
wire scn_ce_pixel = ce_pix;

// --- IHLD/IVLD generation for TC0100SCN ---
// IHLD: pulse at end of each horizontal line (rising edge triggers hcnt reset in TC0100SCN)
// IVLD: high at the IHLD pulse that starts the first line of the frame
// Generated from the compositor's render_x/render_y counters.
// IHLD: level signal from compositor HBlank.
// HBlank pulses every line (high during hblank, low during active), even during vblank.
// TC0100SCN detects rising edge internally (IHLD & ~prev_ihld) on ce_pixel.
// Using render_x >= 864 was WRONG: during vblank render_x is stuck at 900,
// so IHLD stayed high without pulsing → no vcnt increment → no frame sync.
wire scn_ihld = hblank_in;
wire scn_ivld = (render_y == 9'd0);      // high during first line

// --- SCN VRAM: 3× TRUE DUAL-PORT BRAM (32K×16 each) ---
// Port A = CPU (main bus): CPU reads/writes directly, no dependency on TC0100SCN FSM
// Port B = TC0100SCN chip: read-only for rendering
// This avoids the "memory test fails" bug where CPU read got TC0100SCN's current
// rendering address instead of CPU's target address.

// Port B signals (from TC0100SCN chip) — keep original names, chip drives them
// Fix #37: indirizzo esteso a 16 bit (era 15) per supportare wide mode:
// chip VA è 18-bit, SA è 15-bit + SCE0n/SCE1n per discriminare 2 SRAM.
// Qui unificato in scn*_ram_full_addr[15:0] dove bit[15] = ~SCE0n (1 = extra SRAM).
// BRAM principale 32K word ($00000-$0FFFF), BRAM extra 8K word ($10000-$13FFF).
wire [14:0] scn0_ram_addr;
wire [15:0] scn0_ram_din;
reg  [15:0] scn0_ram_dout;
wire        scn0_we_hi;
wire        scn0_we_lo;
wire        scn0_sce0n;
// full 16-bit ram addr seen by VRAM: MSB = extra-SRAM selector (1=extra)
// BUG FIX: scn0_sce0n=0 → main (mux selects main when bit15=0).
// Previously `{~scn0_sce0n, ...}` selected EXT for main access. Inverted.
wire [15:0] scn0_ram_full_addr = {scn0_sce0n, scn0_ram_addr};

// Port A signals (CPU side) — driven directly from CPU bus (skip TC0100SCN)
// VRAM SCN è una sola BRAM fisica, con alias su 3 range ($280000/$2C/$30).
// Per WRITE la BRAM deve ricevere i dati da qualsiasi dei 3 range → include
// tutti e 3 i sel nel cpu_active (altrimenti memtest CUSTOM2/CUSTOM3 fallisce:
// scrittura $2C0000 non arriva, read ritorna 0000).
// NOTA: questo fa sì che i 3 range siano alias della stessa BRAM. Il gioco
// vede 3 schermi con stesso tilemap + scroll separato per chip — design-limit.
wire scn0_cpu_main_active = sel_scn0_ram;
wire scn0_cpu_sub_active  = 1'b0;        // sub-CPU rimossa
wire scn0_cpu_active      = scn0_cpu_main_active;

// CPU address VRAM: addr[16] distingue SRAM principale (=0) da extra (=1).
//   CPU $280000-$28FFFF → addr[15:1]=0-$7FFF, bit[16]=0 → BRAM principale
//   CPU $290000-$293FFF → addr[15:1]=0-$1FFF, bit[16]=1 → BRAM extra
wire [15:0] scn0_a_addr_c  = main_bus_addr[16:1];
wire [15:0] scn0_a_wdata_c = main_bus_dout;

// Write trigger: gated on DSn asserted, one-shot per rising edge.
wire scn0_wr_req = scn0_cpu_active & ~main_bus_rnw & (main_bus_dsn != 2'b11);


// Latched write-time signals: una write per edge.
reg  [15:0] scn0_a_addr_l;
reg  [15:0] scn0_a_wdata_l;
reg   [1:0] scn0_a_be_l;
reg         scn0_a_wr_l;

reg scn0_wr_req_prev = 1'b0;
wire scn0_wr_rising = scn0_wr_req & ~scn0_wr_req_prev;

// La scrittura resta IN ATTESA (scn0_wr_pend) finche' dura la fotografia
// delle tabelle; il DTACK (vram_dack_n) non arriva finche' non e' entrata.
// Fuori dalla fotografia i tempi sono quelli di prima: fronte al ciclo r,
// scrittura in RAM al ciclo r+1.
always @(posedge clk) begin
	scn0_wr_req_prev <= scn0_wr_req;
	if (scn0_wr_rising) begin
		scn0_a_addr_l  <= scn0_a_addr_c;
		scn0_a_wdata_l <= scn0_a_wdata_c;
		scn0_a_be_l    <= ~main_bus_dsn;
		scn0_wr_pend   <= 1'b1;
	end else if (scn0_a_wr_l)
		scn0_wr_pend   <= 1'b0;
end
always @(*) scn0_a_wr_l = scn0_wr_pend & ~scn_vram_hold;

// Effective Port A signals into BRAM
wire [15:0] scn0_a_addr  = scn0_a_wr_l ? scn0_a_addr_l : scn0_a_addr_c;
wire [15:0] scn0_a_wdata = scn0_a_wdata_l;
wire  [1:0] scn0_a_be    = scn0_a_be_l;
wire        scn0_a_wr    = scn0_a_wr_l;

// =====================================================================
// Fix #37: VRAM split in principale 32K word (SRAM0) + extra 8K word (SRAM1).
// MAME TC0100SCN wide mode: 0x00000-0x0FFFF = SCE0 (64KB = 32K word),
//                           0x10000-0x13FFF = SCE1 (16KB = 8K word).
// Bit [15] del CPU address o bit [16] del chip ram_addr seleziona quale.
// =====================================================================

// Fix #37 v3: BRAM inferenza in 2 always separati per ogni array (port A + port B).
// Quartus così inferisce true dual-port M10K standard (minimo packing).
// SRAM principale 32K word + SRAM extra 8K word per SCN wide mode.
// CPU (port A) = R/W. Chip rendering (port B) = R only.

// --- SCN MAIN SRAM (condivisa SCN0/SCN1/SCN2) ---
// Primario: Port A = CPU R/W. Port B non usata.
// Mirror:   Port A = CPU write only (no read). Port B = arbiter chip (read).
// Il mirror elimina la race Port A/Port B: nessuna CPU read sul mirror →
// nessuna collisione con il chip read su Port B.
(* ramstyle = "M10K,no_rw_check" *) reg [7:0] scn0_vram_hi  [0:32767];
(* ramstyle = "M10K,no_rw_check" *) reg [7:0] scn0_vram_lo  [0:32767];
// Mirror: scrittura gated con FIFO 1-slot per evitare collisioni Port A
// (CPU write) vs Port B (chip read) nello stesso clk stessa addr.
(* ramstyle = "M10K,no_rw_check" *) reg [7:0] scn0_vram_mirror_hi [0:32767];
(* ramstyle = "M10K,no_rw_check" *) reg [7:0] scn0_vram_mirror_lo [0:32767];
reg [15:0] scn0_a_rdata_main;

// Mirror BRAM: scrittura DIRETTA (no FIFO). M10K no_rw_check gestisce
// nativamente write-during-read same-address (dato letto undefined, ma
// BRAM non corrotto). FIFO precedente perdeva scritture durante rendering.
wire mirror_full = 1'b0;  // tied off: no FIFO, no backpressure

// [SS] adaptor VRAM main: trasparente in gioco (passa i segnali CPU), durante il
// savestate dirotta indirizzo/dato sul ssbus. q_in = readback registrato a 1 clock,
// che e' esattamente la temporizzazione attesa dall'adaptor.
wire        svr_we_lo, svr_we_hi;
wire [14:0] svr_addr;
wire [15:0] svr_wdata;
ss_ram16_adaptor #(.WIDTHAD(15), .SS_IDX(SS_IDX_VRAM)) u_ss_vram (
	.clk(clk),
	.we_lo_in (scn0_a_wr & ~scn0_a_addr[15] & scn0_a_be[0]),
	.we_hi_in (scn0_a_wr & ~scn0_a_addr[15] & scn0_a_be[1]),
	.addr_in  (scn0_a_addr[14:0]),
	.wdata_in (scn0_a_wdata),
	.we_lo_out(svr_we_lo), .we_hi_out(svr_we_hi),
	.addr_out (svr_addr),  .wdata_out(svr_wdata),
	.q_in     (scn0_a_rdata_main),
	.ssbus    (ssb[SS_IDX_VRAM])
);

always @(posedge clk) begin
	// Mirror write: stessi segnali del primario, cosi' un restore aggiorna anche il
	// mirror che il renderer legge (altrimenti resterebbe la grafica vecchia).
	if (svr_we_hi) scn0_vram_mirror_hi[svr_addr] <= svr_wdata[15:8];
	if (svr_we_lo) scn0_vram_mirror_lo[svr_addr] <= svr_wdata[7:0];

	// VRAM primaria (Port A): write + readback continuo all'indirizzo corrente
	if (svr_we_hi) scn0_vram_hi[svr_addr] <= svr_wdata[15:8];
	if (svr_we_lo) scn0_vram_lo[svr_addr] <= svr_wdata[7:0];

	scn0_a_rdata_main <= {scn0_vram_hi[svr_addr], scn0_vram_lo[svr_addr]};
end

// --- SCN EXTRA SRAM ---
(* ramstyle = "M10K,no_rw_check" *) reg [7:0] scn0_vramx_hi [0:8191];
(* ramstyle = "M10K,no_rw_check" *) reg [7:0] scn0_vramx_lo [0:8191];
// Mirror extra: FIFO 1-slot gate collision (come main).
(* ramstyle = "M10K,no_rw_check" *) reg [7:0] scn0_vramx_mirror_hi [0:8191];
(* ramstyle = "M10K,no_rw_check" *) reg [7:0] scn0_vramx_mirror_lo [0:8191];
reg [15:0] scn0_a_rdata_ext;

// Mirror EXT BRAM: scrittura DIRETTA (no FIFO). Vedi commento mirror main.
wire mirrorx_full = 1'b0;

// [SS] adaptor VRAM extra (wide mode), stesso schema del main.
wire        svx_we_lo, svx_we_hi;
wire [12:0] svx_addr;
wire [15:0] svx_wdata;
ss_ram16_adaptor #(.WIDTHAD(13), .SS_IDX(SS_IDX_VRAMX)) u_ss_vramx (
	.clk(clk),
	.we_lo_in (scn0_a_wr & scn0_a_addr[15] & scn0_a_be[0]),
	.we_hi_in (scn0_a_wr & scn0_a_addr[15] & scn0_a_be[1]),
	.addr_in  (scn0_a_addr[12:0]),
	.wdata_in (scn0_a_wdata),
	.we_lo_out(svx_we_lo), .we_hi_out(svx_we_hi),
	.addr_out (svx_addr),  .wdata_out(svx_wdata),
	.q_in     (scn0_a_rdata_ext),
	.ssbus    (ssb[SS_IDX_VRAMX])
);

always @(posedge clk) begin
	if (svx_we_hi) scn0_vramx_mirror_hi[svx_addr] <= svx_wdata[15:8];
	if (svx_we_lo) scn0_vramx_mirror_lo[svx_addr] <= svx_wdata[7:0];

	// VRAMX primaria (Port A readback)
	if (svx_we_hi) scn0_vramx_hi[svx_addr] <= svx_wdata[15:8];
	if (svx_we_lo) scn0_vramx_lo[svx_addr] <= svx_wdata[7:0];

	scn0_a_rdata_ext <= {scn0_vramx_hi[svx_addr], scn0_vramx_lo[svx_addr]};
end

// Port A CPU read: mux main/ext via addr MSB latched
reg scn0_a_addr_msb_l;
always @(posedge clk) scn0_a_addr_msb_l <= scn0_a_addr[15];
always @(*) scn0_a_rdata = scn0_a_addr_msb_l ? scn0_a_rdata_ext : scn0_a_rdata_main;

// =====================================================================
// VRAM SCN: single chip, port B fetch diretto dal MIRROR (no arbiter).
// =====================================================================

// Alias per FIFO mirror collision detect (legacy ex-arbiter wire name).
wire [15:0] scn_pb_addr = scn_m0_vram_b_addr;

// Port B fetch: il chip MAME emette vram_b_addr[15:0] (bit 15 = main/ext).
// Lettura registered dal MIRROR → dato a +1 clk allineato per il chip.
reg [15:0] scn_pb_dout_main_r, scn_pb_dout_ext_r;
reg        scn_pb_addr_msb_d;
always @(posedge clk) begin
	scn_pb_dout_main_r <= {scn0_vram_mirror_hi [scn_m0_vram_b_addr[14:0]], scn0_vram_mirror_lo [scn_m0_vram_b_addr[14:0]]};
	scn_pb_dout_ext_r  <= {scn0_vramx_mirror_hi[scn_m0_vram_b_addr[12:0]], scn0_vramx_mirror_lo[scn_m0_vram_b_addr[12:0]]};
	scn_pb_addr_msb_d  <= scn_m0_vram_b_addr[15];
end
wire [15:0] scn_pb_dout_raw = scn_pb_addr_msb_d ? scn_pb_dout_ext_r : scn_pb_dout_main_r;

// Inoltro del dato appena scritto sulla porta B (quella del renderer).
// Lo specchio e' dichiarato no_rw_check: se la CPU scrive la stessa parola che
// il renderer sta leggendo nello stesso clock, il dato letto NON e' garantito e
// a schermo finisce un pixel di tile sbagliato, in un punto qualunque. Stesso
// difetto della palette qui sotto, su un'altra memoria.
reg        pb_fwd_hit;
reg [15:0] pb_fwd_data;
reg  [1:0] pb_fwd_be;
always @(posedge clk) begin
	pb_fwd_hit  <= scn0_a_wr && (scn0_a_addr[15] == scn_m0_vram_b_addr[15]) &&
	               (scn0_a_addr[15] ? (scn0_a_addr[12:0] == scn_m0_vram_b_addr[12:0])
	                                : (scn0_a_addr[14:0] == scn_m0_vram_b_addr[14:0]));
	pb_fwd_data <= scn0_a_wdata;
	pb_fwd_be   <= scn0_a_be;
end
wire [15:0] scn_pb_dout = {
	(pb_fwd_hit & pb_fwd_be[1]) ? pb_fwd_data[15:8] : scn_pb_dout_raw[15:8],
	(pb_fwd_hit & pb_fwd_be[0]) ? pb_fwd_data[7:0]  : scn_pb_dout_raw[7:0]
};

// Chip cen sempre attivo (no arbiter 3-way)
wire scn_m0_cen = 1'b1;

reg [15:0] scn0_ram_dout_r;
always @(posedge clk) scn0_ram_dout_r <= scn_pb_dout;
always @(*) scn0_ram_dout = scn0_ram_dout_r;

// --- TC0100SCN tile ROM interface ---
wire [20:0] scn0_rom_addr;
wire [31:0] scn0_rom_data;
wire        scn0_rom_req;
wire        scn0_rom_ack;

// --- TC0100SCN video output → TC0110PR ---
wire [14:0] scn0_sc;


// --- Sync from SCN[0] (master) ---
wire scn0_hsyn, scn0_vsyn, scn0_hblo, scn0_vblo;

// =====================================================================
// TC0100SCN bindings (chip MAME guida dout/dack/SC/rom; legacy wire tied-off)
// =====================================================================

// render_x per pannello (single screen: solo panel0)
wire [9:0] render_x_panel0 = render_x;

// CPU path: redirigi dout/dack dal chip MAME
assign scn0_dout    = scn_m0_cpu_dout;
assign scn0_dack_n  = scn_m0_cpu_dtack_n;

// SC → palette
assign scn0_sc      = scn_m0_sc;

// Tile ROM interface
assign scn0_rom_addr = scn_m0_rom_addr;
assign scn0_rom_req  = scn_m0_rom_req;

// Port B VRAM legacy tied-off (chip MAME guida via scn_m0_vram_b_addr)
assign scn0_ram_addr = 15'd0;
assign scn0_ram_din  = 16'd0;
assign scn0_we_hi    = 1'b1;
assign scn0_we_lo    = 1'b1;
assign scn0_sce0n    = 1'b0;

// Sync output: TC0110PR li dichiara ma body non li usa.
assign scn0_hsyn = 1'b1;
assign scn0_vsyn = 1'b1;
assign scn0_hblo = 1'b1;
assign scn0_vblo = 1'b1;

// hcnt/line_end ricostruiti dal compositor
reg prev_hblank_scn;
always @(posedge clk) prev_hblank_scn <= hblank_in;
wire hblank_rise_scn = hblank_in & ~prev_hblank_scn;
assign scn0_hcnt     = render_x_panel0[8:0] + 9'd26;
assign scn0_line_end = hblank_rise_scn;

// =====================================================================
// MAME-model TC0100SCN instances (3×) — PARALLEL with Donlon for now.
// Not yet wired to output. Used for sintax/resource verification in Step 2.
// In Step 3 Donlon will be disconnected and MAME will drive SC, rom_req, etc.
// =====================================================================

reg  prev_hblank_mame;
always @(posedge clk) prev_hblank_mame <= hblank_in;
wire hblank_rise_mame = hblank_in & ~prev_hblank_mame;

wire scn_m0_done;
wire scn_m0_active = 1'b0;  // unused — tied off for new tc0100scn_cadash chip
wire scn_m0_go = hblank_rise_mame;

// MAME chip signals (single chip)
wire [15:0] scn_m0_cpu_dout;
wire        scn_m0_cpu_dtack_n;
wire [15:0] scn_m0_vram_a_addr;
wire [15:0] scn_m0_vram_a_wdata;
wire  [1:0] scn_m0_vram_a_we;
wire [15:0] scn_m0_vram_b_addr;
wire [20:0] scn_m0_rom_addr;
wire        scn_m0_rom_req;
wire [14:0] scn_m0_sc;

wire [127:0] scn0_ctrl_flat;
// [SS] registri di scroll del chip nel savestate (128 bit = ctrl[0..7]).
// Fase 1 = solo SAVE: bits_out/bits_wr non ricablati nel chip.
wire [127:0] ss_ctrl_out_unused;
wire         ss_ctrl_wr_unused;
auto_save_adaptor #(.N_BITS(128), .SS_IDX(SS_IDX_CTRL)) u_ss_ctrl (
	.clk(clk), .ssbus(ssb[SS_IDX_CTRL]),
	.bits_in(scn0_ctrl_flat),
	.bits_out(ss_ctrl_out_unused), .bits_wr(ss_ctrl_wr_unused)
);   // [SS] ctrl[0..7] del TC0100SCN
tc0100scn_cadash #(.SS_IDX_RSLOG(SS_IDX_RSLOG)) u_scn_cadash (
	.clk(clk), .reset(reset),
	// cpu_addr[17] = ctrl access, [16:1] = word addr
	.cpu_addr({sel_scn0_ctrl, main_bus_addr[16:0]}),
	.cpu_din(main_bus_dout),
	.cpu_dout(scn_m0_cpu_dout),
	.cpu_rnw(main_bus_rnw),
	.cpu_dsn(main_bus_dsn),
	.cpu_cs(sel_scn0),
	.cpu_dtack_n(scn_m0_cpu_dtack_n),
	.vram_a_addr(scn_m0_vram_a_addr),
	.vram_a_wdata(scn_m0_vram_a_wdata),
	.vram_a_we(scn_m0_vram_a_we),
	.vram_a_rdata(scn0_a_rdata),
	.vram_b_addr(scn_m0_vram_b_addr),
	.vram_b_rdata(scn0_ram_dout_r),
	.rom_addr(scn_m0_rom_addr),
	.rom_data(scn0_rom_data),
	.rom_req(scn_m0_rom_req),
	.rom_ack(scn0_rom_ack),
	.SC(scn_m0_sc),
	.render_x(render_x_panel0), .render_y(render_y),
	.last_line(frame_last_line),
	.snap(vbl_snap),
	.scroll_frame_latch(~spr_pcb_timing),
	.snap_busy(scn_snap_busy),
	.scn_x_off1(cfg_scn_x_off1),     // TC0100SCN set_offsets(1,0) o (0,0)
	.go(scn_m0_go), .done(scn_m0_done),
	.osd_layer_en(osd_tile_layer_en),
	.bg0_xoff_ext(l0_xoff), .bg0_yoff_ext(l0_yoff),
	.bg1_xoff_ext(l1_xoff), .bg1_yoff_ext(l1_yoff),
	.fg0_xoff_ext(fg_xoff), .fg0_yoff_ext(fg_yoff),
	.ctrl_flat(scn0_ctrl_flat),         // [SS] registri di scroll per il dump
	.ss_rslog(ssb[SS_IDX_RSLOG])
);
// scn_m0_active was multi-chip mux signal; new chip doesn't drive it
// (declared at line ~1111 as wire — leaving floating since unused)

// u_scn_mame_1, u_scn_mame_2 rimossi (single-screen Asuka family).

// --- TC0110PR palette instances (3×, one per screen) ---
// Each TC0110PR has its own palette RAM (8K×16).
// CPU access via $340000/$350000/$360000 (4 registers each).
// Video input: SC[14:0] from TC0100SCN, OB[14:0] from sprite renderer.

// Palette chip selects (from MAME darius2_master_map)
// TC0110PCR: $A00000-$A0000F su Cadash, $200000-$20000F su asuka_map
assign sel_pal0 = bus_raw_active && (main_bus_addr >= ADR_PCR) && (main_bus_addr <= ADR_PCR + 24'hF);

// Sprite OB output (shared across all 3 screens).
// Driven by asuka_sprite_renderer below.
wire [14:0] sprite_ob;

// Palette RAM: 3× 8K×16 (CA[12:0], CDin/CDout[15:0])
wire [12:0] pal0_ca;
reg  [15:0] pal0_cdin;
wire [15:0] pal0_cdout;
wire        pal0_wel, pal0_weh;

// Palette RAM 0
// Gate WE during ioctl_download to avoid spurious writes before CPU is released.
// Write-through bypass on cdin: if writing this cycle, forward cdout to cdin so
// the CPU readback (TC0110PR Dout<=CDin) sees the value it just wrote instead of
// garbage from the no_rw_check same-cycle W+R collision on M10K.
wire pal0_weh_g = pal0_weh | ioctl_download;
wire pal0_wel_g = pal0_wel | ioctl_download;
// TRUE DUAL-PORT: Port A = chip (write + read-back CDin); Port B = video raw (read only).
// Two separate always blocks per array → Quartus infers true dual-port M10K.
(* ramstyle = "M10K,no_rw_check" *) reg [7:0] pal0_ram_hi [0:4095];
(* ramstyle = "M10K,no_rw_check" *) reg [7:0] pal0_ram_lo [0:4095];
// Port A (chip) — write + CDin readback
// [SS] adaptor palette. Le WE del chip sono ATTIVE BASSE: qui vengono convertite
// ad attive alte per l'adaptor e riusate cosi' nel blocco RAM. Il bypass
// write-through sul readback e' preservato (ora pilotato dalle WE muxate).
wire        spl_we_lo, spl_we_hi;
wire [11:0] spl_addr;
wire [15:0] spl_wdata;
ss_ram16_adaptor #(.WIDTHAD(12), .SS_IDX(SS_IDX_PAL0)) u_ss_pal0 (
	.clk(clk),
	.we_lo_in (~pal0_wel_g),
	.we_hi_in (~pal0_weh_g),
	.addr_in  (pal0_ca[11:0]),
	.wdata_in (pal0_cdout),
	.we_lo_out(spl_we_lo), .we_hi_out(spl_we_hi),
	.addr_out (spl_addr),  .wdata_out(spl_wdata),
	.q_in     (pal0_cdin),
	.ssbus    (ssb[SS_IDX_PAL0])
);

always @(posedge clk) begin
	if (spl_we_hi) pal0_ram_hi[spl_addr] <= spl_wdata[15:8];
	pal0_cdin[15:8] <= spl_we_hi ? spl_wdata[15:8] : pal0_ram_hi[spl_addr];
end
always @(posedge clk) begin
	if (spl_we_lo) pal0_ram_lo[spl_addr] <= spl_wdata[7:0];
	pal0_cdin[7:0]  <= spl_we_lo ? spl_wdata[7:0]  : pal0_ram_lo[spl_addr];
end

// Palette RAM 1/2 rimosse (single screen Asuka family).

// CPU mux verso TC0110PR — single CPU, single palette chip (Asuka family)
wire [15:0] pal_din      = main_bus_dout;
wire [1:0]  pal_va       = main_bus_addr[2:1];
wire        pal_rwn      = main_bus_rnw;
wire [1:0]  pal_dsn      = main_bus_dsn;
wire        pal_any_main = sel_pal0;
wire        pal0_scen    = ~sel_pal0;

TC0110PR pal0 (
	.clk(clk), .ce_pixel(scn_ce_pixel),
	.Din(pal_din), .Dout(pal0_dout),
	.VA(pal_va), .RWn(pal_rwn),
	.UDSn(pal_dsn[1]), .LDSn(pal_dsn[0]),
	.SCEn(pal0_scen), .DACKn(pal0_dack_n),
	.HSYn(scn0_hsyn), .VSYn(scn0_vsyn),
	.SC(scn0_sc), .OB(sprite_ob),
	.CA(pal0_ca), .CDin(pal0_cdin), .CDout(pal0_cdout),
	.WELn(pal0_wel), .WEHn(pal0_weh)
);

// pal1/pal2 rimossi (single screen).

// --- Line buffer 13MHz→24MHz per TC0100SCN ---
wire [8:0] scn0_hcnt;
wire       scn0_line_end;
wire [14:0] scn0_sc_buf = 15'd0;

reg [8:0]  scn0_wr_x_r;
reg        scn0_wr_valid_r;
reg [14:0] scn0_sc_r;
always @(posedge clk) begin
	scn0_wr_x_r     <= (scn0_hcnt >= 9'd26) ? (scn0_hcnt - 9'd26) : 9'd0;
	scn0_wr_valid_r <= (scn0_hcnt >= 9'd26) && (scn0_hcnt < 9'd346);
	scn0_sc_r       <= scn0_sc;
end
reg ce_13m_r;
always @(posedge clk) ce_13m_r <= ce_13m;

// Compositor reads panel window 0..287 from each chip (offset 16 for center).
// --- Palette lookup (single screen) ---
// Spegnimento sprite dall'OSD: la voce c'era ma non era collegata a niente, e
// "Sprite: Off" lasciava gli sprite a schermo.
wire [14:0] sprite_ob_g = dbg_dis_spr ? 15'd0 : sprite_ob;
wire spr_hit = sprite_ob_g[14];
// Priorita' sprite/tile: nel driver e' GLOBALE, decisa una volta per frame dal
// callback che riceve sprite_ctrl (MAME asuka.cpp:467-477), non per sprite.
//   Cadash          fixed_colpri:    pri_mask sempre $f0 — lo sprite sta SOPRA
//                                    il layer alto, sempre.
//   tutti gli altri variable_colpri: pri_mask = (sprite_ctrl & 1) ? $fc : $f0 —
//                                    col bit 0 acceso lo sprite passa DIETRO.
wire spr_prio_low = cfg_colpri_fixed ? 1'b0 : spr_ctrl_use[0];

function automatic sprite_wins_fn;
	input [14:0] sc;
	input        hit;
	input        prio_low;
	reg sc_is_fg, sc_is_top, sc_is_bot, sc_empty;
	begin
		sc_is_fg  = (sc[14:13] == 2'b01);
		sc_is_top = (sc[14:13] == 2'b11);
		sc_is_bot = (sc[14:13] == 2'b10);
		sc_empty  = (sc[14:13] == 2'b00);
		sprite_wins_fn = hit && !sc_is_fg &&
		                 (sc_empty || sc_is_bot || (sc_is_top && !prio_low));
	end
endfunction

wire spr_wins0 = sprite_wins_fn(scn0_sc, spr_hit, spr_prio_low);
wire [11:0] vid_pal_idx0 = spr_wins0 ? sprite_ob_g[11:0] : scn0_sc[11:0];
wire        r0_opaque_c  = spr_wins0 ? 1'b1 : |scn0_sc[3:0];
wire [1:0]  r0_prio_c    = spr_wins0 ? (spr_prio_low ? 2'b10 : 2'b11) : scn0_sc[14:13];

reg [15:0] vid_pal_raw0;
reg        r0_opaque;
reg  [1:0] r0_prio;
// Inoltro del dato appena scritto sulla porta VIDEO della palette.
// I due banchi sono dichiarati no_rw_check: se la CPU scrive la stessa cella
// che il video sta leggendo nello stesso clock, il dato letto NON e' garantito,
// e a schermo esce un pixel di colore a caso, in un punto qualunque. Non lo
// spegne nessun interruttore dei layer, perche' anche a piani spenti l'indice
// vale 0 e quella cella la si legge lo stesso. Si vede di piu' nei giochi che
// riscrivono la palette di continuo (dissolvenze e cicli di colore).
// Sull'altra porta, quella della CPU, l'inoltro c'era gia' (pal0_cdin).
// La LETTURA resta nuda, com'era: se le si mette un ternario dentro, Quartus
// non riconosce piu' la porta come porta di memoria e ci costruisce un
// multiplexer da 4096 ingressi (provato: 64.000 ALM e build che non entra).
// L'inoltro si applica DOPO il registro, con la coppia indirizzo/dato
// ritardata di un clock esattamente come il dato che esce dalla RAM.
reg        pal_fwd_hi_d, pal_fwd_lo_d;
reg [15:0] pal_fwd_data_d;
always @(posedge clk) begin
	pal_fwd_hi_d   <= spl_we_hi && (spl_addr == vid_pal_idx0);
	pal_fwd_lo_d   <= spl_we_lo && (spl_addr == vid_pal_idx0);
	pal_fwd_data_d <= spl_wdata;
	vid_pal_raw0 <= {pal0_ram_hi[vid_pal_idx0], pal0_ram_lo[vid_pal_idx0]};
	r0_opaque    <= r0_opaque_c;
	r0_prio      <= r0_prio_c;
end
wire [15:0] vid_pal0 = {
	pal_fwd_hi_d ? pal_fwd_data_d[15:8] : vid_pal_raw0[15:8],
	pal_fwd_lo_d ? pal_fwd_data_d[7:0]  : vid_pal_raw0[7:0]
};

// Formato del colore: dipende dal gioco, non dal chip. Il TC0110PCR e' lo
// stesso, ma il driver lo legge in due modi diversi (MAME asuka.cpp:479-487):
//
//   Cadash          color_xbgr444: R=data[3:0]   G=data[7:4]  B=data[11:8]
//   tutti gli altri color_xbgr555: R=data[4:0]   G=data[9:5]  B=data[14:10]
//
// L'espansione a 8 bit replica i bit alti (4'hF -> 8'hFF, 5'h1F -> 8'hFF),
// che e' quello che fanno pal4bit/pal5bit di MAME.
wire        pal_444 = cfg_pal444;                    // xbgr444 solo Cadash

wire [3:0] r0_r4 = vid_pal0[3:0];
wire [3:0] r0_g4 = vid_pal0[7:4];
wire [3:0] r0_b4 = vid_pal0[11:8];
wire [23:0] r0_rgb444 = {r0_r4, r0_r4, r0_g4, r0_g4, r0_b4, r0_b4};

wire [4:0] r0_r5 = vid_pal0[4:0];
wire [4:0] r0_g5 = vid_pal0[9:5];
wire [4:0] r0_b5 = vid_pal0[14:10];
wire [23:0] r0_rgb555 = {r0_r5, r0_r5[4:2], r0_g5, r0_g5[4:2], r0_b5, r0_b5[4:2]};

wire [23:0] r0_rgb = pal_444 ? r0_rgb444 : r0_rgb555;

// Tile ROM interface single channel
wire [23:0] r0_tilerom_addr = {3'd0, scn0_rom_addr};
wire        r0_tilerom_req  = scn0_rom_req;
wire [31:0] r0_tilerom_data;
wire        r0_tilerom_valid;
assign scn0_rom_data = r0_tilerom_data;

reg scn0_rom_ack_r;
always @(posedge clk) begin
	if (reset) scn0_rom_ack_r <= 1'b0;
	else if (r0_tilerom_valid) scn0_rom_ack_r <= scn0_rom_req;
end
assign scn0_rom_ack = scn0_rom_ack_r;

// Sprite renderer ROM interface
wire [23:0] sprite_romaddr;
wire        sprite_romreq;
wire [31:0] sprite_romdata;
wire        sprite_romvalid;

// Darius 1 legacy removed: FG palette, FG renderer (FG is inside TC0100SCN)
// Darius 1 legacy removed: sprite palette snooped copy (palette is inside TC0110PR)

// Stub FG outputs (FG is now inside TC0100SCN, output via palette)
assign fg_rgb = 24'd0;
assign fg_opaque = 1'b0;

// GFX ROM arbiter: single tile channel + 3 stub inutilizzati
tile_rom_arbiter u_tile_arb (
	.clk(clk), .reset(reset),
	.hblank(render_x >= 10'd320),
	.r0_req(r0_tilerom_req), .r0_addr(r0_tilerom_addr),
	.r0_data(r0_tilerom_data), .r0_valid(r0_tilerom_valid),
	.r1_req(1'b0), .r1_addr(24'd0), .r1_data(), .r1_valid(),
	.r2_req(1'b0), .r2_addr(24'd0), .r2_data(), .r2_valid(),
	.r3_req(1'b0), .r3_addr(24'd0), .r3_data(), .r3_valid(),
	.r4_req(1'b0), .r4_addr(24'd0), .r4_data(), .r4_valid(),
	.tile_req(tilerom_req), .tile_addr(tilerom_addr),
	.tile_is_sprite(tilerom_is_sprite),
	.tile_is_text(tilerom_is_text),
	.tile_data(tilerom_data), .tile_valid(tilerom_valid)
);

// Sprite ROM cache → DDR3 port 4 (path dedicato sprite, libera SDRAM)
wire [27:0] sprite_ddr_rdaddr;
wire [31:0] sprite_ddr_dout;
wire        sprite_ddr_rd_req;
wire        sprite_ddr_rd_ack;

sprite_rom_cache u_spr_cache (
	.clk(clk), .reset(reset),
	.req_addr(sprite_romaddr),
	.req_pulse(sprite_romreq),
	.resp_data(sprite_romdata),
	.resp_valid(sprite_romvalid),
	.ddr_addr(sprite_ddr_rdaddr),
	.ddr_req(sprite_ddr_rd_req),
	.ddr_data(sprite_ddr_dout),
	.ddr_ack(sprite_ddr_rd_ack)
);

// =====================================================================
// Sprite ROM ioctl download → DDR3 (port 4 write via audio_top mux)
// =====================================================================
// Range MRA: ioctl_addr 0x140000-0x33FFFF (2 MB) durante ioctl_index=0.
// audio_top espone we toggle protocol, qui generiamo le request.
wire is_sprite_dl = ioctl_download && (ioctl_index == 16'd0)
                     && (ioctl_addr >= 27'h140000) && (ioctl_addr < 27'h340000);
reg  [27:0] spr_dl_waddr;
reg  [15:0] spr_dl_wdata;
reg         spr_dl_we_req;
wire        spr_dl_we_ack;
reg         ioctl_wr_prev_spr;
always @(posedge clk) begin
	ioctl_wr_prev_spr <= ioctl_wr;
	if (ioctl_wr && !ioctl_wr_prev_spr && is_sprite_dl) begin
		spr_dl_waddr <= 28'h0400000 + {1'b0, ioctl_addr - 27'h140000};
		spr_dl_wdata <= ioctl_dout;
		spr_dl_we_req <= ~spr_dl_we_req;
	end
end

// Output single panel (no triple-screen mux)
assign tile_rgb    = r0_rgb;
assign tile_prio   = r0_prio;
assign tile_opaque = r0_opaque;


// =====================================================================
// Sprite renderer (palette now in TC0110PR, not snooped copy)
// =====================================================================
wire [10:0] sprite_pal_addr;  // driven by sprite renderer (unused in Darius 2, palette via TC0110PR)
wire [15:0] sprite_pal_data = 16'd0;  // stub — sprite gets color from TC0110PR not from snooped palette

// [ARCH] Copy-to-frozen: legge u_sprite_ram su Port B. Nessuna contesa (sub-CPU
// assente) -> grant immediato. Forwarding write-first: se la main CPU scrive la
// stessa cella che la copy sta leggendo nello stesso ck, la BRAM (no_rw_check)
// darebbe dato indefinito; qui si inoltra il dato appena scritto.
wire [12:0] uspr_copy_addr;
wire        uspr_copy_en;
wire        uspr_copy_grant = uspr_copy_en;
reg         uspr_fwd_hit;
reg  [15:0] uspr_fwd_data;
reg   [1:0] uspr_fwd_be;
always @(posedge clk) begin
	uspr_fwd_hit  <= uspr_copy_grant & main_sprite_wr_g & (main_sprite_addr == uspr_copy_addr);
	uspr_fwd_data <= main_sprite_wdata;
	uspr_fwd_be   <= main_sprite_be;
end
wire [15:0] uspr_copy_data_fwd = {
	(uspr_fwd_hit & uspr_fwd_be[1]) ? uspr_fwd_data[15:8] : sprite_sub_rdata[15:8],
	(uspr_fwd_hit & uspr_fwd_be[0]) ? uspr_fwd_data[7:0]  : sprite_sub_rdata[7:0]
};

asuka_sprite_renderer u_sprite (
	.clk(clk), .reset(reset),
	.render_x(render_x), .render_y(render_y),
	.frame_last_line(frame_last_line),
	.spr_pcb_timing(spr_pcb_timing),
	.snap(vbl_snap),
	.spr_buffered(cfg_spr_buffer),
	.spr_copy_hold(spr_copy_hold),
	.x_offset(10'd0),  // wide-screen: sprites use raw sx, no panel offset needed
	// Sprite RAM writes qualificati (stessa semantica di u_sprite_ram)
	.main_sprite_wr(main_sprite_wr_g),
	.main_sprite_addr(main_sprite_addr),
	.main_sprite_wdata(main_sprite_wdata),
	.main_sprite_be(main_sprite_be),
	.sub_sprite_wr(1'b0),
	.sub_sprite_addr(13'd0),
	.sub_sprite_wdata(16'd0),
	.sub_sprite_be(2'b00),
	.spriterom_data(sprite_romdata), .spriterom_valid(sprite_romvalid),
	.spriterom_addr(sprite_romaddr), .spriterom_req(sprite_romreq),
	// X: niente +1. Gli sprite uscivano un pixel piu' a destra di MAME (visto su
	// Bonze Adventure). La Y invece il +1 ce l'ha e ci resta: senza, gli sprite
	// stanno un pixel piu' in alto di dove devono.
	.spr_xoff(spr_xoff), .spr_yoff(spr_yoff + 10'sd1),
	.sprite_colbank(sprite_colbank),
	.flip_screen(spr_flip_use),
	.pal_data(sprite_pal_data), .pal_lookup_addr(sprite_pal_addr),
	.sprite_rgb(sprite_rgb), .sprite_prio(sprite_prio), .sprite_opaque(sprite_opaque),
	.sprite_ob(sprite_ob),
	.usprite_copy_addr(uspr_copy_addr),
	.usprite_copy_en(uspr_copy_en),
	.usprite_copy_data(uspr_copy_data_fwd),
	.usprite_copy_grant(uspr_copy_grant),
	.dbg_disp_word()
);

// =====================================================================
// Bus DDR3: due master di gioco (asuka_ddram e il rotate) arbitrati da
// asuka_ddr_mux, e l'uscita del mux che poi divide i pin col savestate
// tramite ss_ddr_gate. Stesso schema di Raiden, che ha lo stesso problema:
// le ROM sprite stanno in DDR3 e devono convivere col framebuffer ruotato.
//   ddr_game = client a -> asuka_ddram (ROM Z80, ADPCM, ROM sprite)
//   ddr_rot  = client b -> FIFO dei write del framebuffer
//   ddr_host = uscita del mux -> ss_ddr_gate -> pin DDRAM_*
// =====================================================================
ddr_if ddr_game();
ddr_if ddr_rot();
ddr_if ddr_host();
wire   game_ddr_want;

// =====================================================================
// Audio subsystem (Darius 2 / Ninja Warriors)
//   Z80 + YM2610 (jt10) + TC0140SYT
//   ROM Z80 128 KB cached da DDRAM, ADPCM A/B da DDRAM via bridge
// =====================================================================
asuka_audio_top u_audio (
	.clk(clk),
	.ddram_clk(DDRAM_CLK),
	.reset(reset),
	.pause(paused_safe),
	// ioctl
	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),
	.ioctl_wait(ioctl_wait_audio),
	// Comunicazione main 68000 ↔ TC0140SYT
	.main_din(main_bus_dout[3:0]),  // byte LSB nibble basso (umask 0x00ff)
	.main_dout(syt_main_dout_w),
	// Segnali dal maincpu_map_new (registrati, gestiscono DTACK internamente)
	.main_a1(syt_a1),
	.main_cs_n(syt_cs_n),
	.main_wr_n(syt_wr_n),
	.main_rd_n(syt_rd_n),
	// Non parla piu' coi pin: e' il client a del ddr_mux, che poi passa per
	// ss_ddr_gate. Busy e dati di ritorno arrivano dal mux, che tiene busy=1
	// quando il bus ce l'ha il rotate o il savestate.
	.DDRAM_BUSY(ddr_game.busy),
	.DDRAM_BURSTCNT(game_DDRAM_BURSTCNT),
	.DDRAM_ADDR(game_DDRAM_ADDR),
	.DDRAM_DOUT(ddr_game.rdata),
	.DDRAM_DOUT_READY(ddr_game.rdata_ready),
	.DDRAM_RD(game_DDRAM_RD),
	.DDRAM_DIN(game_DDRAM_DIN),
	.DDRAM_BE(game_DDRAM_BE),
	.DDRAM_WE(game_DDRAM_WE),
	.ddr_want(game_ddr_want),
	.msm_enable(cfg_has_msm),
	.cfg_bonze(cfg_bonze),
	// Sprite ROM read/write port (DDR3 port 4)
	.spr_rdaddr(sprite_ddr_rdaddr),
	.spr_dout(sprite_ddr_dout),
	.spr_rd_req(sprite_ddr_rd_req),
	.spr_rd_ack(sprite_ddr_rd_ack),
	.spr_we_addr(spr_dl_waddr),
	.spr_we_data(spr_dl_wdata),
	.spr_we_req(spr_dl_we_req),
	.spr_we_ack(spr_dl_we_ack),
	// Audio out
	.audio_l(audio_l),
	.audio_r(audio_r),
	.adpcma_tap_l(adpcma_tap_l),
	.adpcma_tap_r(adpcma_tap_r),
	.fm_tap_l(fm_tap_l),
	.fm_tap_r(fm_tap_r),
	.osd_fm_vol(osd_fm_vol),
	.osd_adpcma_vol(osd_adpcma_vol),
	.osd_adpcmb_vol(osd_adpcmb_vol),
	.osd_psg_vol(osd_psg_vol),
	// Debug
	.dbg_z80_active(dbg_z80_active),
	.dbg_ym_active(dbg_ym_active),
	.dbg_syt_main_act(dbg_syt_main_act),
	.dbg_syt_z80_act(dbg_syt_z80_act),
	.dbg_audio_nonzero(dbg_audio_nonzero),
	// [SS] audio
	.ss_zram_cpu_we(ss_zram_cpu_we),
	.ss_zram_cpu_addr(ss_zram_cpu_addr),
	.ss_zram_cpu_wdata(ss_zram_cpu_wdata),
	.ss_zram_we(ss_zram_we),
	.ss_zram_addr(ss_zram_addr),
	.ss_zram_wdata(ss_zram_wdata),
	.ss_zram_q(ss_zram_q),
	.ss_z80_out(ss_z80_out), .ss_z80_in(ss_z80_in), .ss_z80_wr(ss_z80_wr),
	.ss_amisc_out(ss_amisc_out), .ss_amisc_in(ss_amisc_in), .ss_amisc_ld(ss_amisc_ld),
	.ss_syt_out(ss_syt_out), .ss_syt_in(ss_syt_in), .ss_syt_ld(ss_syt_ld),
	.ss_ym_wr(ss_ym_wr), .ss_ym_a0(ss_ym_a0), .ss_ym_wdata(ss_ym_wdata),
	.ss_ce_ym(ss_ce_ym),
	.ss_ymrp_active(ss_ymrp_active), .ss_ymrp_cs(ss_ymrp_cs),
	.ss_ymrp_a0(ss_ymrp_a0), .ss_ymrp_data(ss_ymrp_data), .ss_ymrp_wr(ss_ymrp_wr)
);

// =====================================================================
// Debug assignments (placed here so all signals are declared)
// =====================================================================
assign dbg_bus_addr    = main_bus_addr;
assign dbg_bus_busy    = main_bus_busy;
assign dbg_ext_dtack_n = main_ext_dtack_n;

reg [14:0] vid_dbg_sc_latch;
reg        vid_dbg_sc_seen;
reg        vid_dbg_trom_seen;
reg [15:0] vid_dbg_vram_latch;
reg        vid_dbg_vram_seen;
always @(posedge clk) begin
	if (reset) begin
		vid_dbg_sc_latch  <= 15'd0;
		vid_dbg_sc_seen   <= 1'b0;
		vid_dbg_trom_seen <= 1'b0;
		vid_dbg_vram_latch <= 16'd0;
		vid_dbg_vram_seen  <= 1'b0;
	end else begin
		// Latch first SC with non-zero pixel (SC[3:0]!=0 = opaque)
		if (|scn0_sc[3:0]) begin
			vid_dbg_sc_latch <= scn0_sc;
			vid_dbg_sc_seen  <= 1'b1;
		end else if (!vid_dbg_sc_seen && |scn0_sc) begin
			// Fallback: latch any non-zero SC if no opaque pixel seen yet
			vid_dbg_sc_latch <= scn0_sc;
		end
		if (scn0_rom_req) vid_dbg_trom_seen <= 1'b1;
		// Latch first non-zero tile code read from VRAM by TC0100SCN
		if (!vid_dbg_vram_seen && |scn0_ram_dout) begin
			vid_dbg_vram_latch <= scn0_ram_dout;
			vid_dbg_vram_seen  <= 1'b1;
		end
	end
end
// Count SCN0 CPU write events (CS asserted + write)
reg [15:0] vid_dbg_scn0_wr_cnt;
reg        vid_dbg_scn0_cs_prev;
always @(posedge clk) begin
	if (reset) begin
		vid_dbg_scn0_wr_cnt  <= 16'd0;
		vid_dbg_scn0_cs_prev <= 1'b1;
	end else begin
		vid_dbg_scn0_cs_prev <= scn0_cs_n;
		// Count falling edge of SCN0 CS with RW=0 (write)
		if (~scn0_cs_n & vid_dbg_scn0_cs_prev & ~scn0_rnw)
			vid_dbg_scn0_wr_cnt <= vid_dbg_scn0_wr_cnt + 1'd1;
	end
end

// Count vblank IRQ assertions
reg [15:0] vid_dbg_irq_cnt;
reg        vid_dbg_irq_prev;
always @(posedge clk) begin
	if (reset) begin
		vid_dbg_irq_cnt  <= 16'd0;
		vid_dbg_irq_prev <= 1'b0;
	end else begin
		vid_dbg_irq_prev <= gen_vblank_irq.main_irq4_pending;
		if (gen_vblank_irq.main_irq4_pending & ~vid_dbg_irq_prev)
			vid_dbg_irq_cnt <= vid_dbg_irq_cnt + 1'd1;
	end
end

assign dbg_scn0_sc          = vid_dbg_sc_latch;
// CW display: [15:8]=irq_count, [7:0]=iack_count
// If IRQ grows but IACK doesn't = CPU not acknowledging interrupts
reg [7:0] vid_dbg_iack_cnt;
reg       vid_dbg_iack_prev;
always @(posedge clk) begin
	if (reset) begin
		vid_dbg_iack_cnt  <= 8'd0;
		vid_dbg_iack_prev <= 1'b0;
	end else begin
		vid_dbg_iack_prev <= main_iack;
		if (main_iack & ~vid_dbg_iack_prev)
			vid_dbg_iack_cnt <= vid_dbg_iack_cnt + 1'd1;
	end
end
assign dbg_scn0_wr_cnt = {vid_dbg_irq_cnt[7:0], vid_dbg_iack_cnt};
assign dbg_scn0_sc_seen     = vid_dbg_sc_seen;
assign dbg_tilerom_req_seen = vid_dbg_trom_seen;

// dbg_d6/d7 are driven by the main cpu_node instance via its new output ports.
// See u_main_cpu port connections below.


// ============================================================================
// [SS] Driver 68000 — pausa sicura e cattura dei registri.
// Meccanismo (Martin Donlon / wickerwaka, F2): forza IPL7; la CPU completa
// l'istruzione in corso, poi esegue un mini-handler iniettato sul bus che con
// movem.l spinge d0-d7/a0-a6 sul proprio stack (work RAM, gia' nel savestate)
// e scrive l'SSP in uno scratch intercettato. Al restore: reset con vettore
// custom, il handler riparte e fa rte. Nessuna lettura di stato interno CPU.
// ============================================================================
ss_m68k #(.SS_GLOB_IDX(SS_IDX_GLOB)) u_ss_m68k (
	.clk(clk), .ce_cpu(1'b1),
	.cpu_word_addr(main_bus_addr),
	.cpu_ds_n(main_bus_dsn),
	.cpu_rw(main_bus_rnw),
	.cpu_fc(main_cpu_fc),
	.iack_n(~main_iack),
	.cpu_data_out(main_bus_dout),
	.do_save(ss_save), .do_restore(ss_load),
	.paused_real(paused_safe),          // gia' allineato al vblank
	.ss_mem_write(ss_do_save), .ss_mem_read(ss_do_load),
	.ss_busy(ss_busy),
	.ss_glob(ssb[SS_IDX_GLOB]),
	.ss_din_en(ss_din_en), .ss_din_data(ss_din_data),
	.ss_irq(ss_irq68), .ss_reset(ss_reset68),
	.ss_pause(ss_pause68), .ss_cpu_exec(ss_cpu_exec68),
	.ss_restore_done(), .ss_state_out()
);

// ============================================================================
// [SS] Infrastruttura savestate — mux, streamer verso DDR3 e gate del bus.
// ============================================================================
wire [7:0]  game_DDRAM_BURSTCNT;
wire [28:0] game_DDRAM_ADDR;
wire        game_DDRAM_RD;
wire [63:0] game_DDRAM_DIN;
wire [7:0]  game_DDRAM_BE;
wire        game_DDRAM_WE;
wire        ss_hold, ss_ddr_grant;

// Adattamento di asuka_ddram (che parla in pin DDRAM_*) al ddr_if del mux.
// addr del ddr_if e' un indirizzo di BYTE, DDRAM_ADDR e' a parole da 64 bit:
// qui si rimettono i 3 bit bassi e il gate poi rifa addr[31:3]. `acquire` e'
// ss_want: quando il gioco non ha niente in ballo lascia il bus al rotate.
assign ddr_game.addr       = {game_DDRAM_ADDR, 3'b0};   // 29+3 = 32 esatti
assign ddr_game.wdata      = game_DDRAM_DIN;
assign ddr_game.read       = game_DDRAM_RD;
assign ddr_game.write      = game_DDRAM_WE;
assign ddr_game.burstcnt   = game_DDRAM_BURSTCNT;
assign ddr_game.byteenable = game_DDRAM_BE;
assign ddr_game.acquire    = game_ddr_want;

asuka_rotate_fifo u_rot_fifo (
	.clk      (clk),
	.rot_addr (rot_addr),
	.rot_data (rot_data),
	.rot_be   (rot_be),
	.rot_we   (rot_we),
	.ddr      (ddr_rot)
);

asuka_ddr_mux u_ddr_mux (
	.clk     (clk),
	.ss_hold (ss_hold),   // durante il savestate blocca i client alla sorgente
	.x       (ddr_host),
	.a       (ddr_game),
	.b       (ddr_rot)
);

// Ritorni dai pin verso l'uscita del mux.
assign ddr_host.rdata       = DDRAM_DOUT;
assign ddr_host.rdata_ready = ss_ddr_grant ? 1'b0 : DDRAM_DOUT_READY;
assign ddr_host.busy        = (ss_ddr_grant | ss_hold) ? 1'b1 : DDRAM_BUSY;

ddr_if ss_ddr();
assign ss_ddr.rdata       = DDRAM_DOUT;
assign ss_ddr.rdata_ready = DDRAM_DOUT_READY & ss_ddr_grant;
assign ss_ddr.busy        = DDRAM_BUSY | ~ss_ddr_grant;
wire   ss_tx_inflight     = ss_ddr.read | ss_ddr.write;

// Pausa: il savestate chiede la pausa, Template la fa passare da paused_safe
// (che cambia solo sul rising edge del vblank) -> congelamento a confine di frame.
// La pausa resta alta anche durante la rigiocata dei registri del YM: le CPU
// devono stare ferme finche' l'iniettore non ha finito.
assign ss_pause_req = ss_pause68 | ss_ym_replay_busy;

ss_ddr_gate #(.AW(29), .DRAIN_TH(3)) u_ss_ddr_gate (
	.clk(clk), .reset(reset),
	.ss_busy(ss_busy), .ss_tx_inflight(ss_tx_inflight),
	// master GIOCO = uscita del mux (asuka_ddram e rotate gia' arbitrati)
	.game_burstcnt(ddr_host.burstcnt), .game_addr(ddr_host.addr[31:3]),
	.game_rd(ddr_host.read), .game_din(ddr_host.wdata),
	.game_be(ddr_host.byteenable), .game_we(ddr_host.write),
	.ss_burstcnt(ss_ddr.burstcnt), .ss_addr(ss_ddr.addr[31:3]),
	.ss_rd(ss_ddr.read), .ss_din(ss_ddr.wdata),
	.ss_be(ss_ddr.byteenable), .ss_we(ss_ddr.write),
	.DDRAM_BUSY(DDRAM_BUSY),
	.DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
	.DDRAM_RD(DDRAM_RD), .DDRAM_DIN(DDRAM_DIN),
	.DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE),
	.ss_hold(ss_hold), .ss_ddr_grant(ss_ddr_grant)
);

// ---------------------------------------------------------------------
// [SS] audio: RAM sonora, registri Z80, banco, handshake del SYT.
// La RAM passa per l'adattatore (in gioco e' un passaggio diretto); gli
// altri tre sono registri e usano auto_save_adaptor. Il salvataggio
// avviene a CPU ferme, fra un colpo di clock enable e l'altro.
// ---------------------------------------------------------------------
wire        ss_zram_cpu_we;
wire [12:0] ss_zram_cpu_addr;
wire  [7:0] ss_zram_cpu_wdata;
wire        ss_zram_we;
wire [12:0] ss_zram_addr;
wire  [7:0] ss_zram_wdata;
wire  [7:0] ss_zram_q;
ss_ram_adaptor #(.WIDTH(8), .WIDTHAD(13), .SS_IDX(SS_IDX_ZRAM)) u_ss_zram (
	.clk(clk),
	.wren_in(ss_zram_cpu_we), .addr_in(ss_zram_cpu_addr), .wdata_in(ss_zram_cpu_wdata),
	.wren_out(ss_zram_we),    .addr_out(ss_zram_addr),    .wdata_out(ss_zram_wdata),
	.q_in(ss_zram_q),
	.ssbus(ssb[SS_IDX_ZRAM])
);

wire [357:0] ss_z80_out, ss_z80_in;
wire         ss_z80_wr;
auto_save_adaptor #(.N_BITS(358), .SS_IDX(SS_IDX_Z80)) u_ss_z80 (
	.clk(clk), .ssbus(ssb[SS_IDX_Z80]),
	.bits_in(ss_z80_out), .bits_out(ss_z80_in), .bits_wr(ss_z80_wr)
);

wire [31:0] ss_amisc_out, ss_amisc_in;
wire        ss_amisc_ld;
auto_save_adaptor #(.N_BITS(32), .SS_IDX(SS_IDX_AMISC)) u_ss_amisc (
	.clk(clk), .ssbus(ssb[SS_IDX_AMISC]),
	.bits_in(ss_amisc_out), .bits_out(ss_amisc_in), .bits_wr(ss_amisc_ld)
);

// Handshake del PC060HA: e' il chip di comunicazione col sonoro della
// famiglia Asuka (su Bonze c'e' il TC0140SYT qui sopra).
wire [45:0] ss_pc060_out, ss_pc060_in;
wire        ss_pc060_ld;
auto_save_adaptor #(.N_BITS(46), .SS_IDX(SS_IDX_PC060)) u_ss_pc060 (
	.clk(clk), .ssbus(ssb[SS_IDX_PC060]),
	.bits_in(ss_pc060_out), .bits_out(ss_pc060_in), .bits_wr(ss_pc060_ld)
);

wire [48:0] ss_syt_out, ss_syt_in;
wire        ss_syt_ld;
auto_save_adaptor #(.N_BITS(49), .SS_IDX(SS_IDX_SYT)) u_ss_syt (
	.clk(clk), .ssbus(ssb[SS_IDX_SYT]),
	.bits_in(ss_syt_out), .bits_out(ss_syt_in), .bits_wr(ss_syt_ld)
);

// Ombra dei registri del YM2151: si intercettano le scritture, si salvano, e
// al ricaricamento un iniettore le rigioca sul chip con le CPU ferme. Cosi'
// tornano a posto anche CT1/CT2 (registro 0x1B), che su queste schede
// scelgono il banco della ROM sonora.
wire        ss_ym_wr, ss_ym_a0, ss_ce_ym;
wire  [7:0] ss_ym_wdata;
wire        ss_ymrp_active, ss_ymrp_cs, ss_ymrp_a0, ss_ymrp_wr;
wire  [7:0] ss_ymrp_data;
wire        ss_ym_replay_busy;
ss_ym2151_shadow #(.SS_IDX_SH(SS_IDX_YMSH)) u_ss_ymsh (
	.clk(clk), .reset(reset), .ce_ym(ss_ce_ym),
	.ym_wr(ss_ym_wr), .a0(ss_ym_a0), .wdata(ss_ym_wdata),
	.ss_mem_read(ss_do_load), .replay_busy(ss_ym_replay_busy),
	.rp_active(ss_ymrp_active), .rp_cs(ss_ymrp_cs), .rp_a0(ss_ymrp_a0),
	.rp_data(ss_ymrp_data), .rp_wr(ss_ymrp_wr),
	.ssb(ssb[SS_IDX_YMSH])
);

ssbus_mux #(.COUNT(SS_NSLAVES)) u_ss_mux (
	.clk(clk), .slave(ssbus), .masters(ssb)
);

save_state_data #(.COUNT(SS_NSLAVES)) u_save_state (
	.clk(clk), .reset(reset),
	.ddr(ss_ddr),
	.read_start(ss_do_load), .write_start(ss_do_save),
	.index(ss_slot),
	.busy(ss_busy), .slot_empty(),
	.ssbus(ssbus)
);

endmodule
