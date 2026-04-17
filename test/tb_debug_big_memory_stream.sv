`timescale 1ns / 1ps

module tb_debug_big_memory_stream;
    reg clk;
    reg reset;
    wire hlt;

    tinker_core uut (.clk(clk), .reset(reset), .hlt(hlt));

    always #5 clk = ~clk;

    localparam OP_MOV_L  = 5'h12;
    localparam OP_MOV_ML = 5'h10;
    localparam OP_MOV_SM = 5'h13;
    localparam OP_SHFTLI = 5'h07;
    localparam OP_ADDI   = 5'h19;
    localparam OP_SUBI   = 5'h1B;
    localparam OP_ADD    = 5'h18;
    localparam OP_BRNZ   = 5'h0B;
    localparam OP_PRIV   = 5'h0F;

    integer cycles;
    reg [31:0] inst;

    task write_inst;
        input [63:0] addr;
        input [4:0]  op;
        input [4:0]  rd;
        input [4:0]  rs;
        input [4:0]  rt;
        input [11:0] imm;
        begin
            inst = {op, rd, rs, rt, imm};
            uut.memory.bytes[addr]   = inst[7:0];
            uut.memory.bytes[addr+1] = inst[15:8];
            uut.memory.bytes[addr+2] = inst[23:16];
            uut.memory.bytes[addr+3] = inst[31:24];
        end
    endtask

    task write_mem64;
        input [63:0] addr;
        input [63:0] data;
        begin
            uut.memory.bytes[addr]   = data[7:0];
            uut.memory.bytes[addr+1] = data[15:8];
            uut.memory.bytes[addr+2] = data[23:16];
            uut.memory.bytes[addr+3] = data[31:24];
            uut.memory.bytes[addr+4] = data[39:32];
            uut.memory.bytes[addr+5] = data[47:40];
            uut.memory.bytes[addr+6] = data[55:48];
            uut.memory.bytes[addr+7] = data[63:56];
        end
    endtask

    initial begin
        clk = 0;
        reset = 1;

        write_mem64(16'h0100, 64'd1);
        write_mem64(16'h0108, 64'd2);
        write_mem64(16'h0110, 64'd3);
        write_mem64(16'h0118, 64'd4);

        write_inst(16'h2000, OP_MOV_L,  5'd0,  5'd0,  5'd0, 12'h100);
        write_inst(16'h2004, OP_MOV_L,  5'd20, 5'd0,  5'd0, 12'h201);
        write_inst(16'h2008, OP_SHFTLI, 5'd20, 5'd0,  5'd0, 12'd4);
        write_inst(16'h200C, OP_MOV_L,  5'd21, 5'd0,  5'd0, 12'd255);

        write_inst(16'h2010, OP_MOV_ML, 5'd1,  5'd0,  5'd0, 12'd0);
        write_inst(16'h2014, OP_MOV_ML, 5'd2,  5'd0,  5'd0, 12'd8);
        write_inst(16'h2018, OP_ADD,    5'd3,  5'd1,  5'd2, 12'd0);
        write_inst(16'h201C, OP_MOV_SM, 5'd0,  5'd3,  5'd0, 12'd16);
        write_inst(16'h2020, OP_ADDI,   5'd0,  5'd0,  5'd0, 12'd8);
        write_inst(16'h2024, OP_SUBI,   5'd21, 5'd21, 5'd0, 12'd1);
        write_inst(16'h2028, OP_BRNZ,   5'd20, 5'd21, 5'd0, 12'd0);
        write_inst(16'h202C, OP_PRIV,   5'd0,  5'd0,  5'd0, 12'd0);

        #12 reset = 0;

        cycles = 0;
        while (!hlt && cycles < 5000) begin
            @(posedge clk);
            cycles = cycles + 1;
        end

        $display("BIG_MEM_STREAM cycles=%0d hlt=%0d rob=%0d free=%0d r21=%0d",
            cycles, hlt, uut.rob_count, uut.free_count, uut.reg_file.registers[21]);
        $finish;
    end
endmodule
