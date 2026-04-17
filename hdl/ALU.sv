module ALU (
    input [63:0] a,
    input [63:0] b,
    input [4:0] op,
    output reg [63:0] res
);
    always @(*) begin
        case (op)
            5'h00: res = a & b;
            5'h01: res = a | b;
            5'h02: res = a ^ b;
            5'h03: res = ~a;
            5'h18, 5'h19: res = a + b;
            5'h10, 5'h13: res = a + b;
            5'h1a, 5'h1b: res = a - b;
            5'h1c: res = a * b;
            5'h1d: res = (b == 0) ? 64'h0 : (a / b);
            5'h04, 5'h05: res = a >> b[5:0];
            5'h06, 5'h07: res = a << b[5:0];
            5'h11: res = a;
            5'h12: res = {a[63:12], b[11:0]};
            default: res = 64'b0;
        endcase
    end
endmodule
