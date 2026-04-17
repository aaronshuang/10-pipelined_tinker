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
    localparam ENTRIES = 64;

    reg valid [0:ENTRIES - 1];
    reg [1:0] counter [0:ENTRIES - 1];
    reg [55:0] tags [0:ENTRIES - 1];
    reg [63:0] targets [0:ENTRIES - 1];
    integer i;
    integer idx;
    integer uidx;

    always @(*) begin
        idx = lookup_pc[7:2];
        if (valid[idx] && tags[idx] == lookup_pc[63:8]) begin
            predict_taken = counter[idx][1];
            predict_target = counter[idx][1] ? targets[idx] : (lookup_pc + 4);
        end else begin
            predict_taken = 1'b0;
            predict_target = lookup_pc + 4;
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            for (i = 0; i < ENTRIES; i = i + 1) begin
                valid[i] <= 1'b0;
                counter[i] <= 2'b01;
                tags[i] <= 56'b0;
                targets[i] <= 64'b0;
            end
        end else if (update_en) begin
            uidx = update_pc[7:2];
            valid[uidx] <= 1'b1;
            tags[uidx] <= update_pc[63:8];
            targets[uidx] <= update_target;
            if (update_taken) begin
                if (counter[uidx] != 2'b11) counter[uidx] <= counter[uidx] + 2'b01;
            end else begin
                if (counter[uidx] != 2'b00) counter[uidx] <= counter[uidx] - 2'b01;
            end
        end
    end
endmodule
