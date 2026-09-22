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

// sprite_rom_cache.sv — cache 2-way set associative + DDR3 backend.
//
// Sprite ROM ora vive in DDR3 (port 4 del asuka_ddram), non piu' in SDRAM.
// Questo libera completamente la SDRAM port 0 per i 3 chip TC0100SCN +
// elimina la serializzazione tra port 0 e port 3 della SDRAM.
//
// Protocolli:
//   - Lato renderer: rising edge su `req_pulse`, addr stabile, `resp_valid` 1 ck con `resp_data`
//   - Lato DDR3: toggle protocol (`ddr_req` flip = nuova request, `ddr_ack` flip = dato pronto)
//
// Cache 2-way set associative, 1024 set × 2 way = 2048 entry totali.
//   Index = addr[11:2] (10 bit → 1024 set)
//   Tag   = addr[21:12] (10 bit)

module sprite_rom_cache #(
	parameter [27:0] DDR_BASE_ADDR = 28'h0400000   // offset sprite ROM in DDR3
)(
	input  wire        clk,
	input  wire        reset,

	// Renderer interface (rising-edge protocol)
	input  wire [23:0] req_addr,
	input  wire        req_pulse,
	output reg  [31:0] resp_data,
	output reg         resp_valid,

	// DDR3 read port 4 (toggle protocol, 32-bit data)
	output reg  [27:0] ddr_addr,
	output reg         ddr_req,
	input  wire [31:0] ddr_data,
	input  wire        ddr_ack
);

// =====================================================================
// 2-way set associative cache
// =====================================================================
(* ramstyle = "M10K" *) reg [31:0] cache_data_w0 [0:1023];
(* ramstyle = "M10K" *) reg [31:0] cache_data_w1 [0:1023];
(* ramstyle = "M10K" *) reg [10:0] cache_tag_w0  [0:1023];   // [10]=valid, [9:0]=tag
(* ramstyle = "M10K" *) reg [10:0] cache_tag_w1  [0:1023];
// LRU 1-bit per set: 0=way0 LRU, 1=way1 LRU.
reg lru [0:1023];

wire [9:0]  req_idx    = req_addr[11:2];
wire [9:0]  req_tag_in = req_addr[21:12];

// Clear post-reset: 1024 cicli azzerano tag (valid=0) per entrambe le way
reg [9:0]  clr_cnt;
reg        cache_ready;

// BRAM lookup registered (1 ck latency)
reg [31:0] cache_data_q_w0, cache_data_q_w1;
reg [10:0] cache_tag_q_w0,  cache_tag_q_w1;
reg [9:0]  req_tag_q;
reg [9:0]  req_idx_q;
reg        lru_q;

always @(posedge clk) begin
	cache_data_q_w0 <= cache_data_w0[req_idx];
	cache_data_q_w1 <= cache_data_w1[req_idx];
	cache_tag_q_w0  <= cache_tag_w0[req_idx];
	cache_tag_q_w1  <= cache_tag_w1[req_idx];
	lru_q           <= lru[req_idx];
	req_tag_q       <= req_tag_in;
	req_idx_q       <= req_idx;
end

wire hit_w0 = cache_ready && cache_tag_q_w0[10] && (cache_tag_q_w0[9:0] == req_tag_q);
wire hit_w1 = cache_ready && cache_tag_q_w1[10] && (cache_tag_q_w1[9:0] == req_tag_q);
wire cache_hit = hit_w0 | hit_w1;

// =====================================================================
// FSM
// =====================================================================
localparam ST_CLEAR    = 2'd0;
localparam ST_IDLE     = 2'd1;
localparam ST_LOOKUP   = 2'd2;
localparam ST_WAIT_RAM = 2'd3;

reg [1:0]  state;
reg [23:0] pending_addr;

reg        cache_we_w0, cache_we_w1;
reg [9:0]  cache_we_idx;
reg [10:0] cache_we_tag;
reg [31:0] cache_we_data;
reg        lru_we;
reg        lru_we_val;

always @(posedge clk) begin
	if (cache_we_w0) begin
		cache_data_w0[cache_we_idx] <= cache_we_data;
		cache_tag_w0 [cache_we_idx] <= cache_we_tag;
	end
	if (cache_we_w1) begin
		cache_data_w1[cache_we_idx] <= cache_we_data;
		cache_tag_w1 [cache_we_idx] <= cache_we_tag;
	end
	if (lru_we) begin
		lru[cache_we_idx] <= lru_we_val;
	end
end

// DDR3 protocol: dato pronto quando ddr_ack si allinea a ddr_req (entrambi
// fanno toggle, quando uguali la write/read e' completata dal backend).

always @(posedge clk) begin
	if (reset) begin
		state         <= ST_CLEAR;
		clr_cnt       <= 10'd0;
		cache_ready   <= 1'b0;
		ddr_req       <= 1'b0;
		ddr_addr      <= 28'd0;
		resp_valid    <= 1'b0;
		resp_data     <= 32'd0;
		pending_addr  <= 24'd0;
		cache_we_w0   <= 1'b0;
		cache_we_w1   <= 1'b0;
		cache_we_idx  <= 10'd0;
		cache_we_tag  <= 11'd0;
		cache_we_data <= 32'd0;
		lru_we        <= 1'b0;
		lru_we_val    <= 1'b0;
	end else begin
		resp_valid   <= 1'b0;
		cache_we_w0  <= 1'b0;
		cache_we_w1  <= 1'b0;
		lru_we       <= 1'b0;

		case (state)
			ST_CLEAR: begin
				cache_we_w0  <= 1'b1;
				cache_we_w1  <= 1'b1;
				cache_we_idx <= clr_cnt;
				cache_we_tag <= 11'd0;     // valid=0
				cache_we_data<= 32'd0;
				if (clr_cnt == 10'd1023) begin
					cache_ready <= 1'b1;
					state       <= ST_IDLE;
				end else begin
					clr_cnt <= clr_cnt + 10'd1;
				end
			end

			ST_IDLE: begin
				if (req_pulse) begin
					pending_addr <= req_addr;
					state        <= ST_LOOKUP;
				end
			end

			ST_LOOKUP: begin
				if (cache_hit) begin
					resp_data    <= hit_w0 ? cache_data_q_w0 : cache_data_q_w1;
					resp_valid   <= 1'b1;
					cache_we_idx <= req_idx_q;
					lru_we       <= 1'b1;
					lru_we_val   <= hit_w0 ? 1'b1 : 1'b0;
					state        <= ST_IDLE;
				end else begin
					// Lancia DDR3 fetch (offset DDR base + pending_addr 24-bit)
					ddr_addr <= DDR_BASE_ADDR + {4'd0, pending_addr};
					ddr_req  <= ~ddr_req;
					state    <= ST_WAIT_RAM;
				end
			end

			ST_WAIT_RAM: begin
				if (ddr_req == ddr_ack) begin
					resp_data    <= ddr_data;
					resp_valid   <= 1'b1;
					cache_we_idx <= pending_addr[11:2];
					cache_we_tag <= {1'b1, pending_addr[21:12]};
					cache_we_data<= ddr_data;
					if (lru_q) cache_we_w1 <= 1'b1;
					else       cache_we_w0 <= 1'b1;
					lru_we     <= 1'b1;
					lru_we_val <= ~lru_q;
					state      <= ST_IDLE;
				end
			end

			default: state <= ST_IDLE;
		endcase
	end
end

endmodule
