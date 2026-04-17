`include "hdl/instruction_decoder.sv"
`include "hdl/register_file.sv"
`include "hdl/ALU.sv"
`include "hdl/FPU.sv"
`include "hdl/memory.sv"
`include "hdl/branch_predictor.sv"

module tinker_core (
    input clk,
    input reset,
    output logic hlt
);
    localparam ROB_SIZE = 16;
    localparam ALU_RS_SIZE = 8;
    localparam FPU_RS_SIZE = 8;
    localparam PHYS_REGS = 64;
    localparam FREE_REGS = 32;

    localparam OP_AND = 5'h00;
    localparam OP_OR = 5'h01;
    localparam OP_XOR = 5'h02;
    localparam OP_NOT = 5'h03;
    localparam OP_SHFTR = 5'h04;
    localparam OP_SHFTRI = 5'h05;
    localparam OP_SHFTL = 5'h06;
    localparam OP_SHFTLI = 5'h07;
    localparam OP_BR = 5'h08;
    localparam OP_BRR_R = 5'h09;
    localparam OP_BRR_L = 5'h0a;
    localparam OP_BRNZ = 5'h0b;
    localparam OP_CALL = 5'h0c;
    localparam OP_RET = 5'h0d;
    localparam OP_BRGT = 5'h0e;
    localparam OP_PRIV = 5'h0f;
    localparam OP_MOV_ML = 5'h10;
    localparam OP_MOV_RR = 5'h11;
    localparam OP_MOV_L = 5'h12;
    localparam OP_MOV_SM = 5'h13;
    localparam OP_ADDF = 5'h14;
    localparam OP_SUBF = 5'h15;
    localparam OP_MULF = 5'h16;
    localparam OP_DIVF = 5'h17;
    localparam OP_ADD = 5'h18;
    localparam OP_ADDI = 5'h19;
    localparam OP_SUB = 5'h1a;
    localparam OP_SUBI = 5'h1b;
    localparam OP_MUL = 5'h1c;
    localparam OP_DIV = 5'h1d;

    function [63:0] signext12;
        input [11:0] imm;
        begin
            signext12 = {{52{imm[11]}}, imm};
        end
    endfunction

    function [63:0] zeroext12;
        input [11:0] imm;
        begin
            zeroext12 = {52'b0, imm};
        end
    endfunction

    function is_fpu_op;
        input [4:0] op;
        begin
            is_fpu_op = (op >= OP_ADDF) && (op <= OP_DIVF);
        end
    endfunction

    function writes_dest;
        input [4:0] op;
        begin
            case (op)
                OP_AND, OP_OR, OP_XOR, OP_NOT,
                OP_SHFTR, OP_SHFTRI, OP_SHFTL, OP_SHFTLI,
                OP_MOV_ML, OP_MOV_RR, OP_MOV_L,
                OP_ADDF, OP_SUBF, OP_MULF, OP_DIVF,
                OP_ADD, OP_ADDI, OP_SUB, OP_SUBI, OP_MUL, OP_DIV:
                    writes_dest = 1'b1;
                default:
                    writes_dest = 1'b0;
            endcase
        end
    endfunction

    function is_load_op;
        input [4:0] op;
        begin
            is_load_op = (op == OP_MOV_ML) || (op == OP_RET);
        end
    endfunction

    function is_store_op;
        input [4:0] op;
        begin
            is_store_op = (op == OP_MOV_SM);
        end
    endfunction

    function is_control_op;
        input [4:0] op;
        begin
            case (op)
                OP_BR, OP_BRR_R, OP_BRR_L, OP_BRNZ, OP_CALL, OP_RET, OP_BRGT, OP_PRIV:
                    is_control_op = 1'b1;
                default:
                    is_control_op = 1'b0;
            endcase
        end
    endfunction

    function uses_alu_rs;
        input [4:0] op;
        begin
            case (op)
                OP_AND, OP_OR, OP_XOR, OP_NOT,
                OP_SHFTR, OP_SHFTRI, OP_SHFTL, OP_SHFTLI,
                OP_MOV_RR, OP_MOV_L,
                OP_BR, OP_BRR_R, OP_BRR_L, OP_BRNZ, OP_CALL, OP_BRGT,
                OP_ADD, OP_ADDI, OP_SUB, OP_SUBI, OP_MUL, OP_DIV:
                    uses_alu_rs = 1'b1;
                default:
                    uses_alu_rs = 1'b0;
            endcase
        end
    endfunction

    function uses_lsq;
        input [4:0] op;
        begin
            uses_lsq = (op == OP_MOV_ML) || (op == OP_MOV_SM) || (op == OP_CALL) || (op == OP_RET);
        end
    endfunction

    function [63:0] imm_operand;
        input [4:0] op;
        input [11:0] imm;
        begin
            if ((op == OP_ADDI) || (op == OP_SUBI)) imm_operand = zeroext12(imm);
            else imm_operand = signext12(imm);
        end
    endfunction

    function rob_before;
        input [4:0] cand;
        input [4:0] cur;
        integer dc;
        integer du;
        begin
            dc = cand - rob_head;
            du = cur - rob_head;
            if (dc < 0) dc = dc + ROB_SIZE;
            if (du < 0) du = du + ROB_SIZE;
            rob_before = (dc < du);
        end
    endfunction

    reg [63:0] fetch_pc;
    reg [63:0] fetch_line_base;
    reg fetch_line_valid;
    reg [31:0] fetch_words [0:15];
    reg control_stall;

    reg [5:0] rat [0:31];
    reg [63:0] phys_value [0:PHYS_REGS - 1];
    reg phys_ready [0:PHYS_REGS - 1];
    reg [5:0] free_list [0:FREE_REGS - 1];
    integer free_head;
    integer free_tail;
    integer free_count;

    reg rob_valid [0:ROB_SIZE - 1];
    reg rob_ready [0:ROB_SIZE - 1];
    reg rob_branch_done [0:ROB_SIZE - 1];
    reg rob_store_done [0:ROB_SIZE - 1];
    reg rob_has_dest [0:ROB_SIZE - 1];
    reg [4:0] rob_arch_dest [0:ROB_SIZE - 1];
    reg [5:0] rob_phys_dest [0:ROB_SIZE - 1];
    reg [5:0] rob_old_phys [0:ROB_SIZE - 1];
    reg [4:0] rob_op [0:ROB_SIZE - 1];
    reg [63:0] rob_pc [0:ROB_SIZE - 1];
    reg [63:0] rob_value [0:ROB_SIZE - 1];
    reg [63:0] rob_target [0:ROB_SIZE - 1];
    reg rob_taken [0:ROB_SIZE - 1];
    integer rob_head;
    integer rob_tail;
    integer rob_count;

    reg alu_rs_valid [0:ALU_RS_SIZE - 1];
    reg [4:0] alu_rs_op [0:ALU_RS_SIZE - 1];
    reg [4:0] alu_rs_rob [0:ALU_RS_SIZE - 1];
    reg alu_rs_has_dest [0:ALU_RS_SIZE - 1];
    reg [5:0] alu_rs_dest [0:ALU_RS_SIZE - 1];
    reg alu_rs_s0_ready [0:ALU_RS_SIZE - 1];
    reg alu_rs_s1_ready [0:ALU_RS_SIZE - 1];
    reg alu_rs_s2_ready [0:ALU_RS_SIZE - 1];
    reg [5:0] alu_rs_s0_tag [0:ALU_RS_SIZE - 1];
    reg [5:0] alu_rs_s1_tag [0:ALU_RS_SIZE - 1];
    reg [5:0] alu_rs_s2_tag [0:ALU_RS_SIZE - 1];
    reg [63:0] alu_rs_s0_val [0:ALU_RS_SIZE - 1];
    reg [63:0] alu_rs_s1_val [0:ALU_RS_SIZE - 1];
    reg [63:0] alu_rs_s2_val [0:ALU_RS_SIZE - 1];
    reg [11:0] alu_rs_imm [0:ALU_RS_SIZE - 1];
    reg [63:0] alu_rs_pc [0:ALU_RS_SIZE - 1];

    reg fpu_rs_valid [0:FPU_RS_SIZE - 1];
    reg [4:0] fpu_rs_op [0:FPU_RS_SIZE - 1];
    reg [4:0] fpu_rs_rob [0:FPU_RS_SIZE - 1];
    reg [5:0] fpu_rs_dest [0:FPU_RS_SIZE - 1];
    reg fpu_rs_s0_ready [0:FPU_RS_SIZE - 1];
    reg fpu_rs_s1_ready [0:FPU_RS_SIZE - 1];
    reg [5:0] fpu_rs_s0_tag [0:FPU_RS_SIZE - 1];
    reg [5:0] fpu_rs_s1_tag [0:FPU_RS_SIZE - 1];
    reg [63:0] fpu_rs_s0_val [0:FPU_RS_SIZE - 1];
    reg [63:0] fpu_rs_s1_val [0:FPU_RS_SIZE - 1];

    reg lsq_valid [0:ROB_SIZE - 1];
    reg lsq_issued [0:ROB_SIZE - 1];
    reg [4:0] lsq_op [0:ROB_SIZE - 1];
    reg lsq_has_dest [0:ROB_SIZE - 1];
    reg [5:0] lsq_dest [0:ROB_SIZE - 1];
    reg lsq_addr_ready [0:ROB_SIZE - 1];
    reg [5:0] lsq_addr_tag [0:ROB_SIZE - 1];
    reg [63:0] lsq_addr_val [0:ROB_SIZE - 1];
    reg lsq_data_ready [0:ROB_SIZE - 1];
    reg [5:0] lsq_data_tag [0:ROB_SIZE - 1];
    reg [63:0] lsq_data_val [0:ROB_SIZE - 1];
    reg [11:0] lsq_imm [0:ROB_SIZE - 1];
    reg [63:0] lsq_pc [0:ROB_SIZE - 1];

    reg alu0_s0_valid;
    reg alu0_s1_valid;
    reg [4:0] alu0_s0_op;
    reg [4:0] alu0_s0_rob;
    reg alu0_s0_has_dest;
    reg [5:0] alu0_s0_dest;
    reg [63:0] alu0_s0_a;
    reg [63:0] alu0_s0_b;
    reg [63:0] alu0_s0_c;
    reg [11:0] alu0_s0_imm;
    reg [63:0] alu0_s0_pc;
    reg [4:0] alu0_s1_rob;
    reg alu0_s1_has_dest;
    reg [5:0] alu0_s1_dest;
    reg [63:0] alu0_s1_res;
    reg alu0_s1_branch_valid;
    reg alu0_s1_taken;
    reg [63:0] alu0_s1_target;

    reg alu1_s0_valid;
    reg alu1_s1_valid;
    reg [4:0] alu1_s0_op;
    reg [4:0] alu1_s0_rob;
    reg alu1_s0_has_dest;
    reg [5:0] alu1_s0_dest;
    reg [63:0] alu1_s0_a;
    reg [63:0] alu1_s0_b;
    reg [63:0] alu1_s0_c;
    reg [11:0] alu1_s0_imm;
    reg [63:0] alu1_s0_pc;
    reg [4:0] alu1_s1_rob;
    reg alu1_s1_has_dest;
    reg [5:0] alu1_s1_dest;
    reg [63:0] alu1_s1_res;
    reg alu1_s1_branch_valid;
    reg alu1_s1_taken;
    reg [63:0] alu1_s1_target;

    reg fpu0_valid [0:4];
    reg [4:0] fpu0_op [0:4];
    reg [4:0] fpu0_rob [0:4];
    reg [5:0] fpu0_dest [0:4];
    reg [63:0] fpu0_a [0:4];
    reg [63:0] fpu0_b [0:4];
    reg [63:0] fpu0_res [0:4];

    reg fpu1_valid [0:4];
    reg [4:0] fpu1_op [0:4];
    reg [4:0] fpu1_rob [0:4];
    reg [5:0] fpu1_dest [0:4];
    reg [63:0] fpu1_a [0:4];
    reg [63:0] fpu1_b [0:4];
    reg [63:0] fpu1_res [0:4];

    reg ls0_s0_valid;
    reg ls0_s1_valid;
    reg [4:0] ls0_s0_op;
    reg [4:0] ls0_s0_rob;
    reg ls0_s0_has_dest;
    reg [5:0] ls0_s0_dest;
    reg [63:0] ls0_s0_addr;
    reg [63:0] ls0_s0_forward_data;
    reg ls0_s0_forward_hit;
    reg [4:0] ls0_s1_rob;
    reg ls0_s1_has_dest;
    reg [5:0] ls0_s1_dest;
    reg [63:0] ls0_s1_res;
    reg ls0_s1_is_ret;

    reg ls1_s0_valid;
    reg ls1_s1_valid;
    reg [4:0] ls1_s0_op;
    reg [4:0] ls1_s0_rob;
    reg ls1_s0_has_dest;
    reg [5:0] ls1_s0_dest;
    reg [63:0] ls1_s0_addr;
    reg [63:0] ls1_s0_forward_data;
    reg ls1_s0_forward_hit;
    reg [4:0] ls1_s1_rob;
    reg ls1_s1_has_dest;
    reg [5:0] ls1_s1_dest;
    reg [63:0] ls1_s1_res;
    reg ls1_s1_is_ret;

    wire [63:0] alu0_comb_res;
    wire [63:0] alu1_comb_res;
    wire [63:0] fpu0_comb_res;
    wire [63:0] fpu1_comb_res;
    wire [63:0] memory_read_data;
    wire [63:0] arch_rd_val;
    wire [63:0] arch_rs_val;
    wire [63:0] arch_rt_val;
    wire [63:0] arch_r31_val;
    wire bp_predict_taken;
    wire [63:0] bp_predict_target;

    reg arch_write_enable;
    reg [4:0] arch_write_rd;
    reg [63:0] arch_write_data;
    reg commit_mem_write;
    reg [63:0] commit_mem_addr;
    reg [63:0] commit_mem_data;
    reg bp_update_en;
    reg [63:0] bp_update_pc;
    reg bp_update_taken;
    reg [63:0] bp_update_target;

    integer i;
    integer j;
    integer k;
    integer idx;
    integer next_tail;
    integer rs_idx;
    integer f_idx;
    integer entry_idx;
    integer issue0_idx;
    integer issue1_idx;
    integer ls_issue0;
    integer ls_issue1;
    integer scan_idx;
    integer younger_stop;
    integer free_rs_found;
    integer free_fp_found;
    integer can_issue;
    integer forward_found;
    integer forward_idx;
    reg [63:0] forward_value;
    reg fpu0_s2_valid_hold;
    reg fpu1_s2_valid_hold;
    reg [63:0] fpu0_s2_res_hold;
    reg [63:0] fpu1_s2_res_hold;
    reg [31:0] inst0;
    reg [31:0] inst1;
    reg [4:0] op0;
    reg [4:0] rd0;
    reg [4:0] rs0;
    reg [4:0] rt0;
    reg [11:0] imm0;
    reg [4:0] op1;
    reg [4:0] rd1;
    reg [4:0] rs1;
    reg [4:0] rt1;
    reg [11:0] imm1;
    reg [63:0] pc0;
    reg [63:0] pc1;
    reg [5:0] new_phys;
    reg [5:0] new_phys1;
    reg [5:0] old_phys1;
    reg [5:0] map_src;
    reg [5:0] map_src1;
    reg [3:0] word_idx0;
    reg [3:0] word_idx1;

    ALU alu0 (.a(alu0_s0_a), .b(alu0_s0_b), .op(alu0_s0_op), .res(alu0_comb_res));
    ALU alu1 (.a(alu1_s0_a), .b(alu1_s0_b), .op(alu1_s0_op), .res(alu1_comb_res));
    FPU fpu (.a(fpu0_a[2]), .b(fpu0_b[2]), .op(fpu0_op[2]), .res(fpu0_comb_res));
    FPU fpu_aux (.a(fpu1_a[2]), .b(fpu1_b[2]), .op(fpu1_op[2]), .res(fpu1_comb_res));

    register_file reg_file (
        .clk(~clk),
        .reset(reset),
        .data(arch_write_data),
        .rd(arch_write_rd),
        .rs(5'd0),
        .rt(5'd0),
        .write_enable(arch_write_enable),
        .rd_val(arch_rd_val),
        .rs_val(arch_rs_val),
        .rt_val(arch_rt_val),
        .r31_val(arch_r31_val)
    );

    memory memory (
        .clk(~clk),
        .addr(commit_mem_addr),
        .write_data(commit_mem_data),
        .mem_write(commit_mem_write),
        .mem_read(1'b0),
        .read_data(memory_read_data)
    );

    branch_predictor predictor (
        .clk(clk),
        .reset(reset),
        .lookup_pc(fetch_pc),
        .predict_taken(bp_predict_taken),
        .predict_target(bp_predict_target),
        .update_en(bp_update_en),
        .update_pc(bp_update_pc),
        .update_taken(bp_update_taken),
        .update_target(bp_update_target)
    );

    task broadcast_result;
        input [5:0] tag;
        input [63:0] value;
        begin
            phys_value[tag] = value;
            phys_ready[tag] = 1'b1;
            for (j = 0; j < ALU_RS_SIZE; j = j + 1) begin
                if (alu_rs_valid[j] && !alu_rs_s0_ready[j] && (alu_rs_s0_tag[j] == tag)) begin
                    alu_rs_s0_ready[j] = 1'b1;
                    alu_rs_s0_val[j] = value;
                end
                if (alu_rs_valid[j] && !alu_rs_s1_ready[j] && (alu_rs_s1_tag[j] == tag)) begin
                    alu_rs_s1_ready[j] = 1'b1;
                    alu_rs_s1_val[j] = value;
                end
                if (alu_rs_valid[j] && !alu_rs_s2_ready[j] && (alu_rs_s2_tag[j] == tag)) begin
                    alu_rs_s2_ready[j] = 1'b1;
                    alu_rs_s2_val[j] = value;
                end
            end
            for (j = 0; j < FPU_RS_SIZE; j = j + 1) begin
                if (fpu_rs_valid[j] && !fpu_rs_s0_ready[j] && (fpu_rs_s0_tag[j] == tag)) begin
                    fpu_rs_s0_ready[j] = 1'b1;
                    fpu_rs_s0_val[j] = value;
                end
                if (fpu_rs_valid[j] && !fpu_rs_s1_ready[j] && (fpu_rs_s1_tag[j] == tag)) begin
                    fpu_rs_s1_ready[j] = 1'b1;
                    fpu_rs_s1_val[j] = value;
                end
            end
            for (j = 0; j < ROB_SIZE; j = j + 1) begin
                if (lsq_valid[j] && !lsq_addr_ready[j] && (lsq_addr_tag[j] == tag)) begin
                    lsq_addr_ready[j] = 1'b1;
                    lsq_addr_val[j] = value;
                end
                if (lsq_valid[j] && !lsq_data_ready[j] && (lsq_data_tag[j] == tag)) begin
                    lsq_data_ready[j] = 1'b1;
                    lsq_data_val[j] = value;
                end
            end
        end
    endtask

    task resolve_branch;
        input [4:0] rob_idx_in;
        input taken_in;
        input [63:0] target_in;
        input [63:0] pc_in;
        begin
            rob_branch_done[rob_idx_in] = 1'b1;
            rob_taken[rob_idx_in] = taken_in;
            rob_target[rob_idx_in] = target_in;
            if (rob_op[rob_idx_in] == OP_CALL) begin
                if (rob_store_done[rob_idx_in]) rob_ready[rob_idx_in] = 1'b1;
            end else begin
                rob_ready[rob_idx_in] = 1'b1;
            end

            control_stall = 1'b0;
            if (taken_in) begin
                fetch_pc = target_in;
                fetch_line_valid = 1'b0;
            end

            bp_update_en = 1'b1;
            bp_update_pc = pc_in;
            bp_update_taken = taken_in;
            bp_update_target = target_in;
        end
    endtask

    always @(posedge clk) begin
        if (reset) begin
            hlt = 1'b0;
            fetch_pc = 64'h2000;
            fetch_line_base = 64'b0;
            fetch_line_valid = 1'b0;
            control_stall = 1'b0;

            arch_write_enable = 1'b0;
            arch_write_rd = 5'b0;
            arch_write_data = 64'b0;
            commit_mem_write = 1'b0;
            commit_mem_addr = 64'b0;
            commit_mem_data = 64'b0;
            bp_update_en = 1'b0;
            bp_update_pc = 64'b0;
            bp_update_taken = 1'b0;
            bp_update_target = 64'b0;

            rob_head = 0;
            rob_tail = 0;
            rob_count = 0;

            free_head = 0;
            free_tail = 0;
            free_count = FREE_REGS;
            for (i = 0; i < FREE_REGS; i = i + 1) begin
                free_list[i] = i + 32;
            end

            for (i = 0; i < 32; i = i + 1) begin
                rat[i] = i[5:0];
            end

            for (i = 0; i < PHYS_REGS; i = i + 1) begin
                phys_value[i] = 64'b0;
                phys_ready[i] = 1'b1;
            end
            phys_value[31] = 64'd524288;

            for (i = 0; i < ROB_SIZE; i = i + 1) begin
                rob_valid[i] = 1'b0;
                rob_ready[i] = 1'b0;
                rob_branch_done[i] = 1'b0;
                rob_store_done[i] = 1'b0;
                rob_has_dest[i] = 1'b0;
                rob_arch_dest[i] = 5'b0;
                rob_phys_dest[i] = 6'b0;
                rob_old_phys[i] = 6'b0;
                rob_op[i] = 5'b0;
                rob_pc[i] = 64'b0;
                rob_value[i] = 64'b0;
                rob_target[i] = 64'b0;
                rob_taken[i] = 1'b0;
                lsq_valid[i] = 1'b0;
                lsq_issued[i] = 1'b0;
                lsq_op[i] = 5'b0;
                lsq_has_dest[i] = 1'b0;
                lsq_dest[i] = 6'b0;
                lsq_addr_ready[i] = 1'b0;
                lsq_addr_tag[i] = 6'b0;
                lsq_addr_val[i] = 64'b0;
                lsq_data_ready[i] = 1'b0;
                lsq_data_tag[i] = 6'b0;
                lsq_data_val[i] = 64'b0;
                lsq_imm[i] = 12'b0;
                lsq_pc[i] = 64'b0;
            end

            for (i = 0; i < ALU_RS_SIZE; i = i + 1) begin
                alu_rs_valid[i] = 1'b0;
                alu_rs_op[i] = 5'b0;
                alu_rs_rob[i] = 5'b0;
                alu_rs_has_dest[i] = 1'b0;
                alu_rs_dest[i] = 6'b0;
                alu_rs_s0_ready[i] = 1'b0;
                alu_rs_s1_ready[i] = 1'b0;
                alu_rs_s2_ready[i] = 1'b0;
                alu_rs_s0_tag[i] = 6'b0;
                alu_rs_s1_tag[i] = 6'b0;
                alu_rs_s2_tag[i] = 6'b0;
                alu_rs_s0_val[i] = 64'b0;
                alu_rs_s1_val[i] = 64'b0;
                alu_rs_s2_val[i] = 64'b0;
                alu_rs_imm[i] = 12'b0;
                alu_rs_pc[i] = 64'b0;
            end

            for (i = 0; i < FPU_RS_SIZE; i = i + 1) begin
                fpu_rs_valid[i] = 1'b0;
                fpu_rs_op[i] = 5'b0;
                fpu_rs_rob[i] = 5'b0;
                fpu_rs_dest[i] = 6'b0;
                fpu_rs_s0_ready[i] = 1'b0;
                fpu_rs_s1_ready[i] = 1'b0;
                fpu_rs_s0_tag[i] = 6'b0;
                fpu_rs_s1_tag[i] = 6'b0;
                fpu_rs_s0_val[i] = 64'b0;
                fpu_rs_s1_val[i] = 64'b0;
            end

            alu0_s0_valid = 1'b0;
            alu0_s1_valid = 1'b0;
            alu1_s0_valid = 1'b0;
            alu1_s1_valid = 1'b0;
            ls0_s0_valid = 1'b0;
            ls0_s1_valid = 1'b0;
            ls1_s0_valid = 1'b0;
            ls1_s1_valid = 1'b0;
            for (i = 0; i < 5; i = i + 1) begin
                fpu0_valid[i] = 1'b0;
                fpu1_valid[i] = 1'b0;
                fpu0_op[i] = 5'b0;
                fpu1_op[i] = 5'b0;
                fpu0_rob[i] = 5'b0;
                fpu1_rob[i] = 5'b0;
                fpu0_dest[i] = 6'b0;
                fpu1_dest[i] = 6'b0;
                fpu0_a[i] = 64'b0;
                fpu0_b[i] = 64'b0;
                fpu1_a[i] = 64'b0;
                fpu1_b[i] = 64'b0;
                fpu0_res[i] = 64'b0;
                fpu1_res[i] = 64'b0;
            end
        end else if (!hlt) begin
            arch_write_enable = 1'b0;
            commit_mem_write = 1'b0;
            bp_update_en = 1'b0;

            if (rob_count > 0 && rob_valid[rob_head] && rob_ready[rob_head]) begin
                if (rob_has_dest[rob_head]) begin
                    arch_write_enable = 1'b1;
                    arch_write_rd = rob_arch_dest[rob_head];
                    arch_write_data = rob_value[rob_head];
                end

                if ((rob_op[rob_head] == OP_MOV_SM) || (rob_op[rob_head] == OP_CALL)) begin
                    commit_mem_write = 1'b1;
                    commit_mem_addr = lsq_addr_val[rob_head] + ((rob_op[rob_head] == OP_CALL) ? 64'hfffffffffffffff8 : signext12(lsq_imm[rob_head]));
                    commit_mem_data = lsq_data_val[rob_head];
                end

                if (rob_has_dest[rob_head]) begin
                    if (rob_old_phys[rob_head] >= 32) begin
                        free_list[free_tail] = rob_old_phys[rob_head];
                        free_tail = (free_tail + 1) % FREE_REGS;
                        free_count = free_count + 1;
                    end
                end

                if (rob_op[rob_head] == OP_PRIV) begin
                    hlt = 1'b1;
                end

                lsq_valid[rob_head] = 1'b0;
                rob_valid[rob_head] = 1'b0;
                rob_ready[rob_head] = 1'b0;
                rob_head = (rob_head + 1) % ROB_SIZE;
                rob_count = rob_count - 1;
            end

            if (alu0_s1_valid) begin
                if (alu0_s1_has_dest) begin
                    rob_value[alu0_s1_rob] = alu0_s1_res;
                    rob_ready[alu0_s1_rob] = 1'b1;
                    broadcast_result(alu0_s1_dest, alu0_s1_res);
                end else if (alu0_s1_branch_valid) begin
                    resolve_branch(alu0_s1_rob, alu0_s1_taken, alu0_s1_target, rob_pc[alu0_s1_rob]);
                end else begin
                    rob_ready[alu0_s1_rob] = 1'b1;
                end
            end

            if (alu1_s1_valid) begin
                if (alu1_s1_has_dest) begin
                    rob_value[alu1_s1_rob] = alu1_s1_res;
                    rob_ready[alu1_s1_rob] = 1'b1;
                    broadcast_result(alu1_s1_dest, alu1_s1_res);
                end else if (alu1_s1_branch_valid) begin
                    resolve_branch(alu1_s1_rob, alu1_s1_taken, alu1_s1_target, rob_pc[alu1_s1_rob]);
                end else begin
                    rob_ready[alu1_s1_rob] = 1'b1;
                end
            end

            if (fpu0_valid[4]) begin
                rob_value[fpu0_rob[4]] = fpu0_res[4];
                rob_ready[fpu0_rob[4]] = 1'b1;
                broadcast_result(fpu0_dest[4], fpu0_res[4]);
            end
            if (fpu1_valid[4]) begin
                rob_value[fpu1_rob[4]] = fpu1_res[4];
                rob_ready[fpu1_rob[4]] = 1'b1;
                broadcast_result(fpu1_dest[4], fpu1_res[4]);
            end

            if (ls0_s1_valid) begin
                if (ls0_s1_has_dest) begin
                    rob_value[ls0_s1_rob] = ls0_s1_res;
                    rob_ready[ls0_s1_rob] = 1'b1;
                    broadcast_result(ls0_s1_dest, ls0_s1_res);
                end else if (rob_op[ls0_s1_rob] == OP_RET) begin
                    rob_value[ls0_s1_rob] = ls0_s1_res;
                    resolve_branch(ls0_s1_rob, 1'b1, ls0_s1_res, rob_pc[ls0_s1_rob]);
                end
            end
            if (ls1_s1_valid) begin
                if (ls1_s1_has_dest) begin
                    rob_value[ls1_s1_rob] = ls1_s1_res;
                    rob_ready[ls1_s1_rob] = 1'b1;
                    broadcast_result(ls1_s1_dest, ls1_s1_res);
                end else if (rob_op[ls1_s1_rob] == OP_RET) begin
                    rob_value[ls1_s1_rob] = ls1_s1_res;
                    resolve_branch(ls1_s1_rob, 1'b1, ls1_s1_res, rob_pc[ls1_s1_rob]);
                end
            end

            for (i = 0; i < ROB_SIZE; i = i + 1) begin
                if (lsq_valid[i] && !rob_store_done[i] && (rob_op[i] == OP_MOV_SM || rob_op[i] == OP_CALL) &&
                    lsq_addr_ready[i] && lsq_data_ready[i]) begin
                    rob_store_done[i] = 1'b1;
                    if (rob_op[i] == OP_MOV_SM) rob_ready[i] = 1'b1;
                    else if (rob_branch_done[i]) rob_ready[i] = 1'b1;
                end
            end

            alu0_s1_valid = alu0_s0_valid;
            alu0_s1_rob = alu0_s0_rob;
            alu0_s1_has_dest = alu0_s0_has_dest;
            alu0_s1_dest = alu0_s0_dest;
            alu0_s1_branch_valid = 1'b0;
            alu0_s1_taken = 1'b0;
            alu0_s1_target = 64'b0;
            alu0_s1_res = alu0_comb_res;
            if (alu0_s0_valid) begin
                case (alu0_s0_op)
                    OP_BR: begin
                        alu0_s1_branch_valid = 1'b1;
                        alu0_s1_taken = 1'b1;
                        alu0_s1_target = alu0_s0_a;
                    end
                    OP_BRR_R: begin
                        alu0_s1_branch_valid = 1'b1;
                        alu0_s1_taken = 1'b1;
                        alu0_s1_target = alu0_s0_pc + alu0_s0_a;
                    end
                    OP_BRR_L: begin
                        alu0_s1_branch_valid = 1'b1;
                        alu0_s1_taken = 1'b1;
                        alu0_s1_target = alu0_s0_pc + signext12(alu0_s0_imm);
                    end
                    OP_BRNZ: begin
                        alu0_s1_branch_valid = 1'b1;
                        alu0_s1_taken = (alu0_s0_b != 0);
                        alu0_s1_target = alu0_s0_a;
                    end
                    OP_BRGT: begin
                        alu0_s1_branch_valid = 1'b1;
                        alu0_s1_taken = (alu0_s0_b > alu0_s0_c);
                        alu0_s1_target = alu0_s0_a;
                    end
                    OP_CALL: begin
                        alu0_s1_branch_valid = 1'b1;
                        alu0_s1_taken = 1'b1;
                        alu0_s1_target = alu0_s0_a;
                    end
                    default: begin
                    end
                endcase
            end

            alu1_s1_valid = alu1_s0_valid;
            alu1_s1_rob = alu1_s0_rob;
            alu1_s1_has_dest = alu1_s0_has_dest;
            alu1_s1_dest = alu1_s0_dest;
            alu1_s1_branch_valid = 1'b0;
            alu1_s1_taken = 1'b0;
            alu1_s1_target = 64'b0;
            alu1_s1_res = alu1_comb_res;
            if (alu1_s0_valid) begin
                case (alu1_s0_op)
                    OP_BR: begin
                        alu1_s1_branch_valid = 1'b1;
                        alu1_s1_taken = 1'b1;
                        alu1_s1_target = alu1_s0_a;
                    end
                    OP_BRR_R: begin
                        alu1_s1_branch_valid = 1'b1;
                        alu1_s1_taken = 1'b1;
                        alu1_s1_target = alu1_s0_pc + alu1_s0_a;
                    end
                    OP_BRR_L: begin
                        alu1_s1_branch_valid = 1'b1;
                        alu1_s1_taken = 1'b1;
                        alu1_s1_target = alu1_s0_pc + signext12(alu1_s0_imm);
                    end
                    OP_BRNZ: begin
                        alu1_s1_branch_valid = 1'b1;
                        alu1_s1_taken = (alu1_s0_b != 0);
                        alu1_s1_target = alu1_s0_a;
                    end
                    OP_BRGT: begin
                        alu1_s1_branch_valid = 1'b1;
                        alu1_s1_taken = (alu1_s0_b > alu1_s0_c);
                        alu1_s1_target = alu1_s0_a;
                    end
                    OP_CALL: begin
                        alu1_s1_branch_valid = 1'b1;
                        alu1_s1_taken = 1'b1;
                        alu1_s1_target = alu1_s0_a;
                    end
                    default: begin
                    end
                endcase
            end

            alu0_s0_valid = 1'b0;
            alu1_s0_valid = 1'b0;

            fpu0_s2_valid_hold = fpu0_valid[2];
            fpu1_s2_valid_hold = fpu1_valid[2];
            fpu0_s2_res_hold = fpu0_comb_res;
            fpu1_s2_res_hold = fpu1_comb_res;

            for (i = 4; i > 0; i = i - 1) begin
                fpu0_valid[i] = fpu0_valid[i - 1];
                fpu0_op[i] = fpu0_op[i - 1];
                fpu0_rob[i] = fpu0_rob[i - 1];
                fpu0_dest[i] = fpu0_dest[i - 1];
                fpu0_a[i] = fpu0_a[i - 1];
                fpu0_b[i] = fpu0_b[i - 1];
                fpu0_res[i] = fpu0_res[i - 1];
                fpu1_valid[i] = fpu1_valid[i - 1];
                fpu1_op[i] = fpu1_op[i - 1];
                fpu1_rob[i] = fpu1_rob[i - 1];
                fpu1_dest[i] = fpu1_dest[i - 1];
                fpu1_a[i] = fpu1_a[i - 1];
                fpu1_b[i] = fpu1_b[i - 1];
                fpu1_res[i] = fpu1_res[i - 1];
            end
            fpu0_valid[0] = 1'b0;
            fpu1_valid[0] = 1'b0;
            if (fpu0_s2_valid_hold) fpu0_res[3] = fpu0_s2_res_hold;
            if (fpu1_s2_valid_hold) fpu1_res[3] = fpu1_s2_res_hold;

            ls0_s1_valid = ls0_s0_valid;
            ls0_s1_rob = ls0_s0_rob;
            ls0_s1_has_dest = ls0_s0_has_dest;
            ls0_s1_dest = ls0_s0_dest;
            ls0_s1_is_ret = (ls0_s0_op == OP_RET);
            ls0_s1_res = ls0_s0_forward_hit ? ls0_s0_forward_data : {
                memory.bytes[ls0_s0_addr + 7], memory.bytes[ls0_s0_addr + 6], memory.bytes[ls0_s0_addr + 5], memory.bytes[ls0_s0_addr + 4],
                memory.bytes[ls0_s0_addr + 3], memory.bytes[ls0_s0_addr + 2], memory.bytes[ls0_s0_addr + 1], memory.bytes[ls0_s0_addr]
            };
            ls1_s1_valid = ls1_s0_valid;
            ls1_s1_rob = ls1_s0_rob;
            ls1_s1_has_dest = ls1_s0_has_dest;
            ls1_s1_dest = ls1_s0_dest;
            ls1_s1_is_ret = (ls1_s0_op == OP_RET);
            ls1_s1_res = ls1_s0_forward_hit ? ls1_s0_forward_data : {
                memory.bytes[ls1_s0_addr + 7], memory.bytes[ls1_s0_addr + 6], memory.bytes[ls1_s0_addr + 5], memory.bytes[ls1_s0_addr + 4],
                memory.bytes[ls1_s0_addr + 3], memory.bytes[ls1_s0_addr + 2], memory.bytes[ls1_s0_addr + 1], memory.bytes[ls1_s0_addr]
            };
            ls0_s0_valid = 1'b0;
            ls1_s0_valid = 1'b0;

            issue0_idx = -1;
            issue1_idx = -1;
            for (i = 0; i < ALU_RS_SIZE; i = i + 1) begin
                if (alu_rs_valid[i] && alu_rs_s0_ready[i] &&
                    ((alu_rs_op[i] == OP_BR) || (alu_rs_op[i] == OP_BRR_R) || (alu_rs_op[i] == OP_BRR_L) ||
                     (alu_rs_op[i] == OP_CALL) ||
                     ((alu_rs_op[i] == OP_BRNZ) && alu_rs_s1_ready[i]) ||
                     ((alu_rs_op[i] == OP_BRGT) && alu_rs_s1_ready[i] && alu_rs_s2_ready[i]) ||
                     (!(alu_rs_op[i] == OP_BR || alu_rs_op[i] == OP_BRR_R || alu_rs_op[i] == OP_BRR_L || alu_rs_op[i] == OP_CALL || alu_rs_op[i] == OP_BRNZ || alu_rs_op[i] == OP_BRGT) &&
                      ((alu_rs_op[i] == OP_NOT || alu_rs_op[i] == OP_MOV_RR) || alu_rs_s1_ready[i])))) begin
                    if (issue0_idx == -1) issue0_idx = i;
                    else if (issue1_idx == -1) issue1_idx = i;
                end
            end

            if (issue0_idx != -1) begin
                alu0_s0_valid = 1'b1;
                alu0_s0_op = alu_rs_op[issue0_idx];
                alu0_s0_rob = alu_rs_rob[issue0_idx];
                alu0_s0_has_dest = alu_rs_has_dest[issue0_idx];
                alu0_s0_dest = alu_rs_dest[issue0_idx];
                alu0_s0_a = alu_rs_s0_val[issue0_idx];
                alu0_s0_b = alu_rs_s1_val[issue0_idx];
                alu0_s0_c = alu_rs_s2_val[issue0_idx];
                alu0_s0_imm = alu_rs_imm[issue0_idx];
                alu0_s0_pc = alu_rs_pc[issue0_idx];
                if ((alu_rs_op[issue0_idx] == OP_ADDI) || (alu_rs_op[issue0_idx] == OP_SUBI) ||
                    (alu_rs_op[issue0_idx] == OP_SHFTRI) || (alu_rs_op[issue0_idx] == OP_SHFTLI) ||
                    (alu_rs_op[issue0_idx] == OP_MOV_L)) begin
                    alu0_s0_b = imm_operand(alu_rs_op[issue0_idx], alu_rs_imm[issue0_idx]);
                end
                alu_rs_valid[issue0_idx] = 1'b0;
            end

            if (issue1_idx != -1) begin
                alu1_s0_valid = 1'b1;
                alu1_s0_op = alu_rs_op[issue1_idx];
                alu1_s0_rob = alu_rs_rob[issue1_idx];
                alu1_s0_has_dest = alu_rs_has_dest[issue1_idx];
                alu1_s0_dest = alu_rs_dest[issue1_idx];
                alu1_s0_a = alu_rs_s0_val[issue1_idx];
                alu1_s0_b = alu_rs_s1_val[issue1_idx];
                alu1_s0_c = alu_rs_s2_val[issue1_idx];
                alu1_s0_imm = alu_rs_imm[issue1_idx];
                alu1_s0_pc = alu_rs_pc[issue1_idx];
                if ((alu_rs_op[issue1_idx] == OP_ADDI) || (alu_rs_op[issue1_idx] == OP_SUBI) ||
                    (alu_rs_op[issue1_idx] == OP_SHFTRI) || (alu_rs_op[issue1_idx] == OP_SHFTLI) ||
                    (alu_rs_op[issue1_idx] == OP_MOV_L)) begin
                    alu1_s0_b = imm_operand(alu_rs_op[issue1_idx], alu_rs_imm[issue1_idx]);
                end
                alu_rs_valid[issue1_idx] = 1'b0;
            end

            issue0_idx = -1;
            issue1_idx = -1;
            for (i = 0; i < FPU_RS_SIZE; i = i + 1) begin
                if (fpu_rs_valid[i] && fpu_rs_s0_ready[i] && fpu_rs_s1_ready[i]) begin
                    if (issue0_idx == -1) issue0_idx = i;
                    else if (issue1_idx == -1) issue1_idx = i;
                end
            end

            if ((issue0_idx != -1) && !fpu0_valid[0]) begin
                fpu0_valid[0] = 1'b1;
                fpu0_op[0] = fpu_rs_op[issue0_idx];
                fpu0_rob[0] = fpu_rs_rob[issue0_idx];
                fpu0_dest[0] = fpu_rs_dest[issue0_idx];
                fpu0_a[0] = fpu_rs_s0_val[issue0_idx];
                fpu0_b[0] = fpu_rs_s1_val[issue0_idx];
                fpu0_res[0] = 64'b0;
                fpu_rs_valid[issue0_idx] = 1'b0;
            end
            if ((issue1_idx != -1) && !fpu1_valid[0]) begin
                fpu1_valid[0] = 1'b1;
                fpu1_op[0] = fpu_rs_op[issue1_idx];
                fpu1_rob[0] = fpu_rs_rob[issue1_idx];
                fpu1_dest[0] = fpu_rs_dest[issue1_idx];
                fpu1_a[0] = fpu_rs_s0_val[issue1_idx];
                fpu1_b[0] = fpu_rs_s1_val[issue1_idx];
                fpu1_res[0] = 64'b0;
                fpu_rs_valid[issue1_idx] = 1'b0;
            end

            ls_issue0 = -1;
            ls_issue1 = -1;
            for (i = 0; i < ROB_SIZE; i = i + 1) begin
                if (lsq_valid[i] && !lsq_issued[i] && (rob_op[i] == OP_MOV_ML || rob_op[i] == OP_RET) && lsq_addr_ready[i]) begin
                    can_issue = 1;
                    forward_found = 0;
                    forward_idx = -1;
                    forward_value = 64'b0;
                    for (k = 0; k < ROB_SIZE; k = k + 1) begin
                        if (lsq_valid[k] && (rob_op[k] == OP_MOV_SM || rob_op[k] == OP_CALL) && rob_before(k[4:0], i[4:0])) begin
                            if (!lsq_addr_ready[k]) can_issue = 0;
                            else if (lsq_addr_val[k] + ((rob_op[k] == OP_CALL) ? 64'hfffffffffffffff8 : signext12(lsq_imm[k])) == lsq_addr_val[i] + ((rob_op[i] == OP_RET) ? 64'hfffffffffffffff8 : signext12(lsq_imm[i]))) begin
                                if (!lsq_data_ready[k]) can_issue = 0;
                                else begin
                                    forward_found = 1;
                                    forward_idx = k;
                                    forward_value = lsq_data_val[k];
                                end
                            end
                        end
                    end
                    if (can_issue) begin
                        if (ls_issue0 == -1) begin
                            ls_issue0 = i;
                            ls0_s0_forward_hit = forward_found;
                            ls0_s0_forward_data = forward_value;
                        end else if (ls_issue1 == -1) begin
                            ls_issue1 = i;
                            ls1_s0_forward_hit = forward_found;
                            ls1_s0_forward_data = forward_value;
                        end
                    end
                end
            end

            if (ls_issue0 != -1) begin
                ls0_s0_valid = 1'b1;
                ls0_s0_op = lsq_op[ls_issue0];
                ls0_s0_rob = ls_issue0[4:0];
                ls0_s0_has_dest = lsq_has_dest[ls_issue0];
                ls0_s0_dest = lsq_dest[ls_issue0];
                ls0_s0_addr = lsq_addr_val[ls_issue0] + ((lsq_op[ls_issue0] == OP_RET) ? 64'hfffffffffffffff8 : signext12(lsq_imm[ls_issue0]));
                lsq_issued[ls_issue0] = 1'b1;
            end
            if (ls_issue1 != -1) begin
                ls1_s0_valid = 1'b1;
                ls1_s0_op = lsq_op[ls_issue1];
                ls1_s0_rob = ls_issue1[4:0];
                ls1_s0_has_dest = lsq_has_dest[ls_issue1];
                ls1_s0_dest = lsq_dest[ls_issue1];
                ls1_s0_addr = lsq_addr_val[ls_issue1] + ((lsq_op[ls_issue1] == OP_RET) ? 64'hfffffffffffffff8 : signext12(lsq_imm[ls_issue1]));
                lsq_issued[ls_issue1] = 1'b1;
            end

            if (!control_stall) begin
                if (!fetch_line_valid || fetch_line_base[63:6] != fetch_pc[63:6]) begin
                    fetch_line_base = {fetch_pc[63:6], 6'b0};
                    for (i = 0; i < 16; i = i + 1) begin
                        idx = {fetch_pc[63:6], 6'b0} + (i * 4);
                        fetch_words[i] = {memory.bytes[idx + 3], memory.bytes[idx + 2], memory.bytes[idx + 1], memory.bytes[idx]};
                    end
                    fetch_line_valid = 1'b1;
                end else begin
                    word_idx0 = fetch_pc[5:2];
                    word_idx1 = word_idx0 + 1;
                    inst0 = fetch_words[word_idx0];
                    op0 = inst0[31:27];
                    rd0 = inst0[26:22];
                    rs0 = inst0[21:17];
                    rt0 = inst0[16:12];
                    imm0 = inst0[11:0];
                    pc0 = fetch_pc;

                    if (rob_count < ROB_SIZE) begin
                        free_rs_found = -1;
                        free_fp_found = -1;
                        if (uses_alu_rs(op0)) begin
                            for (i = 0; i < ALU_RS_SIZE; i = i + 1) begin
                                if (!alu_rs_valid[i] && free_rs_found == -1) free_rs_found = i;
                            end
                        end
                        if (is_fpu_op(op0)) begin
                            for (i = 0; i < FPU_RS_SIZE; i = i + 1) begin
                                if (!fpu_rs_valid[i] && free_fp_found == -1) free_fp_found = i;
                            end
                        end

                        if ((!writes_dest(op0) || (free_count > 0)) &&
                            (!uses_alu_rs(op0) || (free_rs_found != -1)) &&
                            (!is_fpu_op(op0) || (free_fp_found != -1))) begin
                            entry_idx = rob_tail;
                            rob_valid[entry_idx] = 1'b1;
                            rob_ready[entry_idx] = (op0 == OP_PRIV);
                            rob_branch_done[entry_idx] = 1'b0;
                            rob_store_done[entry_idx] = 1'b0;
                            rob_has_dest[entry_idx] = writes_dest(op0);
                            rob_arch_dest[entry_idx] = rd0;
                            rob_op[entry_idx] = op0;
                            rob_pc[entry_idx] = pc0;
                            rob_value[entry_idx] = 64'b0;
                            rob_target[entry_idx] = 64'b0;
                            rob_taken[entry_idx] = 1'b0;

                            if (writes_dest(op0)) begin
                                new_phys = free_list[free_head];
                                free_head = (free_head + 1) % FREE_REGS;
                                free_count = free_count - 1;
                                rob_phys_dest[entry_idx] = new_phys;
                                rob_old_phys[entry_idx] = rat[rd0];
                                rat[rd0] = new_phys;
                                phys_ready[new_phys] = 1'b0;
                                phys_value[new_phys] = 64'b0;
                            end else begin
                                rob_phys_dest[entry_idx] = 6'b0;
                                rob_old_phys[entry_idx] = 6'b0;
                            end

                            if (uses_alu_rs(op0)) begin
                                alu_rs_valid[free_rs_found] = 1'b1;
                                alu_rs_op[free_rs_found] = op0;
                                alu_rs_rob[free_rs_found] = entry_idx[4:0];
                                alu_rs_has_dest[free_rs_found] = writes_dest(op0);
                                alu_rs_dest[free_rs_found] = rob_phys_dest[entry_idx];
                                alu_rs_imm[free_rs_found] = imm0;
                                alu_rs_pc[free_rs_found] = pc0;
                                alu_rs_s0_ready[free_rs_found] = 1'b0;
                                alu_rs_s1_ready[free_rs_found] = 1'b0;
                                alu_rs_s2_ready[free_rs_found] = 1'b0;

                                case (op0)
                                    OP_ADDI, OP_SUBI, OP_SHFTRI, OP_SHFTLI, OP_MOV_L: begin
                                        map_src = rob_has_dest[entry_idx] ? rob_old_phys[entry_idx] : rat[rd0];
                                        alu_rs_s0_tag[free_rs_found] = map_src;
                                        alu_rs_s0_ready[free_rs_found] = phys_ready[map_src];
                                        alu_rs_s0_val[free_rs_found] = phys_value[map_src];
                                        alu_rs_s1_ready[free_rs_found] = 1'b1;
                                        alu_rs_s1_val[free_rs_found] = imm_operand(op0, imm0);
                                    end
                                    OP_MOV_RR, OP_NOT: begin
                                        map_src = rat[rs0];
                                        alu_rs_s0_tag[free_rs_found] = map_src;
                                        alu_rs_s0_ready[free_rs_found] = phys_ready[map_src];
                                        alu_rs_s0_val[free_rs_found] = phys_value[map_src];
                                        alu_rs_s1_ready[free_rs_found] = 1'b1;
                                        alu_rs_s1_val[free_rs_found] = 64'b0;
                                    end
                                    OP_BR: begin
                                        map_src = rat[rd0];
                                        alu_rs_s0_tag[free_rs_found] = map_src;
                                        alu_rs_s0_ready[free_rs_found] = phys_ready[map_src];
                                        alu_rs_s0_val[free_rs_found] = phys_value[map_src];
                                    end
                                    OP_BRR_R: begin
                                        map_src = rat[rd0];
                                        alu_rs_s0_tag[free_rs_found] = map_src;
                                        alu_rs_s0_ready[free_rs_found] = phys_ready[map_src];
                                        alu_rs_s0_val[free_rs_found] = phys_value[map_src];
                                    end
                                    OP_BRR_L: begin
                                        alu_rs_s0_ready[free_rs_found] = 1'b1;
                                        alu_rs_s0_val[free_rs_found] = 64'b0;
                                    end
                                    OP_BRNZ: begin
                                        map_src = rat[rd0];
                                        alu_rs_s0_tag[free_rs_found] = map_src;
                                        alu_rs_s0_ready[free_rs_found] = phys_ready[map_src];
                                        alu_rs_s0_val[free_rs_found] = phys_value[map_src];
                                        map_src = rat[rs0];
                                        alu_rs_s1_tag[free_rs_found] = map_src;
                                        alu_rs_s1_ready[free_rs_found] = phys_ready[map_src];
                                        alu_rs_s1_val[free_rs_found] = phys_value[map_src];
                                    end
                                    OP_BRGT: begin
                                        map_src = rat[rd0];
                                        alu_rs_s0_tag[free_rs_found] = map_src;
                                        alu_rs_s0_ready[free_rs_found] = phys_ready[map_src];
                                        alu_rs_s0_val[free_rs_found] = phys_value[map_src];
                                        map_src = rat[rs0];
                                        alu_rs_s1_tag[free_rs_found] = map_src;
                                        alu_rs_s1_ready[free_rs_found] = phys_ready[map_src];
                                        alu_rs_s1_val[free_rs_found] = phys_value[map_src];
                                        map_src = rat[rt0];
                                        alu_rs_s2_tag[free_rs_found] = map_src;
                                        alu_rs_s2_ready[free_rs_found] = phys_ready[map_src];
                                        alu_rs_s2_val[free_rs_found] = phys_value[map_src];
                                    end
                                    OP_CALL: begin
                                        map_src = rat[rd0];
                                        alu_rs_s0_tag[free_rs_found] = map_src;
                                        alu_rs_s0_ready[free_rs_found] = phys_ready[map_src];
                                        alu_rs_s0_val[free_rs_found] = phys_value[map_src];
                                    end
                                    default: begin
                                        map_src = rat[rs0];
                                        alu_rs_s0_tag[free_rs_found] = map_src;
                                        alu_rs_s0_ready[free_rs_found] = phys_ready[map_src];
                                        alu_rs_s0_val[free_rs_found] = phys_value[map_src];
                                        if (op0 == OP_NOT) begin
                                            alu_rs_s1_ready[free_rs_found] = 1'b1;
                                            alu_rs_s1_val[free_rs_found] = 64'b0;
                                        end else begin
                                            map_src = rat[rt0];
                                            alu_rs_s1_tag[free_rs_found] = map_src;
                                            alu_rs_s1_ready[free_rs_found] = phys_ready[map_src];
                                            alu_rs_s1_val[free_rs_found] = phys_value[map_src];
                                        end
                                    end
                                endcase
                            end else if (is_fpu_op(op0)) begin
                                fpu_rs_valid[free_fp_found] = 1'b1;
                                fpu_rs_op[free_fp_found] = op0;
                                fpu_rs_rob[free_fp_found] = entry_idx[4:0];
                                fpu_rs_dest[free_fp_found] = rob_phys_dest[entry_idx];
                                map_src = rat[rs0];
                                fpu_rs_s0_tag[free_fp_found] = map_src;
                                fpu_rs_s0_ready[free_fp_found] = phys_ready[map_src];
                                fpu_rs_s0_val[free_fp_found] = phys_value[map_src];
                                map_src = rat[rt0];
                                fpu_rs_s1_tag[free_fp_found] = map_src;
                                fpu_rs_s1_ready[free_fp_found] = phys_ready[map_src];
                                fpu_rs_s1_val[free_fp_found] = phys_value[map_src];
                            end

                            if (uses_lsq(op0)) begin
                                lsq_valid[entry_idx] = 1'b1;
                                lsq_issued[entry_idx] = 1'b0;
                                lsq_op[entry_idx] = op0;
                                lsq_has_dest[entry_idx] = writes_dest(op0);
                                lsq_dest[entry_idx] = rob_phys_dest[entry_idx];
                                lsq_imm[entry_idx] = imm0;
                                lsq_pc[entry_idx] = pc0;
                                if (op0 == OP_MOV_ML) begin
                                    map_src = rat[rs0];
                                    lsq_addr_tag[entry_idx] = map_src;
                                    lsq_addr_ready[entry_idx] = phys_ready[map_src];
                                    lsq_addr_val[entry_idx] = phys_value[map_src];
                                    lsq_data_ready[entry_idx] = 1'b0;
                                end else if (op0 == OP_MOV_SM) begin
                                    map_src = rat[rd0];
                                    lsq_addr_tag[entry_idx] = map_src;
                                    lsq_addr_ready[entry_idx] = phys_ready[map_src];
                                    lsq_addr_val[entry_idx] = phys_value[map_src];
                                    map_src = rat[rs0];
                                    lsq_data_tag[entry_idx] = map_src;
                                    lsq_data_ready[entry_idx] = phys_ready[map_src];
                                    lsq_data_val[entry_idx] = phys_value[map_src];
                                end else if (op0 == OP_CALL) begin
                                    map_src = rat[31];
                                    lsq_addr_tag[entry_idx] = map_src;
                                    lsq_addr_ready[entry_idx] = phys_ready[map_src];
                                    lsq_addr_val[entry_idx] = phys_value[map_src];
                                    lsq_data_ready[entry_idx] = 1'b1;
                                    lsq_data_val[entry_idx] = pc0 + 4;
                                end else if (op0 == OP_RET) begin
                                    map_src = rat[31];
                                    lsq_addr_tag[entry_idx] = map_src;
                                    lsq_addr_ready[entry_idx] = phys_ready[map_src];
                                    lsq_addr_val[entry_idx] = phys_value[map_src];
                                    lsq_data_ready[entry_idx] = 1'b0;
                                end
                            end

                            rob_tail = (rob_tail + 1) % ROB_SIZE;
                            rob_count = rob_count + 1;
                            fetch_pc = fetch_pc + 4;
                            if (is_control_op(op0)) control_stall = 1'b1;

                            if (!control_stall && word_idx0 != 4'd15 && !is_control_op(op0) && (rob_count < ROB_SIZE)) begin
                                inst1 = fetch_words[word_idx1];
                                op1 = inst1[31:27];
                                rd1 = inst1[26:22];
                                rs1 = inst1[21:17];
                                rt1 = inst1[16:12];
                                imm1 = inst1[11:0];
                                pc1 = pc0 + 4;

                                free_rs_found = -1;
                                free_fp_found = -1;
                                if (uses_alu_rs(op1)) begin
                                    for (i = 0; i < ALU_RS_SIZE; i = i + 1) begin
                                        if (!alu_rs_valid[i] && free_rs_found == -1) free_rs_found = i;
                                    end
                                end
                                if (is_fpu_op(op1)) begin
                                    for (i = 0; i < FPU_RS_SIZE; i = i + 1) begin
                                        if (!fpu_rs_valid[i] && free_fp_found == -1) free_fp_found = i;
                                    end
                                end

                                if ((!writes_dest(op1) || (free_count > 0)) &&
                                    (!uses_alu_rs(op1) || (free_rs_found != -1)) &&
                                    (!is_fpu_op(op1) || (free_fp_found != -1))) begin
                                    entry_idx = rob_tail;
                                    rob_valid[entry_idx] = 1'b1;
                                    rob_ready[entry_idx] = (op1 == OP_PRIV);
                                    rob_branch_done[entry_idx] = 1'b0;
                                    rob_store_done[entry_idx] = 1'b0;
                                    rob_has_dest[entry_idx] = writes_dest(op1);
                                    rob_arch_dest[entry_idx] = rd1;
                                    rob_op[entry_idx] = op1;
                                    rob_pc[entry_idx] = pc1;
                                    rob_value[entry_idx] = 64'b0;
                                    rob_target[entry_idx] = 64'b0;
                                    rob_taken[entry_idx] = 1'b0;

                                    if (writes_dest(op1)) begin
                                        new_phys1 = free_list[free_head];
                                        free_head = (free_head + 1) % FREE_REGS;
                                        free_count = free_count - 1;
                                        old_phys1 = (writes_dest(op0) && (rd1 == rd0)) ? rob_phys_dest[rob_tail == 0 ? ROB_SIZE - 1 : rob_tail - 1] : rat[rd1];
                                        rob_phys_dest[entry_idx] = new_phys1;
                                        rob_old_phys[entry_idx] = old_phys1;
                                        rat[rd1] = new_phys1;
                                        phys_ready[new_phys1] = 1'b0;
                                        phys_value[new_phys1] = 64'b0;
                                    end else begin
                                        rob_phys_dest[entry_idx] = 6'b0;
                                        rob_old_phys[entry_idx] = 6'b0;
                                    end

                                    if (uses_alu_rs(op1)) begin
                                        alu_rs_valid[free_rs_found] = 1'b1;
                                        alu_rs_op[free_rs_found] = op1;
                                        alu_rs_rob[free_rs_found] = entry_idx[4:0];
                                        alu_rs_has_dest[free_rs_found] = writes_dest(op1);
                                        alu_rs_dest[free_rs_found] = rob_phys_dest[entry_idx];
                                        alu_rs_imm[free_rs_found] = imm1;
                                        alu_rs_pc[free_rs_found] = pc1;
                                        alu_rs_s0_ready[free_rs_found] = 1'b0;
                                        alu_rs_s1_ready[free_rs_found] = 1'b0;
                                        alu_rs_s2_ready[free_rs_found] = 1'b0;

                                        case (op1)
                                            OP_ADDI, OP_SUBI, OP_SHFTRI, OP_SHFTLI, OP_MOV_L: begin
                                                map_src1 = rob_old_phys[entry_idx];
                                                alu_rs_s0_tag[free_rs_found] = map_src1;
                                                alu_rs_s0_ready[free_rs_found] = phys_ready[map_src1];
                                                alu_rs_s0_val[free_rs_found] = phys_value[map_src1];
                                                alu_rs_s1_ready[free_rs_found] = 1'b1;
                                                alu_rs_s1_val[free_rs_found] = imm_operand(op1, imm1);
                                            end
                                            OP_MOV_RR, OP_NOT: begin
                                                map_src1 = (writes_dest(op0) && (rs1 == rd0)) ? rob_phys_dest[rob_tail == 0 ? ROB_SIZE - 1 : rob_tail - 1] : rat[rs1];
                                                alu_rs_s0_tag[free_rs_found] = map_src1;
                                                alu_rs_s0_ready[free_rs_found] = phys_ready[map_src1];
                                                alu_rs_s0_val[free_rs_found] = phys_value[map_src1];
                                                alu_rs_s1_ready[free_rs_found] = 1'b1;
                                                alu_rs_s1_val[free_rs_found] = 64'b0;
                                            end
                                            OP_BR, OP_BRR_R, OP_CALL: begin
                                                map_src1 = (writes_dest(op0) && (rd1 == rd0)) ? rob_phys_dest[rob_tail == 0 ? ROB_SIZE - 1 : rob_tail - 1] : rat[rd1];
                                                alu_rs_s0_tag[free_rs_found] = map_src1;
                                                alu_rs_s0_ready[free_rs_found] = phys_ready[map_src1];
                                                alu_rs_s0_val[free_rs_found] = phys_value[map_src1];
                                            end
                                            OP_BRR_L: begin
                                                alu_rs_s0_ready[free_rs_found] = 1'b1;
                                                alu_rs_s0_val[free_rs_found] = 64'b0;
                                            end
                                            OP_BRNZ: begin
                                                map_src1 = (writes_dest(op0) && (rd1 == rd0)) ? rob_phys_dest[rob_tail == 0 ? ROB_SIZE - 1 : rob_tail - 1] : rat[rd1];
                                                alu_rs_s0_tag[free_rs_found] = map_src1;
                                                alu_rs_s0_ready[free_rs_found] = phys_ready[map_src1];
                                                alu_rs_s0_val[free_rs_found] = phys_value[map_src1];
                                                map_src1 = (writes_dest(op0) && (rs1 == rd0)) ? rob_phys_dest[rob_tail == 0 ? ROB_SIZE - 1 : rob_tail - 1] : rat[rs1];
                                                alu_rs_s1_tag[free_rs_found] = map_src1;
                                                alu_rs_s1_ready[free_rs_found] = phys_ready[map_src1];
                                                alu_rs_s1_val[free_rs_found] = phys_value[map_src1];
                                            end
                                            OP_BRGT: begin
                                                map_src1 = (writes_dest(op0) && (rd1 == rd0)) ? rob_phys_dest[rob_tail == 0 ? ROB_SIZE - 1 : rob_tail - 1] : rat[rd1];
                                                alu_rs_s0_tag[free_rs_found] = map_src1;
                                                alu_rs_s0_ready[free_rs_found] = phys_ready[map_src1];
                                                alu_rs_s0_val[free_rs_found] = phys_value[map_src1];
                                                map_src1 = (writes_dest(op0) && (rs1 == rd0)) ? rob_phys_dest[rob_tail == 0 ? ROB_SIZE - 1 : rob_tail - 1] : rat[rs1];
                                                alu_rs_s1_tag[free_rs_found] = map_src1;
                                                alu_rs_s1_ready[free_rs_found] = phys_ready[map_src1];
                                                alu_rs_s1_val[free_rs_found] = phys_value[map_src1];
                                                map_src1 = (writes_dest(op0) && (rt1 == rd0)) ? rob_phys_dest[rob_tail == 0 ? ROB_SIZE - 1 : rob_tail - 1] : rat[rt1];
                                                alu_rs_s2_tag[free_rs_found] = map_src1;
                                                alu_rs_s2_ready[free_rs_found] = phys_ready[map_src1];
                                                alu_rs_s2_val[free_rs_found] = phys_value[map_src1];
                                            end
                                            default: begin
                                                map_src1 = (writes_dest(op0) && (rs1 == rd0)) ? rob_phys_dest[rob_tail == 0 ? ROB_SIZE - 1 : rob_tail - 1] : rat[rs1];
                                                alu_rs_s0_tag[free_rs_found] = map_src1;
                                                alu_rs_s0_ready[free_rs_found] = phys_ready[map_src1];
                                                alu_rs_s0_val[free_rs_found] = phys_value[map_src1];
                                                map_src1 = (writes_dest(op0) && (rt1 == rd0)) ? rob_phys_dest[rob_tail == 0 ? ROB_SIZE - 1 : rob_tail - 1] : rat[rt1];
                                                alu_rs_s1_tag[free_rs_found] = map_src1;
                                                alu_rs_s1_ready[free_rs_found] = phys_ready[map_src1];
                                                alu_rs_s1_val[free_rs_found] = phys_value[map_src1];
                                            end
                                        endcase
                                    end else if (is_fpu_op(op1)) begin
                                        fpu_rs_valid[free_fp_found] = 1'b1;
                                        fpu_rs_op[free_fp_found] = op1;
                                        fpu_rs_rob[free_fp_found] = entry_idx[4:0];
                                        fpu_rs_dest[free_fp_found] = rob_phys_dest[entry_idx];
                                        map_src1 = (writes_dest(op0) && (rs1 == rd0)) ? rob_phys_dest[rob_tail == 0 ? ROB_SIZE - 1 : rob_tail - 1] : rat[rs1];
                                        fpu_rs_s0_tag[free_fp_found] = map_src1;
                                        fpu_rs_s0_ready[free_fp_found] = phys_ready[map_src1];
                                        fpu_rs_s0_val[free_fp_found] = phys_value[map_src1];
                                        map_src1 = (writes_dest(op0) && (rt1 == rd0)) ? rob_phys_dest[rob_tail == 0 ? ROB_SIZE - 1 : rob_tail - 1] : rat[rt1];
                                        fpu_rs_s1_tag[free_fp_found] = map_src1;
                                        fpu_rs_s1_ready[free_fp_found] = phys_ready[map_src1];
                                        fpu_rs_s1_val[free_fp_found] = phys_value[map_src1];
                                    end

                                    if (uses_lsq(op1)) begin
                                        lsq_valid[entry_idx] = 1'b1;
                                        lsq_issued[entry_idx] = 1'b0;
                                        lsq_op[entry_idx] = op1;
                                        lsq_has_dest[entry_idx] = writes_dest(op1);
                                        lsq_dest[entry_idx] = rob_phys_dest[entry_idx];
                                        lsq_imm[entry_idx] = imm1;
                                        lsq_pc[entry_idx] = pc1;
                                        if (op1 == OP_MOV_ML) begin
                                            map_src1 = (writes_dest(op0) && (rs1 == rd0)) ? rob_phys_dest[rob_tail == 0 ? ROB_SIZE - 1 : rob_tail - 1] : rat[rs1];
                                            lsq_addr_tag[entry_idx] = map_src1;
                                            lsq_addr_ready[entry_idx] = phys_ready[map_src1];
                                            lsq_addr_val[entry_idx] = phys_value[map_src1];
                                            lsq_data_ready[entry_idx] = 1'b0;
                                        end else if (op1 == OP_MOV_SM) begin
                                            map_src1 = (writes_dest(op0) && (rd1 == rd0)) ? rob_phys_dest[rob_tail == 0 ? ROB_SIZE - 1 : rob_tail - 1] : rat[rd1];
                                            lsq_addr_tag[entry_idx] = map_src1;
                                            lsq_addr_ready[entry_idx] = phys_ready[map_src1];
                                            lsq_addr_val[entry_idx] = phys_value[map_src1];
                                            map_src1 = (writes_dest(op0) && (rs1 == rd0)) ? rob_phys_dest[rob_tail == 0 ? ROB_SIZE - 1 : rob_tail - 1] : rat[rs1];
                                            lsq_data_tag[entry_idx] = map_src1;
                                            lsq_data_ready[entry_idx] = phys_ready[map_src1];
                                            lsq_data_val[entry_idx] = phys_value[map_src1];
                                        end else if (op1 == OP_CALL) begin
                                            map_src1 = rat[31];
                                            lsq_addr_tag[entry_idx] = map_src1;
                                            lsq_addr_ready[entry_idx] = phys_ready[map_src1];
                                            lsq_addr_val[entry_idx] = phys_value[map_src1];
                                            lsq_data_ready[entry_idx] = 1'b1;
                                            lsq_data_val[entry_idx] = pc1 + 4;
                                        end else if (op1 == OP_RET) begin
                                            map_src1 = rat[31];
                                            lsq_addr_tag[entry_idx] = map_src1;
                                            lsq_addr_ready[entry_idx] = phys_ready[map_src1];
                                            lsq_addr_val[entry_idx] = phys_value[map_src1];
                                            lsq_data_ready[entry_idx] = 1'b0;
                                        end
                                    end

                                    rob_tail = (rob_tail + 1) % ROB_SIZE;
                                    rob_count = rob_count + 1;
                                    fetch_pc = fetch_pc + 4;
                                    if (is_control_op(op1)) control_stall = 1'b1;
                                end
                            end
                        end
                    end
                end
            end
        end
    end
endmodule
