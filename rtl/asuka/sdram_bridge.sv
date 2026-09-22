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

// sdram_bridge — Darius 2. Copia identica del bridge Darius 1 funzionante,
// modificando solo le BASE offset per il layout Darius 2.
// Multiplexa 3 client sul controller Genesis 4-port di Sorgelig:
//   Port 0: Tile/Sprite/Text ROM reads + ROM download writes
//   Port 1: Main CPU ROM
//   Port 2: Sub CPU ROM
//   Port 3: unused (audio Z80 ROM lives in BRAM, not SDRAM)

module sdram_bridge (
	input         clk,
	input         reset,
	input         sdram_ready,

	// Download from HPS
	input         ioctl_download,
	input         ioctl_wr,
	input  [26:0] ioctl_addr,
	input  [15:0] ioctl_dout,
	input  [15:0] ioctl_index,
	output        ioctl_wait,

	// Video / Tile ROM (port 0)
	input  [23:0] tile_byte_addr,
	input         tile_req,
	input         tile_is_sprite,
	input         tile_is_text,
	output [31:0] tile_data,
	output reg    tile_valid,

	// Sprite ROM dedicated (port 3) — toggle protocol come tile, 32-bit reads
	input  [23:0] spr_byte_addr,
	input         spr_req,
	output [31:0] spr_data,
	output reg    spr_valid,

	// Main CPU ROM (port 1)
	input  [23:0] main_byte_addr,
	input         main_req,
	output [15:0] main_data,
	output reg    main_ready,

	// Sub CPU ROM (port 2)
	input  [23:0] sub_byte_addr,
	input         sub_req,
	output [15:0] sub_data,
	output reg    sub_ready,

	// Genesis SDRAM controller ports
	output reg [24:1] sdram_addr0,
	output reg [15:0] sdram_din0,
	output reg        sdram_wrl0,
	output reg        sdram_wrh0,
	output reg        sdram_req0,
	input             sdram_ack0,
	input      [15:0] sdram_dout0,

	output reg [24:1] sdram_addr1,
	output     [15:0] sdram_din1,
	output             sdram_wrl1,
	output             sdram_wrh1,
	output reg        sdram_req1,
	input             sdram_ack1,
	input      [15:0] sdram_dout1,

	output reg [24:1] sdram_addr2,
	output     [15:0] sdram_din2,
	output             sdram_wrl2,
	output             sdram_wrh2,
	output reg        sdram_req2,
	input             sdram_ack2,
	input      [15:0] sdram_dout2,

	output wire [24:1] sdram_addr3,
	output wire [15:0] sdram_din3,
	output wire        sdram_wrl3,
	output wire        sdram_wrh3,
	output wire        sdram_req3,
	input             sdram_ack3,
	input      [15:0] sdram_dout3,

	// Debug
	output wire        dbg_main_pending,
	output wire        dbg_download_active,
	// SDRAM peek: reads word 0 from all 4 banks cyclically via port 3
	// dbg_peek_val = value in bank 0 (first seen value)
	// dbg_peek_match = 1 if banks 1/2/3 all match bank 0 (bank dup OK)
	output reg  [15:0] dbg_peek_val,
	output reg         dbg_peek_match
);

// CPU/Audio ROM ports are read-only
assign sdram_din1 = 16'd0;
assign sdram_wrl1 = 1'b0;
assign sdram_wrh1 = 1'b0;
assign sdram_din2 = 16'd0;
assign sdram_wrl2 = 1'b0;
assign sdram_wrh2 = 1'b0;
assign sdram_din3 = 16'd0;
assign sdram_wrl3 = 1'b0;
assign sdram_wrh3 = 1'b0;

// ================================================================
// SDRAM layout (word addresses)
// Darius 2 MRA order: main -> sub -> audio -> sprite -> tile -> adpcm
// ================================================================
// Layout allargato a 2MB sprite per supportare Ninja Warriors full.
// Darius 2 usa 1MB (upper half vuota). Ninjaw carica tutte 4 ROM (2MB).
localparam [23:0] MAIN_BASE   = 24'h000000;  // 768KB main CPU ROM   (byte 0x000000)
localparam [23:0] SUB_BASE    = 24'h060000;  // 512KB sub CPU slot   (byte 0x0C0000)
localparam [23:0] SPRITE_BASE = 24'h0A0000;  // 2MB sprite ROM slot  (byte 0x140000)
localparam [23:0] TILE_BASE   = 24'h1A0000;  // 1MB tile SCN ROM     (byte 0x340000)
localparam [23:0] TEXT_BASE   = 24'h1A0000;  // unused (FG text in TC0100SCN VRAM)

// ================================================================
// PORT 0: Download writes + Tile 32-bit reads
// ================================================================

// --- Download byte-pair assembler (identical to Darius 1) ---
reg        dl_phase;       // unused, kept for name parity (D1 had byte-pair but this logic is word-mode)
reg  [7:0] dl_hi_byte;
reg  [7:0] dl_lo_byte;
reg [26:0] dl_addr_save;
reg        dl_word_valid;
reg        dl_toggle;
reg        dl_wait_r;
reg  [1:0] dl_bank_idx;

wire dl_idle = (sdram_ack0 == dl_toggle);

reg download_active;
always @(posedge clk) begin
	if (reset)
		download_active <= 0;
	else if (ioctl_download)
		download_active <= 1;
	else if (dl_idle && !dl_wait_r)
		// FIX: scendere SOLO quando la sequenza bank 0..3 è completata.
		// dl_wait_r=1 significa che siamo ancora dentro una scrittura
		// multi-bank della word corrente; download_active deve restare alto
		// per non lasciare il mux Port 0 al branch tile prima della fine.
		download_active <= 0;
end

always @(posedge clk) begin
	if (reset) begin
		dl_toggle     <= 0;
		dl_wait_r     <= 0;
		dl_bank_idx   <= 2'd0;
	end else begin
		// FIX: NON resettare dl_wait_r al cadere di ioctl_download.
		// Se la sequenza bank 0..3 è in corso, lasciarla completare.
		// Altrimenti l'ultima word del download può perdere i bank 1/2/3.
		// (rimosso "if (~ioctl_download) dl_wait_r <= 0;")

		// WIDE=1: Genesis-style — latch word, then write to banks 0..3
		if (ioctl_download && ioctl_wr && ioctl_index == 16'd0) begin
			dl_hi_byte   <= ioctl_dout[15:8];
			dl_lo_byte   <= ioctl_dout[7:0];
			dl_addr_save <= ioctl_addr;
			dl_wait_r    <= 1;
			dl_bank_idx  <= 2'd0;
			dl_toggle    <= ~dl_toggle;
		end
		else if (dl_wait_r && dl_idle) begin
			if (dl_bank_idx < 2'd3) begin
				dl_bank_idx <= dl_bank_idx + 2'd1;
				dl_toggle   <= ~dl_toggle;
			end else begin
				dl_wait_r <= 0;
			end
		end
	end
end

assign ioctl_wait = dl_wait_r | (ioctl_download & ~sdram_ready);

// --- Tile 32-bit prefetch FSM (identical to Darius 1) ---
reg [2:0]  tile_state;
reg [15:0] tile_hi_word;
reg [15:0] tile_lo_word;
reg        tile_req_prev;
reg        tile_toggle;

localparam [2:0]
	TS_IDLE    = 3'd0,
	TS_REQ_HI  = 3'd1,
	TS_WAIT_HI = 3'd2,
	TS_REQ_LO  = 3'd3,
	TS_WAIT_LO = 3'd4;

wire tile_idle = (sdram_ack0 == tile_toggle);
wire [23:1] tile_word_addr = tile_byte_addr[23:1];

always @(posedge clk) begin
	if (reset || download_active) begin
		tile_state    <= TS_IDLE;
		tile_valid    <= 0;
		tile_toggle   <= dl_toggle;
		tile_req_prev <= 0;
	end else begin
		tile_valid    <= 0;
		tile_req_prev <= tile_req;

		case (tile_state)
			TS_IDLE: begin
				if (tile_req && !tile_req_prev) begin
					tile_state <= TS_REQ_HI;
				end
			end

			TS_REQ_HI: begin
				if (tile_idle) begin
					tile_toggle <= ~tile_toggle;
					tile_state  <= TS_WAIT_HI;
				end
			end

			TS_WAIT_HI: begin
				if (tile_idle) begin
					tile_hi_word <= sdram_dout0;
					tile_state   <= TS_REQ_LO;
				end
			end

			TS_REQ_LO: begin
				if (tile_idle) begin
					tile_toggle <= ~tile_toggle;
					tile_state  <= TS_WAIT_LO;
				end
			end

			TS_WAIT_LO: begin
				if (tile_idle) begin
					tile_lo_word <= sdram_dout0;
					tile_valid <= 1;
					tile_state <= TS_IDLE;
				end
			end

			default: tile_state <= TS_IDLE;
		endcase
	end
end

// Word-swap concat (SIM-verified MAME-compliant).
// tile_lo_word latched in TS_WAIT_LO per evitare race con fetch successivi
// che potrebbero alterare sdram_dout0 prima che l'arbiter campioni tile_data.
assign tile_data = {tile_lo_word, tile_hi_word};

// --- Port 0 mux: download OR tile (identical to Darius 1) ---
always @(*) begin
	if (download_active) begin
		sdram_addr0 = {dl_bank_idx, dl_addr_save[22:1]};
		sdram_din0  = {dl_hi_byte, dl_lo_byte};
		sdram_wrl0  = 1'b1;
		sdram_wrh0  = 1'b1;
		sdram_req0  = dl_toggle;
	end else begin
		begin
			reg [23:0] gfx_base;
			reg [23:0] gfx_addr;
			gfx_base = tile_is_text ? TEXT_BASE : tile_is_sprite ? SPRITE_BASE : TILE_BASE;
			case (tile_state)
				TS_WAIT_HI,
				TS_REQ_HI:  gfx_addr = {1'b0, tile_word_addr} + gfx_base;
				TS_WAIT_LO,
				TS_REQ_LO:  gfx_addr = {1'b0, tile_word_addr} + gfx_base + 24'd1;
				default:     gfx_addr = {1'b0, tile_word_addr} + gfx_base;
			endcase
			sdram_addr0 = {2'b00, gfx_addr[21:0]};
		end
		sdram_din0  = 16'd0;
		sdram_wrl0  = 1'b0;
		sdram_wrh0  = 1'b0;
		sdram_req0  = tile_toggle;
	end
end

// ================================================================
// PORT 1: Main CPU ROM (identical to Darius 1)
// ================================================================
reg        main_req_prev;
reg        main_pending;
reg [15:0] main_data_reg;

always @(posedge clk) begin
	if (reset) begin
		sdram_req1    <= 0;
		main_pending  <= 0;
		main_ready    <= 0;
		main_req_prev <= 0;
		main_data_reg <= 16'd0;
	end else begin
		main_ready    <= 0;
		main_req_prev <= main_req;

		if (main_req && !main_req_prev && !main_pending) begin
			sdram_req1   <= ~sdram_req1;
			main_pending <= 1;
		end

		if (main_pending && (sdram_ack1 == sdram_req1)) begin
			main_data_reg <= sdram_dout1;
			main_ready    <= 1;
			main_pending  <= 0;
		end
	end
end

assign main_data = main_data_reg;
assign dbg_main_pending   = main_pending;
assign dbg_download_active = download_active;

always @(*) begin
	reg [23:0] main_word;
	main_word = {1'b0, main_byte_addr[23:1]} + MAIN_BASE;
	sdram_addr1 = {2'b01, main_word[21:0]};
end

// ================================================================
// PORT 2: Sub CPU ROM (identical to Darius 1)
// ================================================================
reg        sub_req_prev;
reg        sub_pending;
reg [15:0] sub_data_reg;

always @(posedge clk) begin
	if (reset) begin
		sdram_req2    <= 0;
		sub_pending   <= 0;
		sub_ready     <= 0;
		sub_req_prev  <= 0;
		sub_data_reg  <= 16'd0;
	end else begin
		sub_ready    <= 0;
		sub_req_prev <= sub_req;

		if (sub_req && !sub_req_prev && !sub_pending) begin
			sdram_req2  <= ~sdram_req2;
			sub_pending <= 1;
		end

		if (sub_pending && (sdram_ack2 == sdram_req2)) begin
			sub_data_reg <= sdram_dout2;
			sub_ready    <= 1;
			sub_pending  <= 0;
		end
	end
end

assign sub_data = sub_data_reg;

always @(*) begin
	reg [23:0] sub_word;
	sub_word = {1'b0, sub_byte_addr[23:1]} + SUB_BASE;
	sdram_addr2 = {2'b10, sub_word[21:0]};
end

// ================================================================
// PORT 3: Sprite ROM dedicated 32-bit prefetch FSM
// ================================================================
// Stessa logica del path tile su port 0 (TS_REQ_HI/LO/...) ma su SDRAM
// port 3 dedicata. Elimina contention sprite-vs-tile.
// Toggle protocol: spr_req cambia → bridge legge 2 word consecutive,
// concat word-swap come tile, e alza spr_valid 1 ck quando il dato è pronto.

reg [2:0]  spr_state;
reg [15:0] spr_hi_word;
reg [15:0] spr_lo_word;
reg        spr_req_prev;
reg        spr_toggle;

reg [24:1] sdram_addr3_r;
reg        sdram_req3_r;
assign sdram_addr3 = sdram_addr3_r;
assign sdram_req3  = sdram_req3_r;

localparam [2:0]
	SS_IDLE    = 3'd0,
	SS_REQ_HI  = 3'd1,
	SS_WAIT_HI = 3'd2,
	SS_REQ_LO  = 3'd3,
	SS_WAIT_LO = 3'd4;

wire spr_idle = (sdram_ack3 == spr_toggle);
wire [23:1] spr_word_addr = spr_byte_addr[23:1];
wire [23:0] spr_addr_full_hi = {1'b0, spr_word_addr} + SPRITE_BASE;
wire [23:0] spr_addr_full_lo = {1'b0, spr_word_addr} + SPRITE_BASE + 24'd1;

always @(posedge clk) begin
	if (reset) begin
		spr_state    <= SS_IDLE;
		spr_valid    <= 0;
		spr_toggle   <= 0;
		sdram_req3_r <= 0;
		spr_req_prev <= 0;
		sdram_addr3_r<= 24'd0;
	end else begin
		spr_valid    <= 0;
		spr_req_prev <= spr_req;

		case (spr_state)
			SS_IDLE: begin
				// rising edge nuovo request → comincia fetch high word
				if (spr_req != spr_req_prev) begin
					spr_state <= SS_REQ_HI;
				end
			end

			SS_REQ_HI: begin
				if (spr_idle) begin
					sdram_addr3_r <= {2'b00, spr_addr_full_hi[21:0]};
					spr_toggle    <= ~spr_toggle;
					sdram_req3_r  <= ~sdram_req3_r;
					spr_state     <= SS_WAIT_HI;
				end
			end

			SS_WAIT_HI: begin
				if (spr_idle) begin
					spr_hi_word <= sdram_dout3;
					spr_state   <= SS_REQ_LO;
				end
			end

			SS_REQ_LO: begin
				if (spr_idle) begin
					sdram_addr3_r <= {2'b00, spr_addr_full_lo[21:0]};
					spr_toggle    <= ~spr_toggle;
					sdram_req3_r  <= ~sdram_req3_r;
					spr_state     <= SS_WAIT_LO;
				end
			end

			SS_WAIT_LO: begin
				if (spr_idle) begin
					spr_lo_word <= sdram_dout3;
					spr_valid   <= 1;
					spr_state   <= SS_IDLE;
				end
			end

			default: spr_state <= SS_IDLE;
		endcase
	end
end

assign spr_data = {spr_lo_word, spr_hi_word};

// Debug peek: dismesso (port 3 ora dedicata sprite ROM). Tied costanti.
always @(posedge clk) begin
	dbg_peek_val   <= 16'hDEAD;
	dbg_peek_match <= 1'b0;
end

endmodule
