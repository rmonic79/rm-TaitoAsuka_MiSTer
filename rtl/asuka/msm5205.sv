/*  This file is part of Arcade_TaitoAsuka_MiSTer.
    GPL-3.
    Author: Umberto Parisi (rmonic79)
*/

// msm5205.sv — decoder ADPCM OKI MSM5205, modo 4 bit.
//
// Fedele a MAME src/devices/sound/msm5205.cpp:
//
//   stepval = floor(16 * (11/10)^step)          step = 0..48
//   diff    = sign * ( stepval*b2 + stepval/2*b1 + stepval/4*b0 + stepval/8 )
//             con nibble = {sign, b2, b1, b0} e divisioni INTERE, troncate
//             una per una. Non e' la stessa cosa di (stepval*(2*mag+1))>>3:
//             le due formule danno risultati diversi in 204 celle su 784.
//   signal += diff, saturato a [-2048, 2047]
//   step   += index_shift[b2:b0] = {-1,-1,-1,-1, 2, 4, 6, 8}, limitato a 0..48
//
// Un nibble viene consumato a ogni colpo di `nib_ce`. Con `run` basso il
// decoder e' tenuto azzerato (equivale a reset_w(1) sul chip vero).

module msm5205 (
	input  wire              clk,
	input  wire              reset,

	input  wire              run,       // 0 = chip in reset (reset_w(1))
	input  wire              nib_ce,    // 1 colpo quando c'e' un nibble nuovo
	input  wire [3:0]        nib,       // {sign, b2, b1, b0}

	output reg signed [11:0] sample     // uscita 12 bit segnata
);

// --- tabella degli step: floor(16 * 1.1^n), n = 0..48 ---------------------
wire [10:0] stepval;
reg  [10:0] step_rom [0:63];
initial begin : init_step_rom
	integer i;
	step_rom[ 0]=11'd16;   step_rom[ 1]=11'd17;   step_rom[ 2]=11'd19;
	step_rom[ 3]=11'd21;   step_rom[ 4]=11'd23;   step_rom[ 5]=11'd25;
	step_rom[ 6]=11'd28;   step_rom[ 7]=11'd31;   step_rom[ 8]=11'd34;
	step_rom[ 9]=11'd37;   step_rom[10]=11'd41;   step_rom[11]=11'd45;
	step_rom[12]=11'd50;   step_rom[13]=11'd55;   step_rom[14]=11'd60;
	step_rom[15]=11'd66;   step_rom[16]=11'd73;   step_rom[17]=11'd80;
	step_rom[18]=11'd88;   step_rom[19]=11'd97;   step_rom[20]=11'd107;
	step_rom[21]=11'd118;  step_rom[22]=11'd130;  step_rom[23]=11'd143;
	step_rom[24]=11'd157;  step_rom[25]=11'd173;  step_rom[26]=11'd190;
	step_rom[27]=11'd209;  step_rom[28]=11'd230;  step_rom[29]=11'd253;
	step_rom[30]=11'd279;  step_rom[31]=11'd307;  step_rom[32]=11'd337;
	step_rom[33]=11'd371;  step_rom[34]=11'd408;  step_rom[35]=11'd449;
	step_rom[36]=11'd494;  step_rom[37]=11'd544;  step_rom[38]=11'd598;
	step_rom[39]=11'd658;  step_rom[40]=11'd724;  step_rom[41]=11'd796;
	step_rom[42]=11'd876;  step_rom[43]=11'd963;  step_rom[44]=11'd1060;
	step_rom[45]=11'd1166; step_rom[46]=11'd1282; step_rom[47]=11'd1411;
	step_rom[48]=11'd1552;
	// 49..63 non raggiungibili (step e' limitato a 48): riempite col valore
	// di coda per non lasciare indefinito il blocco di memoria.
	for (i = 49; i < 64; i = i + 1) step_rom[i] = 11'd1552;
end

reg [5:0] step;
assign stepval = step_rom[step];

// --- ampiezza del passo, a troncamenti separati come MAME -----------------
wire [11:0] term2 =  nib[2] ? {1'b0, stepval}        : 12'd0;   // stepval
wire [11:0] term1 =  nib[1] ? {2'b0, stepval[10:1]}  : 12'd0;   // stepval/2
wire [11:0] term0 =  nib[0] ? {3'b0, stepval[10:2]}  : 12'd0;   // stepval/4
wire [11:0] term8 =            {4'b0, stepval[10:3]};           // stepval/8
wire [13:0] diff_mag = {2'd0, term2} + {2'd0, term1} + {2'd0, term0} + {2'd0, term8};

wire signed [14:0] diff   = nib[3] ? -$signed({1'b0, diff_mag}) : $signed({1'b0, diff_mag});
wire signed [14:0] sum    = $signed({{3{sample[11]}}, sample}) + diff;
wire signed [11:0] sum_sat = (sum >  15'sd2047) ?  12'sd2047 :
                             (sum < -15'sd2048) ? -12'sd2048 :
                                                  sum[11:0];

// --- indice dello step: {-1,-1,-1,-1, 2, 4, 6, 8} -------------------------
reg signed [4:0] idx_adj;
always @(*) case (nib[2:0])
	3'd0, 3'd1, 3'd2, 3'd3: idx_adj = -5'sd1;
	3'd4:                   idx_adj =  5'sd2;
	3'd5:                   idx_adj =  5'sd4;
	3'd6:                   idx_adj =  5'sd6;
	3'd7:                   idx_adj =  5'sd8;
endcase

wire signed [6:0] step_next = $signed({1'b0, step}) + {{2{idx_adj[4]}}, idx_adj};
wire       [5:0]  step_sat  = (step_next > 7'sd48) ? 6'd48 :
                              (step_next < 7'sd0)  ? 6'd0  :
                                                     step_next[5:0];

always @(posedge clk) begin
	if (reset || !run) begin
		sample <= 12'sd0;
		step   <= 6'd0;
	end else if (nib_ce) begin
		sample <= sum_sat;
		step   <= step_sat;
	end
end

endmodule
