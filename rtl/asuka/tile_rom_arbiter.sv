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

// tile_rom_arbiter — Round-robin arbiter per tile e sprite ROM.
// Multiplexa i client su un singolo Port0 del sdram_bridge:
//   Client 0-2: tile renderer (LEFT/CENTER/RIGHT)
//   Client 3:   sprite renderer
//   Client 4:   unused (FG text ROM lives in BRAM, not SDRAM)
// Tutti usano letture 32-bit dalla SDRAM.

module tile_rom_arbiter (
	input  wire        clk,
	input  wire        reset,
	input  wire        hblank,   // FG gets exclusive access during hblank

	// Renderer 0 (LEFT)
	input  wire        r0_req,
	input  wire [23:0] r0_addr,
	output reg  [31:0] r0_data,
	output reg         r0_valid,

	// Renderer 1 (CENTER)
	input  wire        r1_req,
	input  wire [23:0] r1_addr,
	output reg  [31:0] r1_data,
	output reg         r1_valid,

	// Renderer 2 (RIGHT)
	input  wire        r2_req,
	input  wire [23:0] r2_addr,
	output reg  [31:0] r2_data,
	output reg         r2_valid,

	// Sprite renderer
	input  wire        r3_req,
	input  wire [23:0] r3_addr,
	output reg  [31:0] r3_data,
	output reg         r3_valid,

	// FG text renderer
	input  wire        r4_req,
	input  wire [23:0] r4_addr,
	output reg  [31:0] r4_data,
	output reg         r4_valid,

	// To sdram_bridge Port0
	output reg         tile_req,
	output reg  [23:0] tile_addr,
	output reg         tile_is_sprite,  // 1=sprite ROM, 0=tile ROM (for base address selection)
	output reg         tile_is_text,    // 1=text ROM (for TEXT_BASE offset)
	input  wire [31:0] tile_data,
	input  wire        tile_valid
);

// =====================================================================
// Tile ROM cache — 256-entry direct-mapped (per tile clients 0-2)
// =====================================================================
// Aumentato da 64 → 256 (2026-04-30) per ridurre thrashing tra 3 chip
// TC0100SCN (ognuno richiede ~36 row/scanline → 108 totali). Cache 64
// causava cache miss raffica in zone congestionate Ninja Warriors → flicker.
// Index = addr[9:2] (8 bits → 256 entries)
// Tag   = addr[19:10] (10 bits — copre l'intero tile ROM 1 MB)
// Data  = 32-bit tile row → 256×32 = 8192 bit = 1 M10K
reg [31:0] cache_data [0:255];
reg [9:0]  cache_tag  [0:255];
reg [255:0] cache_valid;

wire [7:0]  cache_idx    = tile_addr[9:2];
wire [9:0]  cache_tag_in = tile_addr[19:10];
wire        cache_hit    = cache_valid[cache_idx] && (cache_tag[cache_idx] == cache_tag_in);

// Sprite ROM cache RIMOSSA (sprite ora su DDR3 port 4 via sprite_rom_cache.sv).
// Client 3 dell'arbiter resta nei port per compat ma e' scollegato dall'esterno
// (r3_req=0). Liberati 2 M10K dello spr_cache_tag (gestione clear FSM).

// Rising edge detection on all 5 clients
reg r0_req_prev, r1_req_prev, r2_req_prev, r3_req_prev, r4_req_prev;

// Pending request bits — set on rising edge, cleared on grant
reg [4:0] pending;

// Latched addresses
reg [23:0] r0_addr_lat, r1_addr_lat, r2_addr_lat, r3_addr_lat, r4_addr_lat;

// Round-robin priority: which client to check first (0-4)
reg [2:0] next_prio;

// Active client being served
reg [2:0] active_client;

// FSM
localparam ARB_IDLE      = 3'd0;
localparam ARB_CHECK     = 3'd1;  // tile cache lookup result ready (combinatorial)
localparam ARB_WAIT      = 3'd3;  // waiting SDRAM
reg [2:0] arb_state;

// Detect any edge (toggle protocol: TC0100SCN toggles rom_req for each new request)
// Clients 0-2 use toggle protocol, clients 3-4 use rising edge
wire r0_rising = r0_req ^ r0_req_prev;
wire r1_rising = r1_req ^ r1_req_prev;
wire r2_rising = r2_req ^ r2_req_prev;
wire r3_rising = r3_req && !r3_req_prev;
wire r4_rising = r4_req && !r4_req_prev;

// Combinational grant selection (round-robin across 5 clients)
reg [2:0] grant_id;
reg       grant_found;
reg [23:0] grant_addr;

always @(*) begin
	grant_found = 0;
	grant_id    = 3'd0;
	grant_addr  = r0_addr_lat;

	if (hblank && pending[4]) begin
		// HBlank: FG text gets exclusive access for bandwidth
		grant_found = 1;
		grant_id    = 3'd4;
		grant_addr  = r4_addr_lat;
	end else if (pending[3]) begin
		// Priorita' assoluta sprite (client 3): scena densa scia/pesce
		// non puo' permettersi attese round-robin che fanno saltare tile.
		grant_found = 1;
		grant_id    = 3'd3;
		grant_addr  = r3_addr_lat;
	end else begin
		// Normal: round-robin tra tile renderers (0,1,2) e FG (4)
		begin : grant_search
			integer i;
			reg [2:0] check;
			reg [3:0] check_wide;
			for (i = 0; i < 5; i = i + 1) begin
				check_wide = {1'b0, next_prio} + i[3:0];
				check = (check_wide >= 4'd5) ? check_wide[2:0] - 3'd5 : check_wide[2:0];
				if (!grant_found && pending[check]) begin
					grant_id = check;
					case (check)
						3'd0: grant_addr = r0_addr_lat;
						3'd1: grant_addr = r1_addr_lat;
						3'd2: grant_addr = r2_addr_lat;
						3'd3: grant_addr = r3_addr_lat;
						3'd4: grant_addr = r4_addr_lat;
						default: grant_addr = r0_addr_lat;
					endcase
					grant_found = 1;
				end
			end
		end
	end
end

always @(posedge clk) begin
	if (reset) begin
		cache_valid     <= 256'b0;
		r0_req_prev  <= 0;
		r1_req_prev  <= 0;
		r2_req_prev  <= 0;
		r3_req_prev  <= 0;
		r4_req_prev  <= 0;
		pending      <= 5'b00000;
		r0_addr_lat  <= 0;
		r1_addr_lat  <= 0;
		r2_addr_lat  <= 0;
		r3_addr_lat  <= 0;
		r4_addr_lat  <= 0;
		next_prio    <= 0;
		active_client <= 0;
		arb_state    <= ARB_IDLE;
		tile_req     <= 0;
		tile_addr    <= 0;
		tile_is_sprite <= 0;
		tile_is_text   <= 0;
		r0_data      <= 0;
		r1_data      <= 0;
		r2_data      <= 0;
		r3_data      <= 0;
		r4_data      <= 0;
		r0_valid     <= 0;
		r1_valid     <= 0;
		r2_valid     <= 0;
		r3_valid     <= 0;
		r4_valid     <= 0;
	end else begin
		// Edge detection
		r0_req_prev <= r0_req;
		r1_req_prev <= r1_req;
		r2_req_prev <= r2_req;
		r3_req_prev <= r3_req;
		r4_req_prev <= r4_req;

		// Latch addresses and set pending on rising edge
		if (r0_rising) begin pending[0] <= 1'b1; r0_addr_lat <= r0_addr; end
		if (r1_rising) begin pending[1] <= 1'b1; r1_addr_lat <= r1_addr; end
		if (r2_rising) begin pending[2] <= 1'b1; r2_addr_lat <= r2_addr; end
		if (r3_rising) begin pending[3] <= 1'b1; r3_addr_lat <= r3_addr; end
		if (r4_rising) begin pending[4] <= 1'b1; r4_addr_lat <= r4_addr; end

		// Clear valid pulses (1-cycle)
		r0_valid <= 0;
		r1_valid <= 0;
		r2_valid <= 0;
		r3_valid <= 0;
		r4_valid <= 0;

		// Clear tile_req after 1 cycle (bridge detects rising edge)
		tile_req <= 0;

		case (arb_state)
			ARB_IDLE: begin
				if (grant_found) begin
					active_client  <= grant_id;
					pending[grant_id] <= 1'b0;
					// Latch grant address for cache/SDRAM use next cycle
					tile_addr      <= grant_addr;
					tile_is_sprite <= (grant_id == 3'd3);
					tile_is_text   <= (grant_id == 3'd4);
					arb_state      <= ARB_CHECK;
				end
			end

			ARB_CHECK: begin
				if (cache_hit && active_client != 3'd4) begin
					// Tile cache hit — deliver data (solo client 0-2)
					case (active_client)
						3'd0: begin r0_data <= cache_data[cache_idx]; r0_valid <= 1'b1; end
						3'd1: begin r1_data <= cache_data[cache_idx]; r1_valid <= 1'b1; end
						3'd2: begin r2_data <= cache_data[cache_idx]; r2_valid <= 1'b1; end
						default: ;
					endcase
					next_prio <= (active_client == 3'd4) ? 3'd0 : active_client + 3'd1;
					arb_state <= ARB_IDLE;
				end else begin
					// Cache miss o FG — fetch from SDRAM
					tile_req  <= 1'b1;
					arb_state <= ARB_WAIT;
				end
			end

			ARB_WAIT: begin
				if (tile_valid) begin
					case (active_client)
						3'd0: begin r0_data <= tile_data; r0_valid <= 1'b1; end
						3'd1: begin r1_data <= tile_data; r1_valid <= 1'b1; end
						3'd2: begin r2_data <= tile_data; r2_valid <= 1'b1; end
						3'd3: begin r3_data <= tile_data; r3_valid <= 1'b1; end
						3'd4: begin r4_data <= tile_data; r4_valid <= 1'b1; end
						default: ;
					endcase
					if (active_client <= 3'd2) begin
						cache_data[tile_addr[9:2]]  <= tile_data;
						cache_tag[tile_addr[9:2]]   <= tile_addr[19:10];
						cache_valid[tile_addr[9:2]] <= 1'b1;
					end
					next_prio <= (active_client == 3'd4) ? 3'd0 : active_client + 3'd1;
					arb_state <= ARB_IDLE;
				end
			end

			default: arb_state <= ARB_IDLE;
		endcase
	end
end

endmodule
