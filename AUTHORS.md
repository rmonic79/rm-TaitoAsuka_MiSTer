# Authors and Credits

## TaitoAsuka_MiSTer core

**Author**: Umberto Parisi ([rmonic79](https://github.com/rmonic79))

The original RTL source files for the Taito Asuka specific logic (under
`rtl/asuka/`, including the TC0100SCN and PC090OJ video chips, the TC0220IOC,
PC060HA and TC0140SYT interface chips, the MSM5205 ADPCM decoder, the Cadash
two-cabinet link, the savestate wiring, and the project wrapper `Template.sv`)
are copyright Umberto Parisi and distributed under GNU GPL v3 or later.

## Third-party components

This core builds on top of excellent open-source projects. All third-party
sources retain their original copyright and license. The core as a whole
is distributed under **GNU GPL v3 or later** to stay compatible with the
most restrictive upstream (JTFRAME / JTCORES).

| Component | Author | Project | License |
|-----------|--------|---------|---------|
| **FX68K** — Motorola 68000 (main CPU) cycle-accurate core | Jorge Cwik ([ijor](https://github.com/ijor)) | [ijor/fx68k](https://github.com/ijor/fx68k) | GPL-3 |
| **T80 / TV80** — Zilog Z80 (sound CPU) core; TV80 carries the savestate ports | Daniel Wallner (T80, OpenCores) with MikeJ fixes and MiSTer-devel maintenance; Guy Hutchison (TV80) | [MiSTer-devel](https://github.com/MiSTer-devel) / [OpenCores](https://opencores.org) | GPL-3 / BSD |
| **IKA87AD** — NEC uPD78C11, the CPU die inside the Taito C-Chip, reconstructed from the decapped die and the NEC datasheet | Raki | included under `rtl/cchip/` | see `rtl/cchip/LICENSE.IKA87AD` |
| **jttc0030cmd** — Taito TC0030CMD (C-Chip) module around IKA87AD | Andrea Bogazzi ([@asturur](https://github.com/asturur)) | [jotego/jtcores](https://github.com/jotego/jtcores) | GPL-3 |
| **JT51** — Yamaha YM2151 (OPM) FM synthesizer | Jose Tejada ([@topapate](https://twitter.com/topapate)) | [jotego/jt51](https://github.com/jotego/jt51) | GPL-3 |
| **JT12 / JT10** — Yamaha YM2610 (OPNB) FM + ADPCM-A/B, used by Bonze Adventure | Jose Tejada | [jotego/jt12](https://github.com/jotego/jt12) | GPL-3 |
| **JT5205** — OKI MSM5205 clock and timing reference | Jose Tejada | [jotego/jt5205](https://github.com/jotego/jt5205) | GPL-3 |
| **JTFRAME** — framework, clock enables, dividers, filters, mixer, dual-port RAM, SDRAM64 controller | Jose Tejada | [jotego/jtframe](https://github.com/jotego/jtframe) | GPL-3 |
| **Savestate infrastructure** — ssbus, memory_stream, auto_save_adaptor, ram adaptors, DDR path and rotation FIFO | Martin Donlon ([wickerwaka](https://github.com/wickerwaka)) | [wickerwaka/Arcade-TaitoF2_MiSTer](https://github.com/wickerwaka/Arcade-TaitoF2_MiSTer) | GPL-3 |
| **MAME** — reference for the TC0100SCN and PC090OJ video chips, the C-Chip, memory maps, timing and the whole `asuka.cpp` driver | MAMEDev team | [mamedev/mame](https://github.com/mamedev/mame) | GPL-2+ |
| **sys/ framework** — MiSTer HPS/IO, OSD, video scaler, audio | Sorgelig / MiSTer-devel | [MiSTer-devel/Main_MiSTer](https://github.com/MiSTer-devel/Main_MiSTer) | GPL-3 |

## Reference

- **Taito Asuka & Asuka hardware** — Taito Corporation, 1988-1994, the family
  MAME collects in `asuka.cpp`: Cadash, Asuka & Asuka, Maze of Flott, Galmedes,
  U.N. Defense Force: Earth Joker, Kokontouzai Eto Monogatari and Bonze
  Adventure. This FPGA core is a reimplementation from MAME source code, from
  the program ROMs disassembled where the driver stops short, and from
  observation of real hardware behavior. ROMs are **not** included and must be
  provided by the user.
- **MAME project** — invaluable reference for memory maps, timing, the
  TC0100SCN tilemap chip, the PC090OJ sprite chip, the TC0110PCR palette chip,
  the C-Chip and the sound interface chips.
  [mamedev/mame](https://github.com/mamedev/mame)
