/*  TC0110PR — Taito custom palette controller chip
    Source: https://github.com/wickerwaka/Arcade-TaitoF2_MiSTer
    Author: Sean Gonsalves (wickerwaka)
    Modifications by Umberto Parisi for Darius2NinjaWarriors_MiSTer.
    License: GNU General Public License v3 or later

    This file is part of Darius2NinjaWarriors_MiSTer.

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.
*/

module TC0110PR(
    input clk,
    input ce_pixel,

    // CPU Interface
    input [15:0] Din,
    output reg [15:0] Dout,

    input [1:0] VA,
    input RWn,
    input UDSn,
    input LDSn,

    input SCEn,
    output DACKn,

    // Video Input
    input HSYn,
    input VSYn,

    input [14:0] SC,
    input [14:0] OB,

    // RAM Interface
    output [12:0] CA,
    input [15:0] CDin,
    output [15:0] CDout,
    output reg WELn,
    output reg WEHn
);

reg cpu_mode = 0;
reg end_cpu_mode = 0;
reg [12:0] cpu_addr;
reg dtack_n;
reg [12:0] color_addr;
reg prev_sce_n = 1'b1;  // CS starts inactive → enable edge detection on first CS
// read_pending: on VA=01 read, wait 1 extra cycle so CDin reflects pal_ram[cpu_addr]
// AFTER the BRAM registered-output latency. Without this, Dout<=CDin samples stale CDin.
reg read_pending = 0;

assign CDout = Din;
assign CA = cpu_mode ? cpu_addr : color_addr;
assign DACKn = SCEn ? 0 : (read_pending | dtack_n);

always_ff @(posedge clk) begin
    prev_sce_n <= SCEn;
    WELn <= 1;
    WEHn <= 1;
    // Resolve pending read: CDin is valid now
    if (read_pending) begin
        Dout <= CDin;
        dtack_n <= 0;
        read_pending <= 0;
    end
    if (~SCEn & prev_sce_n) begin
        if (RWn) begin
            case(VA)
                2'b00: begin
                    Dout[12:0] <= cpu_addr;
                    dtack_n <= 0;
                    cpu_mode <= 1;
                end
                2'b01: begin
                    // Defer Dout<=CDin by 1 cycle via read_pending so CDin reflects
                    // the value at pal_ram[cpu_addr] AFTER the BRAM registered latency.
                    read_pending <= 1;
                    dtack_n <= 1;  // hold DTACK high until read resolves
                    cpu_mode <= 1;
                end
                default: begin
                    dtack_n <= 0;
                end
            endcase
        end else begin
            case(VA)
                2'b00: begin
                    if (~UDSn) cpu_addr[12:8] <= Din[12:8];
                    if (~LDSn) cpu_addr[7:0] <= Din[7:0];
                    dtack_n <= 0;
                    cpu_mode <= 1;
                end
                2'b01: begin
                    WELn <= LDSn;
                    WEHn <= UDSn;
                    dtack_n <= 0;
                    cpu_mode <= 1;
                    // DO NOT set end_cpu_mode here: cpu_mode must persist so the
                    // following VA=01 read finds CA=cpu_addr already stable,
                    // and CDin = pal_ram[cpu_addr] ready for immediate Dout<=CDin.
                    // MAME chip behaviour: cpu_mode only closes on explicit VA=10.
                end
                2'b10: begin
                    dtack_n <= 0;
                    end_cpu_mode <= 1;
                end
                default: begin
                    dtack_n <= 0;
                end
            endcase
        end
    end

    if (SCEn) begin
        if (end_cpu_mode) begin
            end_cpu_mode <= 0;
            cpu_mode <= 0;
        end
        dtack_n <= 1;
    end

    if (ce_pixel) begin
        // Priority MAME ninjaw (draw_sprites + primask):
        //   sprite prio 0 (OB[13]=0): sotto FG, sopra tutto il resto
        //   sprite prio 1 (OB[13]=1): sotto FG, sotto MID layer, sopra BOTTOM
        // SC[14:13] dal chip MAME tc0100scn codifica il RUOLO del layer visibile:
        //   01 = FG text (top)
        //   11 = BG top    (middle nella terminologia MAME primask)
        //   10 = BG bottom
        //   00 = nessun tile opaco
        //
        // Sprite vince quando: hit E (no-tile OR SC_bottom OR (SC_top E prio=0)).
        // FG vince sempre.
        begin
            reg sprite_hit;
            reg sprite_prio_low;  // 1 = sprite bassa priorità (OB[13]=1)
            reg sc_is_fg;
            reg sc_is_top_bg;
            reg sc_is_bot_bg;
            reg sc_empty;
            reg sprite_wins;
            sprite_hit      = OB[14];
            sprite_prio_low = OB[13];
            sc_is_fg     = (SC[14:13] == 2'b01);
            sc_is_top_bg = (SC[14:13] == 2'b11);  // layer BG "top" → MAME mid
            sc_is_bot_bg = (SC[14:13] == 2'b10);  // layer BG "bottom"
            sc_empty     = (SC[14:13] == 2'b00);
            sprite_wins = sprite_hit && !sc_is_fg &&
                          (sc_empty || sc_is_bot_bg || (sc_is_top_bg && !sprite_prio_low));
            color_addr <= sprite_wins ? {1'b0, OB[11:0]} : {1'b0, SC[11:0]};
        end
    end
end

endmodule



