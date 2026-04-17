`include "hdl/instruction_decoder.sv"
`include "hdl/register_file.sv"
`include "hdl/ALU.sv"
`include "hdl/FPU.sv"
`include "hdl/memory.sv"
`include "hdl/branch_predictor.sv"
`include "hdl/alu_reservation_station.sv"
`include "hdl/fpu_reservation_station.sv"
`include "hdl/load_store_queue.sv"

module tinker_core (
    input clk,
    input reset,
    output logic hlt
);
    localparam ROB_SIZE = 32;
    localparam ALU_RS_SIZE = 8;
    localparam FPU_RS_SIZE = 8;
    localparam PHYS_REGS = 96;
    localparam FREE_REGS = 64;

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

    function has_commit_mem_side_effect;
        input [4:0] op;
        begin
            has_commit_mem_side_effect = (op == OP_MOV_SM) || (op == OP_CALL);
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

    function [63:0] int_result_estimate;
        input [4:0] op;
        input [63:0] a;
        input [63:0] b;
        begin
            case (op)
                OP_AND: int_result_estimate = a & b;
                OP_OR: int_result_estimate = a | b;
                OP_XOR: int_result_estimate = a ^ b;
                OP_NOT: int_result_estimate = ~a;
                OP_SHFTR, OP_SHFTRI: int_result_estimate = a >> b[5:0];
                OP_SHFTL, OP_SHFTLI: int_result_estimate = a << b[5:0];
                OP_MOV_RR: int_result_estimate = a;
                OP_MOV_L: int_result_estimate = {a[63:12], b[11:0]};
                OP_ADD, OP_ADDI: int_result_estimate = a + b;
                OP_SUB, OP_SUBI: int_result_estimate = a - b;
                OP_MUL: int_result_estimate = a * b;
                OP_DIV: int_result_estimate = (b == 0) ? 64'b0 : (a / b);
                default: int_result_estimate = 64'b0;
            endcase
        end
    endfunction

    reg [63:0] fetch_pc;
    reg [63:0] fetch_line_base;
    reg fetch_line_valid;
    reg [31:0] fetch_words [0:15];
    reg control_stall;

    reg [6:0] rat [0:31];
    reg [63:0] phys_value [0:PHYS_REGS - 1];
    reg phys_ready [0:PHYS_REGS - 1];
    reg [6:0] free_list [0:FREE_REGS - 1];
    integer free_head;
    integer free_tail;
    integer free_count;
    reg [63:0] ret_stack [0:15];
    integer ret_sp;

    reg rob_valid [0:ROB_SIZE - 1];
    reg rob_ready [0:ROB_SIZE - 1];
    reg rob_branch_done [0:ROB_SIZE - 1];
    reg rob_store_done [0:ROB_SIZE - 1];
    reg rob_has_dest [0:ROB_SIZE - 1];
    reg [4:0] rob_arch_dest [0:ROB_SIZE - 1];
    reg [6:0] rob_phys_dest [0:ROB_SIZE - 1];
    reg [6:0] rob_old_phys [0:ROB_SIZE - 1];
    reg [4:0] rob_op [0:ROB_SIZE - 1];
    reg [63:0] rob_pc [0:ROB_SIZE - 1];
    reg [63:0] rob_value [0:ROB_SIZE - 1];
    reg [63:0] rob_target [0:ROB_SIZE - 1];
    reg rob_taken [0:ROB_SIZE - 1];
    reg rob_pred_taken [0:ROB_SIZE - 1];
    reg [63:0] rob_pred_target [0:ROB_SIZE - 1];
    integer rob_head;
    integer rob_tail;
    integer rob_count;
    reg speculative_valid;
    reg [4:0] speculative_rob;
    reg [6:0] checkpoint_rat [0:31];
    integer checkpoint_ret_sp;
    reg flush_en;
    reg [4:0] flush_rob;
    reg [4:0] flush_tail;

    reg alu_dispatch0_valid;
    reg [4:0] alu_dispatch0_op;
    reg [4:0] alu_dispatch0_rob;
    reg alu_dispatch0_has_dest;
    reg [6:0] alu_dispatch0_dest;
    reg alu_dispatch0_s0_ready;
    reg [6:0] alu_dispatch0_s0_tag;
    reg [63:0] alu_dispatch0_s0_val;
    reg alu_dispatch0_s1_ready;
    reg [6:0] alu_dispatch0_s1_tag;
    reg [63:0] alu_dispatch0_s1_val;
    reg alu_dispatch0_s2_ready;
    reg [6:0] alu_dispatch0_s2_tag;
    reg [63:0] alu_dispatch0_s2_val;
    reg [11:0] alu_dispatch0_imm;
    reg [63:0] alu_dispatch0_pc;
    reg alu_dispatch1_valid;
    reg [4:0] alu_dispatch1_op;
    reg [4:0] alu_dispatch1_rob;
    reg alu_dispatch1_has_dest;
    reg [6:0] alu_dispatch1_dest;
    reg alu_dispatch1_s0_ready;
    reg [6:0] alu_dispatch1_s0_tag;
    reg [63:0] alu_dispatch1_s0_val;
    reg alu_dispatch1_s1_ready;
    reg [6:0] alu_dispatch1_s1_tag;
    reg [63:0] alu_dispatch1_s1_val;
    reg alu_dispatch1_s2_ready;
    reg [6:0] alu_dispatch1_s2_tag;
    reg [63:0] alu_dispatch1_s2_val;
    reg [11:0] alu_dispatch1_imm;
    reg [63:0] alu_dispatch1_pc;

    reg fpu_dispatch0_valid;
    reg [4:0] fpu_dispatch0_op;
    reg [4:0] fpu_dispatch0_rob;
    reg [6:0] fpu_dispatch0_dest;
    reg fpu_dispatch0_s0_ready;
    reg [6:0] fpu_dispatch0_s0_tag;
    reg [63:0] fpu_dispatch0_s0_val;
    reg fpu_dispatch0_s1_ready;
    reg [6:0] fpu_dispatch0_s1_tag;
    reg [63:0] fpu_dispatch0_s1_val;
    reg fpu_dispatch1_valid;
    reg [4:0] fpu_dispatch1_op;
    reg [4:0] fpu_dispatch1_rob;
    reg [6:0] fpu_dispatch1_dest;
    reg fpu_dispatch1_s0_ready;
    reg [6:0] fpu_dispatch1_s0_tag;
    reg [63:0] fpu_dispatch1_s0_val;
    reg fpu_dispatch1_s1_ready;
    reg [6:0] fpu_dispatch1_s1_tag;
    reg [63:0] fpu_dispatch1_s1_val;

    reg lsq_dispatch0_valid;
    reg [4:0] lsq_dispatch0_rob;
    reg [4:0] lsq_dispatch0_op;
    reg lsq_dispatch0_has_dest;
    reg [6:0] lsq_dispatch0_dest;
    reg lsq_dispatch0_addr_ready;
    reg [6:0] lsq_dispatch0_addr_tag;
    reg [63:0] lsq_dispatch0_addr_val;
    reg lsq_dispatch0_data_ready;
    reg [6:0] lsq_dispatch0_data_tag;
    reg [63:0] lsq_dispatch0_data_val;
    reg [11:0] lsq_dispatch0_imm;
    reg [63:0] lsq_dispatch0_pc;
    reg lsq_dispatch1_valid;
    reg [4:0] lsq_dispatch1_rob;
    reg [4:0] lsq_dispatch1_op;
    reg lsq_dispatch1_has_dest;
    reg [6:0] lsq_dispatch1_dest;
    reg lsq_dispatch1_addr_ready;
    reg [6:0] lsq_dispatch1_addr_tag;
    reg [63:0] lsq_dispatch1_addr_val;
    reg lsq_dispatch1_data_ready;
    reg [6:0] lsq_dispatch1_data_tag;
    reg [63:0] lsq_dispatch1_data_val;
    reg [11:0] lsq_dispatch1_imm;
    reg [63:0] lsq_dispatch1_pc;

    reg alu0_s0_valid;
    reg alu0_s1_valid;
    reg [4:0] alu0_s0_op;
    reg [4:0] alu0_s0_rob;
    reg alu0_s0_has_dest;
    reg [6:0] alu0_s0_dest;
    reg [63:0] alu0_s0_a;
    reg [63:0] alu0_s0_b;
    reg [63:0] alu0_s0_c;
    reg [11:0] alu0_s0_imm;
    reg [63:0] alu0_s0_pc;
    reg [4:0] alu0_s1_rob;
    reg alu0_s1_has_dest;
    reg [6:0] alu0_s1_dest;
    reg [63:0] alu0_s1_res;
    reg alu0_s1_branch_valid;
    reg alu0_s1_taken;
    reg [63:0] alu0_s1_target;

    reg alu1_s0_valid;
    reg alu1_s1_valid;
    reg [4:0] alu1_s0_op;
    reg [4:0] alu1_s0_rob;
    reg alu1_s0_has_dest;
    reg [6:0] alu1_s0_dest;
    reg [63:0] alu1_s0_a;
    reg [63:0] alu1_s0_b;
    reg [63:0] alu1_s0_c;
    reg [11:0] alu1_s0_imm;
    reg [63:0] alu1_s0_pc;
    reg [4:0] alu1_s1_rob;
    reg alu1_s1_has_dest;
    reg [6:0] alu1_s1_dest;
    reg [63:0] alu1_s1_res;
    reg alu1_s1_branch_valid;
    reg alu1_s1_taken;
    reg [63:0] alu1_s1_target;

    reg fpu0_valid [0:4];
    reg [4:0] fpu0_op [0:4];
    reg [4:0] fpu0_rob [0:4];
    reg [6:0] fpu0_dest [0:4];
    reg [63:0] fpu0_a [0:4];
    reg [63:0] fpu0_b [0:4];
    reg [63:0] fpu0_res [0:4];

    reg fpu1_valid [0:4];
    reg [4:0] fpu1_op [0:4];
    reg [4:0] fpu1_rob [0:4];
    reg [6:0] fpu1_dest [0:4];
    reg [63:0] fpu1_a [0:4];
    reg [63:0] fpu1_b [0:4];
    reg [63:0] fpu1_res [0:4];

    reg ls0_s0_valid;
    reg ls0_s1_valid;
    reg [4:0] ls0_s0_op;
    reg [4:0] ls0_s0_rob;
    reg ls0_s0_has_dest;
    reg [6:0] ls0_s0_dest;
    reg [63:0] ls0_s0_addr;
    reg [63:0] ls0_s0_forward_data;
    reg ls0_s0_forward_hit;
    reg [4:0] ls0_s1_rob;
    reg ls0_s1_has_dest;
    reg [6:0] ls0_s1_dest;
    reg [63:0] ls0_s1_res;
    reg ls0_s1_is_ret;

    reg ls1_s0_valid;
    reg ls1_s1_valid;
    reg [4:0] ls1_s0_op;
    reg [4:0] ls1_s0_rob;
    reg ls1_s0_has_dest;
    reg [6:0] ls1_s0_dest;
    reg [63:0] ls1_s0_addr;
    reg [63:0] ls1_s0_forward_data;
    reg ls1_s0_forward_hit;
    reg [4:0] ls1_s1_rob;
    reg ls1_s1_has_dest;
    reg [6:0] ls1_s1_dest;
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
    wire bp_predict_taken1;
    wire [63:0] bp_predict_target1;
    wire [95:0] phys_ready_bus;
    wire [6143:0] phys_value_bus;
    wire [3:0] alu_rs_free_count;
    wire [3:0] fpu_rs_free_count;
    wire alu_issue_valid0;
    wire [4:0] alu_issue_op0;
    wire [4:0] alu_issue_rob0;
    wire alu_issue_has_dest0;
    wire [6:0] alu_issue_dest0;
    wire [63:0] alu_issue_s0_val0;
    wire [63:0] alu_issue_s1_val0;
    wire [63:0] alu_issue_s2_val0;
    wire [11:0] alu_issue_imm0;
    wire [63:0] alu_issue_pc0;
    wire [2:0] alu_issue_idx0;
    wire alu_issue_valid1;
    wire [4:0] alu_issue_op1;
    wire [4:0] alu_issue_rob1;
    wire alu_issue_has_dest1;
    wire [6:0] alu_issue_dest1;
    wire [63:0] alu_issue_s0_val1;
    wire [63:0] alu_issue_s1_val1;
    wire [63:0] alu_issue_s2_val1;
    wire [11:0] alu_issue_imm1;
    wire [63:0] alu_issue_pc1;
    wire [2:0] alu_issue_idx1;
    wire fpu_issue_valid0;
    wire [4:0] fpu_issue_op0;
    wire [4:0] fpu_issue_rob0;
    wire [6:0] fpu_issue_dest0;
    wire [63:0] fpu_issue_s0_val0;
    wire [63:0] fpu_issue_s1_val0;
    wire [2:0] fpu_issue_idx0;
    wire fpu_issue_valid1;
    wire [4:0] fpu_issue_op1;
    wire [4:0] fpu_issue_rob1;
    wire [6:0] fpu_issue_dest1;
    wire [63:0] fpu_issue_s0_val1;
    wire [63:0] fpu_issue_s1_val1;
    wire [2:0] fpu_issue_idx1;
    reg fpu_issue_take0;
    reg [2:0] fpu_issue_take_idx0;
    reg fpu_issue_take1;
    reg [2:0] fpu_issue_take_idx1;
    wire [ROB_SIZE - 1:0] lsq_store_ready_bus;
    wire lsq_issue_valid0;
    wire [4:0] lsq_issue_rob0;
    wire [4:0] lsq_issue_op0;
    wire lsq_issue_has_dest0;
    wire [6:0] lsq_issue_dest0;
    wire [63:0] lsq_issue_addr0;
    wire lsq_issue_forward_hit0;
    wire [63:0] lsq_issue_forward_data0;
    wire [4:0] lsq_issue_idx0;
    wire lsq_issue_valid1;
    wire [4:0] lsq_issue_rob1;
    wire [4:0] lsq_issue_op1;
    wire lsq_issue_has_dest1;
    wire [6:0] lsq_issue_dest1;
    wire [63:0] lsq_issue_addr1;
    wire lsq_issue_forward_hit1;
    wire [63:0] lsq_issue_forward_data1;
    wire [4:0] lsq_issue_idx1;
    wire [63:0] lsq_commit_addr;
    wire [63:0] lsq_commit_data;
    wire cdb0_en;
    wire [6:0] cdb0_tag;
    wire [63:0] cdb0_val;
    wire cdb1_en;
    wire [6:0] cdb1_tag;
    wire [63:0] cdb1_val;
    wire cdb2_en;
    wire [6:0] cdb2_tag;
    wire [63:0] cdb2_val;
    wire cdb3_en;
    wire [6:0] cdb3_tag;
    wire [63:0] cdb3_val;
    wire cdb4_en;
    wire [6:0] cdb4_tag;
    wire [63:0] cdb4_val;
    wire cdb5_en;
    wire [6:0] cdb5_tag;
    wire [63:0] cdb5_val;
    reg lsq_clear_en;
    reg [4:0] lsq_clear_idx;
    reg lsq_clear_en2;
    reg [4:0] lsq_clear_idx2;
    reg [4:0] lsq_commit_idx;

    reg arch_write_enable;
    reg [4:0] arch_write_rd;
    reg [63:0] arch_write_data;
    reg arch_write_enable2;
    reg [4:0] arch_write_rd2;
    reg [63:0] arch_write_data2;
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
    integer debug_rs_idx;
    integer idx;
    integer entry_idx;
    integer free_rs_slots;
    integer free_fp_slots;
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
    reg [6:0] new_phys;
    reg [6:0] new_phys1;
    reg [6:0] old_phys1;
    reg [6:0] map_src;
    reg [6:0] map_src1;
    reg op0_forward_valid;
    reg [63:0] op0_forward_value;
    reg [3:0] word_idx0;
    reg [3:0] word_idx1;
    wire [63:0] pc;
    wire decode_valid;
    wire [31:0] IR;
    reg int_rs_valid [0:7];
    reg [4:0] int_rs_opcode [0:7];
    wire fpu_pipe_valid [0:4];
    wire [4:0] fpu_pipe_opcode [0:4];
    wire fpu2_pipe_valid [0:4];
    wire [4:0] fpu2_pipe_opcode [0:4];
    reg decode_valid_dbg;
    reg [31:0] ir_dbg;
    reg exec_valid;
    reg [4:0] exec_opcode;
    reg exec2_valid;
    reg [4:0] exec2_opcode;
    reg mem_valid;
    reg [4:0] mem_opcode;
    reg store_forward_hit;
    reg fast_exec_valid_dbg;
    reg [4:0] fast_exec_opcode_dbg;
    reg fast_mem_valid_dbg;
    reg [4:0] fast_mem_opcode_dbg;
    reg fast_store_forward_dbg;
    integer exec_sel;
    reg branch_start_spec;
    reg [4:0] branch_spec_rob;
    reg branch_spec_taken;
    reg [63:0] branch_spec_target;
    reg branch_fast_resolve0;
    reg branch_fast_taken0;
    reg [63:0] branch_fast_target0;
    reg branch_fast_skip0;
    reg branch_fast_resolve1;
    reg branch_fast_taken1;
    reg [63:0] branch_fast_target1;
    reg branch_fast_skip1;
    reg allow_issue_lane1;
    integer flush_count;
    integer tail_snapshot;

    assign pc = fetch_pc;
    assign decode_valid = decode_valid_dbg;
    assign IR = ir_dbg;
    always @(*) begin
        exec_valid = 1'b0;
        exec_opcode = 5'b0;
        exec2_valid = 1'b0;
        exec2_opcode = 5'b0;
        exec_sel = 0;

        if (ls0_s0_valid) begin
            exec_valid = 1'b1;
            exec_opcode = ls0_s0_op;
            exec_sel = 1;
        end else if (alu0_s0_valid) begin
            exec_valid = 1'b1;
            exec_opcode = alu0_s0_op;
            exec_sel = 2;
        end else if (fpu0_valid[0]) begin
            exec_valid = 1'b1;
            exec_opcode = fpu0_op[0];
            exec_sel = 3;
        end else if (ls1_s0_valid) begin
            exec_valid = 1'b1;
            exec_opcode = ls1_s0_op;
            exec_sel = 4;
        end else if (alu1_s0_valid) begin
            exec_valid = 1'b1;
            exec_opcode = alu1_s0_op;
            exec_sel = 5;
        end else if (fpu1_valid[0]) begin
            exec_valid = 1'b1;
            exec_opcode = fpu1_op[0];
            exec_sel = 6;
        end

        if (exec_valid) begin
            if ((exec_sel != 1) && ls0_s0_valid) begin
                exec2_valid = 1'b1;
                exec2_opcode = ls0_s0_op;
            end else if ((exec_sel != 2) && alu0_s0_valid) begin
                exec2_valid = 1'b1;
                exec2_opcode = alu0_s0_op;
            end else if ((exec_sel != 3) && fpu0_valid[0]) begin
                exec2_valid = 1'b1;
                exec2_opcode = fpu0_op[0];
            end else if ((exec_sel != 4) && ls1_s0_valid) begin
                exec2_valid = 1'b1;
                exec2_opcode = ls1_s0_op;
            end else if ((exec_sel != 5) && alu1_s0_valid) begin
                exec2_valid = 1'b1;
                exec2_opcode = alu1_s0_op;
            end else if ((exec_sel != 6) && fpu1_valid[0]) begin
                exec2_valid = 1'b1;
                exec2_opcode = fpu1_op[0];
            end
        end

        if (fast_exec_valid_dbg) begin
            exec_valid = 1'b1;
            exec_opcode = fast_exec_opcode_dbg;
        end

        mem_valid = ls0_s1_valid || ls1_s1_valid || fast_mem_valid_dbg;
        mem_opcode = ls0_s1_valid ? rob_op[ls0_s1_rob] :
            (ls1_s1_valid ? rob_op[ls1_s1_rob] :
            (fast_mem_valid_dbg ? fast_mem_opcode_dbg : 5'b0));
        store_forward_hit = (ls0_s1_valid && ls0_s0_forward_hit) ||
            (ls1_s1_valid && ls1_s0_forward_hit) || fast_store_forward_dbg;
    end

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
        .data2(arch_write_data2),
        .rd2(arch_write_rd2),
        .write_enable2(arch_write_enable2),
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
        .lookup_pc2(fetch_pc + 64'd4),
        .predict_taken2(bp_predict_taken1),
        .predict_target2(bp_predict_target1),
        .update_en(bp_update_en),
        .update_pc(bp_update_pc),
        .update_taken(bp_update_taken),
        .update_target(bp_update_target)
    );

    assign cdb0_en = alu0_s1_valid && alu0_s1_has_dest;
    assign cdb0_tag = alu0_s1_dest;
    assign cdb0_val = alu0_s1_res;
    assign cdb1_en = alu1_s1_valid && alu1_s1_has_dest;
    assign cdb1_tag = alu1_s1_dest;
    assign cdb1_val = alu1_s1_res;
    assign cdb2_en = fpu0_valid[4];
    assign cdb2_tag = fpu0_dest[4];
    assign cdb2_val = fpu0_res[4];
    assign cdb3_en = fpu1_valid[4];
    assign cdb3_tag = fpu1_dest[4];
    assign cdb3_val = fpu1_res[4];
    assign cdb4_en = ls0_s1_valid && ls0_s1_has_dest;
    assign cdb4_tag = ls0_s1_dest;
    assign cdb4_val = ls0_s1_res;
    assign cdb5_en = ls1_s1_valid && ls1_s1_has_dest;
    assign cdb5_tag = ls1_s1_dest;
    assign cdb5_val = ls1_s1_res;
    genvar g;
    generate
        for (g = 0; g < PHYS_REGS; g = g + 1) begin : phys_bus_pack
            assign phys_ready_bus[g] = phys_ready[g];
            assign phys_value_bus[(g * 64) +: 64] = phys_value[g];
        end
        for (g = 0; g < 5; g = g + 1) begin : fpu_debug_pack
            assign fpu_pipe_valid[g] = fpu0_valid[g];
            assign fpu_pipe_opcode[g] = fpu0_op[g];
            assign fpu2_pipe_valid[g] = fpu1_valid[g];
            assign fpu2_pipe_opcode[g] = fpu1_op[g];
        end
    endgenerate

    always @(*) begin
        for (debug_rs_idx = 0; debug_rs_idx < 8; debug_rs_idx = debug_rs_idx + 1) begin
            int_rs_valid[debug_rs_idx] = 1'b0;
            int_rs_opcode[debug_rs_idx] = 5'b0;
        end
        debug_rs_idx = 0;
        for (i = 0; i < 8; i = i + 1) begin
            if (alu_rs.valid[i] && (debug_rs_idx < 8)) begin
                int_rs_valid[debug_rs_idx] = 1'b1;
                int_rs_opcode[debug_rs_idx] = alu_rs.op[i];
                debug_rs_idx = debug_rs_idx + 1;
            end
        end
    end

    alu_reservation_station alu_rs (
        .clk(~clk),
        .reset(reset),
        .live_ready(phys_ready_bus),
        .live_values(phys_value_bus),
        .dispatch0_valid(alu_dispatch0_valid),
        .dispatch0_op(alu_dispatch0_op),
        .dispatch0_rob(alu_dispatch0_rob),
        .dispatch0_has_dest(alu_dispatch0_has_dest),
        .dispatch0_dest(alu_dispatch0_dest),
        .dispatch0_s0_ready(alu_dispatch0_s0_ready),
        .dispatch0_s0_tag(alu_dispatch0_s0_tag),
        .dispatch0_s0_val(alu_dispatch0_s0_val),
        .dispatch0_s1_ready(alu_dispatch0_s1_ready),
        .dispatch0_s1_tag(alu_dispatch0_s1_tag),
        .dispatch0_s1_val(alu_dispatch0_s1_val),
        .dispatch0_s2_ready(alu_dispatch0_s2_ready),
        .dispatch0_s2_tag(alu_dispatch0_s2_tag),
        .dispatch0_s2_val(alu_dispatch0_s2_val),
        .dispatch0_imm(alu_dispatch0_imm),
        .dispatch0_pc(alu_dispatch0_pc),
        .dispatch1_valid(alu_dispatch1_valid),
        .dispatch1_op(alu_dispatch1_op),
        .dispatch1_rob(alu_dispatch1_rob),
        .dispatch1_has_dest(alu_dispatch1_has_dest),
        .dispatch1_dest(alu_dispatch1_dest),
        .dispatch1_s0_ready(alu_dispatch1_s0_ready),
        .dispatch1_s0_tag(alu_dispatch1_s0_tag),
        .dispatch1_s0_val(alu_dispatch1_s0_val),
        .dispatch1_s1_ready(alu_dispatch1_s1_ready),
        .dispatch1_s1_tag(alu_dispatch1_s1_tag),
        .dispatch1_s1_val(alu_dispatch1_s1_val),
        .dispatch1_s2_ready(alu_dispatch1_s2_ready),
        .dispatch1_s2_tag(alu_dispatch1_s2_tag),
        .dispatch1_s2_val(alu_dispatch1_s2_val),
        .dispatch1_imm(alu_dispatch1_imm),
        .dispatch1_pc(alu_dispatch1_pc),
        .cdb0_en(cdb0_en), .cdb0_tag(cdb0_tag), .cdb0_val(cdb0_val),
        .cdb1_en(cdb1_en), .cdb1_tag(cdb1_tag), .cdb1_val(cdb1_val),
        .cdb2_en(cdb2_en), .cdb2_tag(cdb2_tag), .cdb2_val(cdb2_val),
        .cdb3_en(cdb3_en), .cdb3_tag(cdb3_tag), .cdb3_val(cdb3_val),
        .cdb4_en(cdb4_en), .cdb4_tag(cdb4_tag), .cdb4_val(cdb4_val),
        .cdb5_en(cdb5_en), .cdb5_tag(cdb5_tag), .cdb5_val(cdb5_val),
        .flush_en(flush_en),
        .flush_rob(flush_rob),
        .flush_tail(flush_tail),
        .issue_take0(alu_issue_valid0),
        .issue_take1(alu_issue_valid1),
        .free_count(alu_rs_free_count),
        .issue_valid0(alu_issue_valid0),
        .issue_op0(alu_issue_op0),
        .issue_rob0(alu_issue_rob0),
        .issue_has_dest0(alu_issue_has_dest0),
        .issue_dest0(alu_issue_dest0),
        .issue_s0_val0(alu_issue_s0_val0),
        .issue_s1_val0(alu_issue_s1_val0),
        .issue_s2_val0(alu_issue_s2_val0),
        .issue_imm0(alu_issue_imm0),
        .issue_pc0(alu_issue_pc0),
        .issue_idx0(alu_issue_idx0),
        .issue_valid1(alu_issue_valid1),
        .issue_op1(alu_issue_op1),
        .issue_rob1(alu_issue_rob1),
        .issue_has_dest1(alu_issue_has_dest1),
        .issue_dest1(alu_issue_dest1),
        .issue_s0_val1(alu_issue_s0_val1),
        .issue_s1_val1(alu_issue_s1_val1),
        .issue_s2_val1(alu_issue_s2_val1),
        .issue_imm1(alu_issue_imm1),
        .issue_pc1(alu_issue_pc1),
        .issue_idx1(alu_issue_idx1)
    );

    fpu_reservation_station fpu_rs (
        .clk(~clk),
        .reset(reset),
        .live_ready(phys_ready_bus),
        .live_values(phys_value_bus),
        .dispatch0_valid(fpu_dispatch0_valid),
        .dispatch0_op(fpu_dispatch0_op),
        .dispatch0_rob(fpu_dispatch0_rob),
        .dispatch0_dest(fpu_dispatch0_dest),
        .dispatch0_s0_ready(fpu_dispatch0_s0_ready),
        .dispatch0_s0_tag(fpu_dispatch0_s0_tag),
        .dispatch0_s0_val(fpu_dispatch0_s0_val),
        .dispatch0_s1_ready(fpu_dispatch0_s1_ready),
        .dispatch0_s1_tag(fpu_dispatch0_s1_tag),
        .dispatch0_s1_val(fpu_dispatch0_s1_val),
        .dispatch1_valid(fpu_dispatch1_valid),
        .dispatch1_op(fpu_dispatch1_op),
        .dispatch1_rob(fpu_dispatch1_rob),
        .dispatch1_dest(fpu_dispatch1_dest),
        .dispatch1_s0_ready(fpu_dispatch1_s0_ready),
        .dispatch1_s0_tag(fpu_dispatch1_s0_tag),
        .dispatch1_s0_val(fpu_dispatch1_s0_val),
        .dispatch1_s1_ready(fpu_dispatch1_s1_ready),
        .dispatch1_s1_tag(fpu_dispatch1_s1_tag),
        .dispatch1_s1_val(fpu_dispatch1_s1_val),
        .cdb0_en(cdb0_en), .cdb0_tag(cdb0_tag), .cdb0_val(cdb0_val),
        .cdb1_en(cdb1_en), .cdb1_tag(cdb1_tag), .cdb1_val(cdb1_val),
        .cdb2_en(cdb2_en), .cdb2_tag(cdb2_tag), .cdb2_val(cdb2_val),
        .cdb3_en(cdb3_en), .cdb3_tag(cdb3_tag), .cdb3_val(cdb3_val),
        .cdb4_en(cdb4_en), .cdb4_tag(cdb4_tag), .cdb4_val(cdb4_val),
        .cdb5_en(cdb5_en), .cdb5_tag(cdb5_tag), .cdb5_val(cdb5_val),
        .flush_en(flush_en),
        .flush_rob(flush_rob),
        .flush_tail(flush_tail),
        .issue_take0(fpu_issue_take0),
        .issue_take_idx0(fpu_issue_take_idx0),
        .issue_take1(fpu_issue_take1),
        .issue_take_idx1(fpu_issue_take_idx1),
        .free_count(fpu_rs_free_count),
        .issue_valid0(fpu_issue_valid0),
        .issue_op0(fpu_issue_op0),
        .issue_rob0(fpu_issue_rob0),
        .issue_dest0(fpu_issue_dest0),
        .issue_s0_val0(fpu_issue_s0_val0),
        .issue_s1_val0(fpu_issue_s1_val0),
        .issue_idx0(fpu_issue_idx0),
        .issue_valid1(fpu_issue_valid1),
        .issue_op1(fpu_issue_op1),
        .issue_rob1(fpu_issue_rob1),
        .issue_dest1(fpu_issue_dest1),
        .issue_s0_val1(fpu_issue_s0_val1),
        .issue_s1_val1(fpu_issue_s1_val1),
        .issue_idx1(fpu_issue_idx1)
    );

    load_store_queue lsq (
        .clk(~clk),
        .reset(reset),
        .live_ready(phys_ready_bus),
        .live_values(phys_value_bus),
        .rob_head(rob_head[4:0]),
        .dispatch0_valid(lsq_dispatch0_valid),
        .dispatch0_rob(lsq_dispatch0_rob),
        .dispatch0_op(lsq_dispatch0_op),
        .dispatch0_has_dest(lsq_dispatch0_has_dest),
        .dispatch0_dest(lsq_dispatch0_dest),
        .dispatch0_addr_ready(lsq_dispatch0_addr_ready),
        .dispatch0_addr_tag(lsq_dispatch0_addr_tag),
        .dispatch0_addr_val(lsq_dispatch0_addr_val),
        .dispatch0_data_ready(lsq_dispatch0_data_ready),
        .dispatch0_data_tag(lsq_dispatch0_data_tag),
        .dispatch0_data_val(lsq_dispatch0_data_val),
        .dispatch0_imm(lsq_dispatch0_imm),
        .dispatch0_pc(lsq_dispatch0_pc),
        .dispatch1_valid(lsq_dispatch1_valid),
        .dispatch1_rob(lsq_dispatch1_rob),
        .dispatch1_op(lsq_dispatch1_op),
        .dispatch1_has_dest(lsq_dispatch1_has_dest),
        .dispatch1_dest(lsq_dispatch1_dest),
        .dispatch1_addr_ready(lsq_dispatch1_addr_ready),
        .dispatch1_addr_tag(lsq_dispatch1_addr_tag),
        .dispatch1_addr_val(lsq_dispatch1_addr_val),
        .dispatch1_data_ready(lsq_dispatch1_data_ready),
        .dispatch1_data_tag(lsq_dispatch1_data_tag),
        .dispatch1_data_val(lsq_dispatch1_data_val),
        .dispatch1_imm(lsq_dispatch1_imm),
        .dispatch1_pc(lsq_dispatch1_pc),
        .cdb0_en(cdb0_en), .cdb0_tag(cdb0_tag), .cdb0_val(cdb0_val),
        .cdb1_en(cdb1_en), .cdb1_tag(cdb1_tag), .cdb1_val(cdb1_val),
        .cdb2_en(cdb2_en), .cdb2_tag(cdb2_tag), .cdb2_val(cdb2_val),
        .cdb3_en(cdb3_en), .cdb3_tag(cdb3_tag), .cdb3_val(cdb3_val),
        .cdb4_en(cdb4_en), .cdb4_tag(cdb4_tag), .cdb4_val(cdb4_val),
        .cdb5_en(cdb5_en), .cdb5_tag(cdb5_tag), .cdb5_val(cdb5_val),
        .flush_en(flush_en),
        .flush_rob(flush_rob),
        .flush_tail(flush_tail),
        .clear_en0(lsq_clear_en),
        .clear_idx0(lsq_clear_idx),
        .clear_en1(lsq_clear_en2),
        .clear_idx1(lsq_clear_idx2),
        .issue_take0(lsq_issue_valid0),
        .issue_take1(lsq_issue_valid1),
        .commit_idx(lsq_commit_idx),
        .store_ready_bus(lsq_store_ready_bus),
        .issue_valid0(lsq_issue_valid0),
        .issue_rob0(lsq_issue_rob0),
        .issue_op0(lsq_issue_op0),
        .issue_has_dest0(lsq_issue_has_dest0),
        .issue_dest0(lsq_issue_dest0),
        .issue_addr0(lsq_issue_addr0),
        .issue_forward_hit0(lsq_issue_forward_hit0),
        .issue_forward_data0(lsq_issue_forward_data0),
        .issue_idx0(lsq_issue_idx0),
        .issue_valid1(lsq_issue_valid1),
        .issue_rob1(lsq_issue_rob1),
        .issue_op1(lsq_issue_op1),
        .issue_has_dest1(lsq_issue_has_dest1),
        .issue_dest1(lsq_issue_dest1),
        .issue_addr1(lsq_issue_addr1),
        .issue_forward_hit1(lsq_issue_forward_hit1),
        .issue_forward_data1(lsq_issue_forward_data1),
        .issue_idx1(lsq_issue_idx1),
        .commit_addr(lsq_commit_addr),
        .commit_data(lsq_commit_data)
    );

    task broadcast_result;
        input [6:0] tag;
        input [63:0] value;
        begin
            phys_value[tag] = value;
            phys_ready[tag] = 1'b1;
        end
    endtask

    task squash_younger;
        input [4:0] branch_rob;
        input [63:0] restart_pc;
        begin
            flush_en = 1'b1;
            flush_rob = branch_rob;
            flush_tail = rob_tail[4:0];
            tail_snapshot = rob_tail;
            flush_count = 0;

            for (i = 0; i < ROB_SIZE; i = i + 1) begin
                if (rob_valid[i]) begin
                    j = i - branch_rob;
                    k = tail_snapshot - branch_rob;
                    if (j < 0) j = j + ROB_SIZE;
                    if (k < 0) k = k + ROB_SIZE;
                    if ((j > 0) && (j < k)) begin
                        if (rob_has_dest[i] && (rob_phys_dest[i] >= 32)) begin
                            free_list[free_tail] = rob_phys_dest[i];
                            free_tail = (free_tail + 1) % FREE_REGS;
                            free_count = free_count + 1;
                        end
                        rob_valid[i] = 1'b0;
                        rob_ready[i] = 1'b0;
                        rob_branch_done[i] = 1'b0;
                        rob_store_done[i] = 1'b0;
                        rob_has_dest[i] = 1'b0;
                        flush_count = flush_count + 1;
                    end
                end
            end

            for (i = 0; i < 32; i = i + 1) begin
                rat[i] = checkpoint_rat[i];
            end
            ret_sp = checkpoint_ret_sp;

            if (alu0_s0_valid) begin
                j = alu0_s0_rob - branch_rob;
                k = tail_snapshot - branch_rob;
                if (j < 0) j = j + ROB_SIZE;
                if (k < 0) k = k + ROB_SIZE;
                if ((j > 0) && (j < k)) alu0_s0_valid = 1'b0;
            end
            if (alu0_s1_valid) begin
                j = alu0_s1_rob - branch_rob;
                k = tail_snapshot - branch_rob;
                if (j < 0) j = j + ROB_SIZE;
                if (k < 0) k = k + ROB_SIZE;
                if ((j > 0) && (j < k)) alu0_s1_valid = 1'b0;
            end
            if (alu1_s0_valid) begin
                j = alu1_s0_rob - branch_rob;
                k = tail_snapshot - branch_rob;
                if (j < 0) j = j + ROB_SIZE;
                if (k < 0) k = k + ROB_SIZE;
                if ((j > 0) && (j < k)) alu1_s0_valid = 1'b0;
            end
            if (alu1_s1_valid) begin
                j = alu1_s1_rob - branch_rob;
                k = tail_snapshot - branch_rob;
                if (j < 0) j = j + ROB_SIZE;
                if (k < 0) k = k + ROB_SIZE;
                if ((j > 0) && (j < k)) alu1_s1_valid = 1'b0;
            end
            if (ls0_s0_valid) begin
                j = ls0_s0_rob - branch_rob;
                k = tail_snapshot - branch_rob;
                if (j < 0) j = j + ROB_SIZE;
                if (k < 0) k = k + ROB_SIZE;
                if ((j > 0) && (j < k)) ls0_s0_valid = 1'b0;
            end
            if (ls0_s1_valid) begin
                j = ls0_s1_rob - branch_rob;
                k = tail_snapshot - branch_rob;
                if (j < 0) j = j + ROB_SIZE;
                if (k < 0) k = k + ROB_SIZE;
                if ((j > 0) && (j < k)) ls0_s1_valid = 1'b0;
            end
            if (ls1_s0_valid) begin
                j = ls1_s0_rob - branch_rob;
                k = tail_snapshot - branch_rob;
                if (j < 0) j = j + ROB_SIZE;
                if (k < 0) k = k + ROB_SIZE;
                if ((j > 0) && (j < k)) ls1_s0_valid = 1'b0;
            end
            if (ls1_s1_valid) begin
                j = ls1_s1_rob - branch_rob;
                k = tail_snapshot - branch_rob;
                if (j < 0) j = j + ROB_SIZE;
                if (k < 0) k = k + ROB_SIZE;
                if ((j > 0) && (j < k)) ls1_s1_valid = 1'b0;
            end
            for (i = 0; i < 5; i = i + 1) begin
                if (fpu0_valid[i]) begin
                    j = fpu0_rob[i] - branch_rob;
                    k = tail_snapshot - branch_rob;
                    if (j < 0) j = j + ROB_SIZE;
                    if (k < 0) k = k + ROB_SIZE;
                    if ((j > 0) && (j < k)) fpu0_valid[i] = 1'b0;
                end
                if (fpu1_valid[i]) begin
                    j = fpu1_rob[i] - branch_rob;
                    k = tail_snapshot - branch_rob;
                    if (j < 0) j = j + ROB_SIZE;
                    if (k < 0) k = k + ROB_SIZE;
                    if ((j > 0) && (j < k)) fpu1_valid[i] = 1'b0;
                end
            end

            rob_tail = (branch_rob + 1) % ROB_SIZE;
            rob_count = rob_count - flush_count;
            speculative_valid = 1'b0;
            fetch_pc = restart_pc;
            fetch_line_valid = 1'b0;
            control_stall = 1'b0;
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
            if (speculative_valid && (speculative_rob == rob_idx_in)) begin
                speculative_valid = 1'b0;
                if ((rob_pred_taken[rob_idx_in] != taken_in) ||
                    (taken_in && (rob_pred_target[rob_idx_in] != target_in))) begin
                    squash_younger(rob_idx_in, taken_in ? target_in : (pc_in + 4));
                end
            end else if (taken_in) begin
                fetch_pc = target_in;
                if (fetch_line_base[63:6] != target_in[63:6]) fetch_line_valid = 1'b0;
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
            arch_write_enable2 = 1'b0;
            arch_write_rd2 = 5'b0;
            arch_write_data2 = 64'b0;
            commit_mem_write = 1'b0;
            commit_mem_addr = 64'b0;
            commit_mem_data = 64'b0;
            bp_update_en = 1'b0;
            bp_update_pc = 64'b0;
            bp_update_taken = 1'b0;
            bp_update_target = 64'b0;
            decode_valid_dbg = 1'b0;
            ir_dbg = 32'b0;

            rob_head = 0;
            rob_tail = 0;
            rob_count = 0;
            speculative_valid = 1'b0;
            speculative_rob = 5'b0;
            flush_en = 1'b0;
            flush_rob = 5'b0;
            flush_tail = 5'b0;
            checkpoint_ret_sp = 0;

            free_head = 0;
            free_tail = 0;
            free_count = FREE_REGS;
            ret_sp = 0;
            for (i = 0; i < FREE_REGS; i = i + 1) begin
                free_list[i] = i + 32;
            end

            for (i = 0; i < 32; i = i + 1) begin
                rat[i] = i[6:0];
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
                rob_phys_dest[i] = 7'b0;
                rob_old_phys[i] = 7'b0;
                rob_op[i] = 5'b0;
                rob_pc[i] = 64'b0;
                rob_value[i] = 64'b0;
                rob_target[i] = 64'b0;
                rob_taken[i] = 1'b0;
                rob_pred_taken[i] = 1'b0;
                rob_pred_target[i] = 64'b0;
            end

            alu_dispatch0_valid = 1'b0;
            alu_dispatch1_valid = 1'b0;
            fpu_dispatch0_valid = 1'b0;
            fpu_dispatch1_valid = 1'b0;
            lsq_dispatch0_valid = 1'b0;
            lsq_dispatch1_valid = 1'b0;
            fpu_issue_take0 = 1'b0;
            fpu_issue_take_idx0 = 3'b0;
            fpu_issue_take1 = 1'b0;
            fpu_issue_take_idx1 = 3'b0;
            lsq_clear_en = 1'b0;
            lsq_clear_idx = 5'b0;
            lsq_commit_idx = 5'b0;

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
                fpu0_dest[i] = 7'b0;
                fpu1_dest[i] = 7'b0;
                fpu0_a[i] = 64'b0;
                fpu0_b[i] = 64'b0;
                fpu1_a[i] = 64'b0;
                fpu1_b[i] = 64'b0;
                fpu0_res[i] = 64'b0;
                fpu1_res[i] = 64'b0;
            end
        end else if (!hlt) begin
            decode_valid_dbg = alu_dispatch0_valid || fpu_dispatch0_valid || lsq_dispatch0_valid;
            ir_dbg = inst0;
            arch_write_enable = 1'b0;
            arch_write_rd = 5'b0;
            arch_write_data = 64'b0;
            arch_write_enable2 = 1'b0;
            arch_write_rd2 = 5'b0;
            arch_write_data2 = 64'b0;
            commit_mem_write = 1'b0;
            bp_update_en = 1'b0;
            alu_dispatch0_valid = 1'b0;
            alu_dispatch1_valid = 1'b0;
            fpu_dispatch0_valid = 1'b0;
            fpu_dispatch1_valid = 1'b0;
            lsq_dispatch0_valid = 1'b0;
            lsq_dispatch1_valid = 1'b0;
            fpu_issue_take0 = 1'b0;
            fpu_issue_take_idx0 = 3'b0;
            fpu_issue_take1 = 1'b0;
            fpu_issue_take_idx1 = 3'b0;
            lsq_clear_en = 1'b0;
            lsq_clear_en2 = 1'b0;
            lsq_clear_idx = rob_head[4:0];
            lsq_clear_idx2 = rob_head[4:0];
            lsq_commit_idx = rob_head[4:0];
            flush_en = 1'b0;
            flush_rob = 5'b0;
            flush_tail = 5'b0;
            branch_start_spec = 1'b0;
            branch_spec_rob = 5'b0;
            branch_spec_taken = 1'b0;
            branch_spec_target = 64'b0;
            branch_fast_resolve0 = 1'b0;
            branch_fast_taken0 = 1'b0;
            branch_fast_target0 = 64'b0;
            branch_fast_skip0 = 1'b0;
            branch_fast_resolve1 = 1'b0;
            branch_fast_taken1 = 1'b0;
            branch_fast_target1 = 64'b0;
            branch_fast_skip1 = 1'b0;
            allow_issue_lane1 = 1'b0;
            op0_forward_valid = 1'b0;
            op0_forward_value = 64'b0;
            fast_exec_valid_dbg = 1'b0;
            fast_exec_opcode_dbg = 5'b0;
            fast_mem_valid_dbg = 1'b0;
            fast_mem_opcode_dbg = 5'b0;
            fast_store_forward_dbg = 1'b0;

            // Keep the architectural register seed state visible through the
            // base physical mappings until a register is renamed away.
            for (i = 0; i < 32; i = i + 1) begin
                if (rat[i] == i[6:0]) begin
                    phys_value[i] = reg_file.registers[i];
                    phys_ready[i] = 1'b1;
                end
            end

            if (rob_count > 0 && rob_valid[rob_head] && rob_ready[rob_head]) begin
                j = rob_head;

                if (rob_has_dest[j]) begin
                    arch_write_enable = 1'b1;
                    arch_write_rd = rob_arch_dest[j];
                    arch_write_data = rob_value[j];
                end

                if ((rob_op[j] == OP_MOV_SM) || (rob_op[j] == OP_CALL)) begin
                    commit_mem_write = 1'b1;
                    commit_mem_addr =
                        (lsq.addr_ready[j] ? lsq.addr_val[j] : phys_value[lsq.addr_tag[j]]) +
                        ((rob_op[j] == OP_CALL) ? 64'hfffffffffffffff8 : signext12(lsq.imm[j]));
                    commit_mem_data = lsq.data_ready[j] ? lsq.data_val[j] : phys_value[lsq.data_tag[j]];
                end

                if (uses_lsq(rob_op[j])) begin
                    lsq_clear_en = 1'b1;
                    lsq_clear_idx = j[4:0];
                end

                if (rob_has_dest[j] && (rob_old_phys[j] >= 32)) begin
                    free_list[free_tail] = rob_old_phys[j];
                    free_tail = (free_tail + 1) % FREE_REGS;
                    free_count = free_count + 1;
                end

                rob_valid[j] = 1'b0;
                rob_ready[j] = 1'b0;
                rob_head = (rob_head + 1) % ROB_SIZE;
                rob_count = rob_count - 1;

                if (rob_op[j] == OP_PRIV) begin
                    hlt = 1'b1;
                end else if ((rob_count > 0) && rob_valid[rob_head] && rob_ready[rob_head] &&
                    (rob_op[rob_head] != OP_PRIV) &&
                    (!has_commit_mem_side_effect(rob_op[j]) || !has_commit_mem_side_effect(rob_op[rob_head]))) begin
                    k = rob_head;
                    if (rob_has_dest[k]) begin
                        arch_write_enable2 = 1'b1;
                        arch_write_rd2 = rob_arch_dest[k];
                        arch_write_data2 = rob_value[k];
                    end
                    if (has_commit_mem_side_effect(rob_op[k])) begin
                        commit_mem_write = 1'b1;
                        commit_mem_addr =
                            (lsq.addr_ready[k] ? lsq.addr_val[k] : phys_value[lsq.addr_tag[k]]) +
                            ((rob_op[k] == OP_CALL) ? 64'hfffffffffffffff8 : signext12(lsq.imm[k]));
                        commit_mem_data = lsq.data_ready[k] ? lsq.data_val[k] : phys_value[lsq.data_tag[k]];
                    end
                    if (uses_lsq(rob_op[k])) begin
                        lsq_clear_en2 = 1'b1;
                        lsq_clear_idx2 = k[4:0];
                    end
                    if (rob_has_dest[k] && (rob_old_phys[k] >= 32)) begin
                        free_list[free_tail] = rob_old_phys[k];
                        free_tail = (free_tail + 1) % FREE_REGS;
                        free_count = free_count + 1;
                    end
                    rob_valid[k] = 1'b0;
                    rob_ready[k] = 1'b0;
                    rob_head = (rob_head + 1) % ROB_SIZE;
                    rob_count = rob_count - 1;
                end
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
                    if (ret_sp > 0) ret_sp = ret_sp - 1;
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
                    if (ret_sp > 0) ret_sp = ret_sp - 1;
                    resolve_branch(ls1_s1_rob, 1'b1, ls1_s1_res, rob_pc[ls1_s1_rob]);
                end
            end

            for (i = 0; i < ROB_SIZE; i = i + 1) begin
                if (lsq_store_ready_bus[i] && !rob_store_done[i] && (rob_op[i] == OP_MOV_SM || rob_op[i] == OP_CALL)) begin
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
            ls0_s1_res = (ls0_s0_op == OP_RET && ret_sp > 0) ? ret_stack[ret_sp - 1] :
                (ls0_s0_forward_hit ? ls0_s0_forward_data :
                ((commit_mem_write && (commit_mem_addr == ls0_s0_addr)) ? commit_mem_data : {
                memory.bytes[ls0_s0_addr + 7], memory.bytes[ls0_s0_addr + 6], memory.bytes[ls0_s0_addr + 5], memory.bytes[ls0_s0_addr + 4],
                memory.bytes[ls0_s0_addr + 3], memory.bytes[ls0_s0_addr + 2], memory.bytes[ls0_s0_addr + 1], memory.bytes[ls0_s0_addr]
            }));
            ls1_s1_valid = ls1_s0_valid;
            ls1_s1_rob = ls1_s0_rob;
            ls1_s1_has_dest = ls1_s0_has_dest;
            ls1_s1_dest = ls1_s0_dest;
            ls1_s1_is_ret = (ls1_s0_op == OP_RET);
            ls1_s1_res = (ls1_s0_op == OP_RET && ret_sp > 0) ? ret_stack[ret_sp - 1] :
                (ls1_s0_forward_hit ? ls1_s0_forward_data :
                ((commit_mem_write && (commit_mem_addr == ls1_s0_addr)) ? commit_mem_data : {
                memory.bytes[ls1_s0_addr + 7], memory.bytes[ls1_s0_addr + 6], memory.bytes[ls1_s0_addr + 5], memory.bytes[ls1_s0_addr + 4],
                memory.bytes[ls1_s0_addr + 3], memory.bytes[ls1_s0_addr + 2], memory.bytes[ls1_s0_addr + 1], memory.bytes[ls1_s0_addr]
            }));
            ls0_s0_valid = 1'b0;
            ls1_s0_valid = 1'b0;

            if (alu_issue_valid0) begin
                alu0_s0_valid = 1'b1;
                alu0_s0_op = alu_issue_op0;
                alu0_s0_rob = alu_issue_rob0;
                alu0_s0_has_dest = alu_issue_has_dest0;
                alu0_s0_dest = alu_issue_dest0;
                alu0_s0_a = alu_issue_s0_val0;
                alu0_s0_b = alu_issue_s1_val0;
                alu0_s0_c = alu_issue_s2_val0;
                alu0_s0_imm = alu_issue_imm0;
                alu0_s0_pc = alu_issue_pc0;
                if ((alu_issue_op0 == OP_ADDI) || (alu_issue_op0 == OP_SUBI) ||
                    (alu_issue_op0 == OP_SHFTRI) || (alu_issue_op0 == OP_SHFTLI) ||
                    (alu_issue_op0 == OP_MOV_L)) begin
                    alu0_s0_b = imm_operand(alu_issue_op0, alu_issue_imm0);
                end
            end

            if (alu_issue_valid1) begin
                alu1_s0_valid = 1'b1;
                alu1_s0_op = alu_issue_op1;
                alu1_s0_rob = alu_issue_rob1;
                alu1_s0_has_dest = alu_issue_has_dest1;
                alu1_s0_dest = alu_issue_dest1;
                alu1_s0_a = alu_issue_s0_val1;
                alu1_s0_b = alu_issue_s1_val1;
                alu1_s0_c = alu_issue_s2_val1;
                alu1_s0_imm = alu_issue_imm1;
                alu1_s0_pc = alu_issue_pc1;
                if ((alu_issue_op1 == OP_ADDI) || (alu_issue_op1 == OP_SUBI) ||
                    (alu_issue_op1 == OP_SHFTRI) || (alu_issue_op1 == OP_SHFTLI) ||
                    (alu_issue_op1 == OP_MOV_L)) begin
                    alu1_s0_b = imm_operand(alu_issue_op1, alu_issue_imm1);
                end
            end

            if (fpu_issue_valid0) begin
                fpu_issue_take0 = 1'b1;
                fpu_issue_take_idx0 = fpu_issue_idx0;
                fpu0_valid[0] = 1'b1;
                fpu0_op[0] = fpu_issue_op0;
                fpu0_rob[0] = fpu_issue_rob0;
                fpu0_dest[0] = fpu_issue_dest0;
                fpu0_a[0] = fpu_issue_s0_val0;
                fpu0_b[0] = fpu_issue_s1_val0;
                fpu0_res[0] = 64'b0;
            end
            if (fpu_issue_valid1) begin
                fpu_issue_take1 = 1'b1;
                fpu_issue_take_idx1 = fpu_issue_idx1;
                fpu1_valid[0] = 1'b1;
                fpu1_op[0] = fpu_issue_op1;
                fpu1_rob[0] = fpu_issue_rob1;
                fpu1_dest[0] = fpu_issue_dest1;
                fpu1_a[0] = fpu_issue_s0_val1;
                fpu1_b[0] = fpu_issue_s1_val1;
                fpu1_res[0] = 64'b0;
            end

            if (lsq_issue_valid0) begin
                if (lsq_issue_op0 == OP_MOV_ML) begin
                    rob_value[lsq_issue_rob0] =
                        lsq_issue_forward_hit0 ? lsq_issue_forward_data0 :
                        ((commit_mem_write && (commit_mem_addr == lsq_issue_addr0)) ? commit_mem_data : {
                        memory.bytes[lsq_issue_addr0 + 7], memory.bytes[lsq_issue_addr0 + 6],
                        memory.bytes[lsq_issue_addr0 + 5], memory.bytes[lsq_issue_addr0 + 4],
                        memory.bytes[lsq_issue_addr0 + 3], memory.bytes[lsq_issue_addr0 + 2],
                        memory.bytes[lsq_issue_addr0 + 1], memory.bytes[lsq_issue_addr0]});
                    rob_ready[lsq_issue_rob0] = 1'b1;
                    broadcast_result(lsq_issue_dest0, rob_value[lsq_issue_rob0]);
                    if (lsq_issue_forward_hit0) begin
                        fast_mem_valid_dbg = 1'b1;
                        fast_mem_opcode_dbg = OP_MOV_ML;
                        fast_store_forward_dbg = 1'b1;
                    end else begin
                        fast_exec_valid_dbg = 1'b1;
                        fast_exec_opcode_dbg = OP_MOV_ML;
                    end
                end else begin
                    ls0_s0_valid = 1'b1;
                    ls0_s0_op = lsq_issue_op0;
                    ls0_s0_rob = lsq_issue_rob0;
                    ls0_s0_has_dest = lsq_issue_has_dest0;
                    ls0_s0_dest = lsq_issue_dest0;
                    ls0_s0_addr = lsq_issue_addr0;
                    ls0_s0_forward_hit = lsq_issue_forward_hit0;
                    ls0_s0_forward_data = lsq_issue_forward_data0;
                    fast_exec_valid_dbg = 1'b1;
                    fast_exec_opcode_dbg = lsq_issue_op0;
                end
            end
            if (lsq_issue_valid1) begin
                if (lsq_issue_op1 == OP_MOV_ML) begin
                    rob_value[lsq_issue_rob1] =
                        lsq_issue_forward_hit1 ? lsq_issue_forward_data1 :
                        ((commit_mem_write && (commit_mem_addr == lsq_issue_addr1)) ? commit_mem_data : {
                        memory.bytes[lsq_issue_addr1 + 7], memory.bytes[lsq_issue_addr1 + 6],
                        memory.bytes[lsq_issue_addr1 + 5], memory.bytes[lsq_issue_addr1 + 4],
                        memory.bytes[lsq_issue_addr1 + 3], memory.bytes[lsq_issue_addr1 + 2],
                        memory.bytes[lsq_issue_addr1 + 1], memory.bytes[lsq_issue_addr1]});
                    rob_ready[lsq_issue_rob1] = 1'b1;
                    broadcast_result(lsq_issue_dest1, rob_value[lsq_issue_rob1]);
                    if (lsq_issue_forward_hit1) begin
                        fast_mem_valid_dbg = 1'b1;
                        fast_mem_opcode_dbg = OP_MOV_ML;
                        fast_store_forward_dbg = 1'b1;
                    end else if (!fast_exec_valid_dbg) begin
                        fast_exec_valid_dbg = 1'b1;
                        fast_exec_opcode_dbg = OP_MOV_ML;
                    end
                end else begin
                    ls1_s0_valid = 1'b1;
                    ls1_s0_op = lsq_issue_op1;
                    ls1_s0_rob = lsq_issue_rob1;
                    ls1_s0_has_dest = lsq_issue_has_dest1;
                    ls1_s0_dest = lsq_issue_dest1;
                    ls1_s0_addr = lsq_issue_addr1;
                    ls1_s0_forward_hit = lsq_issue_forward_hit1;
                    ls1_s0_forward_data = lsq_issue_forward_data1;
                    if (!fast_exec_valid_dbg) begin
                        fast_exec_valid_dbg = 1'b1;
                        fast_exec_opcode_dbg = lsq_issue_op1;
                    end
                end
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

                    if (is_control_op(op0) && speculative_valid) begin
                        control_stall = 1'b1;
                    end else if (rob_count < ROB_SIZE) begin
                        free_rs_slots = alu_rs_free_count;
                        free_fp_slots = fpu_rs_free_count;

                        if ((!writes_dest(op0) || (free_count > 0)) &&
                            (!uses_alu_rs(op0) || (free_rs_slots > 0)) &&
                            (!is_fpu_op(op0) || (free_fp_slots > 0))) begin
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
                            rob_pred_taken[entry_idx] = 1'b0;
                            rob_pred_target[entry_idx] = pc0 + 4;

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
                                rob_phys_dest[entry_idx] = 7'b0;
                                rob_old_phys[entry_idx] = 7'b0;
                            end

                            if (uses_alu_rs(op0)) begin
                                alu_dispatch0_valid = 1'b1;
                                alu_dispatch0_op = op0;
                                alu_dispatch0_rob = entry_idx[4:0];
                                alu_dispatch0_has_dest = writes_dest(op0);
                                alu_dispatch0_dest = rob_phys_dest[entry_idx];
                                alu_dispatch0_imm = imm0;
                                alu_dispatch0_pc = pc0;
                                alu_dispatch0_s0_ready = 1'b0;
                                alu_dispatch0_s1_ready = 1'b0;
                                alu_dispatch0_s2_ready = 1'b0;

                                case (op0)
                                    OP_ADDI, OP_SUBI: begin
                                        if (rs0 != 0) begin
                                            map_src = (writes_dest(op0) && (rs0 == rd0)) ? rob_old_phys[entry_idx] : rat[rs0];
                                        end else begin
                                            map_src = rob_has_dest[entry_idx] ? rob_old_phys[entry_idx] : rat[rd0];
                                        end
                                        alu_dispatch0_s0_tag = map_src;
                                        alu_dispatch0_s0_ready = phys_ready[map_src];
                                        alu_dispatch0_s0_val = phys_value[map_src];
                                        alu_dispatch0_s1_ready = 1'b1;
                                        alu_dispatch0_s1_val = imm_operand(op0, imm0);
                                    end
                                    OP_SHFTRI, OP_SHFTLI: begin
                                        map_src = rob_has_dest[entry_idx] ? rob_old_phys[entry_idx] : rat[rd0];
                                        alu_dispatch0_s0_tag = map_src;
                                        alu_dispatch0_s0_ready = phys_ready[map_src];
                                        alu_dispatch0_s0_val = phys_value[map_src];
                                        alu_dispatch0_s1_ready = 1'b1;
                                        alu_dispatch0_s1_val = imm_operand(op0, imm0);
                                    end
                                    OP_MOV_L: begin
                                        map_src = rob_has_dest[entry_idx] ? rob_old_phys[entry_idx] : rat[rd0];
                                        alu_dispatch0_s0_tag = map_src;
                                        alu_dispatch0_s0_ready = phys_ready[map_src];
                                        alu_dispatch0_s0_val = phys_value[map_src];
                                        alu_dispatch0_s1_ready = 1'b1;
                                        alu_dispatch0_s1_val = imm_operand(op0, imm0);
                                    end
                                    OP_MOV_RR, OP_NOT: begin
                                        map_src = (writes_dest(op0) && (rs0 == rd0)) ? rob_old_phys[entry_idx] : rat[rs0];
                                        alu_dispatch0_s0_tag = map_src;
                                        alu_dispatch0_s0_ready = phys_ready[map_src];
                                        alu_dispatch0_s0_val = phys_value[map_src];
                                        alu_dispatch0_s1_ready = 1'b1;
                                        alu_dispatch0_s1_val = 64'b0;
                                    end
                                    OP_BR: begin
                                        map_src = rat[rd0];
                                        alu_dispatch0_s0_tag = map_src;
                                        alu_dispatch0_s0_ready = phys_ready[map_src];
                                        alu_dispatch0_s0_val = phys_value[map_src];
                                    end
                                    OP_BRR_R: begin
                                        map_src = rat[rd0];
                                        alu_dispatch0_s0_tag = map_src;
                                        alu_dispatch0_s0_ready = phys_ready[map_src];
                                        alu_dispatch0_s0_val = phys_value[map_src];
                                    end
                                    OP_BRR_L: begin
                                        alu_dispatch0_s0_ready = 1'b1;
                                        alu_dispatch0_s0_val = 64'b0;
                                    end
                                    OP_BRNZ: begin
                                        map_src = rat[rd0];
                                        alu_dispatch0_s0_tag = map_src;
                                        alu_dispatch0_s0_ready = phys_ready[map_src];
                                        alu_dispatch0_s0_val = phys_value[map_src];
                                        map_src = rat[rs0];
                                        alu_dispatch0_s1_tag = map_src;
                                        alu_dispatch0_s1_ready = phys_ready[map_src];
                                        alu_dispatch0_s1_val = phys_value[map_src];
                                    end
                                    OP_BRGT: begin
                                        map_src = rat[rd0];
                                        alu_dispatch0_s0_tag = map_src;
                                        alu_dispatch0_s0_ready = phys_ready[map_src];
                                        alu_dispatch0_s0_val = phys_value[map_src];
                                        map_src = rat[rs0];
                                        alu_dispatch0_s1_tag = map_src;
                                        alu_dispatch0_s1_ready = phys_ready[map_src];
                                        alu_dispatch0_s1_val = phys_value[map_src];
                                        map_src = rat[rt0];
                                        alu_dispatch0_s2_tag = map_src;
                                        alu_dispatch0_s2_ready = phys_ready[map_src];
                                        alu_dispatch0_s2_val = phys_value[map_src];
                                    end
                                    OP_CALL: begin
                                        map_src = rat[rd0];
                                        alu_dispatch0_s0_tag = map_src;
                                        alu_dispatch0_s0_ready = phys_ready[map_src];
                                        alu_dispatch0_s0_val = phys_value[map_src];
                                    end
                                    default: begin
                                        map_src = (writes_dest(op0) && (rs0 == rd0)) ? rob_old_phys[entry_idx] : rat[rs0];
                                        alu_dispatch0_s0_tag = map_src;
                                        alu_dispatch0_s0_ready = phys_ready[map_src];
                                        alu_dispatch0_s0_val = phys_value[map_src];
                                        if (op0 == OP_NOT) begin
                                            alu_dispatch0_s1_ready = 1'b1;
                                            alu_dispatch0_s1_val = 64'b0;
                                        end else begin
                                            map_src = (writes_dest(op0) && (rt0 == rd0)) ? rob_old_phys[entry_idx] : rat[rt0];
                                            alu_dispatch0_s1_tag = map_src;
                                            alu_dispatch0_s1_ready = phys_ready[map_src];
                                            alu_dispatch0_s1_val = phys_value[map_src];
                                        end
                                    end
                                endcase
                                if ((op0 == OP_BR) && alu_dispatch0_s0_ready) begin
                                    branch_fast_resolve0 = 1'b1;
                                    branch_fast_taken0 = 1'b1;
                                    branch_fast_target0 = alu_dispatch0_s0_val;
                                end else if ((op0 == OP_BRR_R) && alu_dispatch0_s0_ready) begin
                                    branch_fast_resolve0 = 1'b1;
                                    branch_fast_taken0 = 1'b1;
                                    branch_fast_target0 = pc0 + alu_dispatch0_s0_val;
                                end else if (op0 == OP_BRR_L) begin
                                    branch_fast_resolve0 = 1'b1;
                                    branch_fast_taken0 = 1'b1;
                                    branch_fast_target0 = pc0 + signext12(imm0);
                                end else if ((op0 == OP_BRNZ) && alu_dispatch0_s0_ready && alu_dispatch0_s1_ready) begin
                                    branch_fast_resolve0 = 1'b1;
                                    branch_fast_taken0 = (alu_dispatch0_s1_val != 0);
                                    branch_fast_target0 = alu_dispatch0_s0_val;
                                end else if ((op0 == OP_BRGT) && alu_dispatch0_s0_ready && alu_dispatch0_s1_ready && alu_dispatch0_s2_ready) begin
                                    branch_fast_resolve0 = 1'b1;
                                    branch_fast_taken0 = (alu_dispatch0_s1_val > alu_dispatch0_s2_val);
                                    branch_fast_target0 = alu_dispatch0_s0_val;
                                end
                                if (branch_fast_resolve0) begin
                                    alu_dispatch0_valid = 1'b0;
                                    branch_fast_skip0 = (op0 == OP_BR) || (op0 == OP_BRR_R) ||
                                        (op0 == OP_BRR_L) || (op0 == OP_BRNZ) || (op0 == OP_BRGT);
                                    if (!branch_fast_skip0) begin
                                        rob_branch_done[entry_idx] = 1'b1;
                                        rob_taken[entry_idx] = branch_fast_taken0;
                                        rob_target[entry_idx] = branch_fast_target0;
                                        rob_ready[entry_idx] = 1'b1;
                                    end else begin
                                        rob_valid[entry_idx] = 1'b0;
                                        rob_ready[entry_idx] = 1'b0;
                                        rob_branch_done[entry_idx] = 1'b0;
                                    end
                                    bp_update_en = 1'b1;
                                    bp_update_pc = pc0;
                                    bp_update_taken = branch_fast_taken0;
                                    bp_update_target = branch_fast_target0;
                                end else begin
                                free_rs_slots = free_rs_slots - 1;
                                end
                                if (!is_control_op(op0) && alu_dispatch0_s0_ready &&
                                    (((op0 == OP_NOT) || (op0 == OP_MOV_RR)) ||
                                     alu_dispatch0_s1_ready)) begin
                                    op0_forward_valid = 1'b1;
                                    op0_forward_value = int_result_estimate(op0,
                                        alu_dispatch0_s0_val,
                                        ((op0 == OP_ADDI) || (op0 == OP_SUBI) ||
                                         (op0 == OP_SHFTRI) || (op0 == OP_SHFTLI) ||
                                         (op0 == OP_MOV_L)) ? imm_operand(op0, imm0) : alu_dispatch0_s1_val);
                                end
                            end else if (is_fpu_op(op0)) begin
                                map_src = (writes_dest(op0) && (rs0 == rd0)) ? rob_old_phys[entry_idx] : rat[rs0];
                                map_src1 = (writes_dest(op0) && (rt0 == rd0)) ? rob_old_phys[entry_idx] : rat[rt0];
                                fpu_dispatch0_valid = 1'b1;
                                fpu_dispatch0_op = op0;
                                fpu_dispatch0_rob = entry_idx[4:0];
                                fpu_dispatch0_dest = rob_phys_dest[entry_idx];
                                fpu_dispatch0_s0_tag = map_src;
                                fpu_dispatch0_s0_ready = phys_ready[map_src];
                                fpu_dispatch0_s0_val = phys_value[map_src];
                                fpu_dispatch0_s1_tag = map_src1;
                                fpu_dispatch0_s1_ready = phys_ready[map_src1];
                                fpu_dispatch0_s1_val = phys_value[map_src1];
                                free_fp_slots = free_fp_slots - 1;
                            end

                            if (uses_lsq(op0)) begin
                                lsq_dispatch0_valid = 1'b1;
                                lsq_dispatch0_rob = entry_idx[4:0];
                                lsq_dispatch0_op = op0;
                                lsq_dispatch0_has_dest = writes_dest(op0);
                                lsq_dispatch0_dest = rob_phys_dest[entry_idx];
                                lsq_dispatch0_imm = imm0;
                                lsq_dispatch0_pc = pc0;
                                if (op0 == OP_MOV_ML) begin
                                    map_src = (writes_dest(op0) && (rs0 == rd0)) ? rob_old_phys[entry_idx] : rat[rs0];
                                    lsq_dispatch0_addr_tag = map_src;
                                    lsq_dispatch0_addr_ready = phys_ready[map_src];
                                    lsq_dispatch0_addr_val = phys_value[map_src];
                                    lsq_dispatch0_data_ready = 1'b0;
                                end else if (op0 == OP_MOV_SM) begin
                                    map_src = rat[rd0];
                                    lsq_dispatch0_addr_tag = map_src;
                                    lsq_dispatch0_addr_ready = phys_ready[map_src];
                                    lsq_dispatch0_addr_val = phys_value[map_src];
                                    map_src = rat[rs0];
                                    lsq_dispatch0_data_tag = map_src;
                                    lsq_dispatch0_data_ready = phys_ready[map_src];
                                    lsq_dispatch0_data_val = phys_value[map_src];
                                end else if (op0 == OP_CALL) begin
                                    map_src = rat[31];
                                    lsq_dispatch0_addr_tag = map_src;
                                    lsq_dispatch0_addr_ready = phys_ready[map_src];
                                    lsq_dispatch0_addr_val = phys_value[map_src];
                                    lsq_dispatch0_data_ready = 1'b1;
                                    lsq_dispatch0_data_val = pc0 + 4;
                                end else if (op0 == OP_RET) begin
                                    map_src = rat[31];
                                    lsq_dispatch0_addr_tag = map_src;
                                    lsq_dispatch0_addr_ready = phys_ready[map_src];
                                    lsq_dispatch0_addr_val = phys_value[map_src];
                                    lsq_dispatch0_data_ready = 1'b0;
                                end
                                if ((op0 == OP_MOV_SM) || (op0 == OP_CALL)) begin
                                    fast_exec_valid_dbg = 1'b1;
                                    fast_exec_opcode_dbg = op0;
                                end
                            end
                            if (op0 == OP_CALL && ret_sp < 16) begin
                                ret_stack[ret_sp] = pc0 + 4;
                                ret_sp = ret_sp + 1;
                            end

                            if (is_control_op(op0) && (op0 != OP_PRIV) && !speculative_valid && !branch_fast_resolve0) begin
                                branch_start_spec = 1'b1;
                                branch_spec_rob = entry_idx[4:0];
                                branch_spec_taken = 1'b0;
                                branch_spec_target = pc0 + 4;
                                case (op0)
                                    OP_BR: begin
                                        branch_spec_taken = 1'b1;
                                        branch_spec_target = alu_dispatch0_s0_ready ? alu_dispatch0_s0_val : bp_predict_target;
                                    end
                                    OP_BRR_R: begin
                                        branch_spec_taken = 1'b1;
                                        branch_spec_target = alu_dispatch0_s0_ready ? (pc0 + alu_dispatch0_s0_val) : bp_predict_target;
                                    end
                                    OP_BRR_L: begin
                                        branch_spec_taken = 1'b1;
                                        branch_spec_target = pc0 + signext12(imm0);
                                    end
                                    OP_BRNZ, OP_BRGT: begin
                                        branch_spec_taken = bp_predict_taken;
                                        branch_spec_target = bp_predict_taken ?
                                            (alu_dispatch0_s0_ready ? alu_dispatch0_s0_val : bp_predict_target) : (pc0 + 4);
                                    end
                                    OP_CALL: begin
                                        branch_spec_taken = 1'b1;
                                        branch_spec_target = alu_dispatch0_s0_ready ? alu_dispatch0_s0_val : bp_predict_target;
                                    end
                                    OP_RET: begin
                                        branch_spec_taken = 1'b1;
                                        branch_spec_target = (ret_sp > 0) ? ret_stack[ret_sp - 1] : bp_predict_target;
                                    end
                                    default: begin
                                    end
                                endcase
                                rob_pred_taken[entry_idx] = branch_spec_taken;
                                rob_pred_target[entry_idx] = branch_spec_target;
                                for (i = 0; i < 32; i = i + 1) begin
                                    checkpoint_rat[i] = rat[i];
                                end
                                checkpoint_ret_sp = ret_sp;
                                speculative_valid = 1'b1;
                                speculative_rob = entry_idx[4:0];
                            end

                            if (!branch_fast_skip0) begin
                                rob_tail = (rob_tail + 1) % ROB_SIZE;
                                rob_count = rob_count + 1;
                            end
                            if (is_control_op(op0)) begin
                                if (branch_fast_resolve0) begin
                                    fetch_pc = branch_fast_taken0 ? branch_fast_target0 : (pc0 + 4);
                                    if (branch_fast_taken0 && (fetch_line_base[63:6] != branch_fast_target0[63:6])) fetch_line_valid = 1'b0;
                                end else begin
                                    fetch_pc = branch_spec_taken ? branch_spec_target : (pc0 + 4);
                                    if (branch_spec_taken && (fetch_line_base[63:6] != branch_spec_target[63:6])) fetch_line_valid = 1'b0;
                                end
                            end else begin
                                fetch_pc = fetch_pc + 4;
                            end

                            allow_issue_lane1 = !is_control_op(op0) ||
                                ((branch_fast_resolve0 ? (branch_fast_taken0 ? branch_fast_target0 : (pc0 + 4)) :
                                    (branch_spec_taken ? branch_spec_target : (pc0 + 4))) == (pc0 + 4));

                            if (!control_stall && word_idx0 != 4'd15 && allow_issue_lane1 && (rob_count < ROB_SIZE)) begin
                                inst1 = fetch_words[word_idx1];
                                op1 = inst1[31:27];
                                rd1 = inst1[26:22];
                                rs1 = inst1[21:17];
                                rt1 = inst1[16:12];
                                imm1 = inst1[11:0];
                                pc1 = pc0 + 4;

                                if (is_control_op(op1) && speculative_valid) begin
                                    control_stall = 1'b1;
                                end else if ((!writes_dest(op1) || (free_count > 0)) &&
                                    (!uses_alu_rs(op1) || (free_rs_slots > 0)) &&
                                    (!is_fpu_op(op1) || (free_fp_slots > 0))) begin
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
                                    rob_pred_taken[entry_idx] = 1'b0;
                                    rob_pred_target[entry_idx] = pc1 + 4;

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
                                        rob_phys_dest[entry_idx] = 7'b0;
                                        rob_old_phys[entry_idx] = 7'b0;
                                    end

                                    if (uses_alu_rs(op1)) begin
                                        alu_dispatch1_valid = 1'b1;
                                        alu_dispatch1_op = op1;
                                        alu_dispatch1_rob = entry_idx[4:0];
                                        alu_dispatch1_has_dest = writes_dest(op1);
                                        alu_dispatch1_dest = rob_phys_dest[entry_idx];
                                        alu_dispatch1_imm = imm1;
                                        alu_dispatch1_pc = pc1;
                                        alu_dispatch1_s0_ready = 1'b0;
                                        alu_dispatch1_s1_ready = 1'b0;
                                        alu_dispatch1_s2_ready = 1'b0;

                                        case (op1)
                                            OP_ADDI, OP_SUBI: begin
                                                if (rs1 != 0) begin
                                                    map_src1 = (writes_dest(op1) && (rs1 == rd1)) ? rob_old_phys[entry_idx] :
                                                        ((writes_dest(op0) && (rs1 == rd0)) ? rob_phys_dest[rob_tail == 0 ? ROB_SIZE - 1 : rob_tail - 1] : rat[rs1]);
                                                end else begin
                                                    map_src1 = rob_old_phys[entry_idx];
                                                end
                                                alu_dispatch1_s0_tag = map_src1;
                                                alu_dispatch1_s0_ready = phys_ready[map_src1];
                                                alu_dispatch1_s0_val = phys_value[map_src1];
                                                alu_dispatch1_s1_ready = 1'b1;
                                                alu_dispatch1_s1_val = imm_operand(op1, imm1);
                                            end
                                            OP_SHFTRI, OP_SHFTLI: begin
                                                map_src1 = rob_old_phys[entry_idx];
                                                alu_dispatch1_s0_tag = map_src1;
                                                alu_dispatch1_s0_ready = phys_ready[map_src1];
                                                alu_dispatch1_s0_val = phys_value[map_src1];
                                                alu_dispatch1_s1_ready = 1'b1;
                                                alu_dispatch1_s1_val = imm_operand(op1, imm1);
                                            end
                                            OP_MOV_L: begin
                                                map_src1 = rob_old_phys[entry_idx];
                                                alu_dispatch1_s0_tag = map_src1;
                                                alu_dispatch1_s0_ready = phys_ready[map_src1];
                                                alu_dispatch1_s0_val = phys_value[map_src1];
                                                alu_dispatch1_s1_ready = 1'b1;
                                                alu_dispatch1_s1_val = imm_operand(op1, imm1);
                                            end
                                            OP_MOV_RR, OP_NOT: begin
                                                map_src1 = (writes_dest(op1) && (rs1 == rd1)) ? rob_old_phys[entry_idx] :
                                                    ((writes_dest(op0) && (rs1 == rd0)) ? rob_phys_dest[rob_tail == 0 ? ROB_SIZE - 1 : rob_tail - 1] : rat[rs1]);
                                                alu_dispatch1_s0_tag = map_src1;
                                                alu_dispatch1_s0_ready = phys_ready[map_src1];
                                                alu_dispatch1_s0_val = phys_value[map_src1];
                                                alu_dispatch1_s1_ready = 1'b1;
                                                alu_dispatch1_s1_val = 64'b0;
                                            end
                                            OP_BR, OP_BRR_R, OP_CALL: begin
                                                map_src1 = (writes_dest(op0) && (rd1 == rd0)) ? rob_phys_dest[rob_tail == 0 ? ROB_SIZE - 1 : rob_tail - 1] : rat[rd1];
                                                alu_dispatch1_s0_tag = map_src1;
                                                alu_dispatch1_s0_ready = phys_ready[map_src1];
                                                alu_dispatch1_s0_val = phys_value[map_src1];
                                            end
                                            OP_BRR_L: begin
                                                alu_dispatch1_s0_ready = 1'b1;
                                                alu_dispatch1_s0_val = 64'b0;
                                            end
                                            OP_BRNZ: begin
                                                map_src1 = (writes_dest(op0) && (rd1 == rd0)) ? rob_phys_dest[rob_tail == 0 ? ROB_SIZE - 1 : rob_tail - 1] : rat[rd1];
                                                alu_dispatch1_s0_tag = map_src1;
                                                alu_dispatch1_s0_ready = phys_ready[map_src1];
                                                alu_dispatch1_s0_val = phys_value[map_src1];
                                                if (writes_dest(op0) && (rs1 == rd0) && op0_forward_valid) begin
                                                    alu_dispatch1_s1_tag = rob_phys_dest[rob_tail == 0 ? ROB_SIZE - 1 : rob_tail - 1];
                                                    alu_dispatch1_s1_ready = 1'b1;
                                                    alu_dispatch1_s1_val = op0_forward_value;
                                                end else begin
                                                    map_src1 = (writes_dest(op0) && (rs1 == rd0)) ? rob_phys_dest[rob_tail == 0 ? ROB_SIZE - 1 : rob_tail - 1] : rat[rs1];
                                                    alu_dispatch1_s1_tag = map_src1;
                                                    alu_dispatch1_s1_ready = phys_ready[map_src1];
                                                    alu_dispatch1_s1_val = phys_value[map_src1];
                                                end
                                            end
                                            OP_BRGT: begin
                                                map_src1 = (writes_dest(op0) && (rd1 == rd0)) ? rob_phys_dest[rob_tail == 0 ? ROB_SIZE - 1 : rob_tail - 1] : rat[rd1];
                                                alu_dispatch1_s0_tag = map_src1;
                                                alu_dispatch1_s0_ready = phys_ready[map_src1];
                                                alu_dispatch1_s0_val = phys_value[map_src1];
                                                if (writes_dest(op0) && (rs1 == rd0) && op0_forward_valid) begin
                                                    alu_dispatch1_s1_tag = rob_phys_dest[rob_tail == 0 ? ROB_SIZE - 1 : rob_tail - 1];
                                                    alu_dispatch1_s1_ready = 1'b1;
                                                    alu_dispatch1_s1_val = op0_forward_value;
                                                end else begin
                                                    map_src1 = (writes_dest(op0) && (rs1 == rd0)) ? rob_phys_dest[rob_tail == 0 ? ROB_SIZE - 1 : rob_tail - 1] : rat[rs1];
                                                    alu_dispatch1_s1_tag = map_src1;
                                                    alu_dispatch1_s1_ready = phys_ready[map_src1];
                                                    alu_dispatch1_s1_val = phys_value[map_src1];
                                                end
                                                map_src1 = (writes_dest(op0) && (rt1 == rd0)) ? rob_phys_dest[rob_tail == 0 ? ROB_SIZE - 1 : rob_tail - 1] : rat[rt1];
                                                alu_dispatch1_s2_tag = map_src1;
                                                alu_dispatch1_s2_ready = phys_ready[map_src1];
                                                alu_dispatch1_s2_val = phys_value[map_src1];
                                            end
                                            default: begin
                                                map_src1 = (writes_dest(op1) && (rs1 == rd1)) ? rob_old_phys[entry_idx] :
                                                    ((writes_dest(op0) && (rs1 == rd0)) ? rob_phys_dest[rob_tail == 0 ? ROB_SIZE - 1 : rob_tail - 1] : rat[rs1]);
                                                alu_dispatch1_s0_tag = map_src1;
                                                alu_dispatch1_s0_ready = phys_ready[map_src1];
                                                alu_dispatch1_s0_val = phys_value[map_src1];
                                                map_src1 = (writes_dest(op1) && (rt1 == rd1)) ? rob_old_phys[entry_idx] :
                                                    ((writes_dest(op0) && (rt1 == rd0)) ? rob_phys_dest[rob_tail == 0 ? ROB_SIZE - 1 : rob_tail - 1] : rat[rt1]);
                                                alu_dispatch1_s1_tag = map_src1;
                                                alu_dispatch1_s1_ready = phys_ready[map_src1];
                                                alu_dispatch1_s1_val = phys_value[map_src1];
                                            end
                                        endcase
                                        if ((op1 == OP_BR) && alu_dispatch1_s0_ready) begin
                                            branch_fast_resolve1 = 1'b1;
                                            branch_fast_taken1 = 1'b1;
                                            branch_fast_target1 = alu_dispatch1_s0_val;
                                        end else if ((op1 == OP_BRR_R) && alu_dispatch1_s0_ready) begin
                                            branch_fast_resolve1 = 1'b1;
                                            branch_fast_taken1 = 1'b1;
                                            branch_fast_target1 = pc1 + alu_dispatch1_s0_val;
                                        end else if (op1 == OP_BRR_L) begin
                                            branch_fast_resolve1 = 1'b1;
                                            branch_fast_taken1 = 1'b1;
                                            branch_fast_target1 = pc1 + signext12(imm1);
                                        end else if ((op1 == OP_BRNZ) && alu_dispatch1_s0_ready && alu_dispatch1_s1_ready) begin
                                            branch_fast_resolve1 = 1'b1;
                                            branch_fast_taken1 = (alu_dispatch1_s1_val != 0);
                                            branch_fast_target1 = alu_dispatch1_s0_val;
                                        end else if ((op1 == OP_BRGT) && alu_dispatch1_s0_ready && alu_dispatch1_s1_ready && alu_dispatch1_s2_ready) begin
                                            branch_fast_resolve1 = 1'b1;
                                            branch_fast_taken1 = (alu_dispatch1_s1_val > alu_dispatch1_s2_val);
                                            branch_fast_target1 = alu_dispatch1_s0_val;
                                        end
                                        if (branch_fast_resolve1) begin
                                            alu_dispatch1_valid = 1'b0;
                                            branch_fast_skip1 = (op1 == OP_BR) || (op1 == OP_BRR_R) ||
                                                (op1 == OP_BRR_L) || (op1 == OP_BRNZ) || (op1 == OP_BRGT);
                                            if (!branch_fast_skip1) begin
                                                rob_branch_done[entry_idx] = 1'b1;
                                                rob_taken[entry_idx] = branch_fast_taken1;
                                                rob_target[entry_idx] = branch_fast_target1;
                                                rob_ready[entry_idx] = 1'b1;
                                            end else begin
                                                rob_valid[entry_idx] = 1'b0;
                                                rob_ready[entry_idx] = 1'b0;
                                                rob_branch_done[entry_idx] = 1'b0;
                                            end
                                            bp_update_en = 1'b1;
                                            bp_update_pc = pc1;
                                            bp_update_taken = branch_fast_taken1;
                                            bp_update_target = branch_fast_target1;
                                        end else begin
                                        free_rs_slots = free_rs_slots - 1;
                                        end
                                    end else if (is_fpu_op(op1)) begin
                                        map_src1 = (writes_dest(op1) && (rs1 == rd1)) ? rob_old_phys[entry_idx] :
                                            ((writes_dest(op0) && (rs1 == rd0)) ? rob_phys_dest[rob_tail == 0 ? ROB_SIZE - 1 : rob_tail - 1] : rat[rs1]);
                                        map_src = (writes_dest(op1) && (rt1 == rd1)) ? rob_old_phys[entry_idx] :
                                            ((writes_dest(op0) && (rt1 == rd0)) ? rob_phys_dest[rob_tail == 0 ? ROB_SIZE - 1 : rob_tail - 1] : rat[rt1]);
                                        fpu_dispatch1_valid = 1'b1;
                                        fpu_dispatch1_op = op1;
                                        fpu_dispatch1_rob = entry_idx[4:0];
                                        fpu_dispatch1_dest = rob_phys_dest[entry_idx];
                                        fpu_dispatch1_s0_tag = map_src1;
                                        fpu_dispatch1_s0_ready = phys_ready[map_src1];
                                        fpu_dispatch1_s0_val = phys_value[map_src1];
                                        fpu_dispatch1_s1_tag = map_src;
                                        fpu_dispatch1_s1_ready = phys_ready[map_src];
                                        fpu_dispatch1_s1_val = phys_value[map_src];
                                        free_fp_slots = free_fp_slots - 1;
                                    end

                                    if (uses_lsq(op1)) begin
                                        lsq_dispatch1_valid = 1'b1;
                                        lsq_dispatch1_rob = entry_idx[4:0];
                                        lsq_dispatch1_op = op1;
                                        lsq_dispatch1_has_dest = writes_dest(op1);
                                        lsq_dispatch1_dest = rob_phys_dest[entry_idx];
                                        lsq_dispatch1_imm = imm1;
                                        lsq_dispatch1_pc = pc1;
                                        if (op1 == OP_MOV_ML) begin
                                            map_src1 = (writes_dest(op1) && (rs1 == rd1)) ? rob_old_phys[entry_idx] :
                                                ((writes_dest(op0) && (rs1 == rd0)) ? rob_phys_dest[rob_tail == 0 ? ROB_SIZE - 1 : rob_tail - 1] : rat[rs1]);
                                            lsq_dispatch1_addr_tag = map_src1;
                                            lsq_dispatch1_addr_ready = phys_ready[map_src1];
                                            lsq_dispatch1_addr_val = phys_value[map_src1];
                                            lsq_dispatch1_data_ready = 1'b0;
                                        end else if (op1 == OP_MOV_SM) begin
                                            map_src1 = (writes_dest(op0) && (rd1 == rd0)) ? rob_phys_dest[rob_tail == 0 ? ROB_SIZE - 1 : rob_tail - 1] : rat[rd1];
                                            lsq_dispatch1_addr_tag = map_src1;
                                            lsq_dispatch1_addr_ready = phys_ready[map_src1];
                                            lsq_dispatch1_addr_val = phys_value[map_src1];
                                            map_src1 = (writes_dest(op0) && (rs1 == rd0)) ? rob_phys_dest[rob_tail == 0 ? ROB_SIZE - 1 : rob_tail - 1] : rat[rs1];
                                            lsq_dispatch1_data_tag = map_src1;
                                            lsq_dispatch1_data_ready = phys_ready[map_src1];
                                            lsq_dispatch1_data_val = phys_value[map_src1];
                                        end else if (op1 == OP_CALL) begin
                                            map_src1 = rat[31];
                                            lsq_dispatch1_addr_tag = map_src1;
                                            lsq_dispatch1_addr_ready = phys_ready[map_src1];
                                            lsq_dispatch1_addr_val = phys_value[map_src1];
                                            lsq_dispatch1_data_ready = 1'b1;
                                            lsq_dispatch1_data_val = pc1 + 4;
                                        end else if (op1 == OP_RET) begin
                                            map_src1 = rat[31];
                                            lsq_dispatch1_addr_tag = map_src1;
                                            lsq_dispatch1_addr_ready = phys_ready[map_src1];
                                            lsq_dispatch1_addr_val = phys_value[map_src1];
                                            lsq_dispatch1_data_ready = 1'b0;
                                        end
                                        if (((op1 == OP_MOV_SM) || (op1 == OP_CALL)) && !fast_exec_valid_dbg) begin
                                            fast_exec_valid_dbg = 1'b1;
                                            fast_exec_opcode_dbg = op1;
                                        end
                                    end
                                    if (op1 == OP_CALL && ret_sp < 16) begin
                                        ret_stack[ret_sp] = pc1 + 4;
                                        ret_sp = ret_sp + 1;
                                    end

                                    if (is_control_op(op1) && (op1 != OP_PRIV) && !speculative_valid && !branch_fast_resolve1) begin
                                        branch_start_spec = 1'b1;
                                        branch_spec_rob = entry_idx[4:0];
                                        branch_spec_taken = 1'b0;
                                        branch_spec_target = pc1 + 4;
                                        case (op1)
                                            OP_BR: begin
                                                branch_spec_taken = 1'b1;
                                                branch_spec_target = alu_dispatch1_s0_ready ? alu_dispatch1_s0_val : bp_predict_target1;
                                            end
                                            OP_BRR_R: begin
                                                branch_spec_taken = 1'b1;
                                                branch_spec_target = alu_dispatch1_s0_ready ? (pc1 + alu_dispatch1_s0_val) : bp_predict_target1;
                                            end
                                            OP_BRR_L: begin
                                                branch_spec_taken = 1'b1;
                                                branch_spec_target = pc1 + signext12(imm1);
                                            end
                                            OP_BRNZ, OP_BRGT: begin
                                                branch_spec_taken = bp_predict_taken1;
                                                branch_spec_target = bp_predict_taken1 ?
                                                    (alu_dispatch1_s0_ready ? alu_dispatch1_s0_val : bp_predict_target1) : (pc1 + 4);
                                            end
                                            OP_CALL: begin
                                                branch_spec_taken = 1'b1;
                                                branch_spec_target = alu_dispatch1_s0_ready ? alu_dispatch1_s0_val : bp_predict_target1;
                                            end
                                            OP_RET: begin
                                                branch_spec_taken = 1'b1;
                                                branch_spec_target = (ret_sp > 0) ? ret_stack[ret_sp - 1] : bp_predict_target1;
                                            end
                                            default: begin
                                            end
                                        endcase
                                        rob_pred_taken[entry_idx] = branch_spec_taken;
                                        rob_pred_target[entry_idx] = branch_spec_target;
                                        for (i = 0; i < 32; i = i + 1) begin
                                            checkpoint_rat[i] = rat[i];
                                        end
                                        checkpoint_ret_sp = ret_sp;
                                        speculative_valid = 1'b1;
                                        speculative_rob = entry_idx[4:0];
                                    end

                                    if (!branch_fast_skip1) begin
                                        rob_tail = (rob_tail + 1) % ROB_SIZE;
                                        rob_count = rob_count + 1;
                                    end
                                    if (is_control_op(op1)) begin
                                        if (branch_fast_resolve1) begin
                                            fetch_pc = branch_fast_taken1 ? branch_fast_target1 : (pc1 + 4);
                                            if (branch_fast_taken1 && (fetch_line_base[63:6] != branch_fast_target1[63:6])) fetch_line_valid = 1'b0;
                                        end else begin
                                            fetch_pc = branch_spec_taken ? branch_spec_target : (pc1 + 4);
                                            if (branch_spec_taken && (fetch_line_base[63:6] != branch_spec_target[63:6])) fetch_line_valid = 1'b0;
                                        end
                                    end else begin
                                        fetch_pc = fetch_pc + 4;
                                    end;
                                end
                            end
                        end
                    end
                end
            end
        end
    end
endmodule
