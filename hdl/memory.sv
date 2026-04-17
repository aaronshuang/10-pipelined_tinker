module memory (
    input clk,
    input [63:0] addr,
    input [63:0] write_data,
    input mem_write,
    input mem_read,
    output [63:0] read_data
);
    parameter MEM_SIZE = 524288;
    reg [7:0] bytes [0:MEM_SIZE - 1];
    integer i;

    initial begin
        for (i = 0; i < MEM_SIZE; i = i + 1) begin
            bytes[i] = 8'b0;
        end
    end

    assign read_data = mem_read ? {
        bytes[addr + 7], bytes[addr + 6], bytes[addr + 5], bytes[addr + 4],
        bytes[addr + 3], bytes[addr + 2], bytes[addr + 1], bytes[addr]
    } : 64'b0;

    always @(posedge clk) begin
        if (mem_write) begin
            bytes[addr] <= write_data[7:0];
            bytes[addr + 1] <= write_data[15:8];
            bytes[addr + 2] <= write_data[23:16];
            bytes[addr + 3] <= write_data[31:24];
            bytes[addr + 4] <= write_data[39:32];
            bytes[addr + 5] <= write_data[47:40];
            bytes[addr + 6] <= write_data[55:48];
            bytes[addr + 7] <= write_data[63:56];
        end
    end
endmodule
