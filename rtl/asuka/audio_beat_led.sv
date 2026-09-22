// audio_beat_led — beat detector dual-channel per LED MiSTer a tempo musica.
//
// Channel A (USER LED): FM-only L+R → traccia melodia/bassi BGM (FM channels)
// Channel B (DISK LED): ADPCM-A L+R → traccia drum/percussion
//
// Algoritmo per canale:
//  1. Mono mix L+R / 2 (abs)
//  2. Envelope follower (peak hold + decay)
//  3. Media lenta (background level)
//  4. Beat = env > avg * threshold AND avg > gate
//  5. Pulse stretch ~60-80ms

module audio_beat_led (
	input  wire        clk,
	input  wire        reset,
	input  wire        ce_48k,
	// Channel A: FM (melodia/bassi BGM)
	input  wire signed [15:0] fm_l,
	input  wire signed [15:0] fm_r,
	// Channel B: ADPCM-A (drum)
	input  wire signed [15:0] adpcma_l,
	input  wire signed [15:0] adpcma_r,
	output reg         led_user_beat,    // pulsa su beat FM (musica)
	output reg         led_disk_beat     // pulsa su beat ADPCM-A (drum)
);

// ============================================================
// Channel A: FM beat detector
// ============================================================
reg [15:0] fm_abs;
always @(posedge clk) if (ce_48k) begin
	reg signed [16:0] s;
	s = $signed({fm_l[15], fm_l}) + $signed({fm_r[15], fm_r});
	fm_abs <= (s < 0) ? ({1'b0, -s[16:1]}) : ({1'b0, s[16:1]});
end

reg [15:0] fm_env, fm_avg;
always @(posedge clk) if (ce_48k) begin
	reg [15:0] dec;
	dec = fm_env - (fm_env >> 8);
	if (fm_abs > dec) fm_env <= fm_abs;
	else              fm_env <= dec;

	if (fm_env > fm_avg) fm_avg <= fm_avg + ((fm_env - fm_avg) >> 9);
	else                 fm_avg <= fm_avg - ((fm_avg - fm_env) >> 9);
end

wire fm_beat_now = (fm_env > (fm_avg + (fm_avg >> 1))) && (fm_avg > 16'd100);

reg [12:0] fm_cnt;
always @(posedge clk) if (reset) begin
	fm_cnt <= 0; led_user_beat <= 1'b0;
end else if (ce_48k) begin
	if (fm_beat_now) begin
		fm_cnt <= 13'd2880;   // ~60ms @ 48kHz
		led_user_beat <= 1'b1;
	end else if (fm_cnt != 0) begin
		fm_cnt <= fm_cnt - 13'd1;
		led_user_beat <= 1'b1;
	end else led_user_beat <= 1'b0;
end

// ============================================================
// Channel B: ADPCM-A beat detector (drum)
// ============================================================
reg [15:0] ad_abs;
always @(posedge clk) if (ce_48k) begin
	reg signed [16:0] s;
	s = $signed({adpcma_l[15], adpcma_l}) + $signed({adpcma_r[15], adpcma_r});
	ad_abs <= (s < 0) ? ({1'b0, -s[16:1]}) : ({1'b0, s[16:1]});
end

reg [15:0] ad_env, ad_avg;
always @(posedge clk) if (ce_48k) begin
	reg [15:0] dec;
	dec = ad_env - (ad_env >> 8);
	if (ad_abs > dec) ad_env <= ad_abs;
	else              ad_env <= dec;

	if (ad_env > ad_avg) ad_avg <= ad_avg + ((ad_env - ad_avg) >> 9);
	else                 ad_avg <= ad_avg - ((ad_avg - ad_env) >> 9);
end

wire ad_beat_now = (ad_env > (ad_avg + (ad_avg >> 1))) && (ad_avg > 16'd100);

reg [12:0] ad_cnt;
always @(posedge clk) if (reset) begin
	ad_cnt <= 0; led_disk_beat <= 1'b0;
end else if (ce_48k) begin
	if (ad_beat_now) begin
		ad_cnt <= 13'd2880;
		led_disk_beat <= 1'b1;
	end else if (ad_cnt != 0) begin
		ad_cnt <= ad_cnt - 13'd1;
		led_disk_beat <= 1'b1;
	end else led_disk_beat <= 1'b0;
end

endmodule
