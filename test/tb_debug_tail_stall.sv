`timescale 1ns / 1ps

module tb_debug_tail_stall;
    reg clk;
    reg reset;
    wire hlt;
    integer i;
    integer cycles;

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

    initial begin
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
        while (!hlt && cycles < 500) begin
            @(posedge clk);
            cycles = cycles + 1;
            if (cycles > 28) begin
                $display("cy=%0d pc=%h stall=%b rob_count=%0d head=%0d tail=%0d ffree=%0d fd0=%b:%h/%0d fd1=%b:%h/%0d f0=%b%b%b%b%b f1=%b%b%b%b%b issue=%b:%0d/%b:%0d take=%b/%b rs=%b%b%b%b%b%b%b%b p55=%b:%h p59=%b:%h r17=%h r18=%h r25=%h r26=%h r27=%h",
                    cycles, uut.fetch_pc, uut.control_stall, uut.rob_count, uut.rob_head, uut.rob_tail,
                    uut.fpu_rs_free_count,
                    uut.fpu_dispatch0_valid, uut.fpu_dispatch0_op, uut.fpu_dispatch0_rob,
                    uut.fpu_dispatch1_valid, uut.fpu_dispatch1_op, uut.fpu_dispatch1_rob,
                    uut.fpu0_valid[4], uut.fpu0_valid[3], uut.fpu0_valid[2], uut.fpu0_valid[1], uut.fpu0_valid[0],
                    uut.fpu1_valid[4], uut.fpu1_valid[3], uut.fpu1_valid[2], uut.fpu1_valid[1], uut.fpu1_valid[0],
                    uut.fpu_issue_valid0, uut.fpu_issue_rob0, uut.fpu_issue_valid1, uut.fpu_issue_rob1,
                    uut.fpu_issue_take0, uut.fpu_issue_take1,
                    uut.fpu_rs.valid[7], uut.fpu_rs.valid[6], uut.fpu_rs.valid[5], uut.fpu_rs.valid[4],
                    uut.fpu_rs.valid[3], uut.fpu_rs.valid[2], uut.fpu_rs.valid[1], uut.fpu_rs.valid[0],
                    uut.phys_ready[55], uut.phys_value[55], uut.phys_ready[59], uut.phys_value[59],
                    uut.reg_file.registers[17], uut.reg_file.registers[18],
                    uut.reg_file.registers[25], uut.reg_file.registers[26], uut.reg_file.registers[27]);
            end
            if (cycles > 120 && !hlt) begin
                $display("---- ROB ----");
                for (i = 0; i < 16; i = i + 1) begin
                    $display("rob[%0d] v=%b rdy=%b op=%h pc=%h hasd=%b ard=%0d pd=%0d val=%h tgt=%h taken=%b bdone=%b sdone=%b",
                        i, uut.rob_valid[i], uut.rob_ready[i], uut.rob_op[i], uut.rob_pc[i],
                        uut.rob_has_dest[i], uut.rob_arch_dest[i], uut.rob_phys_dest[i], uut.rob_value[i],
                        uut.rob_target[i], uut.rob_taken[i], uut.rob_branch_done[i], uut.rob_store_done[i]);
                end
                $display("---- FPU0 ----");
                for (i = 0; i < 5; i = i + 1) begin
                    $display("fpu0[%0d] v=%b op=%h rob=%0d dest=%0d a=%h b=%h res=%h",
                        i, uut.fpu0_valid[i], uut.fpu0_op[i], uut.fpu0_rob[i], uut.fpu0_dest[i],
                        uut.fpu0_a[i], uut.fpu0_b[i], uut.fpu0_res[i]);
                end
                $display("---- FPU1 ----");
                for (i = 0; i < 5; i = i + 1) begin
                    $display("fpu1[%0d] v=%b op=%h rob=%0d dest=%0d a=%h b=%h res=%h",
                        i, uut.fpu1_valid[i], uut.fpu1_op[i], uut.fpu1_rob[i], uut.fpu1_dest[i],
                        uut.fpu1_a[i], uut.fpu1_b[i], uut.fpu1_res[i]);
                end
                $display("---- FPURS ----");
                for (i = 0; i < 8; i = i + 1) begin
                    $display("rs[%0d] v=%b op=%h rob=%0d dest=%0d r0=%b t0=%0d v0=%h r1=%b t1=%0d v1=%h",
                        i, uut.fpu_rs.valid[i], uut.fpu_rs.op[i], uut.fpu_rs.rob[i], uut.fpu_rs.dest[i],
                        uut.fpu_rs.s0_ready[i], uut.fpu_rs.s0_tag[i], uut.fpu_rs.s0_val[i],
                        uut.fpu_rs.s1_ready[i], uut.fpu_rs.s1_tag[i], uut.fpu_rs.s1_val[i]);
                end
                $finish;
            end
        end
        $display("hlt=%b cycles=%0d", hlt, cycles);
        $finish;
    end
endmodule
