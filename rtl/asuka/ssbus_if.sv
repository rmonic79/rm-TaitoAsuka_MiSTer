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

// ssbus_if — Savestate bus interface (dummy stub)
//
// Placeholder interface compatible with Martin Donlon's TC0100SCN
// savestate port. All signals are inactive — no savestate functionality.
// Replace with real implementation when savestate support is added.

interface ssbus_if;
    logic [23:0] addr;
    logic [63:0] data;
    logic        read;
    logic        write;

    modport slave(input addr, input data, input read, input write,
                  import setup, import access, import write_ack, import read_response);

    function automatic void setup(input int idx, input int count, input int width);
    endfunction

    function automatic bit access(input int idx);
        return 0; // never active
    endfunction

    task automatic write_ack(input int idx);
    endtask

    task automatic read_response(input int idx, input logic [63:0] rdata);
    endtask

endinterface
