/*  This file is part of BoogieWings_MiSTer.
    GPL-3.
    Original author: Martin Donlon (wickerwaka) — Arcade-TaitoF2 savestate system.
    Modified/adapted for BoogieWings by: Umberto Parisi (rmonc79)
*/

//============================================================================
//  ss_m68k — Savestate del 68000 (mini-handler 68K che pusha lo stato in work RAM)
//
//  Portato da Arcade-TaitoF2 (Martin Donlon), F2.sv:160-385,1042,1114-1116.
//  NON estrae i registri interni di fx68k: forza la CPU a eseguire un mini-handler
//  (ss_irq_handler, codice 68K) che pusha tutti i registri sullo stack (= work RAM,
//  gia' salvata via adaptor) e scrive l'SSP a un indirizzo scratch intercettato.
//  Al restore inietta un reset-vector custom -> la CPU riparte e fa rte ripristinando.
//
//  Adattamento BoogieWings: indirizzo scratch SSP = 0xFF0000 (fuori dalla mappa 68K
//  reale: ROM 0x0xxxxx, RAM 0x20xxxx, video 0x24-0x28, ace 0x3C). Intercettato qui.
//============================================================================

`timescale 1ns / 1ps

module ss_m68k #(
	parameter integer SS_GLOB_IDX = 0
) (
	input  wire        clk,
	input  wire        ce_cpu,        // clock-enable CPU (per il reset counter timing)

	// Bus 68000 (osservato)
	input  wire [23:0] cpu_word_addr, // = {fx_addr, 1'b0}
	input  wire [1:0]  cpu_ds_n,      // {uds_n, lds_n}
	input  wire        cpu_rw,        // 1=read, 0=write
	input  wire [2:0]  cpu_fc,        // function code
	input  wire        iack_n,        // ~(&cpu_fc) — basso durante IACK
	input  wire [15:0] cpu_data_out,  // dato scritto dalla CPU (per catturare l'SSP)

	// Trigger (da savestate_ui)
	input  wire        do_save,
	input  wire        do_restore,
	// Pausa REALE frame-aligned (= paused_safe_r del top, = obj_paused di F2). NON paused_safe
	// combinatorio (che include ss_pause e si auto-soddisfa). La FSM aspetta paused_real PRIMA
	// di gather/scatter, cosi' save/restore avvengono a CPU+audio VERAMENTE fermi.
	input  wire        paused_real,


	// Verso memory_stream (via save_state_data)
	output reg         ss_mem_write,  // pulse: avvia il save su DDR
	output reg         ss_mem_read,   // pulse: avvia il load da DDR
	input  wire        ss_busy,       // memory_stream busy

	// Stato globale SSP via ssbus (SSIDX dedicato)
	ssbus_if.slave     ss_glob,

	// Override verso la CPU
	output wire        ss_din_en,     // 1: cpu_din = ss_din_data (handler/vettore)
	output wire [15:0] ss_din_data,
	output wire        ss_irq,        // 1: forza IPL7 (autovettore)
	output wire        ss_reset,      // 1: reset fx68k (restore)
	output wire        ss_pause,      // 1: gioco in pausa
	output wire        ss_cpu_exec,   // 1: la CPU gira anche se paused (esegue il handler)
	output wire        ss_restore_done, // pulse: restore finito, CPU ripartita su codice normale
	output reg  [3:0]  ss_state_out
);

// Indirizzo scratch dove il mini-handler scrive l'SSP (intercettato, non RAM reale).
localparam [23:0] SS_SCRATCH = 24'hFF0000;

// Mini-handler 68K (F2.sv:187-205). Eseguito quando ss_save_active: pusha tutti i
// registri + USP sullo stack (work RAM) e scrive l'SSP a SS_SCRATCH; al rientro li ripristina.
reg [15:0] ss_irq_handler [0:15];
initial begin
	ss_irq_handler[ 0] = 16'h48e7; ss_irq_handler[ 1] = 16'hfffe; // movem.l d0-d7/a0-a6,-(a7)
	ss_irq_handler[ 2] = 16'h4e6e;                                // move.l usp,a6
	ss_irq_handler[ 3] = 16'h2f0e;                                // move.l a6,-(a7)
	ss_irq_handler[ 4] = 16'h4df9; ss_irq_handler[ 5] = 16'h00ff; ss_irq_handler[ 6] = 16'h0000; // lea 0xff0000,a6
	ss_irq_handler[ 7] = 16'h2c8f;                                // move.l a7,(a6)
	ss_irq_handler[ 8] = 16'h2c5f;                                // move.l (a7)+,a6
	ss_irq_handler[ 9] = 16'h4e66;                                // move.l a6,usp
	ss_irq_handler[10] = 16'h4cdf; ss_irq_handler[11] = 16'h7fff; // movem.l (a7)+,d0-d7/a0-a6
	ss_irq_handler[12] = 16'h4e73;                                // rte
	ss_irq_handler[13] = 16'h0000;
	ss_irq_handler[14] = 16'h0000;
	ss_irq_handler[15] = 16'h0000;
end

reg [31:0] ss_saved_ssp;
reg [31:0] ss_restore_ssp;
reg [15:0] ss_reset_vector [0:3];

// Stato globale via ssbus: salva ss_saved_ssp (1 valore 32-bit), ripristina ss_restore_ssp.
always @(posedge clk) begin
	ss_glob.setup(SS_GLOB_IDX, 1, 2);  // 1 elemento, width 2 = 32 bit
	if (ss_glob.access(SS_GLOB_IDX)) begin
		if (ss_glob.read)  ss_glob.read_response(SS_GLOB_IDX, {32'd0, ss_saved_ssp});
		else if (ss_glob.write) begin
			ss_restore_ssp <= ss_glob.data[31:0];
			ss_glob.write_ack(SS_GLOB_IDX);
		end
	end
end

// FSM ss_state (F2.sv:208-385). WAIT_PAUSE (F2.sv:304-308,344-348): attende paused_real (pausa
// frame-aligned REALE = obj_paused di F2) PRIMA di gather/scatter, cosi' save/restore avvengono
// a CPU+audio fermi davvero. (Differenza da bb2d080: li' aspettavo paused_safe combinatorio che
// si auto-soddisfa; ora aspetto paused_real = paused_safe_r registrato a vblank.)
localparam [3:0]
	SST_IDLE              = 4'd0,
	SST_SAVE_WAIT_PAUSE   = 4'd8,  // attende paused_real prima del save (F2 SST_SAVE_WAIT_PAUSE)
	SST_SAVE_WAIT_IRQ     = 4'd1,  // attende IACK liv7 (la CPU prende l'eccezione)
	SST_SAVE_WAIT_SSP     = 4'd2,  // cattura l'SSP scritto a SS_SCRATCH
	SST_SAVE_WAIT_WRITE   = 4'd3,  // memory_stream salva su DDR
	SST_SAVE_WAIT_EXIT    = 4'd4,  // attende rte del handler
	SST_RESTORE_WAIT_PAUSE= 4'd9,  // attende paused_real prima del restore (F2 SST_RESTORE_WAIT_PAUSE)
	SST_RESTORE_WAIT_READ = 4'd5,  // memory_stream carica da DDR
	SST_RESTORE_HOLD_RST  = 4'd6,  // tiene reset N cicli
	SST_RESTORE_WAIT_RST  = 4'd7;  // attende ripartenza CPU

reg [3:0] ss_state = SST_IDLE;
reg [4:0] ss_reset_counter;
reg [3:0] ss_state_d;  // stato ciclo precedente, per edge detection di ss_restore_done

// ss_override = durante save/restore la CPU e' "dirottata" (F2 ss_override).
// Address intercept (F2 address_translator.sv:69-87 + cpu_data_in F2.sv:1114-1116):
//   0xFF00xx -> SS_SAVEn=0  : la CPU esegue ss_irq_handler[addr[4:1]]  (durante save)
//   0x00007C/7E -> SS_VECn=0: vettore autovector liv7 = 0x00FF0000 (PC del handler)
//   0x00000x -> SS_RESETn=0 : reset-vector custom (durante restore)
wire ss_override = (ss_state != SST_IDLE);
wire ds_active   = ~&cpu_ds_n;  // almeno un byte attivo

// Equivalenti esatti dei chip-select F2 (address_translator). Range "attivo" (= n basso):
//   save  = 0xFF00xx (handler), reset = 0x00000x (reset-vector).
wire ss_saven_n  = (cpu_word_addr[23:8] == 16'hFF00);   // 1 = nel range save (SS_SAVEn=0)
wire ss_resetn_n = (cpu_word_addr[23:4] == 20'h00000);  // 1 = nel range reset (SS_RESETn=0)

// ss_cpu_exec NON include WAIT_WRITE (F2: ss_cpu_execute=0 in SAVE_WAIT_WRITE): mentre
// memory_stream legge la work RAM la CPU deve essere FERMA (snapshot coerente).
wire ss_save_active    = (ss_state == SST_SAVE_WAIT_IRQ) || (ss_state == SST_SAVE_WAIT_SSP) ||
                         (ss_state == SST_SAVE_WAIT_EXIT);
wire ss_restore_active = (ss_state == SST_RESTORE_HOLD_RST) || (ss_state == SST_RESTORE_WAIT_RST);

wire sel_save  = ss_override & ds_active & ss_saven_n;                          // SS_SAVEn
wire sel_vec   = ss_override & ds_active & (cpu_word_addr[23:2] == 22'h00001F); // 0x7C-0x7F -> SS_VECn
wire sel_rst   = ss_override & ds_active & ss_resetn_n;                         // SS_RESETn

assign ss_din_en   = sel_save | sel_vec | sel_rst;
assign ss_din_data = sel_save ? ss_irq_handler[cpu_word_addr[4:1]] :
                     sel_rst  ? ss_reset_vector[cpu_word_addr[2:1]] :
                     sel_vec  ? (cpu_word_addr[1] ? 16'h0000 : 16'h00FF) :  // PC eccezione = 0x00FF0000
                                16'h0000;

assign ss_irq      = (ss_state == SST_SAVE_WAIT_IRQ);
assign ss_reset    = (ss_state == SST_RESTORE_HOLD_RST);
assign ss_pause    = (ss_state != SST_IDLE);  // gioco fermo per tutta la durata del SS
assign ss_cpu_exec = ss_save_active | ss_restore_active;  // la CPU gira per eseguire handler/vettore

always @(posedge clk) begin
	ss_state_d   <= ss_state;
	ss_state_out <= ss_state;
end

// Pulse ss_restore_done: transizione SST_RESTORE_WAIT_RST -> SST_IDLE (restore completo, CPU
// ripartita su codice normale). Il top lo usa per riavviare il DMA palette e ricostruire pal_buf
// da pal_cpu (gia' ricaricata da memory_stream durante lo scatter).
assign ss_restore_done = (ss_state == SST_IDLE) && (ss_state_d == SST_RESTORE_WAIT_RST);

always @(posedge clk) begin
	ss_mem_write <= 1'b0;
	// ss_mem_read NON azzerato di default: e' un livello gestito dentro gli stati restore
	// (alzato in WAIT_PAUSE, abbassato in WAIT_READ su ss_busy) come F2 (pulse puro, no auto-clear).

	case (ss_state)
		SST_IDLE: begin
			ss_mem_read <= 1'b0;   // livello pulito a riposo (no auto-clear globale, come F2 reg ss_read=0)
			if (do_save)    ss_state <= SST_SAVE_WAIT_PAUSE;
			if (do_restore) ss_state <= SST_RESTORE_WAIT_PAUSE;
		end

		// WAIT_PAUSE (F2): parte SOLO quando paused_real=1 = pausa frame-aligned reale (CPU+audio
		// fermi davvero). paused_real = paused_safe_r del top (registrato a vblank), NON paused_safe
		// combinatorio. Si alza <=1 frame dopo ss_pause -> attesa VERA, non no-op.
		SST_SAVE_WAIT_PAUSE: begin
			if (paused_real) ss_state <= SST_SAVE_WAIT_IRQ;
		end

		SST_RESTORE_WAIT_PAUSE: begin
			if (paused_real) begin
				ss_mem_read <= 1'b1;   // pulse puro come F2 (F2.sv:346): alza read entrando in WAIT_READ
				ss_state <= SST_RESTORE_WAIT_READ;
			end
		end

		// SAVE: forza IRQ7 (ss_irq). Attende l'IACK liv7 (la CPU riconosce l'eccezione).
		SST_SAVE_WAIT_IRQ: begin
			if (~iack_n & (cpu_word_addr[3:1] == 3'b111) & ~cpu_ds_n[0])
				ss_state <= SST_SAVE_WAIT_SSP;
		end

		// Cattura l'SSP che il handler scrive a SS_SCRATCH (move.l a7,(a6) con a6=0xFF0000).
		SST_SAVE_WAIT_SSP: begin
			if (cpu_ds_n == 2'b00 && !cpu_rw && cpu_word_addr == SS_SCRATCH)
				ss_saved_ssp[31:16] <= cpu_data_out;
			if (cpu_ds_n == 2'b00 && !cpu_rw && cpu_word_addr == (SS_SCRATCH | 24'd2)) begin
				ss_saved_ssp[15:0] <= cpu_data_out;
				ss_mem_write <= 1'b1;
				ss_state <= SST_SAVE_WAIT_WRITE;
			end
		end

		// memory_stream salva tutto lo stato su DDR.
		SST_SAVE_WAIT_WRITE: begin
			if (~ss_busy & ~ss_mem_write) ss_state <= SST_SAVE_WAIT_EXIT;
		end

		// Attende che il handler faccia rte e la CPU torni a fetchare codice NORMALE
		// (fuori dal range save 0xFF00xx, F2: && SS_SAVEn). NON basta != SS_SCRATCH: la CPU
		// fetcha ancora il resto del handler a 0xFF0008..0xFF001E prima dell'rte.
		SST_SAVE_WAIT_EXIT: begin
			if (cpu_ds_n == 2'b00 && cpu_rw && cpu_fc == 3'b110 && ~ss_saven_n)
				ss_state <= SST_IDLE;
		end

		// RESTORE: memory_stream carica da DDR (ricarica RAM + ss_restore_ssp via ssbus).
		// Pulse puro IDENTICO a F2 (F2.sv:351-363): read alzato in WAIT_PAUSE; qui si abbassa
		// quando memory_stream diventa busy, poi si avanza quando ha finito. Niente ss_read_done.
		SST_RESTORE_WAIT_READ: begin
			if (ss_busy & ss_mem_read) begin
				ss_mem_read <= 1'b0;
			end else if (~ss_busy & ~ss_mem_read) begin
				ss_reset_vector[0] <= ss_restore_ssp[31:16];
				ss_reset_vector[1] <= ss_restore_ssp[15:0];
				ss_reset_vector[2] <= 16'h00FF;  // PC reset = 0x00FF0000 (handler restart point)
				ss_reset_vector[3] <= 16'h0008;
				ss_reset_counter <= 5'd0;
				ss_state <= SST_RESTORE_HOLD_RST;
			end
		end

		// Tiene reset N cicli (la CPU riparte dal reset-vector custom).
		SST_RESTORE_HOLD_RST: begin
			if (ce_cpu) begin
				ss_reset_counter <= ss_reset_counter + 5'd1;
				if (&ss_reset_counter) ss_state <= SST_RESTORE_WAIT_RST;
			end
		end

		// Attende la ripartenza della CPU su codice NORMALE: fuori da ENTRAMBI i range
		// save (0xFF00xx) e reset (0x00000x), F2: && SS_SAVEn && SS_RESETn. La CPU riparte
		// da 0x00FF0008 (restart handler) ed esegue lea/movem/rte prima di tornare al gioco.
		SST_RESTORE_WAIT_RST: begin
			if (cpu_ds_n == 2'b00 && cpu_rw && cpu_fc == 3'b110 && ~ss_saven_n && ~ss_resetn_n)
				ss_state <= SST_IDLE;
		end

		default: ss_state <= SST_IDLE;
	endcase
end

endmodule
