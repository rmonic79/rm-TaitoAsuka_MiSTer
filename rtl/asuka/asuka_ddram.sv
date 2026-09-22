//
// ddram.v
// Copyright (c) 2017 Sorgelig
//
//
// This source file is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version. 
//
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of 
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the 
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License 
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
//
// ------------------------------------------
//

// 8-bit version

module asuka_ddram
(
	input         DDRAM_CLK,

	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	input  [27:0] wraddr,
	input  [15:0] din,
	input         we_byte,  // 0:word write, 1:byte write
	// 1 = il master ha una transazione in ballo (in volo o richiesta pendente).
	// Serve al ddr_mux come 'acquire': quando e' 0 il bus va al rotate.
	output        ss_want,

	input         we_req,
	output reg    we_ack = 0,

	input     [27:0] rdaddr,
	output reg [7:0] dout = 0,
	input            rd_req,
	output reg       rd_ack = 0,

	input     [27:0] rdaddr2,
	output reg [7:0] dout2 = 0,
	input            rd_req2,
	output reg       rd_ack2 = 0,

	input     [27:0] rdaddr3,
	output reg [7:0] dout3 = 0,
	input            rd_req3,
	output reg       rd_ack3 = 0,

	// Port 4: 32-bit fetch dedicato (sprite ROM)
	// Diverso dai port 1-3 (8-bit) per evitare 4× round-trip su sprite-row.
	// Cache 8-byte come gli altri, ma dout4 espone 32-bit selezionati da rdaddr4[2].
	input     [27:0] rdaddr4,
	output reg [31:0] dout4 = 0,
	input            rd_req4,
	output reg       rd_ack4 = 0,

	input     [27:0] cpaddr,
	output reg[63:0] cpdout,
	output reg       cpwr,
	input            cpreq,
	output reg       cpbusy
);

reg  [7:0] ram_burst;
reg [63:0] ram_q, next_q, ram_q2, next_q2, ram_q3, next_q3, ram_q4, next_q4;
reg [63:0] ram_data;
reg [27:0] ram_address;
// cache_addr* inizializzati a '1 (tutti 1) cosi' il primo confronto cache fallisce
// SEMPRE e forza un fetch reale dal DDRAM. Senza questo init, al power-up
// cache_addr=0 e rdaddr=0 → match falso → Z80 legge ram_q=0 (8 NOP) invece della ROM.
reg [27:0] cache_addr  = '1;
reg [27:0] cache_addr2 = '1;
reg [27:0] cache_addr3 = '1;
reg [27:0] cache_addr4 = '1;
reg        ram_read = 0;
reg        ram_write = 0;
reg  [7:0] ram_wr_be;

reg [2:0]  state  = 0;
reg [2:0]  ch = 0;

assign DDRAM_BURSTCNT = ram_burst;
assign DDRAM_BE       = ram_wr_be | {8{ram_read}};
assign DDRAM_ADDR     = {4'b0011, ram_address[27:3]}; // RAM at 0x30000000
assign DDRAM_RD       = ram_read;
assign DDRAM_DIN      = ram_data;
assign DDRAM_WE       = ram_write;

always @(posedge DDRAM_CLK) begin
	reg old_cpreq;
	reg [6:0] cpcnt;

	cpwr <= 0;
	if(!DDRAM_BUSY) begin
		ram_write <= 0;
		ram_read  <= 0;

		case(state)
			0: if(we_ack != we_req) begin
					ram_data	<= we_byte ? {8{din[7:0]}} : {4{din}};
					ram_address <= wraddr;
					ram_write 	<= 1;
					ram_burst   <= 1;
					ram_wr_be   <= we_byte ? (8'd1<<{wraddr[2:0]}) : (8'd3<<{wraddr[2:1],1'b0});
					state       <= 1;
				end
				else if(rd_req != rd_ack) begin
					if(cache_addr[27:3] == rdaddr[27:3]) begin
						rd_ack      <= rd_req;
						dout        <= ram_q[{rdaddr[2:0],3'b000} +:8];
					end
					else if((cache_addr[27:3]+1'd1) == rdaddr[27:3]) begin
						rd_ack      <= rd_req;
						ram_q       <= next_q;
						dout        <= next_q[{rdaddr[2:0],3'b000} +:8];
						cache_addr  <= {rdaddr[27:3],3'b000};
						ram_address <= {rdaddr[27:3]+1'd1,3'b000};
						ram_read    <= 1;
						ram_burst   <= 1;
						ch 			<= 0; 
						state       <= 3;
					end
					else begin
						ram_address <= {rdaddr[27:3],3'b000};
						cache_addr  <= {rdaddr[27:3],3'b000};
						ram_read    <= 1;
						ram_burst   <= 2;
						ch 			<= 0; 
						state       <= 2;
					end 
				end
				else if(rd_req2 != rd_ack2) begin
					if(cache_addr2[27:3] == rdaddr2[27:3]) begin
						rd_ack2     <= rd_req2;
						dout2       <= ram_q2[{rdaddr2[2:0],3'b000} +:8];
					end
					else if((cache_addr2[27:3]+1'd1) == rdaddr2[27:3]) begin
						rd_ack2     <= rd_req2;
						ram_q2      <= next_q2;
						dout2       <= next_q2[{rdaddr2[2:0],3'b000} +:8];
						cache_addr2 <= {rdaddr2[27:3],3'b000};
						ram_address <= {rdaddr2[27:3]+1'd1,3'b000};
						ram_read    <= 1;
						ram_burst   <= 1;
						ch 			<= 1;
						state       <= 3;
					end
					else begin
						ram_address <= {rdaddr2[27:3],3'b000};
						cache_addr2 <= {rdaddr2[27:3],3'b000};
						ram_read    <= 1;
						ram_burst   <= 2;
						ch 			<= 1;
						state       <= 2;
					end 
				end 
				else if(rd_req3 != rd_ack3) begin
					if(cache_addr3[27:3] == rdaddr3[27:3]) begin
						rd_ack3     <= rd_req3;
						dout3       <= ram_q3[{rdaddr3[2:0],3'b000} +:8];
					end
					else if((cache_addr3[27:3]+1'd1) == rdaddr3[27:3]) begin
						rd_ack3     <= rd_req3;
						ram_q3      <= next_q3;
						dout3       <= next_q3[{rdaddr3[2:0],3'b000} +:8];
						cache_addr3 <= {rdaddr3[27:3],3'b000};
						ram_address <= {rdaddr3[27:3]+1'd1,3'b000};
						ram_read    <= 1;
						ram_burst   <= 1;
						ch 			<= 3'd2;
						state       <= 3;
					end
					else begin
						ram_address <= {rdaddr3[27:3],3'b000};
						cache_addr3 <= {rdaddr3[27:3],3'b000};
						ram_read    <= 1;
						ram_burst   <= 2;
						ch 			<= 3'd2;
						state       <= 2;
					end
				end
				else if(rd_req4 != rd_ack4) begin
					if(cache_addr4[27:3] == rdaddr4[27:3]) begin
						rd_ack4     <= rd_req4;
						dout4       <= ram_q4[{rdaddr4[2],5'b00000} +:32];
					end
					else if((cache_addr4[27:3]+1'd1) == rdaddr4[27:3]) begin
						rd_ack4     <= rd_req4;
						ram_q4      <= next_q4;
						dout4       <= next_q4[{rdaddr4[2],5'b00000} +:32];
						cache_addr4 <= {rdaddr4[27:3],3'b000};
						ram_address <= {rdaddr4[27:3]+1'd1,3'b000};
						ram_read    <= 1;
						ram_burst   <= 1;
						ch 			<= 3'd3;
						state       <= 3;
					end
					else begin
						ram_address <= {rdaddr4[27:3],3'b000};
						cache_addr4 <= {rdaddr4[27:3],3'b000};
						ram_read    <= 1;
						ram_burst   <= 2;
						ch 			<= 3'd3;
						state       <= 2;
					end
				end else begin
					cpbusy         <= 0;
					old_cpreq <= cpreq;
					if(~old_cpreq & cpreq) begin
						ram_address <= {cpaddr[27:3],3'b000};
						ram_burst   <= 128;
						ram_read    <= 1;
						state       <= 4;
						cpcnt       <= 127;
						cpbusy      <= 1;
					end
				end

			1: begin
					cache_addr <= '1;
					cache_addr2 <= '1;
					cache_addr3 <= '1;
					cache_addr4 <= '1;
					cache_addr[3:0] <= 0;
					cache_addr2[3:0] <= 0;
					cache_addr3[3:0] <= 0;
					cache_addr4[3:0] <= 0;
					we_ack <= we_req;
					state  <= 0;
				end

			2: if(DDRAM_DOUT_READY) begin
					if (ch==3'd0) begin
						ram_q  <= DDRAM_DOUT;
						dout   <= DDRAM_DOUT[{rdaddr[2:0],3'b000} +:8];
						rd_ack <= rd_req;
					end
					else if (ch==3'd1) begin
						ram_q2  <= DDRAM_DOUT;
						dout2   <= DDRAM_DOUT[{rdaddr2[2:0],3'b000} +:8];
						rd_ack2 <= rd_req2;
					end
					else if (ch==3'd2) begin
						ram_q3  <= DDRAM_DOUT;
						dout3   <= DDRAM_DOUT[{rdaddr3[2:0],3'b000} +:8];
						rd_ack3 <= rd_req3;
					end
					else begin
						ram_q4  <= DDRAM_DOUT;
						dout4   <= DDRAM_DOUT[{rdaddr4[2],5'b00000} +:32];
						rd_ack4 <= rd_req4;
					end
					state  <= 3;
				end

			3: if(DDRAM_DOUT_READY) begin
					if (ch==3'd0) begin
						next_q <= DDRAM_DOUT;
					end
					else if (ch==3'd1) begin
						next_q2 <= DDRAM_DOUT;
					end
					else if (ch==3'd2) begin
						next_q3 <= DDRAM_DOUT;
					end
					else begin
						next_q4 <= DDRAM_DOUT;
					end
					state  <= 0;
				end

			4: if(DDRAM_DOUT_READY) begin
					cpwr   <= 1;
					cpcnt  <= cpcnt - 1'd1;
					cpdout <= DDRAM_DOUT;
					if(!cpcnt) state <= 0;
				end
		endcase
	end
end

// Il bus si puo' cedere solo quando non c'e' niente in volo: nessuna emissione
// verso i pin (ram_read/ram_write), nessun write pendente e nessuna richiesta di
// lettura non ancora servita su nessuna delle 4 porte.
// NB: la porta copy NON entra qui. E' legata a cpreq=1'b0 (non si usa) e
// cpbusy e' un reg senza valore iniziale: metterlo in questa OR propagherebbe
// X in simulazione senza aggiungere niente.
assign ss_want = (state != 3'd0) | ram_read | ram_write
               | (we_ack  != we_req)
               | (rd_ack  != rd_req)  | (rd_ack2 != rd_req2)
               | (rd_ack3 != rd_req3) | (rd_ack4 != rd_req4);

endmodule
