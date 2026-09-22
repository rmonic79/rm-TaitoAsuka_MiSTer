derive_pll_clocks
derive_clock_uncertainty

# core specific constraints

# ============================================================
# Audio subsystem runs at ce_z80_p (96MHz/24 = 4MHz)
# T80 (Z80 audio) registri tutti CE-gated → 24 cicli liberi tra ogni edge attivo.
# Multicycle 4 (conservativo: T80 propaga in pochi cicli logici) → slack chiude.
# Target: tutti i registri sotto T80 dentro darius2_audio_top.
# ============================================================
set_multicycle_path -setup -from [get_registers {*asuka_audio_top*T80*}] -to [get_registers {*asuka_audio_top*T80*}] 4
set_multicycle_path -hold  -from [get_registers {*asuka_audio_top*T80*}] -to [get_registers {*asuka_audio_top*T80*}] 3
# Stessa cosa per gli altri moduli audio CE-gated (jt03, jt12, jt10, syt, mixer)
set_multicycle_path -setup -from [get_registers {*asuka_audio_top*jt*}] -to [get_registers {*asuka_audio_top*jt*}] 4
set_multicycle_path -hold  -from [get_registers {*asuka_audio_top*jt*}] -to [get_registers {*asuka_audio_top*jt*}] 3

# Beat LED detector: gira a ce_48k (clk_sys/2000). Multicycle 8 conservativo.
set_multicycle_path -setup -from [get_registers {*u_beat*}] -to [get_registers {*u_beat*}] 8
set_multicycle_path -hold  -from [get_registers {*u_beat*}] -to [get_registers {*u_beat*}] 7

# C-Chip: il uPD78C11 gira a 12 MHz su clock enable, mai due cicli attivi di
# fila. Vincolo preso dal timing.sdc del modulo (rtl/cchip/timing.sdc).
set_multicycle_path -from {*|IKA87AD:u_mcu|*} -to {*|IKA87AD:u_mcu|*} -setup -end 2
set_multicycle_path -from {*|IKA87AD:u_mcu|*} -to {*|IKA87AD:u_mcu|*} -hold  -end 2

# ============================================================
# Pause overlay: lavora al passo del PIXEL, non del clock.
# render_x/render_y cambiano una volta ogni 14 clock (pxl_en_s = clk_sys/14 =
# 6,86 MHz) e l'uscita la campiona CE_PIXEL. Tutti i registri del modulo (logo,
# testo, pipeline del font) sono alimentati solo da quelle coordinate, quindi
# hanno 14 clock veri per assestarsi.
# Lo STA li valutava a un clock solo: erano 400 cammini in violazione su 400,
# tutti qui dentro, e da soli tenevano il core a Fmax 75 MHz contro i 96
# richiesti. Multicycle 4 su 14 disponibili: conservativo di oltre tre volte.
# ============================================================
set_multicycle_path -setup -to [get_registers {*pause_overlay:u_pause_ovl|*}] 4
set_multicycle_path -hold  -to [get_registers {*pause_overlay:u_pause_ovl|*}] 3

# ============================================================
# Z180 del link Cadash: gira su z180_ce, un clock ogni 12 (96/12 = 8 MHz,
# asuka_top.sv:1018-1025), esattamente come il T80 audio qui sopra. Multicycle 4
# su 12 disponibili.
# ============================================================
set_multicycle_path -setup -from [get_registers {*cadash_link_z180:u_link_z180|*}] -to [get_registers {*cadash_link_z180:u_link_z180|*}] 4
set_multicycle_path -hold  -from [get_registers {*cadash_link_z180:u_link_z180|*}] -to [get_registers {*cadash_link_z180:u_link_z180|*}] 3

# ============================================================
# game_id / link_mp / board_tate: configurazione del set. Li scrive SOLO il
# caricamento della ROM (Template.sv:484-494, ioctl_wr con index 1) e poi non
# cambiano piu' per tutta la partita. Lo STA li valutava come un dato che cambia
# a ogni clock. Multicycle 4, che e' comunque infinitamente conservativo
# rispetto ai milioni di clock in cui quel valore resta fermo.
# ============================================================
set_multicycle_path -setup -from [get_registers {*|game_id[*]}] 4
set_multicycle_path -hold  -from [get_registers {*|game_id[*]}] 3
set_multicycle_path -setup -from [get_registers {*|link_mp}] 4
set_multicycle_path -hold  -from [get_registers {*|link_mp}] 3
set_multicycle_path -setup -from [get_registers {*|board_tate}] 4
set_multicycle_path -hold  -from [get_registers {*|board_tate}] 3

# ============================================================
# crt_vsize, collocazione della finestra DE: o_active_cyc si carica al ciclo 2
# della riga di uscita e o_de_start lo usa al ciclo 4 (sys/crt_vsize.sv:471-478).
# Sono DUE clock veri, uno per costruzione non basta mai.
# ============================================================
set_multicycle_path -setup -from [get_registers {*crt_vsize*|o_active_cyc[*]}] -to [get_registers {*crt_vsize*|o_de_start[*]}] 2
set_multicycle_path -hold  -from [get_registers {*crt_vsize*|o_active_cyc[*]}] -to [get_registers {*crt_vsize*|o_de_start[*]}] 1

# ============================================================
# 68000 -> mappa di memoria: l'indirizzo del fx68k cambia al passo del clock
# enable della CPU (16 MHz su cadash = un colpo ogni 6 clock, 8 MHz sugli altri
# = uno ogni 12), mentre la mappa lo campiona quando la sua macchina a stati
# apre la transazione, sempre dopo. Multicycle 2 su 6 disponibili nel caso
# peggiore.
# ============================================================
set_multicycle_path -setup -from [get_registers {*fx68k:cpu_core|*}] -to [get_registers {*asuka_maincpu_map:u_main_map|*}] 2
set_multicycle_path -hold  -from [get_registers {*fx68k:cpu_core|*}] -to [get_registers {*asuka_maincpu_map:u_main_map|*}] 1

# ============================================================
# scanlines di sys: la pipeline sposta un registro a ogni clock, ma il dato che
# entra cambia solo al passo del pixel (un colpo ogni 14 clock) e chi legge
# l'uscita la campiona su ce_out, che scorre nella stessa pipeline. Multicycle 2
# su 14 disponibili.
# ============================================================
set_multicycle_path -setup -to [get_registers {*scanlines:*|*}] 2
set_multicycle_path -hold  -to [get_registers {*scanlines:*|*}] 1

# ============================================================
# Opzioni dell'OSD (hps_io|status[*]): le scrive l'HPS quando l'utente muove il
# menu, poi restano ferme per miliardi di clock. Alimentano mezzo core (scelte
# di scroll, offset, timing sprite, CRT), e lo STA le valutava come dati che
# cambiano a ogni colpo di clock: da sole tenevano in violazione centinaia di
# cammini dentro il chip tile e il compositore. Multicycle 4.
# ============================================================
set_multicycle_path -setup -from [get_registers {*hps_io*|status[*]}] 4
set_multicycle_path -hold  -from [get_registers {*hps_io*|status[*]}] 3

# ============================================================
# fx68k: tutti i suoi registri hanno l'abilitazione di fase (enPhi1/enPhi2 da
# jtframe_68kdtack_cen). A 16 MHz su clock da 96 sono 6 clock per ciclo di CPU,
# con le due fasi a 3 clock di distanza; sugli altri set, 8 MHz, il doppio.
# Il caso peggiore e' quindi 3 clock veri: multicycle 2.
# ============================================================
set_multicycle_path -setup -from [get_registers {*fx68k:cpu_core|*}] -to [get_registers {*fx68k:cpu_core|*}] 2
set_multicycle_path -hold  -from [get_registers {*fx68k:cpu_core|*}] -to [get_registers {*fx68k:cpu_core|*}] 1

# ============================================================
# Contatori del raster (hc_s, vc_s): avanzano solo su pxl_en_s, un colpo ogni
# 14 clock. Tutto cio' che alimentano (compresa la rotazione dello schermo) ha
# quel tempo, non un clock. Multicycle 2, conservativo di sette volte.
# ============================================================
set_multicycle_path -setup -from [get_registers {*|vc_s[*]}] 2
set_multicycle_path -hold  -from [get_registers {*|vc_s[*]}] 1
set_multicycle_path -setup -from [get_registers {*|hc_s[*]}] 2
set_multicycle_path -hold  -from [get_registers {*|hc_s[*]}] 1

# ============================================================
# Z80 dell'audio: ora e' il tv80s (cambiato per avere il savestate). Gira su
# ce_z80_p, un colpo ogni 24 clock (96/24 = 4 MHz), quindi i suoi cammini interni
# hanno 24 clock veri, non uno. Il vincolo che c'era sopra nomina "T80" e non
# prende i registri del tv80. Multicycle 4 su 24 disponibili.
# ============================================================
set_multicycle_path -setup -from [get_registers {*asuka_audio_top*tv80*}] -to [get_registers {*asuka_audio_top*tv80*}] 4
set_multicycle_path -hold  -from [get_registers {*asuka_audio_top*tv80*}] -to [get_registers {*asuka_audio_top*tv80*}] 3
