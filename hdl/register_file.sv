module register_file (
    input clk,
    input reset,
    input [63:0] data,
    input [4:0] rd,
    input [4:0] rs,
    input [4:0] rt,
    input write_enable,
    output [63:0] rd_val,
    output [63:0] rs_val,
    output [63:0] rt_val,
    output [63:0] r31_val
);
    reg [63:0] registers [0:31];
    integer i;

    assign rd_val = registers[rd];
    assign rs_val = registers[rs];
    assign rt_val = registers[rt];
    assign r31_val = registers[31];

    always @(posedge clk) begin
        if (reset) begin
            for (i = 0; i < 31; i = i + 1) begin
                registers[i] <= 64'b0;
            end
            registers[31] <= 64'd524288;
        end else if (write_enable) begin
            registers[rd] <= data;
        end
    end
endmodule
