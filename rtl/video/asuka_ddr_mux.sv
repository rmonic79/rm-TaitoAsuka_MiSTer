// SPDX-License-Identifier: GPL-3.0-or-later
// Original: Martin Donlon (wickerwaka) - Arcade-TaitoF2. Adattato da Raiden
// (raiden_ddr_mux) per Arcade_TaitoAsuka da Umberto Parisi.
//
// asuka_ddr_mux.sv — arbitro fra i due master DDR3 del gioco:
//   a = asuka_ddram (ROM Z80, ADPCM, ROM sprite)
//   b = FIFO del rotate (write del framebuffer HPS)
//   x = uscita verso ss_ddr_gate, che poi arbitra col savestate.
//
// L'arbitraggio e' su `acquire`: chi lo alza prende il bus e lo tiene finche'
// non lo molla. Il client non servito vede busy=1 e si stalla pulito.
// Con ss_hold alzato non si emette nulla verso i pin: il savestate ha il bus e
// tutti e due i client restano fermi, senza transazioni a meta'.
//
// L'interfaccia ddr_if e' quella del core, dichiarata in rtl/asuka/ss/savestate_ddr.sv.

module asuka_ddr_mux (
	input          clk,
	input          ss_hold,

	ddr_if.to_host   x,
	ddr_if.from_host a,
	ddr_if.from_host b
);

reg a_active = 0;

always_comb begin
	a.rdata = x.rdata;
	b.rdata = x.rdata;

	if (ss_hold) begin
		x.addr       = 32'd0;
		x.wdata      = 64'd0;
		x.read       = 1'b0;
		x.write      = 1'b0;
		x.burstcnt   = 8'd1;
		x.byteenable = 8'd0;
		a.busy = 1'b1;  a.rdata_ready = 1'b0;
		b.busy = 1'b1;  b.rdata_ready = 1'b0;
	end else if (a_active) begin
		x.addr       = a.addr;
		x.wdata      = a.wdata;
		x.read       = a.read;
		x.write      = a.write;
		x.burstcnt   = a.burstcnt;
		x.byteenable = a.byteenable;

		a.busy        = x.busy;
		a.rdata_ready = x.rdata_ready;
		a.rdata       = x.rdata;

		b.busy        = 1'b1;
		b.rdata_ready = 1'b0;
	end else begin
		x.addr       = b.addr;
		x.wdata      = b.wdata;
		x.read       = b.read;
		x.write      = b.write;
		x.burstcnt   = b.burstcnt;
		x.byteenable = b.byteenable;

		b.busy        = x.busy;
		b.rdata_ready = x.rdata_ready;
		b.rdata       = x.rdata;

		a.busy        = 1'b1;
		a.rdata_ready = 1'b0;
	end
end

// Durante ss_hold non acquisiamo il bus: lo lasciamo al savestate.
assign x.acquire = ss_hold ? 1'b0 : (a.acquire | b.acquire);

always_ff @(posedge clk) begin
	if (a.acquire & ~b.acquire) a_active <= 1'b1;
	if (~a.acquire & b.acquire) a_active <= 1'b0;
end

endmodule
