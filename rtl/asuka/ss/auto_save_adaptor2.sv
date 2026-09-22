/*  Savestate — auto_save_adaptor2 (walker device/state per auto_ss).
    Portato 1:1 da Arcade-TaitoF2 rtl/savestates.sv (Martin Donlon).
*/

module auto_save_adaptor2 #(parameter DEVICE_WIDTH=8, STATE_WIDTH=16, COUNT_WIDTH=9, SS_IDX=-1)(
    input clk,

    ssbus_if.slave ssbus,

    output reg rd,
    output reg wr,
    output reg [DEVICE_WIDTH-1:0] device_idx,
    output reg [STATE_WIDTH-1:0] state_idx,
    output reg [31:0] wr_data,
    input      [31:0] rd_data,
    input      ack
);

typedef enum {
    ST_INIT,
    ST_WAIT_READ,
    ST_CHECK_READ,
    ST_READY,
    ST_PREPARE_WRITE,
    ST_DO_WRITE,
    ST_PREPARE_READ,
    ST_DO_READ,
    ST_WAIT_IDLE
} state_t;
state_t state = ST_INIT;

reg [COUNT_WIDTH - 1:0] count;
reg [COUNT_WIDTH - 1:0] addr;
reg [(DEVICE_WIDTH + STATE_WIDTH - 1):0] idx_map[2**COUNT_WIDTH];

always @(posedge clk) begin
    ssbus.setup(SS_IDX, 32'(count), 2);

    case(state)
        ST_INIT: begin
            count <= 0;
            addr <= 0;
            wr <= 0;
            rd <= 1;
            device_idx <= 0;
            state_idx <= 0;
            state <= ST_WAIT_READ;
        end

        ST_WAIT_READ: begin
            state <= ST_CHECK_READ;
        end

        ST_CHECK_READ: begin
            if (ack) begin
                idx_map[addr] <= { device_idx, state_idx };
                addr <= addr + 1;
                count <= count + 1;
                state_idx <= state_idx + 1;
                state <= ST_WAIT_READ;
            end else begin
                state_idx <= 0;
                if (&device_idx) begin
                    state <= ST_READY;
                end else begin
                    device_idx <= device_idx + 1;
                    state <= ST_WAIT_READ;
                end
            end

        end

        ST_READY: begin
            rd <= 0;
            wr <= 0;
            if (ssbus.access(SS_IDX)) begin
                if (ssbus.write) begin
                    addr <= ssbus.addr[COUNT_WIDTH-1:0];
                    state <= ST_PREPARE_WRITE;
                    wr_data <= ssbus.data[31:0];
                end else if (ssbus.read) begin
                    addr <= ssbus.addr[COUNT_WIDTH-1:0];
                    state <= ST_PREPARE_READ;
                end
            end
        end

        ST_PREPARE_WRITE: begin
            { device_idx, state_idx } <= idx_map[addr];
            wr <= 1;
            state <= ST_DO_WRITE;
        end

        ST_DO_WRITE: begin
            wr <= 0;
            state <= ST_WAIT_IDLE;
            ssbus.write_ack(SS_IDX);
        end

        ST_PREPARE_READ: begin
            { device_idx, state_idx } <= idx_map[addr];
            rd <= 1;
            state <= ST_DO_READ;
        end

        ST_DO_READ: begin
            rd <= 0;
            state <= ST_WAIT_IDLE;
            ssbus.read_response(SS_IDX, {32'd0, rd_data } );
        end

        ST_WAIT_IDLE: begin
            if (~(ssbus.read | ssbus.write)) begin
                state <= ST_READY;
            end
        end
    endcase
end

endmodule
