// Darius (Taito 1987) — MiSTer core
// Dual FX68K + Genesis SDRAM controller (3 ports)
// Based on MiSTer Template by Sorgelig

module emu
(
	input         CLK_50M,
	input         RESET,
	inout  [48:0] HPS_BUS,
	output        CLK_VIDEO,
	output        CE_PIXEL,
	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,
	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,
	output        VGA_F1,
	output [1:0]  VGA_SL,
	output        VGA_SCALER,
	output        VGA_DISABLE,

	// CRT Adjust (sys-side): valori dall'OSD + VBlank VERO, inoltrati agli stadi
	// crt_vsize / crt_adjust_sys che stanno in sys_top (solo ramo VGA analogico).
	output              CRT_ON,
	output signed [4:0] CRT_HSIZE,
	output signed [8:0] CRT_HPOS,
	output signed [5:0] CRT_VSHIFT,
	output signed [5:0] CRT_VSIZE,
	output              CRT_VSMODE,
	output              CRT_VBL,
	// Base del generatore di lettura CRT in sys_top, in OTTAVI di clk per pixel:
	// e' il periodo NATIVO del pixel (qui 14 clk x 8 = 112).
	output        [8:0] CRT_RD_BASE,
	// Pixel per riga del raster nativo (436): serve a sys_top per la
	// H-Position negativa di crt_adjust_sys.
	output        [9:0] CRT_HTOTAL,

	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,
	output        HDMI_BLACKOUT,
	output        HDMI_BOB_DEINT,

`ifdef MISTER_FB
	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output [11:0] FB_WIDTH,
	output [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,
`ifdef MISTER_FB_PALETTE
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,
`endif
`endif

	output        LED_USER,
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,
	output  [1:0] BUTTONS,

	input         CLK_AUDIO,
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,
	output  [1:0] AUDIO_MIX,

	inout   [3:0] ADC_BUS,

	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE,

`ifdef MISTER_DUAL_SDRAM
	input         SDRAM2_EN,
	output        SDRAM2_CLK,
	output [12:0] SDRAM2_A,
	output  [1:0] SDRAM2_BA,
	inout  [15:0] SDRAM2_DQ,
	output        SDRAM2_nCS,
	output        SDRAM2_nCAS,
	output        SDRAM2_nRAS,
	output        SDRAM2_nWE,
`endif

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,

	input   [6:0] USER_IN,
	output  [6:0] USER_OUT,

	input         OSD_STATUS
);

///////// Unused ports /////////
assign ADC_BUS  = 'Z;
assign {UART_RTS, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
// DDRAM HPS pilotato direttamente dal game (modulo darius2_ddram dentro audio_top)
assign DDRAM_CLK = clk_sys;

assign VGA_SL = 0;
assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
`ifdef MISTER_FB
// Le altre uscite FB_* le pilota screen_rotate in fondo al file; questa no,
// e senza un pilota resterebbe scollegata.
assign FB_FORCE_BLANK = 0;
`endif
assign VGA_DISABLE = 0;
// Pause: toggle on rising edge of joy[12] (standard MiSTer pause bit)
reg pause_toggle;
reg joy_pause_prev;
always @(posedge clk_sys) begin
	if (reset) begin
		pause_toggle <= 1'b0;
		joy_pause_prev <= 1'b0;
	end else begin
		joy_pause_prev <= joy0[12] | joy1[12];
		if ((joy0[12] | joy1[12]) && !joy_pause_prev)
			pause_toggle <= ~pause_toggle;
	end
end
// [SS] durante save/restore il gioco va fermato: ss_pause_req entra qui e passa
// da paused_safe nel core, che si aggiorna solo al rising edge del vblank.
wire pause = pause_toggle | ss_pause_req;
assign HDMI_FREEZE = 1'b0;  // overlay pause è renderizzato in real-time, no freeze scaler
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S = 1;  // signed audio
wire signed [15:0] game_audio_l, game_audio_r;
assign AUDIO_L = game_audio_l;
assign AUDIO_R = game_audio_r;
assign AUDIO_MIX = 0;

// ce_48k da clk_sys 96 MHz: divider /2000 = 48 kHz audio sample rate.
// Genero qui (semplice), il beat detector lavora con CE-gating → niente impatto timing.
reg [10:0] ce_48k_cnt;
wire       ce_48k = (ce_48k_cnt == 11'd0);
always @(posedge clk_sys) begin
	if (ce_48k_cnt == 11'd1999) ce_48k_cnt <= 11'd0;
	else                         ce_48k_cnt <= ce_48k_cnt + 11'd1;
end

// Beat detector dual-channel:
//   LED_USER ← FM tap (melodia/bassi BGM)
//   LED_DISK ← ADPCM-A tap (drum/percussion)
wire signed [15:0] adpcma_tap_l, adpcma_tap_r;
wire signed [15:0] fm_tap_l, fm_tap_r;
wire led_user_beat, led_disk_beat;
audio_beat_led u_beat (
	.clk           (clk_sys),
	.reset         (reset),
	.ce_48k        (ce_48k),
	.fm_l          (fm_tap_l),
	.fm_r          (fm_tap_r),
	.adpcma_l      (adpcma_tap_l),
	.adpcma_r      (adpcma_tap_r),
	.led_user_beat (led_user_beat),
	.led_disk_beat (led_disk_beat)
);

assign LED_DISK  = {1'b1, led_disk_beat};
assign LED_POWER = 0;
assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////

wire [1:0] ar = status[122:121];

// OSD layer offsets: 6-bit signed 2's complement, default 0 on reset
wire signed [9:0] osd_l0_xoff  = {{4{status[43]}}, status[43:38]};
wire signed [9:0] osd_l0_yoff  = {{4{status[49]}}, status[49:44]};
wire signed [9:0] osd_l1_xoff  = {{4{status[55]}}, status[55:50]};
wire signed [9:0] osd_l1_yoff  = {{4{status[61]}}, status[61:56]};
wire signed [9:0] osd_spr_xoff = {{4{status[67]}}, status[67:62]};
wire signed [9:0] osd_spr_yoff = {{4{status[73]}}, status[73:68]};
wire signed [9:0] osd_fg_xoff  = {{4{status[79]}}, status[79:74]};
wire signed [9:0] osd_fg_yoff  = {{4{status[85]}}, status[85:80]};

`include "build_id.v"
localparam CONF_STR = {
	"TaitoAsuka;SS3E000000:200000;",
	"-;",
	"O[108:105],Savestate Slot,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16;",
	"R[109],Save state (Alt-F1);",
	"R[110],Restore state (F1);",
	"-;",
	"P1,Video;",
	"P1O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"P1O[6:5],Scale,Normal,V-Integer,HV-Integer-,HV-Integer+;",
	"H1P1O[2:1],Rotate,Off,CCW,CW;",
	"H1P1O[3],Flip 180,Off,On;",
	"-;",
	"P1O[111],CRT Adjust,Off,On;",
	"H2P1O[116:112],CRT H-Size,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H2P1O[13:7],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,+32,+33,+34,+35,+36,+37,+38,+39,+40,+41,+42,+43,+44,+45,+46,+47,+48,-48,-47,-46,-45,-44,-43,-42,-41,-40,-39,-38,-37,-36,-35,-34,-33,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H2P1O[100:96],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H2P1O[104:101],CRT V-Size,0,+1,+2,+3,+4,+5,+6,+7,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H2P1O[117],CRT V-Size Mode,PVM,Cabinet;",
	"-;",
	"O[19],Clean Pause,Off,On;",
	"-;",
	"O[30],Layer BG0,On,Off;",
	"O[31],Layer BG1,On,Off;",
	"O[32],Sprite,On,Off;",
	"O[33],Layer FG0,On,Off;",
	"H3O[14],Sprite Timing,Sync,PCB;",
	"H0O[20],Link,Rete,SNAC;",
	"H0O[23:21],SNAC Wiring,Dritto,Incrociato,Senza pin 6,Tre fili,4 fili 0-1-3-4;",
	"-;",
	// Layer Offsets — slider OSD per centratura HW
	"P2,Layer Offsets;",
	"P2O[43:38],BG0 X offset,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"P2O[49:44],BG0 Y offset,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"P2O[55:50],BG1 X offset,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"P2O[61:56],BG1 Y offset,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"P2O[67:62],Sprite X offset,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"P2O[73:68],Sprite Y offset,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"P2O[79:74],FG X offset,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"P2O[85:80],FG Y offset,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"-;",
	"P3,Audio Mixer;",
	"P3O[88:86],FM volume,100%,12%,25%,50%,75%,150%,200%,Mute;",
	"P3O[91:89],ADPCM volume,100%,12%,25%,50%,75%,150%,200%,Mute;",
	"P3O[94:92],ADPCM-B volume,100%,12%,25%,50%,75%,150%,200%,Mute;",
	"P3O[95],PSG volume,Polite,MAME;",
	"-;",
	"DIP;",
	"-;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	"-;",
	"J1,Fire,Bomb,Start 1P,Start 2P,Coin;",
	"jn,A,B,Start,Select,R;",
	"V,v",`BUILD_DATE
};

wire forced_scandoubler;
wire  [1:0] buttons;
wire [127:0] status;
wire [10:0] ps2_key;
wire [15:0] joy0, joy1;
wire        ioctl_download;
wire [15:0] ioctl_index;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire [15:0] ioctl_dout;   // 16-bit: WIDE=1
wire        ioctl_wait_sdram;
wire        ioctl_wait_audio;
wire        ioctl_wait = ioctl_wait_sdram | ioctl_wait_audio;

// Multiplayer abilitato dall'MRA: dichiarato qui perche' serve gia' a hps_io
// per nascondere le voci OSD del link. Il latch sta piu' in basso, insieme a
// game_id, che arriva dalla stessa regione index=1.
reg link_mp = 1'b0;

// Orientamento del set: viene DICHIARATO dall'MRA, non dedotto dal game_id.
// E' il metodo di Guardian (board_tate <= ioctl_dout[8]): un bit esplicito,
// cosi' aggiungere un set non obbliga a rimettere mano a un intervallo di id.
// Qui sta nel byte 2 della regione index=1, perche' il byte 1 e' gia' di
// link_mp. Come per link_mp si pretende il valore esatto $01, cosi' un byte di
// riempimento ($00 o $FF) non puo' accenderlo per sbaglio.
// Dichiarato qui perche' serve gia' a hps_io per la menumask.
reg board_tate = 1'b0;

// Set in esecuzione: byte 0 della regione index=1 dell'MRA. Lo scrive il blocco
// che legge la regione di configurazione, piu' in basso. Sta qui perche' lo
// usano gia' la mappa dei tasti E la menumask (l'opzione Sprite Timing si
// mostra solo su Cadash).
reg [7:0] game_id = 8'h00;
wire cfg_cadash_osd = (game_id == 8'h00);

// Write del framebuffer prodotti da screen_rotate (istanziato in fondo al
// file): dichiarati qui perche' l'istanza di asuka_top, che li consuma, viene
// prima. Quartus pretende la dichiarazione prima dell'uso.
wire [28:0] rot_addr;
wire [63:0] rot_data;
wire  [7:0] rot_be;
wire        rot_we;

// Comandi della rotazione. Stanno qui e non accanto a screen_rotate perche'
// rotate_en serve anche all'aspect ratio, che viene prima nel file.
// status[2:1]: 00=Off, 01=CCW, 10=CW.  status[3] = Flip 180.
wire [1:0] rotate_sel = board_tate ? status[2:1] : 2'd0;
wire       rotate_en  = (rotate_sel != 2'd0);
wire       rotate_ccw = (rotate_sel == 2'd1);
wire       flip_180   = board_tate & status[3];
wire       video_rotated;

hps_io #(.CONF_STR(CONF_STR), .WIDE(1)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),
	.forced_scandoubler(forced_scandoubler),
	.buttons(buttons),
	.status(status),
	// H0 = le voci del link, nascoste quando l'MRA non abilita il multiplayer
	// H1 = le voci di rotazione, nascoste sui set orizzontali
	// H2: gruppo CRT Adjust visibile solo se On
	.status_menumask({12'd0, ~cfg_cadash_osd, ~status[111], ~board_tate, ~link_mp}),
	.ps2_key(ps2_key),
	.joystick_0(joy0),
	.joystick_1(joy1),
	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait)
);

// --- Ingressi del TC0220IOC, DISPOSIZIONE PER SET -------------------------
// Il set lo dice l'MRA nel byte 0 della regione index=1 (game_id), lo stesso
// che sceglie la mappa di memoria. Le due famiglie del driver asuka.cpp hanno
// disposizioni COMPLETAMENTE diverse: sbagliarle non sposta solo un tasto.
//
// Misurato su MAME 0.286 con le porte a riposo:
//                         IN0   IN1   IN2
//   cadash                FF    FF    FF
//   asuka & famiglia      FF    FF    CF   <- i bit 4 e 5 sono ATTIVI ALTI
//
// I due bit attivi alti di Asuka non sono un dettaglio: tenendoli a 1 il gioco
// non scrive un solo colore in palette e non arriva mai al suo cappio di
// riposo ($137E). Provato: forzando FF sull'IN2 di MAME si riproduce esatto lo
// schermo nero e muto, col programma che resta in $14xx come sulla MiSTer.
//
// MiSTer joy: [0]=R [1]=L [2]=D [3]=U [4]=BTN1 [5]=BTN2 [10]=START [11]=COIN
//
// Cadash (game_id 0) — CADASH_PLAYERS_INPUT / IN2:
//   IN0,IN1: 7=UP 6=DOWN 5=LEFT 4=RIGHT 3=BTN1 2=BTN2 1,0=liberi (1)
//   IN2:     0=COIN1 1=COIN2 2=START2 3=START1 4=SERVICE 5=TILT 6,7=liberi (1)
// Asuka, Maze of Flott, Galmedes, Earth Joker — TAITO_JOY_UDLR_2_BUTTONS / IN2:
//   IN0,IN1: 0=UP 1=DOWN 2=LEFT 3=RIGHT 4=BTN1 5=BTN2 6,7=liberi (1)
//   IN2:     0=TILT 1=SERVICE 2=COIN1 3=COIN2 4,5=ATTIVI ALTI (0)
//            6=START1 7=START2
wire cfg_in_cadash = (game_id == 8'h00);

wire [7:0] p1_cadash = {~joy0[3], ~joy0[2], ~joy0[1], ~joy0[0], ~joy0[4], ~joy0[5], 2'b11};
wire [7:0] p2_cadash = {~joy1[3], ~joy1[2], ~joy1[1], ~joy1[0], ~joy1[4], ~joy1[5], 2'b11};
wire [7:0] sys_cadash = {2'b11, 2'b11, ~joy0[10], ~joy1[10], ~joy1[11], ~joy0[11]};

wire [7:0] p1_asuka  = {2'b11, ~joy0[5], ~joy0[4], ~joy0[0], ~joy0[1], ~joy0[2], ~joy0[3]};
wire [7:0] p2_asuka  = {2'b11, ~joy1[5], ~joy1[4], ~joy1[0], ~joy1[1], ~joy1[2], ~joy1[3]};
wire [7:0] sys_asuka = {~joy1[10], ~joy0[10], 2'b00, ~joy1[11], ~joy0[11], 2'b11};

wire [7:0] p1_input     = cfg_in_cadash ? p1_cadash  : p1_asuka;
wire [7:0] p2_input     = cfg_in_cadash ? p2_cadash  : p2_asuka;
wire [7:0] system_input = cfg_in_cadash ? sys_cadash : sys_asuka;

// Bonze Adventure non ha il TC0220IOC: gli ingressi entrano nelle porte del
// microcontrollore del C-Chip, ed e' lui a metterli nella RAM condivisa che il
// 68000 legge. Disposizione dei bit dalle ioport di MAME (asuka.cpp:1106-1110):
//   PA  "800007": 5=START2 6=START1 7=SERVICE, attivi bassi
//   PB  "800009": 0=COIN1 1=COIN2, attivi ALTI e a impulso
//   PC  "80000B": 0=TILT 2=SU 3=GIU 4=SX 5=DX 6=TASTO1 7=TASTO2, attivi bassi
//   AN  "80000D": come PC ma per il secondo giocatore, sfalsato di un bit
//
// I coin sono l'unico punto delicato: in MAME hanno PORT_IMPULSE(1), cioe'
// valgono UN quadro e poi tornano a riposo anche se tieni premuto. Qui lo
// stesso, con un colpo di ~16,7 ms sul fronte di pressione.
reg  [20:0] coin1_imp = 21'd0, coin2_imp = 21'd0;
reg         coin1_prev = 1'b0, coin2_prev = 1'b0;
always @(posedge clk_sys) begin
	coin1_prev <= joy0[11];
	coin2_prev <= joy1[11];
	if (joy0[11] & ~coin1_prev)  coin1_imp <= 21'd1600000;
	else if (coin1_imp != 21'd0) coin1_imp <= coin1_imp - 21'd1;
	if (joy1[11] & ~coin2_prev)  coin2_imp <= 21'd1600000;
	else if (coin2_imp != 21'd0) coin2_imp <= coin2_imp - 21'd1;
end

wire [7:0] cchip_pa = {1'b1, ~joy0[10], ~joy1[10], 5'b11111};
wire [7:0] cchip_pb = {6'd0, (coin2_imp != 21'd0), (coin1_imp != 21'd0)};
wire [7:0] cchip_pc = {~joy0[5], ~joy0[4], ~joy0[0], ~joy0[1], ~joy0[2], ~joy0[3], 2'b11};
wire [7:0] cchip_an = {1'b1, ~joy1[5], ~joy1[4], ~joy1[0], ~joy1[1], ~joy1[2], ~joy1[3], 1'b1};

// DIP switches — loaded from MRA via ioctl (index 254)
// Active-LOW: default "FF,FF" = all OFF = all 1s
reg [15:0] dip_sw = 16'hFFFF;
always @(posedge clk_sys)
	if (ioctl_wr && (ioctl_index == 16'd254) && !ioctl_addr[26:1])
		dip_sw <= ioctl_dout;

// ---------------------------------------------------------------------------
//  Link fra due cabinati (Cadash) — il "cavo" passa dalla rete
// ---------------------------------------------------------------------------
// Sul cabinato i due Z180 sono uniti da quattro fili. Su MiSTer quei fili non
// escono dal case, quindi il collegamento passa dove i due MiSTer sono gia'
// collegati fra loro: la rete.
//
//   core FPGA --UART interna del SoC--> Linux (HPS) --Ethernet--> altro MiSTer
//
// La UART interna non e' un connettore e non ha pin: in sys_top.v e'
// `cyclonev_hps_interface_peripheral_uart`, che collega la UART del processore
// ARM direttamente al fabric. Lato Linux il MiSTer la sa gia' portare in rete
// (System Menu -> Uart Connection -> TCP).
//
// Il ruolo lo decide il dipswitch "Communication Mode" (DSWB bit 6-7), lo stesso
// che il gioco legge per scrivere 'M' o 'S' nella RAM condivisa:
//     bit 6 alto              -> Stand alone: il sotto-sistema resta spento
//     bit 6 basso, bit 7 alto -> Master
//     bit 6 basso, bit 7 basso-> Slave
// Il link vuole DUE consensi: l'MRA (byte 1 della regione index=1) e il
// dipswitch "Communication Mode" (DSWB bit 6). Senza il primo il core e'
// monogiocatore a tutti gli effetti: Z180 in reset, porta user a riposo,
// UART ferma e voci OSD nascoste.
wire link_attivo = ~dip_sw[14] & link_mp;

wire link_uart_txd;
assign UART_TXD = link_attivo ? link_uart_txd : 1'b1;
// SNAC oppure rete: l'opzione sta nell'OSD. I bit stanno nella zona libera
// 20..22: la 34..37 e' gia' presa da prio_mode (arbitro SDRAM) e z80_clk_sel,
// che non hanno voce nell'OSD ma leggono lo stesso quegli status.
wire link_snac = status[20];
wire [2:0] link_snac_cavo = status[23:21];

// Il link puo' passare dal connettore SNAC invece che dalla rete: la user port
// e' aperta al core, che decide lui cosa metterci. Se il link e' spento, oppure
// se passa dalla rete, tutte le linee restano a riposo.
wire [6:0] link_user_out;
assign USER_OUT = (link_attivo & link_snac) ? link_user_out : 7'b1111111;

// Game ID — dall'MRA, regione ioctl_index=1, byte 0.
// Sceglie di quale set del driver asuka.cpp il core deve fare le veci.
//   0x00 = Cadash          (IRQ4 + timer IRQ5 a 500 cicli, xBGR444, Z180 LAN)
//   0x01 = Asuka & Asuka   (IRQ5, xBGR555, MSM5205)
//   0x02 = Maze of Flott   (IRQ5, MSM5205, SCN offset 1)
//   0x03 = Galmedes        (IRQ5, MSM5205)
//   0x04 = Eto Monogatari  (IRQ5, niente MSM5205, SCN offset 1, mappa sua)
//   0x05 = Bonze Adventure (IRQ4, C-Chip, TC0140SYT)
//   0x06 = Earth Joker     (IRQ5, MSM5205)
// Questa numerazione e' quella di riferimento: la tabella in asuka_top.sv la
// segue. Default 0x00 = Cadash, cosi' ogni MRA che il byte non ce l'ha fa Cadash.
// (dichiarato piu' in alto, vicino alla mappa dei tasti che lo usa)
// Multiplayer (link fra due cabinati) — SECONDO byte della stessa regione
// index=1. L'HPS scarica index=1 PRIMA delle ROM (index=0) e i DIP (index=254)
// DOPO, quindi il flag e' gia' valido quando il gioco parte.
//   <part>00</part>      -> solo game_id: multiplayer SPENTO (tutte le MRA
//                           normali, e quelle vecchie che non lo conoscono)
//   <part>00 01</part>   -> multiplayer ACCESO (solo le MRA LINK)
// Si pretende il valore esatto $01: cosi' un byte di riempimento ($00 o $FF)
// non puo' accenderlo per sbaglio. Non viene azzerato dal reset di gioco:
// lo scrive solo ioctl_wr, quindi un soft reset dall'OSD non lo perde.
always @(posedge clk_sys)
	if (ioctl_wr && (ioctl_index == 16'd1)) begin
		// parola 0 = byte 0 (game_id) + byte 1 (link multiplayer)
		if (ioctl_addr[26:1] == 26'd0) begin
			game_id <= ioctl_dout[7:0];
			link_mp <= (ioctl_dout[15:8] == 8'h01);
		end
		// parola 1 = byte 2 (orientamento) + byte 3 (libero)
		if (ioctl_addr[26:1] == 26'd1)
			board_tate <= (ioctl_dout[7:0] == 8'h01);
	end

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys;
wire pll_locked;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.locked(pll_locked)
);

// --- reset comandato dall'altro cabinato (link Cadash) ---------------------
// Resettandone uno solo, i due flussi del link restano sfasati per sempre. Il
// trasporto annuncia all'altro di essere ripartito da zero, e chi lo riceve
// resetta il proprio gioco: cosi' i due ripartono insieme, con i tubi puliti.
// Il modulo alza `link_reset_req` per UN ciclo: qui si allunga a ~1 ms, il
// tempo che il reset arrivi ovunque, e si mette in OR con le altre cause del
// reset del GIOCO — quello del framework (bridge, video, HPS) non si tocca.
wire link_reset_req;
reg [16:0] link_reset_cnt = 17'd0;
always @(posedge clk_sys) begin
	if (link_reset_req)             link_reset_cnt <= 17'd96000;   // ~1 ms a 96 MHz
	else if (link_reset_cnt != 0)   link_reset_cnt <= link_reset_cnt - 17'd1;
end
wire link_reset = (link_reset_cnt != 17'd0);

// Game reset: includes download (game held in reset while ROM loads)
// + hold counter: tiene reset alto per ~2^17 cicli (~1.4ms a 96MHz) dopo che
// la causa cade, per dare tempo a SDRAM/clear FSM/PLL di stabilizzarsi.
wire reset_cause = RESET | status[0] | buttons[1] | ~pll_locked | ioctl_download | link_reset;
reg [16:0] reset_hold_cnt = 17'h1FFFF;  // parte carico al power-on
always @(posedge clk_sys) begin
	if (reset_cause) reset_hold_cnt <= 17'h1FFFF;  // ricarica finche' c'e' causa
	else if (reset_hold_cnt != 17'd0) reset_hold_cnt <= reset_hold_cnt - 17'd1;
end
// Il confronto su 17 bit alimenta mezzo core (CPU, video, chip audio): messo in
// un registro, il cammino verso i moduli lontani diventa solo instradamento.
// Il reset si spegne un clock dopo, su un'attesa che dura 131.071 clock.
reg reset_r = 1'b1;
always @(posedge clk_sys) reset_r <= (reset_hold_cnt != 17'd0);
wire reset = reset_r;
// Bridge reset: ONLY pll_locked — bridge must run during download, before RESET drops
wire bridge_reset = ~pll_locked;
// Video reset: ONLY pll_locked — CRT needs sync always, even during RESET and download
wire video_reset = ~pll_locked;

///////////////////////   SDRAM   ///////////////////////////////

// Genesis 4-port SDRAM controller (Sorgelig + port 3 for audio)
// Port 0: Tile ROM + download
// Port 1: Main CPU ROM
// Port 2: Sub CPU ROM
// Port 3: Audio Z80 ROM

wire [24:1] sd_addr0, sd_addr1, sd_addr2, sd_addr3;
wire [15:0] sd_din0, sd_din1, sd_din2, sd_din3;
wire        sd_wrl0, sd_wrh0, sd_wrl1, sd_wrh1, sd_wrl2, sd_wrh2, sd_wrl3, sd_wrh3;
wire        sd_req0, sd_req1, sd_req2, sd_req3;
wire        sd_ack0, sd_ack1, sd_ack2, sd_ack3;
wire [15:0] sd_dout0, sd_dout1, sd_dout2, sd_dout3;
wire        sdram_ready;

sdram sdram_ctrl
(
	.SDRAM_DQ(SDRAM_DQ),
	.SDRAM_A(SDRAM_A),
	.SDRAM_DQML(SDRAM_DQML),
	.SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA(SDRAM_BA),
	.SDRAM_nCS(SDRAM_nCS),
	.SDRAM_nWE(SDRAM_nWE),
	.SDRAM_nRAS(SDRAM_nRAS),
	.SDRAM_nCAS(SDRAM_nCAS),
	.SDRAM_CLK(SDRAM_CLK),
	.SDRAM_CKE(SDRAM_CKE),

	.init(~pll_locked),
	.clk(clk_sys),
	.prio_mode(status[35:34]),
	.ready(sdram_ready),

	.addr0(sd_addr0), .wrl0(sd_wrl0), .wrh0(sd_wrh0),
	.din0(sd_din0), .dout0(sd_dout0), .req0(sd_req0), .ack0(sd_ack0),

	.addr1(sd_addr1), .wrl1(sd_wrl1), .wrh1(sd_wrh1),
	.din1(sd_din1), .dout1(sd_dout1), .req1(sd_req1), .ack1(sd_ack1),

	.addr2(sd_addr2), .wrl2(sd_wrl2), .wrh2(sd_wrh2),
	.din2(sd_din2), .dout2(sd_dout2), .req2(sd_req2), .ack2(sd_ack2),

	.addr3(sd_addr3), .wrl3(sd_wrl3), .wrh3(sd_wrh3),
	.din3(sd_din3), .dout3(sd_dout3), .req3(sd_req3), .ack3(sd_ack3)
);

///////////////////////   BRIDGE   ///////////////////////////////

// Bridge between darius game logic (level protocol) and Genesis SDRAM (toggle protocol)
wire [23:0] game_tile_addr, game_main_addr, game_sub_addr;
wire        game_tile_req, game_main_req, game_sub_req;
wire        game_tile_is_sprite;
wire        game_tile_is_text;
wire [31:0] game_tile_data;
// SDRAM port 3 sprite scollegata: tie-off del bridge port 3
wire [23:0] game_spr_addr  = 24'd0;
wire        game_spr_req   = 1'b0;
wire [31:0] game_spr_data;        // unused (uscita bridge)
wire        game_spr_valid;       // unused (uscita bridge)

wire        game_tile_valid;
wire [15:0] game_main_data, game_sub_data;
// Audio Z80 ROM removed from SDRAM — will use BRAM when audio implemented
wire        game_main_ready, game_sub_ready;

// ROM instruction cache — between game and SDRAM bridge
wire [23:0] bridge_main_addr, bridge_sub_addr;
wire        bridge_main_req, bridge_sub_req;
wire [15:0] bridge_main_data, bridge_sub_data;
wire        bridge_main_ready, bridge_sub_ready;
wire [1:0]  dbg_cache_state;

rom_cache #(.CACHE_BITS(8)) u_main_cache (
	.clk(clk_sys), .reset(reset),
	.cpu_addr(game_main_addr), .cpu_req(game_main_req),
	.cpu_data(game_main_data), .cpu_ready(game_main_ready),
	.sdram_addr(bridge_main_addr), .sdram_req(bridge_main_req),
	.sdram_data(bridge_main_data), .sdram_ready(bridge_main_ready),
	.dbg_state(dbg_cache_state)
);

rom_cache #(.CACHE_BITS(8)) u_sub_cache (
	.clk(clk_sys), .reset(reset),
	.cpu_addr(game_sub_addr), .cpu_req(game_sub_req),
	.cpu_data(game_sub_data), .cpu_ready(game_sub_ready),
	.sdram_addr(bridge_sub_addr), .sdram_req(bridge_sub_req),
	.sdram_data(bridge_sub_data), .sdram_ready(bridge_sub_ready),
	.dbg_state()
);

sdram_bridge bridge
(
	.clk(clk_sys),
	.reset(bridge_reset),
	.sdram_ready(sdram_ready),

	// HPS download
	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),
	.ioctl_wait(ioctl_wait_sdram),

	// Game: Tile ROM (32-bit)
	.tile_byte_addr(game_tile_addr),
	.tile_req(game_tile_req),
	.tile_is_sprite(game_tile_is_sprite),
	.tile_is_text(game_tile_is_text),
	.tile_data(game_tile_data),
	.tile_valid(game_tile_valid),

	// Sprite ROM dedicato (port 3)
	.spr_byte_addr(game_spr_addr),
	.spr_req(game_spr_req),
	.spr_data(game_spr_data),
	.spr_valid(game_spr_valid),


	// Game: Main CPU ROM (16-bit)
	.main_byte_addr(bridge_main_addr),
	.main_req(bridge_main_req),
	.main_data(bridge_main_data),
	.main_ready(bridge_main_ready),

	// Game: Sub CPU ROM (16-bit)
	.sub_byte_addr(bridge_sub_addr),
	.sub_req(bridge_sub_req),
	.sub_data(bridge_sub_data),
	.sub_ready(bridge_sub_ready),

	// SDRAM ports
	.sdram_addr0(sd_addr0), .sdram_din0(sd_din0),
	.sdram_wrl0(sd_wrl0), .sdram_wrh0(sd_wrh0),
	.sdram_req0(sd_req0), .sdram_ack0(sd_ack0), .sdram_dout0(sd_dout0),

	.sdram_addr1(sd_addr1), .sdram_din1(sd_din1),
	.sdram_wrl1(sd_wrl1), .sdram_wrh1(sd_wrh1),
	.sdram_req1(sd_req1), .sdram_ack1(sd_ack1), .sdram_dout1(sd_dout1),

	.sdram_addr2(sd_addr2), .sdram_din2(sd_din2),
	.sdram_wrl2(sd_wrl2), .sdram_wrh2(sd_wrh2),
	.sdram_req2(sd_req2), .sdram_ack2(sd_ack2), .sdram_dout2(sd_dout2),

	.sdram_addr3(sd_addr3), .sdram_din3(sd_din3),
	.sdram_wrl3(sd_wrl3), .sdram_wrh3(sd_wrh3),
	.sdram_req3(sd_req3), .sdram_ack3(sd_ack3), .sdram_dout3(sd_dout3),
	.dbg_main_pending(dbg_main_pending),
	.dbg_download_active(dbg_download_active),
	.dbg_peek_val(dbg_peek_val),
	.dbg_peek_match(dbg_peek_match)
);
wire [15:0] dbg_peek_val;
wire        dbg_peek_match;

///////////////////////   GAME   ///////////////////////////////

wire ce_pix;  // 24 MHz pixel clock enable (generated by compositor, used by game)
wire [9:0]  render_x;
wire [8:0]  render_y;
wire [23:0] tile_rgb;
wire [1:0]  tile_prio;
wire        tile_opaque;
wire [23:0] game_sprite_rgb;
wire [1:0]  game_sprite_prio;
wire        game_sprite_opaque;
wire [23:0] game_fg_rgb;
wire        game_fg_opaque;
wire [15:0] map_xscroll_l0, map_xscroll_l1;
wire [15:0] map_yscroll_l0, map_yscroll_l1;

// [SS] Savestate UI — genera ss_save/ss_load/ss_slot da OSD e scorciatoie tastiera.
wire       ss_save_t, ss_load_t, ss_pause_req;
wire [3:0] ss_slot;
savestate_ui #(.INFO_TIMEOUT_BITS(25)) u_ss_ui (
	.clk         (clk_sys),
	.ps2_key     (ps2_key),
	.allow_ss    (1'b1),
	.joySS       (joy0[13]),
	.joyRight    (joy0[0]),
	.joyLeft     (joy0[1]),
	.joyDown     (joy0[2]),
	.joyUp       (joy0[3]),
	.joyStart    (joy0[12]),
	.joyRewind   (1'b0),
	.rewindEnable(1'b0),
	.status_slot (status[108:105]),
	.autoincslot (1'b0),
	.OSD_saveload(status[110:109]),
	.ss_save     (ss_save_t),
	.ss_load     (ss_load_t),
	.ss_info_req (),
	.ss_info     (),
	.statusUpdate(),
	.selected_slot(ss_slot)
);

// Riga: 436 pixel a 145.8 ns = 63.58 us. Sync 32 px = 4.67 us (norma 4.7); i
// 404 px fuori dal sync si dividono in parti uguali attorno ai 320 attivi, 42
// e 42, cosi' l'immagine resta centrata. Back porch 42 px = 6.1 us: il clamp
// del livello di nero del televisore ci cade dentro con margine (era 2.67).
localparam [9:0] H_ACTIVE_S = 10'd320;
localparam [9:0] H_FP_S     = 10'd42;
localparam [9:0] H_SYNC_S   = 10'd32;
localparam [9:0] H_BP_S     = 10'd42;
localparam [9:0] H_TOTAL_S  = H_ACTIVE_S + H_FP_S + H_SYNC_S + H_BP_S;  // 436
// Quadro: 262 righe, 22 di blanking come il campo NTSC a 240 righe visibili.
localparam [8:0] V_ACTIVE_S = 9'd240;
localparam [8:0] V_FP_S     = 9'd3;
localparam [8:0] V_SYNC_S   = 9'd3;
localparam [8:0] V_BP_S     = 9'd16;
localparam [8:0] V_TOTAL_S  = V_ACTIVE_S + V_FP_S + V_SYNC_S + V_BP_S;  // 262

asuka_top game
(
	// [SS] savestate — parte video (VRAM TC0100SCN, VRAM ext, palette, ctrl)
	.ss_save(ss_save_t),
	.ss_load(ss_load_t),
	.ss_slot(ss_slot),
	.ss_busy(),
	.ss_pause_req(ss_pause_req),
	.clk(clk_sys),
	.reset(reset),
	.pause(pause),
	.game_id(game_id),
	// Hardcoded 16 MHz (Cadash MAME XTAL 32/2, asuka.cpp:1222).
	// clk_sel code (top case): 0=16MHz
	.clk_sel(3'd0),
	.sub_clk_sel(3'd0),
	.z80_clk_sel(status[37:36]), // OSD: Z80 audio speed
	.p1_input(p1_input),
	.p2_input(p2_input),
	.system_input(system_input),
	.dsw_input(dip_sw),
	.cchip_pa(cchip_pa),
	.cchip_pb(cchip_pb),
	.cchip_pc(cchip_pc),
	.cchip_an(cchip_an),
	// Sprite: sincroni come in MAME (default) o in ritardo come sulla scheda.
	// Sprite Timing: l'unico set con la prova sul ferro e' Cadash, quindi fuori
	// da li' il core resta su Sync qualunque cosa dica il bit dell'OSD (dove
	// l'opzione non compare nemmeno, vedi menumask).
	.spr_pcb_timing(status[14] & cfg_cadash_osd),

	// SDRAM ROM (via bridge)
	.main_rom_rdata(game_main_data),
	.main_rom_ready(game_main_ready),
	.sub_rom_rdata(game_sub_data),
	.sub_rom_ready(game_sub_ready),
	.tilerom_data(game_tile_data),
	.tilerom_valid(game_tile_valid),

	// OSD layer disables: 1=hide layer
	.dbg_dis_bg0(status[30]),
	.dbg_dis_bg1(status[31]),
	// scn_rate_sel rimosso (Donlon-legacy): SCN ora usa ce_13m fisso
	.dbg_dis_fg0(status[33]),
	.dbg_dis_spr(status[32]),

	.main_rom_addr(game_main_addr),
	.main_rom_req(game_main_req),
	.sub_rom_addr(game_sub_addr),
	.sub_rom_req(game_sub_req),

	// --- link fra cabinati (Cadash): trasporto via UART interna -> rete ---
	.link_attivo(link_attivo),
	.link_uart_rxd(UART_RXD),
	.link_uart_txd(link_uart_txd),
	.link_snac(link_snac),
	.link_snac_cavo(link_snac_cavo),
	.user_in(USER_IN),
	.user_out(link_user_out),
	.link_reset_req(link_reset_req),
	.link_dbg_pc(),
	.tilerom_addr(game_tile_addr),
	.tilerom_req(game_tile_req),
	.tilerom_is_sprite(game_tile_is_sprite),
	.tilerom_is_text(game_tile_is_text),
	// (sprite ROM ora su DDR3 port 4 internamente al game, no port qui)

	// Audio ROM download (ioctl → BRAM)
	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),

	// Video
	.render_x(render_x),
	.render_y(render_y),
	.frame_last_line(V_TOTAL_S - 9'd1),
	.hblank_in(HBlank),
	.tile_rgb(tile_rgb),
	.tile_prio(tile_prio),
	.tile_opaque(tile_opaque),
	.sprite_rgb(game_sprite_rgb),
	.sprite_prio(game_sprite_prio),
	.sprite_opaque(game_sprite_opaque),
	.fg_rgb(game_fg_rgb),
	.fg_opaque(game_fg_opaque),

	// Scroll/debug
	.xscroll_l0(map_xscroll_l0),
	.xscroll_l1(map_xscroll_l1),
	.yscroll_l0(map_yscroll_l0),
	.yscroll_l1(map_yscroll_l1),
	.ctrl_l0(),
	.ctrl_l1(),
	// OSD layer offsets
	.l0_xoff(osd_l0_xoff), .l0_yoff(osd_l0_yoff),
	.l1_xoff(osd_l1_xoff), .l1_yoff(osd_l1_yoff),
	.spr_xoff(osd_spr_xoff), .spr_yoff(osd_spr_yoff),
	.fg_xoff(osd_fg_xoff), .fg_yoff(osd_fg_yoff),
	// OSD layer enable (O[30]=BG0, O[31]=BG1, O[33]=FG0). Status bit "Off" = 1 → invertito.
	.osd_tile_layer_en({~status[33], ~status[31], ~status[30]}),
	// Text ROM download -> BRAM del layer testo.
	// La finestra 0x1C0000-0x1C7FFF e' cablata sul layout di Cadash, dove li'
	// c'e' riempimento. Sugli altri set NON e' riempimento: su Asuka a 0x1C0000
	// ci sono le ROM sprite di estensione (b68-06/b68-07), che finivano dentro
	// questa BRAM. Vincolata a Cadash: cosi' Cadash carica esattamente quello
	// che caricava prima e nessun altro set si prende dati non suoi.
	.fg_dl_wr(ioctl_download && ioctl_wr && ioctl_index == 16'd0 &&
	           (game_id == 8'h00) &&
	           ioctl_addr >= 27'h1C0000 && ioctl_addr < 27'h1C8000),
	.fg_dl_addr(ioctl_addr[14:1]),
	.fg_dl_data(ioctl_dout),
	// Compositor pixel clock (24 MHz)
	.ce_pix(ce_pix),
	// Audio
	.audio_l(game_audio_l),
	.audio_r(game_audio_r),
	.adpcma_tap_l(adpcma_tap_l),
	.adpcma_tap_r(adpcma_tap_r),
	.fm_tap_l(fm_tap_l),
	.fm_tap_r(fm_tap_r),
	// Audio mixer OSD volumes (3-bit each, vedi CONF_STR P3 audio mixer)
	.osd_fm_vol    (status[88:86]),
	.osd_adpcma_vol(status[91:89]),
	.osd_adpcmb_vol(status[94:92]),
	.osd_psg_vol   ({2'd0, status[95]}),  // 1-bit OSD: 0=Polite (default), 1=MAME (100%)
	// DDRAM HPS pin (gestiti internamente da darius2_ddram dentro audio_top)
	.DDRAM_CLK(clk_sys),
	.DDRAM_BUSY(DDRAM_BUSY),
	.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
	.DDRAM_ADDR(DDRAM_ADDR),
	.DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
	.DDRAM_RD(DDRAM_RD),
	.DDRAM_DIN(DDRAM_DIN),
	.DDRAM_BE(DDRAM_BE),
	.DDRAM_WE(DDRAM_WE),
	// Write del framebuffer dal rotate: dentro asuka_top vanno alla FIFO e al
	// ddr_mux, che li arbitra col master audio/sprite.
	.rot_addr(rot_addr),
	.rot_data(rot_data),
	.rot_be(rot_be),
	.rot_we(rot_we),
	.ioctl_wait_audio(ioctl_wait_audio),
	// Debug overlay
	.dbg_main_pc(dbg_main_pc),
	.dbg_bus_addr(dbg_bus_addr),
	.dbg_txn_state(dbg_txn_state),
	.dbg_bus_busy(dbg_bus_busy),
	.dbg_dtack_n(dbg_dtack_n),
	.dbg_ext_dtack_n(dbg_ext_dtack_n),
	.dbg_scn0_sc(dbg_scn0_sc),
	.dbg_scn0_sc_seen(dbg_scn0_sc_seen),
	.dbg_tilerom_req_seen(dbg_tilerom_req_seen),
	.dbg_scn0_wr_cnt(dbg_scn0_wr_cnt),
	.dbg_z80_active(dbg_z80_active),
	.dbg_ym_active(dbg_ym_active),
	.dbg_syt_main_act(dbg_syt_main_act),
	.dbg_syt_z80_act(dbg_syt_z80_act),
	.dbg_audio_nonzero(dbg_audio_nonzero),
	.dbg_d6(dbg_d6),
	.dbg_d7(dbg_d7),
	.dbg_d0(dbg_d0),
	.dbg_a0(dbg_a0),
	.dbg_a1(dbg_a1),
	.dbg_ram_wr_cnt(dbg_ram_wr_cnt),
	.dbg_ram_rd_val(dbg_ram_rd_val),
	.dbg_sub_pc(dbg_sub_pc)
);

// --- Debug signals from game + bridge ---
wire [23:0] dbg_main_pc;
wire [23:0] dbg_bus_addr;
wire [3:0]  dbg_txn_state;
wire        dbg_bus_busy;
wire        dbg_dtack_n;
wire        dbg_ext_dtack_n;
wire [14:0] dbg_scn0_sc;
wire        dbg_scn0_sc_seen;
wire        dbg_tilerom_req_seen;
wire [15:0] dbg_scn0_wr_cnt;
wire dbg_z80_active, dbg_ym_active, dbg_syt_main_act, dbg_syt_z80_act, dbg_audio_nonzero;
wire [31:0] dbg_d6, dbg_d7, dbg_d0, dbg_a0, dbg_a1;
wire [15:0] dbg_ram_wr_cnt, dbg_ram_rd_val;
wire [23:0] dbg_sub_pc;
wire        dbg_main_pending;
wire        dbg_download_active;
// dbg_cache_state già dichiarato nel blocco rom_cache
// ROM word: latch first word read by main cache from SDRAM
wire        dbg_rom_word_valid = bridge_main_ready;
wire [15:0] dbg_rom_word       = bridge_main_data;

///////////////////////   VIDEO   ///////////////////////////////

// Raster della scheda, non inventato. Video: quarzo 26.686 MHz (header di
// asuka.cpp, PCB), TC0100SCN → pixel clock = 26.686/4 = 6.6715 MHz, riga di
// 424 pixel = 15.735 kHz (riga NTSC), quadro di 262 righe = 60.06 Hz.
// Visibile 320x240 (MAME: set_size(320,256), visarea(0,319,16,255), 60 Hz).
//
// Da 96 MHz nessun divisore INTERO da' 6.6715 MHz (i vicini sono /14 = +2.8%
// e /15 = -4.1%), e un enable frazionario qui non si usa: fa ballare il passo
// del pixel e il rapporto clk/pixel che crt_vsize MISURA a runtime.
// Quello che deve essere preciso non e' il pixel: sono le due frequenze di
// sync, e si azzeccano scegliendo i totali. Con /14 = 6.8571 MHz e riga da
// 436: 15.727 kHz contro 15.735 e 60.03 Hz contro 60.06, 0.04% su entrambe.
// Resta che i 320 pixel visibili durano 46.7 us invece di 48.0: immagine il
// 2.7% piu' stretta sul tubo, quindi in difetto, non in overscan.
//
// Cosa c'era prima e perche' il CRT si scuriva: 96/16 = 6 MHz, 384x264. I 320
// pixel visibili duravano 53.3 us invece di 48.0 (immagine +11% piu' larga in
// tempo, overscan a destra e sinistra) e il blanking orizzontale scendeva a
// 10.67 us contro i 15.6 della scheda, sotto il minimo di norma. Il back porch
// restava 2.67 us invece di 5.8: l'impulso di clamp del televisore, che aggancia
// il livello del nero, cadeva sui primi pixel attivi e prendeva il contenuto
// come riferimento di nero. Da li' il calo di luminosita', variabile col quadro.
wire        HBlank, VBlank, HSync, VSync;
wire [7:0]  video_r, video_g, video_b;

// I totali del raster sono dichiarati sopra l'istanza del gioco, che li usa.


// Pixel clock: 96 MHz / 14 = 6.8571 MHz, un impulso ogni 14 clock, sempre lo
// stesso passo. crt_vsize misura da se' il rapporto clk/pixel e ci costruisce
// sopra la geometria: deve trovarlo fermo.
reg  [3:0] pxl_div_s;
reg        pxl_en_s;
reg  [9:0] hc_s;
reg  [8:0] vc_s;
// Totale verticale effettivo del frame in corso. Normalmente V_TOTAL_S; il core
// puo' chiedere una riga in piu' o in meno per spostare la fase rispetto
// all'altra macchina (una riga = 64 us su 16,9 ms). L'area attiva non cambia
// mai: si allunga o accorcia solo il blanking.

always @(posedge clk_sys) begin
	if (video_reset) begin
		pxl_div_s <= 0;
		pxl_en_s  <= 0;
		hc_s      <= 0;
		vc_s      <= 0;
	end else begin
		pxl_div_s <= (pxl_div_s == 4'd13) ? 4'd0 : pxl_div_s + 4'd1;
		pxl_en_s  <= (pxl_div_s == 4'd13);
		if (pxl_en_s) begin
			if (hc_s == H_TOTAL_S - 10'd1) begin
				hc_s <= 0;
				if (vc_s == V_TOTAL_S - 9'd1) vc_s <= 0;
				else                          vc_s <= vc_s + 9'd1;
			end else hc_s <= hc_s + 10'd1;
		end
	end
end

wire active_s = (hc_s < H_ACTIVE_S) && (vc_s < V_ACTIVE_S);
assign HBlank = ~(hc_s < H_ACTIVE_S);
assign VBlank = ~(vc_s < V_ACTIVE_S);
assign HSync  = ~((hc_s >= (H_ACTIVE_S + H_FP_S)) && (hc_s < (H_ACTIVE_S + H_FP_S + H_SYNC_S)));
assign VSync  = ~((vc_s >= (V_ACTIVE_S + V_FP_S)) && (vc_s < (V_ACTIVE_S + V_FP_S + V_SYNC_S)));
assign ce_pix    = pxl_en_s;
// Durante hblank, render_x=900 evita re-trigger prefetch tile.
assign render_x  = active_s ? hc_s : 10'd900;
assign render_y  = (vc_s == V_TOTAL_S - 9'd1) ? 9'd0 : vc_s + 9'd1;

// Compositor RGB: tile (BG+FG+sprite già muxati dentro TC0110PR) → out diretto.
// game_sprite_rgb/fg_rgb path esterno NON usato (sprite_ob blending sta nel chip).
assign video_r = active_s ? tile_rgb[23:16] : 8'd0;
assign video_g = active_s ? tile_rgb[15:8]  : 8'd0;
assign video_b = active_s ? tile_rgb[7:0]   : 8'd0;

assign CLK_VIDEO = clk_sys;
assign CE_PIXEL  = ce_pix;
assign VGA_HS    = HSync;
assign VGA_VS    = VSync;

// MAME warning overlay: "DON'T BREAK YOUR WOOFER!" per ~3s su edge status[95]
reg vsync_d;
always @(posedge clk_sys) vsync_d <= VSync;
wire vblank_tick = VSync & ~vsync_d;  // 1 colpo per frame

wire mame_warn_on;
mame_warning_overlay u_mame_warn (
	.clk             (clk_sys),
	.reset           (video_reset),
	.tick            (vblank_tick),
	.mame_psg_active (status[95]),
	.render_x        (render_x),
	.render_y        (render_y),
	.text_on         (mame_warn_on)
);

wire [7:0] mame_r = mame_warn_on ? 8'hFF : video_r;
wire [7:0] mame_g = mame_warn_on ? 8'hFF : video_g;
wire [7:0] mame_b = mame_warn_on ? 8'h00 : video_b;

// Pause overlay: dim video + logo 48x48 al centro + scroll patron + links durante pausa.
// OSD "Clean Pause" (status[19]): ON=video raw senza addon, OFF=overlay attivo.
pause_overlay u_pause_ovl (
	.clk         (clk_sys),
	.pause       (pause),
	.clean       (status[19]),
	.tate        (board_tate),
	.render_x_in (render_x),
	.render_y_in (render_y),
	.rgb_r_in    (mame_r),
	.rgb_g_in    (mame_g),
	.rgb_b_in    (mame_b),
	.rgb_r_out   (VGA_R),
	.rgb_g_out   (VGA_G),
	.rgb_b_out   (VGA_B)
);

// Aspect ratio: Original = 4:3 (Cadash 320x240 single screen), Full Screen = 0:0
// Con la rotazione accesa l'immagine diventa verticale: l'aspect va scambiato,
// altrimenti resta 4:3 su un'immagine 3:4 (Raiden.sv:1794-1795).
wire [11:0] arx = (!ar) ? (rotate_en ? 12'd3 : 12'd4) : (ar - 1'd1);
wire [11:0] ary = (!ar) ? (rotate_en ? 12'd4 : 12'd3) : 12'd0;

// Integer scaling (Scale menu: Normal / V-Integer / HV-Integer- / HV-Integer+).
// SCALE 0 = Normal (default, scaler fa aspect-correct fill).
video_freak video_freak
(
	.CLK_VIDEO(clk_sys),
	.CE_PIXEL(ce_pix),
	.VGA_VS(VSync),
	.HDMI_WIDTH(HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE(VGA_DE),
	.VIDEO_ARX(VIDEO_ARX),
	.VIDEO_ARY(VIDEO_ARY),
	.VGA_DE_IN(~(HBlank | VBlank)),
	.ARX(arx),
	.ARY(ary),
	.CROP_SIZE(12'd0),
	.CROP_OFF(5'd0),
	.SCALE({1'b0, status[6:5]})
);

// LED_USER pilotato dal beat detector audio.
// Se resta spento → Z80 non boota (ROM non in DDRAM o WAIT_n eterno).
assign LED_USER = led_user_beat;

// -- CRT Adjust + V-Size: integrazione SYS-SIDE ----------------------------
// I due stadi NON stanno qui: vivono in sys/sys_top.v, sul solo ramo VGA
// analogico (fra scanlines e vga_osd), cosi' l'HDMI resta bit-identico mentre
// si regola il CRT. Il core decodifica solo l'OSD ed esporta i valori con le
// porte CRT_*. Riferimento: MiSTer_Discovery_Docs doc 17 (regole) e 18.
//
// Regola 1.6 e 1bis: si spegne solo su cio' che RADDOPPIA davvero il CE pixel.
// Questo core non ha video_mixer ne' Scandoubler Fx, quindi resta il solo
// forced_scandoubler; l'opzione OSD "Scale" e' l'integer scaling dell'HDMI, un
// omonimo che non c'entra e che spegnerebbe il CRT Adjust per niente.
wire crt_adj_on = status[111] & ~forced_scandoubler;

// H-Size: complemento a due 5 bit. 0 = nativo, +1..+15 allarga, -1..-16
// stringe. Un passo = un ottavo del periodo del pixel; la base sta in sys_top
// e qui vale 96 MHz / 6.857 MHz = 14 clk x 8 = 112, quindi un passo = 0.89%.
reg  signed [4:0] hsize_s;
always @(posedge clk_sys) if (ce_pix) hsize_s <= crt_adj_on ? $signed(status[116:112]) : 5'sd0;

// H-Position: la lista OSD ha 97 voci (0, +1..+48, -48..-1) e il menu salva
// l'INDICE: il wrap va fatto sulla LUNGHEZZA DELLA LISTA, 97, non a 128. Col
// wrap a 128 la voce "-1" varrebbe -32 px e l'immagine salterebbe di 32 pixel
// al primo scatto (bug reale visto su hardware su un altro core).
reg  [6:0] hsize_hoff_d;
always @(posedge clk_sys) if (ce_pix) hsize_hoff_d <= crt_adj_on ? status[13:7] : 7'd0;
wire signed [8:0] hsize_hoffset = (hsize_hoff_d <= 7'd48)
	? $signed({2'b0, hsize_hoff_d})
	: $signed({2'b0, hsize_hoff_d}) - 9'sd97;

// V-Shift: +-32 righe, campionato a fine riga.
wire line_tick = ce_pix && (hc_s == H_TOTAL_S - 10'd1);
reg signed [5:0] osd_vga_vshift_d;
always @(posedge clk_sys) if (line_tick) osd_vga_vshift_d <= crt_adj_on ? $signed(status[100:96]) : 6'sd0;

// V-Size: un passo OSD = 3 righe; la negazione fa si' che "+" per l'utente =
// piu' ALTA (il modulo usa +N = piu' bassa). Il campo e' a complemento a due su
// 4 bit, quindi va esteso col segno (14 = -2, non +14).
//
// Corsa CALCOLATA SU QUESTO CORE, perche' nessun valore dell'OSD mangi righe o
// sganci il televisore. Raster: 262 righe, 240 attive (vc 0..239), VSync alle
// righe 243..245, riga di 436 pixel da 14 clk -> quadro di 1.599.248 clk.
// vsize = righe AGGIUNTE al quadro (positivo = immagine piu' bassa).
//  PVM (retimer, status[117]=0): il quadro d'uscita ha 262+vsize righe.
//    Frequenza: riga di almeno 5926 clk (16,20 kHz, tetto d'aggancio misurato
//    del televisore) -> al massimo 269 righe; riga di al piu' 6351 clk
//    (15,12 kHz) -> almeno 252.
//    Coda: la riga d'uscita n rigioca la riga n del quadro contata dal VSync, e
//    l'immagine occupa le righe 19..258: sotto 259 righe si perde il fondo. E'
//    questo il vincolo che comanda, non la frequenza -> vsize da -3 ("+1"
//    nell'OSD) a +6 ("-2").
//  Cabinet (timing nativo, status[117]=1): stringere non perde niente fino a
//    +24 ("-8"). Allargando, la finestra parte alla riga 22 dopo il VSync e
//    oltre il quadro si va solo ritardando il VSync di K righe, con K al
//    massimo 22-3-4 = 15: righe disponibili 241+15 = 256, cioe' 16 in piu'
//    delle 240 attive -> senza perdite fino a 15 ("+5").
reg signed [5:0] crt_vsize;
reg              crt_vsmode;
wire signed [5:0] crt_vsz_step = $signed({{2{status[104]}}, status[104:101]});
wire signed [5:0] crt_vsz_req  = -(crt_vsz_step + (crt_vsz_step <<< 1));
wire signed [5:0] crt_vsz_min  = status[117] ? -6'sd15 : -6'sd3;
wire signed [5:0] crt_vsz_max  = status[117] ?  6'sd24 :  6'sd6;
wire signed [5:0] crt_vsz_lim  = (crt_vsz_req < crt_vsz_min) ? crt_vsz_min
                               : (crt_vsz_req > crt_vsz_max) ? crt_vsz_max
                               : crt_vsz_req;
always @(posedge clk_sys) if (ce_pix) begin
	crt_vsize  <= crt_adj_on ? crt_vsz_lim : 6'sd0;
	crt_vsmode <= status[117];
end

assign CRT_ON      = crt_adj_on;
assign CRT_HSIZE   = hsize_s;
assign CRT_HPOS    = hsize_hoffset;
assign CRT_VSHIFT  = osd_vga_vshift_d;
assign CRT_VSIZE   = crt_vsize;
assign CRT_VSMODE  = crt_vsmode;
assign CRT_VBL     = VBlank;         // VBlank VERO nativo, MAI il blank combinato
assign CRT_RD_BASE = 9'd112;         // 96 MHz / 6.857 MHz = 14 clk, in ottavi
assign CRT_HTOTAL  = 10'd436;        // pixel per riga del raster nativo

// ============================================================
// JTAG Debug Probes (readable via quartus_stp / System Console)
// ============================================================
// JTAG boot trace removed to save M10K for 64KB work RAM

// ============================================================
// Rotazione schermo (TATE) — stessa catena di Raiden
// ============================================================
// I set verticali del driver (Asuka & Asuka, Galmedes, Earth Joker, Maze of
// Flott) hanno lo stesso raster 320x240 di Cadash: era il monitor del cabinato
// a essere girato. Qui screen_rotate annusa VGA_* a CLK_VIDEO e scrive il
// framebuffer ruotato in DDR3; la FIFO assorbe i write e il ddr_mux dentro
// asuka_top li arbitra col master che legge ROM audio e sprite.
//
// Le voci sono nascoste (H1) sui set orizzontali: lo status e' unico per core
// e altrimenti su Cadash resterebbe il valore lasciato su un set verticale.

// VGA_SCALER resta 0 (assegnato in testa al file). La rotazione HDMI la fa
// screen_rotate col framebuffer HPS, NON dirottando l'uscita analogica: il CRT
// non deve cambiare percorso quando accendi il rotate. Per questo
// video_rotated resta volutamente non usato.

screen_rotate u_screen_rotate
(
	.CLK_VIDEO     (clk_sys),
	.CE_PIXEL      (ce_pix),

	.VGA_R         (VGA_R),
	.VGA_G         (VGA_G),
	.VGA_B         (VGA_B),
	.VGA_HS        (VGA_HS),
	.VGA_VS        (VGA_VS),
	.VGA_DE        (VGA_DE),

	.rotate_ccw    (rotate_ccw),
	.no_rotate     (~rotate_en),
	.flip          (flip_180),
	.video_rotated (video_rotated),

	.FB_EN         (FB_EN),
	.FB_FORMAT     (FB_FORMAT),
	.FB_WIDTH      (FB_WIDTH),
	.FB_HEIGHT     (FB_HEIGHT),
	.FB_BASE       (FB_BASE),
	.FB_STRIDE     (FB_STRIDE),
	.FB_VBL        (FB_VBL),
	.FB_LL         (FB_LL),

	// I write non vanno ai pin: li prende la FIFO dentro asuka_top, che non si
	// blocca mai, quindi qui il bus e' sempre libero.
	.DDRAM_CLK     (),
	.DDRAM_BUSY    (1'b0),
	.DDRAM_BURSTCNT(),
	.DDRAM_ADDR    (rot_addr),
	.DDRAM_DIN     (rot_data),
	.DDRAM_BE      (rot_be),
	.DDRAM_WE      (rot_we),
	.DDRAM_RD      ()
);

endmodule
