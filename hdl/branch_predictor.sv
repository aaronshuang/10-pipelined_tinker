module branch_predictor (
    input clk,
    input reset,
    input [63:0] lookup_pc,
    output reg predict_taken,
    output reg [63:0] predict_target,
    input update_en,
    input [63:0] update_pc,
    input update_taken,
    input [63:0] update_target
);
    localparam ENTRIES = 16;

    reg valid [0:ENTRIES - 1];
    reg taken [0:ENTRIES - 1];
    reg [57:0] tags [0:ENTRIES - 1];
    reg [63:0] targets [0:ENTRIES - 1];
    integer i;
    integer idx;
    integer uidx;

    always @(*) begin
        idx = lookup_pc[5:2];
        if (valid[idx] && tags[idx] == lookup_pc[63:6]) begin
            predict_taken = taken[idx];
            predict_target = targets[idx];
        end else begin
            predict_taken = 1'b0;
            predict_target = lookup_pc + 4;
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            for (i = 0; i < ENTRIES; i = i + 1) begin
                valid[i] <= 1'b0;
                taken[i] <= 1'b0;
                tags[i] <= 58'b0;
                targets[i] <= 64'b0;
            end
        end else if (update_en) begin
            uidx = update_pc[5:2];
            valid[uidx] <= 1'b1;
            taken[uidx] <= update_taken;
            tags[uidx] <= update_pc[63:6];
            targets[uidx] <= update_target;
        end
    end
endmodule
