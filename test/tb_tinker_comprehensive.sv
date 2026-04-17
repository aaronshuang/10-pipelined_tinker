`timescale 1ns / 1ps

module tb_tinker_comprehensive;
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

    task write_mem64;
        input [63:0] addr;
        input [63:0] data;
        begin
            uut.memory.bytes[addr] = data[7:0];
            uut.memory.bytes[addr + 1] = data[15:8];
            uut.memory.bytes[addr + 2] = data[23:16];
            uut.memory.bytes[addr + 3] = data[31:24];
            uut.memory.bytes[addr + 4] = data[39:32];
            uut.memory.bytes[addr + 5] = data[47:40];
            uut.memory.bytes[addr + 6] = data[55:48];
            uut.memory.bytes[addr + 7] = data[63:56];
        end
    endtask

    task assert_reg;
        input [4:0] reg_idx;
        input [63:0] expected;
        input [255:0] test_name;
        begin
            if (uut.reg_file.registers[reg_idx] !== expected) begin
                $display("[FAIL] %s expected=%h actual=%h", test_name, expected, uut.reg_file.registers[reg_idx]);
                $fatal;
            end else begin
                $display("[PASS] %s", test_name);
            end
        end
    endtask

    integer cycles;

    initial begin
        $dumpfile("/u/aarons07/cs429/12.5-tinkering/10-pipelined_tinker/sim/tinker_comprehensive.vcd");
        $dumpvars(0, tb_tinker_comprehensive);

        clk = 0;
        reset = 1;

        write_mem64(16'h0108, 64'h3FF8000000000000);
        write_mem64(16'h0110, 64'h4000000000000000);
        write_mem64(16'h0118, 64'h7FF8000000000000);
        write_mem64(16'h0120, 64'h7FF0000000000000);

        write_inst(16'h2000, 5'h19, 5'd1,  5'd0, 5'd0, 12'h005);
        write_inst(16'h2004, 5'h19, 5'd2,  5'd0, 5'd0, 12'h00A);
        write_inst(16'h2008, 5'h18, 5'd3,  5'd1, 5'd2, 12'h000);
        write_inst(16'h200C, 5'h1A, 5'd4,  5'd2, 5'd1, 12'h000);
        write_inst(16'h2010, 5'h1C, 5'd5,  5'd1, 5'd2, 12'h000);
        write_inst(16'h2014, 5'h1D, 5'd6,  5'd2, 5'd1, 12'h000);

        write_inst(16'h2018, 5'h00, 5'd7,  5'd1, 5'd2, 12'h000);
        write_inst(16'h201C, 5'h01, 5'd8,  5'd1, 5'd2, 12'h000);
        write_inst(16'h2020, 5'h02, 5'd9,  5'd1, 5'd2, 12'h000);
        write_inst(16'h2024, 5'h03, 5'd10, 5'd1, 5'd0, 12'h000);

        write_inst(16'h2028, 5'h07, 5'd1,  5'd0, 5'd0, 12'h002);
        write_inst(16'h202C, 5'h05, 5'd2,  5'd0, 5'd0, 12'h001);

        write_inst(16'h2030, 5'h12, 5'd11, 5'd0, 5'd0, 12'hABC);
        write_inst(16'h2034, 5'h11, 5'd12, 5'd1, 5'd0, 12'h000);
        write_inst(16'h2038, 5'h13, 5'd0,  5'd12, 5'd0, 12'h100);
        write_inst(16'h203C, 5'h10, 5'd13, 5'd0, 5'd0, 12'h100);

        write_inst(16'h2040, 5'h0A, 5'd0,  5'd0, 5'd0, 12'h008);
        write_inst(16'h2044, 5'h19, 5'd14, 5'd0, 5'd0, 12'h999);

        write_inst(16'h2048, 5'h19, 5'd22, 5'd0, 5'd0, 12'h208);
        write_inst(16'h204C, 5'h07, 5'd22, 5'd0, 5'd0, 12'h004);
        write_inst(16'h2050, 5'h19, 5'd22, 5'd0, 5'd0, 12'h008);
        write_inst(16'h2054, 5'h0C, 5'd22, 5'd0, 5'd0, 12'h000);

        write_inst(16'h2058, 5'h10, 5'd15, 5'd0, 5'd0, 12'h108);
        write_inst(16'h205C, 5'h10, 5'd16, 5'd0, 5'd0, 12'h110);
        write_inst(16'h2060, 5'h14, 5'd17, 5'd15, 5'd16, 12'h000);
        write_inst(16'h2064, 5'h16, 5'd18, 5'd15, 5'd16, 12'h000);
        write_inst(16'h2068, 5'h10, 5'd23, 5'd0, 5'd0, 12'h118);
        write_inst(16'h206C, 5'h10, 5'd24, 5'd0, 5'd0, 12'h120);
        write_inst(16'h2070, 5'h14, 5'd25, 5'd24, 5'd16, 12'h000);
        write_inst(16'h2074, 5'h17, 5'd26, 5'd16, 5'd0, 12'h000);
        write_inst(16'h2078, 5'h16, 5'd27, 5'd23, 5'd16, 12'h000);
        write_inst(16'h207C, 5'h0F, 5'd0,  5'd0,  5'd0, 12'h000);

        write_inst(16'h2088, 5'h19, 5'd21, 5'd0,  5'd0, 12'h111);
        write_inst(16'h208C, 5'h0D, 5'd0,  5'd0,  5'd0, 12'h000);

        #15 reset = 0;

        cycles = 0;
        while (!hlt && cycles < 3000) begin
            @(posedge clk);
            cycles = cycles + 1;
        end

        if (!hlt) begin
            $display("[FAIL] timeout waiting for halt pc=%h stall=%b rob_count=%0d head=%0d tail=%0d r21=%h r22=%h",
                uut.fetch_pc, uut.control_stall, uut.rob_count, uut.rob_head, uut.rob_tail,
                uut.reg_file.registers[21], uut.reg_file.registers[22]);
            $fatal;
        end

        repeat (4) @(posedge clk);

        assert_reg(1, 64'h14, "r1 shift left");
        assert_reg(2, 64'h05, "r2 shift right");
        assert_reg(3, 64'h0F, "r3 add");
        assert_reg(4, 64'h05, "r4 sub");
        assert_reg(5, 64'h32, "r5 mul");
        assert_reg(6, 64'h02, "r6 div");
        assert_reg(7, 64'h00, "r7 and");
        assert_reg(8, 64'h0F, "r8 or");
        assert_reg(9, 64'h0F, "r9 xor");
        assert_reg(10, 64'hFFFFFFFFFFFFFFFA, "r10 not");
        assert_reg(11, 64'h0000000000000ABC, "r11 mov_l");
        assert_reg(12, 64'h14, "r12 mov_rr");
        assert_reg(13, 64'h14, "r13 load");
        assert_reg(14, 64'h00, "r14 skipped");
        assert_reg(21, 64'h111, "call/ret");
        assert_reg(17, 64'h400C000000000000, "addf");
        assert_reg(18, 64'h4008000000000000, "mulf");
        assert_reg(25, 64'h7FF0000000000000, "inf add");
        assert_reg(26, 64'h7FF0000000000000, "div by zero");
        assert_reg(27, 64'h7FF8000000000000, "nan mul");

        $display("all comprehensive tests passed in %0d cycles", cycles);
        $finish;
    end
endmodule
