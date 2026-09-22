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
    Version: 0.1
    Date: 2026

*/

// asuka_maincpu_map — Memory map del Main 68000 per Cadash (Taito Asuka).
//
// MAME: cadash_state::main_map (asuka.cpp:638)
//
// $000000-$07FFFF  ROM (512 KB)             → SDRAM
// $080000-$080003  PC090OJ sprite ctrl      → stub (per ora)
// $0C0001          PC060HA master_port_w    → sound comm
// $0C0003          PC060HA master_comm_r/w  → sound comm
// $100000-$107FFF  Main RAM (32 KB)         → BRAM
// $800000-$800FFF  Network RAM Z180 (LAN)   → stub (multiplayer LAN, futuro)
// $900000-$90000F  TC0220IOC (8-bit even)   → registri (al posto di TC0040IOC)
// $A00000-$A0000F  TC0110PCR palette        → top decode
// $B00000-$B03FFF  PC090OJ sprite RAM       → BRAM
// $C00000-$C0FFFF  TC0100SCN tilemap RAM    → top decode
// $C20000-$C2000F  TC0100SCN ctrl           → top decode

module asuka_maincpu_map
(
	input  wire        clk,
	input  wire        reset,

	// Mappa di memoria del 68000 (MAME asuka.cpp):
	//   0 = cadash_state::main_map  (Cadash)
	//   1 = msm_state::asuka_map    (Asuka & Asuka, Galmedes, Earth Joker, Maze of Flott)
	// Cambia dove stanno IOC, PCR, PC060HA, sprite RAM e sprite ctrl.
	input  wire        map_asuka,
	// Eto Monogatari ha una mappa sua (base_state::eto_map): stessi chip,
	// indirizzi tutti diversi. Vale piu' di map_asuka dove le due si toccano.
	input  wire        map_eto,
	// Bonze Adventure (bonzeadv_state::main_map): niente TC0220IOC, i due DIP
	// si leggono diretti dal bus e gli ingressi passano dal C-Chip.
	input  wire        map_bonze,
	// DIP come arrivano dall'MRA: [7:0] DSWA, [15:8] DSWB. Li usa solo bonze.
	input  wire [15:0] dsw_word,

	// CPU bus
	input  wire [23:0] bus_addr,
	input  wire        bus_asn,
	input  wire        bus_rnw,
	input  wire [1:0]  bus_dsn,
	input  wire [15:0] bus_wdata,
	output wire [15:0] bus_rdata,
	output reg         bus_cs,
	output reg         bus_busy,

	// Byte enable (active high, derived from DSn active low)
	output wire [1:0]  bus_be,

	// ROM (SDRAM via rom_cache)
	output reg  [23:0] rom_addr,
	output reg         rom_req,
	input  wire [15:0] rom_rdata,
	input  wire        rom_ready,

	// Main RAM (64 KB)
	output reg         ram_rd,
	output reg         ram_wr,
	output reg  [1:0]  ram_be_o,    // latched byte enable (bus_be changes when DSn de-asserts)
	output reg  [14:0] ram_addr_o,
	output reg  [15:0] ram_wdata,
	input  wire [15:0] ram_rdata,

	// Shared RAM (64 KB, dual-port — Port A = main)
	output reg         shared_rd,
	output reg         shared_wr,
	output reg  [1:0]  shared_be_o,  // latched byte enable
	output reg  [14:0] shared_addr,
	output reg  [15:0] shared_wdata,
	input  wire [15:0] shared_rdata,
	input  wire        shared_ready,

	// Sprite RAM (16 KB, dual-port — Port A = main)
	output reg         sprite_rd,
	output reg         sprite_wr,
	output reg  [1:0]  sprite_be_o,  // latched byte enable
	output reg  [12:0] sprite_addr,
	output reg  [15:0] sprite_wdata,
	input  wire [15:0] sprite_rdata,
	input  wire        sprite_ready,

	// TC0220IOC (Cadash) — 3-bit address, direct register access
	output wire        ioc_cs,
	output wire        ioc_rnw,
	output wire  [2:0] ioc_addr,
	output wire  [7:0] ioc_wdata,
	input  wire  [7:0] ioc_rdata,  // combinational from tc0220ioc module

	// CPUA ctrl (Cadash: NON usato — single 68k)
	output reg         cpua_ctrl_wr,
	output reg   [7:0] cpua_ctrl_data,
	input  wire  [7:0] cpua_ctrl_q,

	// PC090OJ sprite ctrl ($080000-$080003 Cadash). Solo bit[5:2] per colbank.
	output reg         spr_ctrl_wr,
	output reg  [15:0] spr_ctrl_data,

	// TC0140SYT sound comm (active low, directly to TC0140SYT in top)
	output reg         syt_cs_n,
	output reg         syt_wr_n,
	output reg         syt_rd_n,
	output reg         syt_a1,
	input  wire  [3:0] syt_main_dout,  // dato di ritorno dal TC0140SYT vero (audio_top)

	// TC0100SCN / TC0110PCR — directly decoded in top, not here.
	// The memory map only needs to NOT assert bus_cs/bus_busy for those ranges.
	// The decode for SCN/PCR chip selects is in asuka_top.sv.

	// VBlank status (active high during vblank)
	input  wire        vblank,
	// External DTACK from SCN/palette chips (0 = chip responded)
	input  wire        ext_dtack_n,
	// Debug
	output wire [3:0]  dbg_txn_state
);

assign bus_be = ~bus_dsn;

// --- I/O devices rdata (latched inside FSM for simple devices) ---
reg [15:0] io_rdata;  // TC0040IOC, watchdog, cpua_ctrl, SYT
reg  [3:0] syt_mode;  // TC0140SYT master mode latched on write to $220001
reg        syt_active;  // 1 mentre la transazione corrente e' verso il SYT (CS stretch)

// --- Address decode ---
// Le due mappe, riga per riga (MAME asuka.cpp):
//                        cadash main_map        asuka_map
//   ROM                  000000-07FFFF          000000-0FFFFF  (040000-07FFFF vuoto)
//   PC090OJ sprite ctrl  080000-080003          3A0000-3A0003
//   PC060HA sound comm   0C0000-0C0003          3E0000-3E0003
//   work RAM             100000-107FFF (32K)    100000-103FFF (16K)
//   network RAM Z180     800000-800FFF          non c'e'
//   TC0220IOC            900000-90000F          400000-40000F
//   TC0110PCR palette    A00000-A0000F          200000-20000F
//   PC090OJ sprite RAM   B00000-B03FFF          D00000-D03FFF
//   TC0100SCN RAM        C00000-C0FFFF          uguale
//   TC0100SCN ctrl       C20000-C2000F          uguale
wire bus_active = ~bus_asn && (bus_dsn != 2'b11);

//   eto (base_state::eto_map, asuka.cpp:653):
//   ROM                  000000-0FFFFF
//   TC0110PCR palette    100000-10000F
//   work RAM             200000-203FFF (16K)
//   TC0220IOC            300000-30000F   piu' un mirror in sola lettura
//                                        a 400000-40000F (service mode)
//   PC090OJ sprite ctrl  4A0000-4A0003
//   PC060HA sound comm   4E0000-4E0003
//   PC090OJ sprite RAM   C00000-C03FFF
//   TC0100SCN RAM        D00000-D0FFFF   piu' un mirror in sola scrittura
//                                        a C04000-C0FFFF, sopra la sprite RAM
//   TC0100SCN ctrl       D20000-D2000F
//   bonze (bonzeadv_state::main_map, asuka.cpp:597):
//   ROM                  000000-03FFFF e 080000-0FFFFF (il buco in mezzo
//                                        non e' decodificato, come su asuka)
//   TC0110PCR palette    200000-200007
//   DSWA in lettura      390000-390001   diretti, niente TC0220IOC
//   PC090OJ sprite ctrl  3A0000-3A0001
//   DSWB in lettura      3B0000-3B0001
//   watchdog             3C0000          scrittura, la ignoriamo
//   PC060HA/TC0140SYT    3E0000-3E0003
//   C-Chip               800000-8007FF RAM condivisa, 800800-800FFF ASIC
//   work RAM             10C000-10FFFF (16K)
//   TC0100SCN RAM/ctrl   C00000-C0FFFF / C20000-C2000F  come asuka
//   PC090OJ sprite RAM   D00000-D03FFF                  come asuka
wire [23:0] ROM_LAST    = (map_asuka | map_eto | map_bonze) ? 24'h0FFFFF : 24'h07FFFF;
wire [23:0] SPRCTL_BASE = map_eto ? 24'h4A0000 : (map_asuka | map_bonze) ? 24'h3A0000 : 24'h080000;
wire [23:0] SYT_BASE    = map_eto ? 24'h4E0000 : (map_asuka | map_bonze) ? 24'h3E0000 : 24'h0C0000;
wire [23:0] RAM_BASE    = map_bonze ? 24'h10C000 : map_eto ? 24'h200000 : 24'h100000;
wire [23:0] RAM_LAST    = map_bonze ? 24'h10FFFF : map_eto ? 24'h203FFF : map_asuka ? 24'h103FFF : 24'h107FFF;
wire [23:0] IOC_BASE    = map_eto ? 24'h300000 : map_asuka ? 24'h400000 : 24'h900000;
wire [23:0] PCR_BASE    = map_eto ? 24'h100000 : (map_asuka | map_bonze) ? 24'h200000 : 24'hA00000;
wire [23:0] SPRRAM_BASE = map_eto ? 24'hC00000 : (map_asuka | map_bonze) ? 24'hD00000 : 24'hB00000;
wire [23:0] SCN_BASE    = map_eto ? 24'hD00000 : 24'hC00000;
wire [23:0] SCNCTL_BASE = map_eto ? 24'hD20000 : 24'hC20000;

// ROM 512 KB diretto, no mirror bit 20
wire [23:0] rom_addr_masked = bus_addr;
wire sel_rom     = bus_active && (bus_addr <= ROM_LAST);
wire sel_spr_ctrl= bus_active && (bus_addr >= SPRCTL_BASE) && (bus_addr <= SPRCTL_BASE + 24'h3);
wire sel_syt     = bus_active && (bus_addr >= SYT_BASE)    && (bus_addr <= SYT_BASE    + 24'h3);
wire sel_ram     = bus_active && (bus_addr >= RAM_BASE)    && (bus_addr <= RAM_LAST);
// $800000-$800FFF: su Cadash e' la network RAM del Z180, su Bonze e' la
// finestra del C-Chip (2 KB di RAM condivisa piu' i registri ASIC). Stesso
// indirizzo, stesso blocco di RAM, due clienti diversi. Sulle mappe asuka ed
// eto non e' decodificata e non deve rispondere.
wire sel_shared  = bus_active && ~map_asuka && ~map_eto && ~map_bonze &&
                   (bus_addr >= 24'h800000) && (bus_addr <= 24'h800FFF);
// Su Bonze la stessa finestra e' il C-Chip: chip esterno, risponde lui col
// suo DTACK e il dato arriva dal mux del top.
wire sel_cchip   = bus_active && map_bonze &&
                   (bus_addr >= 24'h800000) && (bus_addr <= 24'h800FFF);
// Su eto l'IOC risponde anche a 400000-40000F, ma in sola LETTURA: e' il
// mirror che il gioco usa per il service mode (asuka.cpp:657).
wire sel_ioc     = bus_active && ~map_bonze &&
                   ( ((bus_addr >= IOC_BASE) && (bus_addr <= IOC_BASE + 24'hF))
                   | (map_eto && bus_rnw &&
                      (bus_addr >= 24'h400000) && (bus_addr <= 24'h40000F)) );
// Bonze legge i DIP direttamente dal bus, a due indirizzi suoi. La parola
// vale 00xx come in MAME, dove la porta e' a 8 bit e i bit alti restano a 0.
wire sel_dswa    = bus_active && map_bonze && bus_rnw &&
                   (bus_addr >= 24'h390000) && (bus_addr <= 24'h390001);
wire sel_dswb    = bus_active && map_bonze && bus_rnw &&
                   (bus_addr >= 24'h3B0000) && (bus_addr <= 24'h3B0001);
wire sel_sprite  = bus_active && (bus_addr >= SPRRAM_BASE) && (bus_addr <= SPRRAM_BASE + 24'h3FFF);

// SCN e PCR: il decode vero sta nel top, qui serve solo a sapere che la
// risposta arriva da fuori. Il mirror in scrittura di eto sta SOPRA la sprite
// RAM, quindi parte da C04000: i primi 16 KB restano sprite.
wire sel_scn_or_pal = bus_active &&
                      ( ((bus_addr >= PCR_BASE)    && (bus_addr <= PCR_BASE + 24'hF))      // PCR palette
                      | ((bus_addr >= SCN_BASE)    && (bus_addr <= SCN_BASE + 24'hFFFF))   // SCN RAM
                      | ((bus_addr >= SCNCTL_BASE) && (bus_addr <= SCNCTL_BASE + 24'hF))   // SCN ctrl
                      | (map_eto && ~bus_rnw &&
                         (bus_addr >= 24'hC04000) && (bus_addr <= 24'hC0FFFF)) );          // mirror SCN

// sel_ctrl (CPUA ctrl) NON usato su Cadash (single 68k) — tied 0
wire sel_ctrl = 1'b0;

// --- Combinational bus_rdata mux (Darius 1 style) ---
// bus_rdata must be valid in the SAME cycle as DTACK. A registered mux would
// delay data by 1 cycle and the CPU would latch stale values (memtest fails).
// SCN / palette reads come from the top-level composite mux (chip outputs).
assign bus_rdata = sel_rom     ? rom_rdata    :
                   sel_dswa    ? {8'h00, dsw_word[7:0]}  :
                   sel_dswb    ? {8'h00, dsw_word[15:8]} :
                   sel_ram     ? ram_rdata    :
                   sel_shared  ? shared_rdata :
                   sel_sprite  ? sprite_rdata :
                   sel_ioc     ? {8'h00, ioc_rdata} :
                   sel_ctrl    ? io_rdata     :
                   sel_syt     ? io_rdata     :
                   16'hFFFF;

// --- TC0040IOC shared via top module. This map provides cs/rnw/addr1/wdata. ---
// ioc_cs is pulsed during sel_ioc TXN_NONE so the top module latches writes.
reg        r_ioc_cs;
reg  [7:0] r_ioc_wdata;
assign ioc_cs    = r_ioc_cs;
assign ioc_rnw   = bus_rnw;
assign ioc_addr  = bus_addr[3:1];
assign ioc_wdata = r_ioc_wdata;

// --- FSM for bus transactions ---
localparam TXN_NONE       = 4'd0;
localparam TXN_ROM        = 4'd1;
localparam TXN_RAM_RD     = 4'd2;
localparam TXN_RAM_WR     = 4'd3;
localparam TXN_SHARED_RD  = 4'd4;
localparam TXN_SHARED_WR  = 4'd5;
localparam TXN_SPRITE_RD  = 4'd6;
localparam TXN_SPRITE_WR  = 4'd7;
localparam TXN_DONE       = 4'd8;
localparam TXN_EXT_WAIT   = 4'd9;  // hold bus_busy=1, DTACK from ext_dtack_n only
localparam TXN_RAM_RD_WAIT = 4'd10; // extra cycle for BRAM output register to settle

reg [3:0] txn_state;
assign dbg_txn_state = txn_state;

always @(posedge clk) begin
	if (reset) begin
		txn_state     <= TXN_NONE;
		bus_cs        <= 1'b0;
		bus_busy      <= 1'b0;
		io_rdata      <= 16'hFFFF;
		rom_req       <= 1'b0;
		rom_addr      <= 24'd0;
		ram_rd        <= 1'b0;
		ram_wr        <= 1'b0;
		shared_rd     <= 1'b0;
		shared_wr     <= 1'b0;
		sprite_rd     <= 1'b0;
		sprite_wr     <= 1'b0;
		cpua_ctrl_wr  <= 1'b0;
		cpua_ctrl_data <= 8'd0;
		spr_ctrl_wr   <= 1'b0;
		spr_ctrl_data <= 16'd0;
		syt_mode      <= 4'd0;
		syt_cs_n      <= 1'b1;
		syt_wr_n      <= 1'b1;
		syt_rd_n      <= 1'b1;
		syt_a1        <= 1'b0;
		syt_active    <= 1'b0;
		r_ioc_cs      <= 1'b0;
		r_ioc_wdata   <= 8'd0;
	end else begin
		// Defaults — pulse signals return to 0 each cycle.
		// syt_cs/wr/rd_n NON vengono resettati ogni ciclo: la durata e' gestita
		// da syt_active (alta per tutta la transazione 68000 verso il SYT).
		rom_req      <= 1'b0;
		ram_rd       <= 1'b0;
		ram_wr       <= 1'b0;
		shared_rd    <= 1'b0;
		shared_wr    <= 1'b0;
		sprite_rd    <= 1'b0;
		sprite_wr    <= 1'b0;
		cpua_ctrl_wr <= 1'b0;
		spr_ctrl_wr  <= 1'b0;
		r_ioc_cs     <= 1'b0;

		case (txn_state)
		TXN_NONE: begin
			bus_cs   <= 1'b0;
			bus_busy <= 1'b0;

			if (bus_active) begin
				// --- ROM fetch ---
				if (sel_rom) begin
					rom_addr  <= rom_addr_masked;  // clear bit 20 for mirror
					rom_req   <= 1'b1;  // single pulse (rom_cache detects rising edge)
					bus_cs    <= 1'b1;
					bus_busy  <= 1'b1;
					txn_state <= TXN_ROM;

				// --- Main RAM ---
				end else if (sel_ram) begin
					ram_addr_o <= bus_addr[15:1];
					ram_wdata  <= bus_wdata;
					ram_be_o   <= ~bus_dsn;  // latch byte enable NOW (DSn may de-assert before write reaches BRAM)
					if (bus_rnw) begin
						ram_rd    <= 1'b1;
						txn_state <= TXN_RAM_RD_WAIT;  // 1-cycle delay: BRAM needs N+2 to present data
					end else begin
						ram_wr    <= 1'b1;
						txn_state <= TXN_RAM_WR;
					end
					bus_cs   <= 1'b1;
					bus_busy <= 1'b1;

				// --- TC0040IOC (shared) ---
				// Pulse ioc_cs so the shared module latches write / provides read.
				// bus_rdata takes ioc_rdata combinationally via the mux above (sel_ioc).
				end else if (sel_ioc) begin
					bus_cs      <= 1'b1;
					bus_busy    <= 1'b0;
					r_ioc_cs    <= 1'b1;
					r_ioc_wdata <= bus_wdata[7:0];
					txn_state   <= TXN_DONE;

				// --- CPUA ctrl ---
				// MAME cpua_ctrl_w: if only high byte is written (UDS only),
				// shift high→low so bit 0 of the low byte is correctly set.
				// if ((data & 0xff00) && ((data & 0xff) == 0)) data = data >> 8;
				end else if (sel_ctrl) begin
					bus_cs   <= 1'b1;
					bus_busy <= 1'b0;
					if (~bus_rnw) begin
						cpua_ctrl_wr   <= 1'b1;
						// MAME-style high-byte-only normalization
						if ((bus_wdata[15:8] != 8'h00) && (bus_wdata[7:0] == 8'h00))
							cpua_ctrl_data <= bus_wdata[15:8];
						else
							cpua_ctrl_data <= bus_wdata[7:0];
					end else begin
						io_rdata  <= {8'h00, cpua_ctrl_q};
					end
					txn_state <= TXN_DONE;

				// --- TC0140SYT sound comm (real, no stub) ---
				// MAME: $220001=master_port_w, $220003=master_comm_r/w
				// Pilotiamo cs/wr/rd/a1 al TC0140SYT vero in audio_top.
				// Lettura: dato dal SYT (syt_main_dout, nibble basso).
				// CS/WR/RD vengono tenuti asseriti per tutta la transazione 68000
				// (TXN_DONE finche' bus_active) cosi' il SYT li campiona col ce_12m.
				end else if (sel_syt) begin
					bus_cs     <= 1'b1;
					bus_busy   <= 1'b0;
					syt_cs_n   <= 1'b0;
					syt_a1     <= bus_addr[1];
					syt_wr_n   <= bus_rnw;
					syt_rd_n   <= ~bus_rnw;
					syt_active <= 1'b1;
					io_rdata   <= {12'h000, syt_main_dout};
					txn_state  <= TXN_DONE;

				// --- Shared RAM ---
				end else if (sel_shared) begin
					shared_addr  <= bus_addr[15:1];
					shared_wdata <= bus_wdata;
					shared_be_o  <= ~bus_dsn;  // latch byte enable
					if (bus_rnw) begin
						shared_rd <= 1'b1;
						txn_state <= TXN_SHARED_RD;
					end else begin
						shared_wr <= 1'b1;
						txn_state <= TXN_SHARED_WR;
					end
					bus_cs   <= 1'b1;
					bus_busy <= 1'b1;

				// --- Sprite RAM ---
				end else if (sel_sprite) begin
					sprite_addr  <= bus_addr[13:1];
					sprite_wdata <= bus_wdata;
					sprite_be_o  <= ~bus_dsn;  // latch byte enable
					if (bus_rnw) begin
						sprite_rd <= 1'b1;
						txn_state <= TXN_SPRITE_RD;
					end else begin
						sprite_wr <= 1'b1;
						txn_state <= TXN_SPRITE_WR;
					end
					bus_cs   <= 1'b1;
					bus_busy <= 1'b1;

				// --- TC0100SCN / TC0110PCR ranges ---
				end else if (sel_scn_or_pal | sel_cchip) begin
					bus_cs   <= 1'b1;
					bus_busy <= 1'b1;
					txn_state <= TXN_EXT_WAIT;

				// --- PC090OJ sprite ctrl $080000-$080003 (write-only, colbank source) ---
				end else if (sel_spr_ctrl) begin
					bus_cs    <= 1'b1;
					bus_busy  <= 1'b0;
					if (~bus_rnw) begin
						spr_ctrl_wr   <= 1'b1;
						spr_ctrl_data <= bus_wdata;
					end
					io_rdata  <= 16'hFFFF;
					txn_state <= TXN_DONE;

				// --- Unknown address ---
				end else begin
					bus_cs    <= 1'b1;
					bus_busy  <= 1'b0;
					txn_state <= TXN_DONE;
				end
			end
		end

		// --- ROM fetch wait ---
		TXN_ROM: begin
			bus_cs   <= 1'b1;
			bus_busy <= ~rom_ready;
			if (rom_ready) begin
				txn_state <= TXN_DONE;
			end
		end

		// --- Main RAM read: BRAM output register needs 1 extra cycle to settle ---
		// Sequence: cycle N: ram_rd<=1 → cycle N+1: BRAM registers addr, reads array
		//           cycle N+2: rdata_hi/lo present on ram_rdata → sample here
		TXN_RAM_RD_WAIT: begin
			bus_cs    <= 1'b1;
			bus_busy  <= 1'b1;      // hold CPU waiting
			txn_state <= TXN_RAM_RD;
		end
		TXN_RAM_RD: begin
			// bus_rdata is combinational from ram_rdata via mux above (Darius 1 style)
			bus_cs    <= 1'b1;
			bus_busy  <= 1'b0;
			txn_state <= TXN_DONE;
		end

		// --- Main RAM write (immediate) ---
		TXN_RAM_WR: begin
			bus_cs    <= 1'b1;
			bus_busy  <= 1'b0;
			txn_state <= TXN_DONE;
		end

		// --- Shared RAM read ---
		TXN_SHARED_RD: begin
			bus_cs   <= 1'b1;
			bus_busy <= ~shared_ready;
			if (shared_ready) begin
				// bus_rdata is combinational from shared_rdata via mux above
				txn_state <= TXN_DONE;
			end
		end

		// --- Shared RAM write ---
		TXN_SHARED_WR: begin
			bus_cs   <= 1'b1;
			bus_busy <= ~shared_ready;
			if (shared_ready) begin
				txn_state <= TXN_DONE;
			end else begin
				shared_wr <= 1'b1;
			end
		end

		// --- Sprite RAM read ---
		TXN_SPRITE_RD: begin
			bus_cs   <= 1'b1;
			bus_busy <= ~sprite_ready;
			if (sprite_ready) begin
				// bus_rdata is combinational from sprite_rdata via mux above
				txn_state <= TXN_DONE;
			end
		end

		// --- Sprite RAM write ---
		TXN_SPRITE_WR: begin
			bus_cs   <= 1'b1;
			bus_busy <= ~sprite_ready;
			if (sprite_ready) begin
				txn_state <= TXN_DONE;
			end else begin
				sprite_wr <= 1'b1;
			end
		end

		// --- External device wait (SCN/palette) ---
		// bus_cs=1; bus_busy follows ext_dtack_n: high while chip busy, low when chip responds.
		// This lets jtframe_68kdtack_cen pass DTACKn=0 to CPU (DTACKn <= DTACKn && bus_cs && bus_busy).
		// When chip responds (ext_dtack_n=0), bus_busy=0 → jtframe drops DTACKn → CPU completes.
		TXN_EXT_WAIT: begin
			bus_cs   <= 1'b1;
			bus_busy <= ext_dtack_n;
			if (~bus_active)
				txn_state <= TXN_NONE;
		end

		// --- Transaction done, wait for bus release ---
		TXN_DONE: begin
			bus_cs   <= 1'b1;
			bus_busy <= 1'b0;
			if (~bus_active) begin
				txn_state  <= TXN_NONE;
				syt_cs_n   <= 1'b1;
				syt_wr_n   <= 1'b1;
				syt_rd_n   <= 1'b1;
				syt_active <= 1'b0;
			end
		end

		default: txn_state <= TXN_NONE;
		endcase
	end
end

endmodule
