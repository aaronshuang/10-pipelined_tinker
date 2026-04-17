`include "hdl/tinker_defs.svh"

module alu_reservation_station (
    input clk,
    input reset,
    input [63:0] live_ready,
    input [4095:0] live_values,
    input dispatch0_valid,
    input [4:0] dispatch0_op,
    input [4:0] dispatch0_rob,
    input dispatch0_has_dest,
    input [5:0] dispatch0_dest,
    input dispatch0_s0_ready,
    input [5:0] dispatch0_s0_tag,
    input [63:0] dispatch0_s0_val,
    input dispatch0_s1_ready,
    input [5:0] dispatch0_s1_tag,
    input [63:0] dispatch0_s1_val,
    input dispatch0_s2_ready,
    input [5:0] dispatch0_s2_tag,
    input [63:0] dispatch0_s2_val,
    input [11:0] dispatch0_imm,
    input [63:0] dispatch0_pc,
    input dispatch1_valid,
    input [4:0] dispatch1_op,
    input [4:0] dispatch1_rob,
    input dispatch1_has_dest,
    input [5:0] dispatch1_dest,
    input dispatch1_s0_ready,
    input [5:0] dispatch1_s0_tag,
    input [63:0] dispatch1_s0_val,
    input dispatch1_s1_ready,
    input [5:0] dispatch1_s1_tag,
    input [63:0] dispatch1_s1_val,
    input dispatch1_s2_ready,
    input [5:0] dispatch1_s2_tag,
    input [63:0] dispatch1_s2_val,
    input [11:0] dispatch1_imm,
    input [63:0] dispatch1_pc,
    input cdb0_en,
    input [5:0] cdb0_tag,
    input [63:0] cdb0_val,
    input cdb1_en,
    input [5:0] cdb1_tag,
    input [63:0] cdb1_val,
    input cdb2_en,
    input [5:0] cdb2_tag,
    input [63:0] cdb2_val,
    input cdb3_en,
    input [5:0] cdb3_tag,
    input [63:0] cdb3_val,
    input cdb4_en,
    input [5:0] cdb4_tag,
    input [63:0] cdb4_val,
    input cdb5_en,
    input [5:0] cdb5_tag,
    input [63:0] cdb5_val,
    input issue_take0,
    input issue_take1,
    output reg [3:0] free_count,
    output reg issue_valid0,
    output reg [4:0] issue_op0,
    output reg [4:0] issue_rob0,
    output reg issue_has_dest0,
    output reg [5:0] issue_dest0,
    output reg [63:0] issue_s0_val0,
    output reg [63:0] issue_s1_val0,
    output reg [63:0] issue_s2_val0,
    output reg [11:0] issue_imm0,
    output reg [63:0] issue_pc0,
    output reg [2:0] issue_idx0,
    output reg issue_valid1,
    output reg [4:0] issue_op1,
    output reg [4:0] issue_rob1,
    output reg issue_has_dest1,
    output reg [5:0] issue_dest1,
    output reg [63:0] issue_s0_val1,
    output reg [63:0] issue_s1_val1,
    output reg [63:0] issue_s2_val1,
    output reg [11:0] issue_imm1,
    output reg [63:0] issue_pc1,
    output reg [2:0] issue_idx1
);
    localparam SIZE = 8;

    reg valid [0:SIZE - 1];
    reg [4:0] op [0:SIZE - 1];
    reg [4:0] rob [0:SIZE - 1];
    reg has_dest [0:SIZE - 1];
    reg [5:0] dest [0:SIZE - 1];
    reg s0_ready [0:SIZE - 1];
    reg s1_ready [0:SIZE - 1];
    reg s2_ready [0:SIZE - 1];
    reg [5:0] s0_tag [0:SIZE - 1];
    reg [5:0] s1_tag [0:SIZE - 1];
    reg [5:0] s2_tag [0:SIZE - 1];
    reg [63:0] s0_val [0:SIZE - 1];
    reg [63:0] s1_val [0:SIZE - 1];
    reg [63:0] s2_val [0:SIZE - 1];
    reg [11:0] imm [0:SIZE - 1];
    reg [63:0] pc [0:SIZE - 1];

    integer i;
    integer free0_idx;
    integer free1_idx;
    integer issue0_idx;
    integer issue1_idx;

    function live_src_ready;
        input in_ready;
        input [5:0] in_tag;
        begin
            live_src_ready = in_ready || live_ready[in_tag];
        end
    endfunction

    function [63:0] live_src_value;
        input in_ready;
        input [63:0] in_value;
        input [5:0] in_tag;
        begin
            if (in_ready) live_src_value = in_value;
            else live_src_value = live_values[(in_tag * 64) +: 64];
        end
    endfunction

    function ready_for_issue;
        input [4:0] in_op;
        input in_s0_ready;
        input [5:0] in_s0_tag;
        input in_s1_ready;
        input [5:0] in_s1_tag;
        input in_s2_ready;
        input [5:0] in_s2_tag;
        begin
            ready_for_issue = 1'b0;
            if (live_src_ready(in_s0_ready, in_s0_tag)) begin
                if ((in_op == `OP_BR) || (in_op == `OP_BRR_R) || (in_op == `OP_BRR_L) || (in_op == `OP_CALL)) begin
                    ready_for_issue = 1'b1;
                end else if (in_op == `OP_BRNZ) begin
                    ready_for_issue = live_src_ready(in_s1_ready, in_s1_tag);
                end else if (in_op == `OP_BRGT) begin
                    ready_for_issue = live_src_ready(in_s1_ready, in_s1_tag) && live_src_ready(in_s2_ready, in_s2_tag);
                end else if ((in_op == `OP_NOT) || (in_op == `OP_MOV_RR) || live_src_ready(in_s1_ready, in_s1_tag)) begin
                    ready_for_issue = 1'b1;
                end
            end
        end
    endfunction

    task wake_entry;
        input integer idx;
        input [5:0] wake_tag;
        input [63:0] wake_val;
        begin
            if (valid[idx] && !s0_ready[idx] && (s0_tag[idx] == wake_tag)) begin
                s0_ready[idx] <= 1'b1;
                s0_val[idx] <= wake_val;
            end
            if (valid[idx] && !s1_ready[idx] && (s1_tag[idx] == wake_tag)) begin
                s1_ready[idx] <= 1'b1;
                s1_val[idx] <= wake_val;
            end
            if (valid[idx] && !s2_ready[idx] && (s2_tag[idx] == wake_tag)) begin
                s2_ready[idx] <= 1'b1;
                s2_val[idx] <= wake_val;
            end
        end
    endtask

    always @(*) begin
        free_count = 0;
        free0_idx = -1;
        free1_idx = -1;
        issue0_idx = -1;
        issue1_idx = -1;
        for (i = 0; i < SIZE; i = i + 1) begin
            if (!valid[i]) begin
                free_count = free_count + 1;
                if (free0_idx == -1) free0_idx = i;
                else if (free1_idx == -1) free1_idx = i;
            end
            if (valid[i] && ready_for_issue(op[i], s0_ready[i], s0_tag[i], s1_ready[i], s1_tag[i], s2_ready[i], s2_tag[i])) begin
                if (issue0_idx == -1) issue0_idx = i;
                else if (issue1_idx == -1) issue1_idx = i;
            end
        end

        issue_valid0 = (issue0_idx != -1);
        issue_valid1 = (issue1_idx != -1);
        issue_idx0 = (issue0_idx != -1) ? issue0_idx[2:0] : 3'b0;
        issue_idx1 = (issue1_idx != -1) ? issue1_idx[2:0] : 3'b0;

        issue_op0 = (issue0_idx != -1) ? op[issue0_idx] : 5'b0;
        issue_rob0 = (issue0_idx != -1) ? rob[issue0_idx] : 5'b0;
        issue_has_dest0 = (issue0_idx != -1) ? has_dest[issue0_idx] : 1'b0;
        issue_dest0 = (issue0_idx != -1) ? dest[issue0_idx] : 6'b0;
        issue_s0_val0 = (issue0_idx != -1) ? live_src_value(s0_ready[issue0_idx], s0_val[issue0_idx], s0_tag[issue0_idx]) : 64'b0;
        issue_s1_val0 = (issue0_idx != -1) ? live_src_value(s1_ready[issue0_idx], s1_val[issue0_idx], s1_tag[issue0_idx]) : 64'b0;
        issue_s2_val0 = (issue0_idx != -1) ? live_src_value(s2_ready[issue0_idx], s2_val[issue0_idx], s2_tag[issue0_idx]) : 64'b0;
        issue_imm0 = (issue0_idx != -1) ? imm[issue0_idx] : 12'b0;
        issue_pc0 = (issue0_idx != -1) ? pc[issue0_idx] : 64'b0;

        issue_op1 = (issue1_idx != -1) ? op[issue1_idx] : 5'b0;
        issue_rob1 = (issue1_idx != -1) ? rob[issue1_idx] : 5'b0;
        issue_has_dest1 = (issue1_idx != -1) ? has_dest[issue1_idx] : 1'b0;
        issue_dest1 = (issue1_idx != -1) ? dest[issue1_idx] : 6'b0;
        issue_s0_val1 = (issue1_idx != -1) ? live_src_value(s0_ready[issue1_idx], s0_val[issue1_idx], s0_tag[issue1_idx]) : 64'b0;
        issue_s1_val1 = (issue1_idx != -1) ? live_src_value(s1_ready[issue1_idx], s1_val[issue1_idx], s1_tag[issue1_idx]) : 64'b0;
        issue_s2_val1 = (issue1_idx != -1) ? live_src_value(s2_ready[issue1_idx], s2_val[issue1_idx], s2_tag[issue1_idx]) : 64'b0;
        issue_imm1 = (issue1_idx != -1) ? imm[issue1_idx] : 12'b0;
        issue_pc1 = (issue1_idx != -1) ? pc[issue1_idx] : 64'b0;
    end

    always @(posedge clk) begin
        if (reset) begin
            for (i = 0; i < SIZE; i = i + 1) begin
                valid[i] <= 1'b0;
                op[i] <= 5'b0;
                rob[i] <= 5'b0;
                has_dest[i] <= 1'b0;
                dest[i] <= 6'b0;
                s0_ready[i] <= 1'b0;
                s1_ready[i] <= 1'b0;
                s2_ready[i] <= 1'b0;
                s0_tag[i] <= 6'b0;
                s1_tag[i] <= 6'b0;
                s2_tag[i] <= 6'b0;
                s0_val[i] <= 64'b0;
                s1_val[i] <= 64'b0;
                s2_val[i] <= 64'b0;
                imm[i] <= 12'b0;
                pc[i] <= 64'b0;
            end
        end else begin
            if (issue_take0) valid[issue_idx0] <= 1'b0;
            if (issue_take1) valid[issue_idx1] <= 1'b0;

            for (i = 0; i < SIZE; i = i + 1) begin
                if (cdb0_en) wake_entry(i, cdb0_tag, cdb0_val);
                if (cdb1_en) wake_entry(i, cdb1_tag, cdb1_val);
                if (cdb2_en) wake_entry(i, cdb2_tag, cdb2_val);
                if (cdb3_en) wake_entry(i, cdb3_tag, cdb3_val);
                if (cdb4_en) wake_entry(i, cdb4_tag, cdb4_val);
                if (cdb5_en) wake_entry(i, cdb5_tag, cdb5_val);
            end

            if (dispatch0_valid && (free0_idx != -1)) begin
                valid[free0_idx] <= 1'b1;
                op[free0_idx] <= dispatch0_op;
                rob[free0_idx] <= dispatch0_rob;
                has_dest[free0_idx] <= dispatch0_has_dest;
                dest[free0_idx] <= dispatch0_dest;
                s0_ready[free0_idx] <= dispatch0_s0_ready;
                s1_ready[free0_idx] <= dispatch0_s1_ready;
                s2_ready[free0_idx] <= dispatch0_s2_ready;
                s0_tag[free0_idx] <= dispatch0_s0_tag;
                s1_tag[free0_idx] <= dispatch0_s1_tag;
                s2_tag[free0_idx] <= dispatch0_s2_tag;
                s0_val[free0_idx] <= dispatch0_s0_val;
                s1_val[free0_idx] <= dispatch0_s1_val;
                s2_val[free0_idx] <= dispatch0_s2_val;
                imm[free0_idx] <= dispatch0_imm;
                pc[free0_idx] <= dispatch0_pc;
            end

            if (dispatch1_valid && (free1_idx != -1)) begin
                valid[free1_idx] <= 1'b1;
                op[free1_idx] <= dispatch1_op;
                rob[free1_idx] <= dispatch1_rob;
                has_dest[free1_idx] <= dispatch1_has_dest;
                dest[free1_idx] <= dispatch1_dest;
                s0_ready[free1_idx] <= dispatch1_s0_ready;
                s1_ready[free1_idx] <= dispatch1_s1_ready;
                s2_ready[free1_idx] <= dispatch1_s2_ready;
                s0_tag[free1_idx] <= dispatch1_s0_tag;
                s1_tag[free1_idx] <= dispatch1_s1_tag;
                s2_tag[free1_idx] <= dispatch1_s2_tag;
                s0_val[free1_idx] <= dispatch1_s0_val;
                s1_val[free1_idx] <= dispatch1_s1_val;
                s2_val[free1_idx] <= dispatch1_s2_val;
                imm[free1_idx] <= dispatch1_imm;
                pc[free1_idx] <= dispatch1_pc;
            end
        end
    end
endmodule
