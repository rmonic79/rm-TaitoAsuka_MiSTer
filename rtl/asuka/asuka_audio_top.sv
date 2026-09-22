/*  This file is part of Darius_MiSTer.
    GPL-3.
    Author: Umberto Parisi (rmonc79)
*/

// asuka_audio_top — sottosistema audio Darius II / Ninja Warriors.
// Tutto su DDRAM HPS via modulo asuka_ddram (Sorgelig pattern, NeoGeo-style).
//
// MRA Darius II / Ninja Warriors layout ioctl:
//   0x120000-0x13FFFF: Z80 ROM (128 KB) → DDRAM byte addr 0x000000 (offset Z80 ROM)
//   0x440000-0x5BFFFF: ADPCM-A (1.5 MB) → DDRAM byte addr 0x100000
//   0x5C0000-0x63FFFF: ADPCM-B (512 KB) → DDRAM byte addr 0x300000

module asuka_audio_top (
	input  wire        clk,         // 96 MHz (sys clk)
	input  wire        ddram_clk,   // DDRAM clock (da sysmem)
	input  wire        reset,
	input  wire        pause,

	// ioctl per write DDRAM (Z80 ROM + ADPCM A + B)
	input  wire        ioctl_download,
	input  wire        ioctl_wr,
	input  wire [26:0] ioctl_addr,
	input  wire [15:0] ioctl_dout,
	input  wire [15:0] ioctl_index,
	output wire        ioctl_wait,

	// Comunicazione main 68000 ↔ TC0140SYT
	input  wire  [3:0] main_din,
	output wire  [3:0] main_dout,
	input  wire        main_a1,
	input  wire        main_cs_n,
	input  wire        main_wr_n,
	input  wire        main_rd_n,

	// DDRAM HPS pin (passa a asuka_ddram)
	input  wire        DDRAM_BUSY,
	output wire  [7:0] DDRAM_BURSTCNT,
	output wire [28:0] DDRAM_ADDR,
	input  wire [63:0] DDRAM_DOUT,
	input  wire        DDRAM_DOUT_READY,
	output wire        DDRAM_RD,
	output wire [63:0] DDRAM_DIN,
	output wire  [7:0] DDRAM_BE,
	output wire        DDRAM_WE,
	// 1 = il master DDRAM ha una transazione in ballo. Va al ddr_mux come
	// 'acquire': quando e' 0 il bus puo' passare al rotate.
	output wire        ddr_want,

	// 1 = il set monta l'MSM5205 (asuka, galmedes, earthjkr, mofflott).
	// Su cadash, eto e bonzeadv il decode $B000/$C000/$D000 resta spento.
	input  wire        msm_enable,
	// Bonze Adventure: YM2610 al posto di YM2151+MSM5205, TC0140SYT a E200 e
	// map Z80 sua (RAM a C000, YM a E000, banco scritto a F200).
	input  wire        cfg_bonze,

	// Sprite ROM read port (DDRAM port 4, 32-bit). Esposto al top per
	// alimentare lo sprite_rom_cache senza istanziarlo qui dentro.
	input  wire [27:0] spr_rdaddr,
	output wire [31:0] spr_dout,
	input  wire        spr_rd_req,
	output wire        spr_rd_ack,

	// Sprite ROM download path (separato da audio): il top si occupa di
	// gestire ioctl per sprite ROM e ce lo passa qui. Quando spr_we_req !=
	// spr_we_ack viene applicato. ddr_waddr/data interni audio_top tengono
	// la priorità solo se nessun audio download attivo.
	input  wire [27:0] spr_we_addr,
	input  wire [15:0] spr_we_data,
	input  wire        spr_we_req,
	output wire        spr_we_ack,

	// Audio output
	output wire signed [15:0] audio_l,
	output wire signed [15:0] audio_r,
	// ADPCM-A drum/percussion tap (output diretto jt10, già registrato) per beat LED
	output wire signed [15:0] adpcma_tap_l,
	output wire signed [15:0] adpcma_tap_r,
	// FM tap (FM senza PSG, registrato dentro jt10) per beat LED secondario
	output wire signed [15:0] fm_tap_l,
	output wire signed [15:0] fm_tap_r,

	// Audio mixer OSD volumes (3-bit each).
	// Mappa sel → fattore in 1/8: 0=8 (100%), 1=1 (12%), 2=2 (25%), 3=4 (50%),
	//                              4=6 (75%), 5=12 (150%), 6=16 (200%), 7=0 (mute)
	input  wire [2:0] osd_fm_vol,
	input  wire [2:0] osd_adpcma_vol,
	input  wire [2:0] osd_adpcmb_vol,
	input  wire [2:0] osd_psg_vol,

	// Debug counters (per LED visibility)
	output wire        dbg_z80_active,    // toggle se Z80 emette M1 (boot OK)
	output wire        dbg_ym_active,     // toggle se Z80 scrive YM (suoni)
	output wire        dbg_syt_main_act,  // toggle se main 68k tocca SYT
	output wire        dbg_syt_z80_act,   // toggle se Z80 tocca SYT (slave port)
	output wire        dbg_audio_nonzero, // 1 se jt10_left|jt10_right != 0 di recente

	// [SS] savestate dell'audio, stesso impianto di Darius 2.
	// RAM sonora: la porta di scrittura esce di qui e il top ci mette in mezzo
	// l'adattatore; in gioco e' un passaggio diretto.
	output wire        ss_zram_cpu_we,
	output wire [12:0] ss_zram_cpu_addr,
	output wire  [7:0] ss_zram_cpu_wdata,
	input  wire        ss_zram_we,
	input  wire [12:0] ss_zram_addr,
	input  wire  [7:0] ss_zram_wdata,
	output wire  [7:0] ss_zram_q,
	// Z80: registri interni del tv80s (358 bit)
	output wire [357:0] ss_z80_out,
	input  wire [357:0] ss_z80_in,
	input  wire         ss_z80_wr,
	// voce misc, 32 bit: banco della ROM sonora piu' lo stato dell'MSM5205
	// (posizione nel campione, nibble, byte in corso, marcia). Senza questo
	// un campione in riproduzione ripartiva a caso dopo il ricaricamento.
	output wire  [31:0] ss_amisc_out,
	input  wire  [31:0] ss_amisc_in,
	input  wire         ss_amisc_ld,
	// handshake del TC0140SYT (49 bit)
	output wire  [48:0] ss_syt_out,
	input  wire  [48:0] ss_syt_in,
	input  wire         ss_syt_ld,
	// ombra dei registri del YM2151: intercettazione verso il modulo,
	// iniettore dal modulo, e il tick a cui il chip campiona la scrittura
	output wire        ss_ym_wr,
	output wire        ss_ym_a0,
	output wire  [7:0] ss_ym_wdata,
	output wire        ss_ce_ym,
	input  wire        ss_ymrp_active,
	input  wire        ss_ymrp_cs,
	input  wire        ss_ymrp_a0,
	input  wire  [7:0] ss_ymrp_data,
	input  wire        ss_ymrp_wr
);

// Offset DDRAM byte (interno al modulo asuka_ddram → addr 28-bit, prefisso 0011 lo aggiunge ddram)
localparam [27:0] DDR_Z80_ROM_OFF  = 28'h0000000;  // 128 KB
localparam [27:0] DDR_ADPCMA_OFF   = 28'h0100000;  // 1.5 MB
localparam [27:0] DDR_ADPCMB_OFF   = 28'h0300000;  //  512 KB
localparam [27:0] DDR_SPRITE_OFF   = 28'h0400000;  //  2 MB sprite ROM (esposto al top)

// =====================================================================
// Clock enables (96 MHz / N) — pattern Darius1 con T80pa CEN_p/CEN_n
// + ce_12m separato per TC0140SYT
// =====================================================================
reg [6:0] ce_z80_cnt;
reg [3:0] ym_div;
reg [2:0] ce12_div;
wire ce_z80_p_raw = (ce_z80_cnt == 7'd23);  // 96/24 = 4 MHz
wire ce_z80_n_raw = (ce_z80_cnt == 7'd11);  // 96/24 = 4 MHz, mezza fase
wire ce_z80_p = ce_z80_p_raw & ~pause;
wire ce_z80_n = ce_z80_n_raw & ~pause;
// Durante la rigiocata dei registri il chip deve campionare, quindi il suo
// clock resta vivo anche in pausa. Lo Z80 invece resta fermo.
wire ce_ym    = (ym_div == 4'd0) & (~pause | ss_ymrp_active);  // 96/12 = 8 MHz
wire ce_12m   = (ce12_div == 3'd0) & ~pause;   // 96/8 = 12 MHz (TC0140SYT)

always @(posedge clk) begin
	if (reset) begin
		ce_z80_cnt <= 0;
		ym_div     <= 0;
		ce12_div   <= 0;
	end else begin
		ce_z80_cnt <= ce_z80_p_raw ? 7'd0 : ce_z80_cnt + 7'd1;
		ym_div     <= (ym_div   == 4'd11) ? 4'd0 : ym_div   + 4'd1;
		ce12_div   <= (ce12_div == 3'd7)  ? 3'd0 : ce12_div + 3'd1;
	end
end

// =====================================================================
// Z80 (T80s)
// =====================================================================
wire [15:0] z80_addr;
wire  [7:0] z80_dout;
reg   [7:0] z80_din;
wire z80_m1_n, z80_mreq_n, z80_iorq_n, z80_rd_n, z80_wr_n;
wire z80_int_n;
wire z80_wait_n_rom;

wire z80_rfsh_n;
wire syt_nmi_n;
// [SS] Z80 = tv80s, che ha le porte auto_ss per il savestate (il T80pa non
// le ha). Stessa scelta di Darius 2 e Guardian. Un solo clock enable:
// ce_z80_p, che avanza uno stato T per colpo.
//
// [NMI] il tv80s riarma il rivelatore di fronte dell'NMI solo se vede la
// linea ALTA durante un colpo di ce_z80_p, mentre il T80pa lo faceva a clock
// pieno. Senza allungare la fase alta, due NMI ravvicinati del 68000 si
// perdono e con loro i comandi musicali. Stesso rimedio di Darius 2.
reg nmi_rearm_pend;
always @(posedge clk) begin
	if (reset)          nmi_rearm_pend <= 1'b0;
	else if (syt_nmi_n) nmi_rearm_pend <= 1'b1;
	else if (ce_z80_p)  nmi_rearm_pend <= 1'b0;
end
wire syt_nmi_n_stretched = syt_nmi_n | nmi_rearm_pend;
tv80s u_z80 (
	.reset_n (~reset),
	.clk     (clk),
	.cen     (ce_z80_p),
	.wait_n  (z80_wait_n_rom),
	.int_n   (z80_int_n),
	.nmi_n   (syt_nmi_n_stretched),
	.busrq_n (1'b1),
	.m1_n    (z80_m1_n),
	.mreq_n  (z80_mreq_n),
	.iorq_n  (z80_iorq_n),
	.rd_n    (z80_rd_n),
	.wr_n    (z80_wr_n),
	.rfsh_n  (z80_rfsh_n),
	.halt_n  (),
	.busak_n (),
	.A       (z80_addr),
	.di      (z80_din),
	.dout    (z80_dout),
	.auto_ss_in  (ss_z80_in),
	.auto_ss_out (ss_z80_out),
	.auto_ss_wr  (ss_z80_wr)
);

// =====================================================================
// Sound RAM: 4 KB a 0x8000-0x8FFF (Cadash e famiglia asuka), 8 KB a
// 0xC000-0xDFFF su Bonze (bonzeadv_state::z80_map). Il blocco e' uno solo,
// da 8 KB: sui set piccoli la meta' alta resta inutilizzata.
// =====================================================================
wire sram_sel = cfg_bonze ? (z80_addr[15:13] == 3'b110)
                          : (z80_addr[15:12] == 4'h8);
wire [12:0] sram_addr = cfg_bonze ? z80_addr[12:0] : {1'b0, z80_addr[11:0]};
wire sram_we  = sram_sel & ~z80_mreq_n & ~z80_wr_n & z80_rfsh_n;
reg [7:0] sound_ram [0:8191];
reg [7:0] sram_q;
// [SS] la porta di scrittura esce dal modulo: il top ci mette in mezzo
// l'adattatore del savestate e rimanda indietro i segnali lato RAM. In gioco
// e' un passaggio diretto. La scrittura si blocca in pausa perche' il tv80s,
// fermo col clock enable, lascia mreq_n/wr_n latchati e senza questo potrebbe
// restare alta a meta' scrittura mentre l'adattatore lavora.
assign ss_zram_cpu_we    = sram_we & ~pause;
assign ss_zram_cpu_addr  = sram_addr;
assign ss_zram_cpu_wdata = z80_dout;
assign ss_zram_q         = sram_q;
always @(posedge clk) begin
	if (ss_zram_we) sound_ram[ss_zram_addr] <= ss_zram_wdata;
	sram_q <= sound_ram[ss_zram_addr];
end

// =====================================================================
// ROM bank register Cadash (mask 0x03 = 4 banchi, da YM2151 CT1/CT2)
// MAME asuka.cpp:1202 ymsnd.port_write_handler().set_membank(m_audiobank).mask(0x03)
// → quando jt51 emette CT1/CT2, bank = {ct2, ct1}.
// =====================================================================
// Su Bonze il banco non viene dal chip sonoro ma da una scrittura del Z80 a
// 0xF200 (base_state::sound_bankswitch_w, mask 0x03): stessi 4 banchi.
reg [1:0] rom_bank;
wire bank_we_bonze = cfg_bonze & (z80_addr == 16'hF200) &
                     ~z80_mreq_n & ~z80_wr_n & z80_rfsh_n;
reg  bank_we_prev;
always @(posedge clk) begin
	if (reset) begin
		rom_bank     <= 2'd0;
		bank_we_prev <= 1'b0;
	end else if (ss_amisc_ld) begin
		rom_bank <= ss_amisc_in[1:0];    // [SS] ricarica, con le CPU ferme
	end else if (cfg_bonze) begin
		bank_we_prev <= bank_we_bonze;
		if (bank_we_bonze & ~bank_we_prev) rom_bank <= z80_dout[1:0];
	end else begin
		rom_bank <= {ym_ct2, ym_ct1};
	end
end
// [SS] banco + stato dell'MSM5205
assign ss_amisc_out = {msm_nib, msm_byte, msm_run, msm_ff, msm_pos, rom_bank};

// =====================================================================
// Z80 ROM addr Cadash (64KB = 4 banchi × 16KB)
// =====================================================================
//   0x0000-0x3FFF → fisso (banco 0)
//   0x4000-0x7FFF → banked, addr_rom[15:14] = rom_bank[1:0]
wire [15:0] rom_logical_addr =
	(z80_addr[15:14] == 2'b00) ? {2'd0, z80_addr[13:0]} :
	(z80_addr[15:14] == 2'b01) ? {rom_bank, z80_addr[13:0]} :
	16'd0;
wire rom_sel = (z80_addr[15] == 1'b0);

// Z80 ROM toggle req/ack (clock crossing tramite synch interno a asuka_ddram)
reg z80_rd_req;
wire z80_rd_ack;
wire [7:0] z80_rom_dout;
reg [15:0] z80_rom_addr_lat;

// Edge detect rising su z80_rom_rd_pulse: 1 toggle per accesso Z80 ROM.
// Il pulse dura ~24 cicli a 96 MHz (Z80 a 4 MHz), quindi prev cattura
// stabilmente il valore precedente e il rising edge e' netto.
reg z80_rom_rd_prev;
wire z80_rom_rd_pulse = rom_sel & ~z80_mreq_n & ~z80_rd_n & z80_rfsh_n;
always @(posedge clk) begin
	if (reset) begin
		z80_rd_req       <= 1'b0;
		z80_rom_rd_prev  <= 1'b0;
		z80_rom_addr_lat <= 16'd0;
	end else begin
		z80_rom_rd_prev <= z80_rom_rd_pulse;
		if (z80_rom_rd_pulse && !z80_rom_rd_prev) begin
			z80_rom_addr_lat <= rom_logical_addr;
			z80_rd_req       <= ~z80_rd_req;
		end
	end
end

// Pattern NeoGeo: wait_n = (req == ack), incondizionato.
// Quando Z80 idle req=ack → wait_n=1. Quando emette rd: edge → req toggla →
// stesso ciclo req!=ack → wait_n=0 → Z80 stalla. Ack arriva da DDRAM → wait_n=1.
assign z80_wait_n_rom = (z80_rd_req == z80_rd_ack);

// =====================================================================
// YM2151 (jt51) — Cadash z80_map 0x9000/0x9001
// Clock: 16/4 = 4 MHz (cen pulse), cen_p1 = 2 MHz (cen ogni 2)
// =====================================================================
// YM2151 a 0x9000-0x90FF (decode larga, MAME mappa solo 9000/9001).
// YM2610 di Bonze a 0xE000-0xE003, e sopra ci sta il TC0140SYT a E200:
// qui il decode deve essere stretto o se lo mangia.
wire ym_sel = cfg_bonze ? ((z80_addr[15:8] == 8'hE0) & (z80_addr[7:2] == 6'd0))
                        : (z80_addr[15:8] == 8'h90);
wire [7:0] ym51_dout, ym10_dout;
wire       ym51_irq_n, ym10_irq_n;
wire [7:0] ym_dout_w = cfg_bonze ? ym10_dout  : ym51_dout;
wire       ym_irq_n  = cfg_bonze ? ym10_irq_n : ym51_irq_n;
wire       ym_ct1, ym_ct2;
wire signed [15:0] jt51_xleft, jt51_xright;

// ce_ym genera 8 MHz (jt10). Per jt51 (YM2151 Cadash 4MHz):
//   cen     = 4 MHz pulse (= ce_ym diviso 2)
//   cen_p1  = 2 MHz pulse (= cen diviso 2)
// Contatore mod-4: bit 0 = toggle ogni ce_ym → ce_ym_4m attivo su bit 0 = 0.
//                  bit 1 = toggle ogni ce_ym_4m → ce_ym_2m attivo su bit 1 = 0.
reg [1:0] ym_div4;
always @(posedge clk) if (ce_ym) ym_div4 <= ym_div4 + 2'd1;
wire ce_ym_4m = ce_ym & (ym_div4[0] == 1'b0);  // 4 MHz: 1 ce_ym su 2
wire ce_ym_2m = ce_ym & (ym_div4 == 2'b00);    // 2 MHz: 1 ce_ym su 4

// [SS] scrittura vera verso il chip: e' quella che l'ombra deve ricordare.
wire ym51_cs   = ym_sel & ~z80_mreq_n & z80_rfsh_n & ~cfg_bonze;
assign ss_ym_wr    = ym51_cs & ~z80_wr_n;
assign ss_ym_a0    = z80_addr[0];
assign ss_ym_wdata = z80_dout;
assign ss_ce_ym    = ce_ym_4m;

jt51 u_jt51 (
	.rst    (reset),
	.clk    (clk),
	.cen    (ce_ym_4m),
	.cen_p1 (ce_ym_2m),
	.cs_n   (ss_ymrp_active ? ~ss_ymrp_cs : (~ym_sel | z80_mreq_n | ~z80_rfsh_n)),
	.wr_n   (ss_ymrp_active ? ~ss_ymrp_wr : z80_wr_n),
	.a0     (ss_ymrp_active ? ss_ymrp_a0  : z80_addr[0]),
	.din    (ss_ymrp_active ? ss_ymrp_data : z80_dout),
	.dout   (ym51_dout),
	.ct1    (ym_ct1),
	.ct2    (ym_ct2),
	.irq_n  (ym51_irq_n),
	.sample (),
	.left   (),
	.right  (),
	.xleft  (jt51_xleft),
	.xright (jt51_xright)
);

// =====================================================================
// YM2610 (jt10) — solo Bonze Adventure, z80_map 0xE000-0xE003
// =====================================================================
// Clock 16/2 = 8 MHz, che e' esattamente ce_ym (96/12).
//
// ADPCM-A: la scheda di Bonze NON monta la ROM del canale A (in MAME c'e'
// la sola regione ymsnd:adpcmb). Il bus A resta quindi senza lettore DDR e
// il dato torna FF, come leggere la regione vuota: il canale non viene mai
// suonato dal gioco. Il cliente DDR dell'ADPCM-A e' dell'MSM5205, che su
// Bonze non gira, e cosi' i due non si pestano i piedi.
// ADPCM-B: 512 KB, letti dal cliente DDR che era gia' cablato e inutilizzato.
wire [19:0] adpcma_addr_jt;
wire [3:0]  adpcma_bank_jt;
wire        adpcma_roe_n_jt;
wire [7:0]  adpcma_data_w = 8'hFF;   // niente ROM del canale A su questa scheda
wire [23:0] adpcmb_addr_jt;
wire        adpcmb_roe_n_jt;
wire [7:0]  adpcmb_data_w;

wire signed [15:0] jt10_left, jt10_right;
wire signed [15:0] jt10_adpcmA_l, jt10_adpcmA_r;
wire signed [15:0] jt10_adpcmB_l, jt10_adpcmB_r;
wire signed [15:0] jt10_fm_l, jt10_fm_r;   // FM + ADPCM senza PSG

jt10 u_jt10 (
	.rst    (reset),
	.clk    (clk),
	.cen    (ce_ym),
	.din    (z80_dout),
	.addr   (z80_addr[1:0]),
	.cs_n   (~ym_sel | z80_mreq_n | ~z80_rfsh_n | ~cfg_bonze),
	.wr_n   (z80_wr_n),
	.dout   (ym10_dout),
	.irq_n  (ym10_irq_n),
	.adpcma_addr  (adpcma_addr_jt),
	.adpcma_bank  (adpcma_bank_jt),
	.adpcma_roe_n (adpcma_roe_n_jt),
	.adpcma_data  (adpcma_data_w),
	.adpcmb_addr  (adpcmb_addr_jt),
	.adpcmb_roe_n (adpcmb_roe_n_jt),
	.adpcmb_data  (adpcmb_data_w),
	.psg_A(), .psg_B(), .psg_C(),
	.fm_snd(),
	.psg_snd(),
	.snd_left  (jt10_left),
	.snd_right (jt10_right),
	.snd_sample(),
	.ch_enable(6'b111111),
	.adpcmA_l_o(jt10_adpcmA_l),
	.adpcmA_r_o(jt10_adpcmA_r),
	.adpcmB_l_o(jt10_adpcmB_l),
	.adpcmB_r_o(jt10_adpcmB_r),
	.fm_snd_left_o (jt10_fm_l),
	.fm_snd_right_o(jt10_fm_r)
);

// Tap per il LED a battito: su Bonze arrivano dal YM2610, sugli altri set
// non c'e' un ADPCM separato e il FM e' quello del YM2151.
assign adpcma_tap_l = cfg_bonze ? jt10_adpcmA_l : 16'sd0;
assign adpcma_tap_r = cfg_bonze ? jt10_adpcmA_r : 16'sd0;
assign fm_tap_l     = cfg_bonze ? jt10_fm_l : jt51_xleft;
assign fm_tap_r     = cfg_bonze ? jt10_fm_r : jt51_xright;

// Cadash NON ha TC0060DCA (era Ninja Warriors specific). YM2151 stereo
// diretto da jt51.xleft / xright.

// Mixer TC0060DCA:
//   audio_l = (FM_only_l * pan_data[0] + ADPCM_l * pan_data[2]) / 256 + PSG_l
//   audio_r = (FM_only_r * pan_data[1] + ADPCM_r * pan_data[3]) / 256 + PSG_r
//
// FM_only = jt10.snd - ADPCM-A - ADPCM-B - PSG (estraggo FM puro da snd_left
// che ha tutto mixato). PSG resta non panneggiato (in MAME va al subwoofer
// mono, qui lo sommo a entrambi i canali).
//
// jt10_adpcm{A,B}_{l,r} sono signed 16-bit, jt10_left/right anche.
// jt10_psg e' 10-bit unsigned: in jt12_top:483 viene sommato a fm_snd come
// {1'b0, psg, 5'd0} = unsigned 16-bit (max 0x7FE0).
// =====================================================================
// Cadash mixer: YM2151 stereo diretto + OSD volume
// =====================================================================
// LUT volume OSD: 3-bit sel → fattore 5-bit in unita' di 1/8.
function [4:0] vol_lut;
	input [2:0] sel;
	case (sel)
		3'd0: vol_lut = 5'd8;
		3'd1: vol_lut = 5'd1;
		3'd2: vol_lut = 5'd2;
		3'd3: vol_lut = 5'd4;
		3'd4: vol_lut = 5'd6;
		3'd5: vol_lut = 5'd12;
		3'd6: vol_lut = 5'd16;
		3'd7: vol_lut = 5'd0;
		default: vol_lut = 5'd8;
	endcase
endfunction

wire [4:0] vol_fm = vol_lut(osd_fm_vol);
// osd_adpcma pilota l'MSM5205 (e' la voce ADPCM del driver). osd_adpcmb e
// osd_psg restano inutilizzati: nessun set di asuka.cpp ha quei blocchi.
wire [4:0] vol_msm = vol_lut(osd_adpcma_vol);

// Su Bonze la voce e' il YM2610, che esce gia' mixato (FM + ADPCM + PSG):
// la manopola FM dell'OSD agisce su tutto il chip, e le due voci ADPCM
// dell'OSD non hanno presa qui perche' l'MSM5205 su questa scheda non c'e'.
wire signed [15:0] ym_mix_l = cfg_bonze ? jt10_left  : jt51_xleft;
wire signed [15:0] ym_mix_r = cfg_bonze ? jt10_right : jt51_xright;

// FM × vol_fm: signed_16 * unsigned_5 = signed_21
wire signed [20:0] l_vol = ym_mix_l * $signed({1'b0, vol_fm});
wire signed [20:0] r_vol = ym_mix_r * $signed({1'b0, vol_fm});

// MSM5205: 12 bit segnati portati a 16, poi stesso percorso di volume del FM.
// In MAME lo YM2151 va sul bus a 0.25 e l'MSM a 0.5, cioe' l'ADPCM e' il
// doppio del FM; qui pero' il FM e' gia' a fondo scala, quindi raddoppiarlo
// significherebbe solo saturare. Li tengo allo stesso peso di fondo scala e
// il rapporto lo decide la voce ADPCM dell'OSD.
wire signed [11:0] msm_sample;
wire signed [15:0] msm_s16 = {msm_sample, 4'd0};
wire signed [20:0] m_vol = msm_s16 * $signed({1'b0, vol_msm});

// >>3 per /8 (compensa max vol = ×2). Saturate signed 16-bit.
function signed [15:0] sat16;
	input signed [20:0] v;
	if (v > $signed(21'sd32767))       sat16 = 16'sd32767;
	else if (v < $signed(-21'sd32768)) sat16 = -16'sd32768;
	else                                sat16 = v[15:0];
endfunction

// Somma FM + ADPCM a 22 bit, poi >>3 come prima. Su Cadash m_vol e' zero e
// il risultato e' identico bit per bit a quello di prima.
wire signed [21:0] mix_l = $signed({l_vol[20], l_vol}) + $signed({m_vol[20], m_vol});
wire signed [21:0] mix_r = $signed({r_vol[20], r_vol}) + $signed({m_vol[20], m_vol});

wire signed [20:0] sum_l = $signed({{2{mix_l[21]}}, mix_l[21:3]});
wire signed [20:0] sum_r = $signed({{2{mix_r[21]}}, mix_r[21:3]});

assign audio_l = sat16(sum_l);
assign audio_r = sat16(sum_r);

// =====================================================================
// MSM5205 ADPCM — famiglia Asuka (asuka, galmedes, earthjkr, mofflott).
//
// Cadash non monta il chip e il suo Z80 non scrive mai $B000/$C000/$D000,
// quindi il player resta fermo da solo: non serve nessun gate su game_id, e
// con msm_run basso l'uscita e' zero e il mixer non cambia di un bit.
//
// MAME msm_state (asuka.cpp), z80_map:
//   $B000 w -> pos = (pos & 0x00FF) | (data << 8)
//   $C000 w -> reset_w(0): parte. adpcm_ff = 0
//   $D000 w -> reset_w(1): ferma.  pos &= 0xFF00
// e a ogni VCK:
//   ff = !ff; select_w(ff); se ff -> ba_w(rom[pos]), pos++
// L'LS157 manda fuori il nibble alto con select=1 e quello basso con
// select=0, quindi l'ordine emesso e': alto(b0), basso(b0), alto(b1), ...
//
// La ROM ADPCM (64 KB) sta in DDRAM a DDR_ADPCMA_OFF, caricata dall'MRA a
// partire dal byte $440000 — il percorso di download esiste gia'.
// =====================================================================

// VCK 8 kHz: prescaler S48_4B su clock 384 kHz = 8000 Hz. Da 96 MHz: /12000.
reg [13:0] vck_div;
wire vck_ce = (vck_div == 14'd0) & ~pause;
always @(posedge clk) begin
	if (reset) vck_div <= 14'd0;
	else       vck_div <= (vck_div == 14'd11999) ? 14'd0 : vck_div + 14'd1;
end

// Decode Z80 (parziale, come sul PCB: $8000-$8FFF RAM, $9000 YM, $A000 CIU,
// $B000/$C000/$D000 liberi per l'MSM).
wire msm_wr_cycle = msm_enable & ~z80_mreq_n & ~z80_wr_n & z80_rfsh_n;
wire msm_addr_sel  = (z80_addr[15:12] == 4'hB) & msm_wr_cycle;
wire msm_start_sel = (z80_addr[15:12] == 4'hC) & msm_wr_cycle;
wire msm_stop_sel  = (z80_addr[15:12] == 4'hD) & msm_wr_cycle;

reg msm_addr_prev, msm_start_prev, msm_stop_prev;

reg         adpcma_rd_req = 1'b0;
wire        adpcma_rd_ack;
wire  [7:0] adpcma_dout_ddr;
reg  [27:0] adpcma_addr_lat = 28'd0;

reg [15:0] msm_pos;
reg        msm_ff;
reg        msm_run;
reg        msm_wait;      // lettura DDRAM in corso
reg  [7:0] msm_byte;
reg  [3:0] msm_nib;
reg        msm_nib_ce;


always @(posedge clk) begin
	if (reset) begin
		msm_pos        <= 16'd0;
		msm_ff         <= 1'b0;
		msm_run        <= 1'b0;
		msm_wait       <= 1'b0;
		msm_byte       <= 8'd0;
		msm_nib        <= 4'd0;
		msm_nib_ce     <= 1'b0;
		msm_addr_prev  <= 1'b0;
		msm_start_prev <= 1'b0;
		msm_stop_prev  <= 1'b0;
	end else begin
		msm_nib_ce     <= 1'b0;
		msm_addr_prev  <= msm_addr_sel;
		msm_start_prev <= msm_start_sel;
		if (ss_amisc_ld) begin   // [SS] ricarica dello stato del campione
			msm_pos  <= ss_amisc_in[17:2];
			msm_ff   <= ss_amisc_in[18];
			msm_run  <= ss_amisc_in[19];
			msm_byte <= ss_amisc_in[27:20];
			msm_nib  <= ss_amisc_in[31:28];
		end
		msm_stop_prev  <= msm_stop_sel;

		// Le scritture del Z80 durano decine di cicli a 96 MHz: fronte.
		if (msm_addr_sel  && !msm_addr_prev)  msm_pos[15:8] <= z80_dout;
		if (msm_start_sel && !msm_start_prev) begin
			msm_run <= 1'b1;
			msm_ff  <= 1'b0;
		end
		if (msm_stop_sel && !msm_stop_prev) begin
			msm_run      <= 1'b0;
			msm_pos[7:0] <= 8'd0;
			msm_wait     <= 1'b0;
		end

		if (msm_run && vck_ce) begin
			msm_ff <= ~msm_ff;
			if (!msm_ff) begin
				// ff passa a 1: byte nuovo, esce il nibble alto.
				adpcma_addr_lat <= DDR_ADPCMA_OFF + {12'd0, msm_pos};
				adpcma_rd_req   <= ~adpcma_rd_req;
				msm_pos         <= msm_pos + 16'd1;
				msm_wait        <= 1'b1;
			end else begin
				// ff passa a 0: nibble basso dello stesso byte.
				msm_nib    <= msm_byte[3:0];
				msm_nib_ce <= 1'b1;
			end
		end

		// Il byte torna dalla DDRAM: req == ack. Fra un VCK e l'altro ci sono
		// 125 us, la latenza DDRAM e' trascurabile.
		if (msm_wait && (adpcma_rd_req == adpcma_rd_ack)) begin
			msm_byte   <= adpcma_dout_ddr;
			msm_nib    <= adpcma_dout_ddr[7:4];
			msm_nib_ce <= 1'b1;
			msm_wait   <= 1'b0;
		end
	end
end

msm5205 u_msm5205 (
	.clk    (clk),
	.reset  (reset),
	.run    (msm_run),
	.nib_ce (msm_nib_ce),
	.nib    (msm_nib),
	.sample (msm_sample)
);

// Porta 3 (ADPCM-B): la usa il YM2610 di Bonze. Il chip tiene l'indirizzo
// stabile e lo cambia quando gli serve il byte dopo: la richiesta parte sul
// cambio di indirizzo, come faceva la versione Darius di questo modulo.
reg adpcmb_rd_req = 1'b0;
wire adpcmb_rd_ack;
wire [7:0] adpcmb_dout_ddr;
reg [27:0] adpcmb_addr_lat = 28'd0;
reg [23:0] adpcmb_addr_prev = 24'd0;
assign adpcmb_data_w = adpcmb_dout_ddr;
always @(posedge clk) begin
	if (reset) begin
		adpcmb_addr_lat  <= 28'd0;
		adpcmb_addr_prev <= 24'd0;
	end else begin
		adpcmb_addr_prev <= adpcmb_addr_jt;
		if (adpcmb_addr_jt != adpcmb_addr_prev) begin
			adpcmb_addr_lat <= DDR_ADPCMB_OFF + {4'd0, adpcmb_addr_jt};
			adpcmb_rd_req   <= ~adpcmb_rd_req;
		end
	end
end

// =====================================================================
// TC0140SYT (sound comm)
// =====================================================================
// Cadash z80_map 0xA000-0xA001 PC060HA slave (TC0140SYT compatible)
// PC060HA a 0xA000-0xA001 sugli altri set, TC0140SYT a 0xE200-0xE201 su
// Bonze: due indirizzi, stesso modulo.
wire syt_sel = (cfg_bonze ? (z80_addr[15:1] == 15'h7100)
                          : (z80_addr[15:8] == 8'hA0)) & ~z80_mreq_n;
wire [3:0] syt_z80_dout;

// TC0140SYT vuole anche ADPCM bus master (sdr_*), ma noi gestiamo ADPCM via
// ddram diretto. Lasciamo sdr_* tied a vuoto (TC0140SYT versione "passthrough").
wire [26:0] sdr_address_unused;
wire [15:0] sdr_data_unused = 16'd0;
wire        sdr_req_unused;
wire        sdr_ack_unused = 1'b0;

TC0140SYT u_syt (
	.clk(clk),
	.ce_12m(ce_12m),
	.ce_4m(ce_z80_p),
	.RESn(~reset),
	.MDin(main_din),
	.MDout(main_dout),
	.MA1(main_a1),
	.MCSn(main_cs_n),
	.MWRn(main_wr_n),
	.MRDn(main_rd_n),
	.slave_cs(syt_sel),
	.MREQn(z80_mreq_n),
	.RFSHn(z80_rfsh_n),
	.RDn(z80_rd_n),
	.WRn(z80_wr_n),
	.A(z80_addr),
	.Din(z80_dout[3:0]),
	.Dout(syt_z80_dout),
	.ROUTn(), .NMIn(syt_nmi_n), .ROMCS0n(), .ROMCS1n(), .RAMCSn(),
	.ROMA14(), .ROMA15(),
	.OPXn(),
	.YAOEn(adpcma_roe_n_jt),
	.YBOEn(adpcmb_roe_n_jt),
	.YAA({adpcma_bank_jt, adpcma_addr_jt}),
	.YBA(adpcmb_addr_jt),
	.YAD(),    // non usato (ADPCM A va via ddram diretto)
	.YBD(),    // non usato
	.CSAn(), .CSBn(),
	.IOA(), .IOC(),
	.sdr_address(sdr_address_unused),
	.sdr_data(sdr_data_unused),
	.sdr_req(sdr_req_unused),
	.sdr_ack(sdr_ack_unused),
	// [SS] handshake salvato e ricaricato dal top
	.ss_out(ss_syt_out), .ss_ld(ss_syt_ld), .ss_in(ss_syt_in)
);

// =====================================================================
// ioctl write DDRAM (Z80 ROM + ADPCM A + B)
// =====================================================================
wire is_rom_dl  = ioctl_download && (ioctl_index == 16'd0);
wire is_z80_dl  = is_rom_dl && (ioctl_addr >= 27'h120000) && (ioctl_addr < 27'h140000);
wire is_adpa_dl = is_rom_dl && (ioctl_addr >= 27'h440000) && (ioctl_addr < 27'h5C0000);
wire is_adpb_dl = is_rom_dl && (ioctl_addr >= 27'h5C0000) && (ioctl_addr < 27'h640000);
wire is_audio_dl = is_z80_dl | is_adpa_dl | is_adpb_dl;

wire [27:0] ddr_audio_waddr =
	is_z80_dl  ? (DDR_Z80_ROM_OFF + {1'b0, ioctl_addr - 27'h120000}) :
	is_adpa_dl ? (DDR_ADPCMA_OFF  + {1'b0, ioctl_addr - 27'h440000}) :
	is_adpb_dl ? (DDR_ADPCMB_OFF  + {1'b0, ioctl_addr - 27'h5C0000}) :
	28'd0;

// Audio side: rising edge ioctl_wr trasformato in toggle audio_we_req.
reg  audio_we_req = 1'b0;
reg  audio_we_ack_r = 1'b0;
reg  ioctl_wr_prev = 1'b0;
always @(posedge clk) begin
	ioctl_wr_prev <= ioctl_wr;
	if (ioctl_wr && !ioctl_wr_prev && is_audio_dl) audio_we_req <= ~audio_we_req;
end

// Sprite side: ack registrato per matching toggle protocol con il top.
reg  spr_we_ack_r = 1'b0;

// Mux write DDRAM: due client (audio + sprite). Una sola write a tempo.
// FSM: IDLE → grant client che ha pending → wait we_ack → ack client.
reg  we_req = 1'b0;
reg  we_pick_spr = 1'b0;
reg  [27:0] ddr_waddr;
reg  [15:0] ddr_wdata;
wire we_ack;
reg  we_active = 1'b0;

wire audio_pending = (audio_we_req != audio_we_ack_r);
wire spr_pending   = (spr_we_req   != spr_we_ack_r);

always @(posedge clk) begin
	if (!we_active) begin
		// IDLE: lancia se qualcuno ha pending
		if (audio_pending) begin
			ddr_waddr   <= ddr_audio_waddr;
			ddr_wdata   <= ioctl_dout;
			we_pick_spr <= 1'b0;
			we_req      <= ~we_req;
			we_active   <= 1'b1;
		end else if (spr_pending) begin
			ddr_waddr   <= spr_we_addr;
			ddr_wdata   <= spr_we_data;
			we_pick_spr <= 1'b1;
			we_req      <= ~we_req;
			we_active   <= 1'b1;
		end
	end else begin
		// Wait completion (we_ack si allinea a we_req)
		if (we_req == we_ack) begin
			if (we_pick_spr) spr_we_ack_r   <= ~spr_we_ack_r;
			else             audio_we_ack_r <= ~audio_we_ack_r;
			we_active <= 1'b0;
		end
	end
end

assign spr_we_ack = spr_we_ack_r;
// ioctl_wait alza durante audio download finche' write non completa
assign ioctl_wait = audio_pending;

// =====================================================================
// asuka_ddram (NeoGeo Sorgelig pattern)
//   Port write: ioctl
//   Port rd1:   Z80 ROM
//   Port rd2:   ADPCM A
//   Port rd3:   ADPCM B
//   Port cp:    non usato
// =====================================================================
asuka_ddram u_ddram (
	.ss_want (ddr_want),
	.DDRAM_CLK       (ddram_clk),
	.DDRAM_BUSY      (DDRAM_BUSY),
	.DDRAM_BURSTCNT  (DDRAM_BURSTCNT),
	.DDRAM_ADDR      (DDRAM_ADDR),
	.DDRAM_DOUT      (DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
	.DDRAM_RD        (DDRAM_RD),
	.DDRAM_DIN       (DDRAM_DIN),
	.DDRAM_BE        (DDRAM_BE),
	.DDRAM_WE        (DDRAM_WE),

	// Write port (ioctl audio + sprite muxati sopra)
	.wraddr  (ddr_waddr),
	.din     (ddr_wdata),
	.we_byte (1'b0),     // word write
	.we_req  (we_req),
	.we_ack  (we_ack),

	// Read port 1: Z80 ROM
	.rdaddr  ({11'd0, z80_rom_addr_lat}),
	.dout    (z80_rom_dout),
	.rd_req  (z80_rd_req),
	.rd_ack  (z80_rd_ack),

	// Read port 2: ADPCM A
	.rdaddr2 (adpcma_addr_lat),
	.dout2   (adpcma_dout_ddr),
	.rd_req2 (adpcma_rd_req),
	.rd_ack2 (adpcma_rd_ack),

	// Read port 3: ADPCM B
	.rdaddr3 (adpcmb_addr_lat),
	.dout3   (adpcmb_dout_ddr),
	.rd_req3 (adpcmb_rd_req),
	.rd_ack3 (adpcmb_rd_ack),

	// Read port 4: sprite ROM (32-bit fetch dal top)
	.rdaddr4 (spr_rdaddr),
	.dout4   (spr_dout),
	.rd_req4 (spr_rd_req),
	.rd_ack4 (spr_rd_ack),

	// Copy port (non usato)
	.cpaddr  (28'd0),
	.cpdout  (),
	.cpwr    (),
	.cpreq   (1'b0),
	.cpbusy  ()
);

// =====================================================================
// Z80 din mux
// =====================================================================
always @(*) begin
	z80_din = 8'hFF;
	if (rom_sel & ~z80_mreq_n & ~z80_rd_n) z80_din = z80_rom_dout;
	else if (sram_sel & ~z80_mreq_n & ~z80_rd_n) z80_din = sram_q;
	else if (ym_sel & ~z80_mreq_n & ~z80_rd_n) z80_din = ym_dout_w;
	else if (syt_sel & ~z80_rd_n) z80_din = {4'd0, syt_z80_dout};
end

assign z80_int_n = ym_irq_n;

// =====================================================================
// Debug counters: bit alto lampeggia se evento attivo (~3Hz)
// =====================================================================
reg [25:0] z80_active_cnt;
reg [25:0] ym_active_cnt;
reg [25:0] syt_main_cnt;
reg [25:0] syt_z80_cnt;
reg main_cs_n_d;
always @(posedge clk) begin
	main_cs_n_d <= main_cs_n;
	if (reset) begin
		z80_active_cnt <= 0;
		ym_active_cnt  <= 0;
		syt_main_cnt   <= 0;
		syt_z80_cnt    <= 0;
	end else begin
		if (~z80_m1_n & ~z80_mreq_n) z80_active_cnt <= z80_active_cnt + 1'd1;
		if (ym_sel & ~z80_mreq_n & ~z80_wr_n & z80_rfsh_n) ym_active_cnt <= ym_active_cnt + 1'd1;
		// Edge falling main_cs_n = main 68k apre transazione SYT
		if (main_cs_n_d & ~main_cs_n) syt_main_cnt <= syt_main_cnt + 1'd1;
		// Z80 access slave SYT (0xE200/0xE201)
		if ((z80_addr[15:8] == 8'hA0) & ~z80_mreq_n & (~z80_wr_n | ~z80_rd_n) & z80_rfsh_n)
			syt_z80_cnt <= syt_z80_cnt + 1'd1;
	end
end
assign dbg_z80_active   = z80_active_cnt[24];
assign dbg_ym_active    = ym_active_cnt[14];
assign dbg_syt_main_act = syt_main_cnt[10];
// dbg_syt_z80_act: latch sticky — alto se Z80 ha MAI scritto SYT slave dopo reset.
// Il firmware ninjaw abilita NMI con 1-2 write a 0xE200/0xE201 al boot, poi
// nessun altro tocca il SYT slave finche' non arriva NMI. Un counter su bit
// alto non lo vede. Latch sticky risolve.
reg syt_z80_seen;
always @(posedge clk) begin
	if (reset) syt_z80_seen <= 1'b0;
	else if ((z80_addr[15:8] == 8'hA0) & ~z80_mreq_n & (~z80_wr_n | ~z80_rd_n) & z80_rfsh_n)
		syt_z80_seen <= 1'b1;
end
assign dbg_syt_z80_act  = syt_z80_seen;

// Audio nonzero: tieni alto se jt51 ha emesso qualcosa negli ultimi ~1.4ms.
reg [16:0] audio_nz_decay;
always @(posedge clk) begin
	if (reset) audio_nz_decay <= 0;
	else if (jt51_xleft != 16'sd0 || jt51_xright != 16'sd0)
		audio_nz_decay <= 17'h1FFFF;
	else if (audio_nz_decay != 0)
		audio_nz_decay <= audio_nz_decay - 1'b1;
end
assign dbg_audio_nonzero = (audio_nz_decay != 0);

endmodule
