`timescale 1ns / 1ps

module tb_tinker_issue;
    reg clk;
    reg reset;
    wire hlt;

    tinker_core uut (
        .clk(clk),
        .reset(reset),
        .hlt(hlt)
    );

    always #5 clk = ~clk;

    task write_inst;
        input [63:0] addr;
        input [4:0] op;
        input [4:0] rd;
        input [4:0] rs;
        input [4:0] rt;
        input [11:0] imm;
        reg [31:0] inst;
        begin
            inst = {op, rd, rs, rt, imm};
            uut.memory.bytes[addr] = inst[7:0];
            uut.memory.bytes[addr + 1] = inst[15:8];
            uut.memory.bytes[addr + 2] = inst[23:16];
            uut.memory.bytes[addr + 3] = inst[31:24];
        end
    endtask

    integer cycles;

    initial begin
        clk = 0;
        reset = 1;

        write_inst(16'h2000, 5'h19, 5'd1, 5'd0, 5'd0, 12'd5);
        write_inst(16'h2004, 5'h19, 5'd2, 5'd0, 5'd0, 12'd10);
        write_inst(16'h2008, 5'h19, 5'd3, 5'd0, 5'd0, 12'd20);
        write_inst(16'h200C, 5'h19, 5'd4, 5'd0, 5'd0, 12'd40);
        write_inst(16'h2010, 5'h18, 5'd5, 5'd1, 5'd2, 12'd0);
        write_inst(16'h2014, 5'h18, 5'd6, 5'd3, 5'd4, 12'd0);
        write_inst(16'h2018, 5'h1C, 5'd7, 5'd5, 5'd6, 12'd0);
        write_inst(16'h201C, 5'h0F, 5'd0, 5'd0, 5'd0, 12'd0);

        #15 reset = 0;

        cycles = 0;
        while (!hlt && cycles < 1000) begin
            @(posedge clk);
            cycles = cycles + 1;
        end

        if (!hlt) begin
            $display("[FAIL] issue test timeout");
            $fatal;
        end

        repeat (4) @(posedge clk);

        if (uut.reg_file.registers[7] !== 64'd900) begin
            $display("[FAIL] dual issue / OoO smoke expected 900 got %0d", uut.reg_file.registers[7]);
            $fatal;
        end

        $display("issue smoke test passed in %0d cycles", cycles);
        $finish;
    end
endmodule
