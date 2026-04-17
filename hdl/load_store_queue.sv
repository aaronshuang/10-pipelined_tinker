`include "hdl/tinker_defs.svh"

module load_store_queue (
    input clk,
    input reset,
    input [63:0] live_ready,
    input [4095:0] live_values,
    input [4:0] rob_head,
    input dispatch0_valid,
    input [4:0] dispatch0_rob,
    input [4:0] dispatch0_op,
    input dispatch0_has_dest,
    input [5:0] dispatch0_dest,
    input dispatch0_addr_ready,
    input [5:0] dispatch0_addr_tag,
    input [63:0] dispatch0_addr_val,
    input dispatch0_data_ready,
    input [5:0] dispatch0_data_tag,
    input [63:0] dispatch0_data_val,
    input [11:0] dispatch0_imm,
    input [63:0] dispatch0_pc,
    input dispatch1_valid,
    input [4:0] dispatch1_rob,
    input [4:0] dispatch1_op,
    input dispatch1_has_dest,
    input [5:0] dispatch1_dest,
    input dispatch1_addr_ready,
    input [5:0] dispatch1_addr_tag,
    input [63:0] dispatch1_addr_val,
    input dispatch1_data_ready,
    input [5:0] dispatch1_data_tag,
    input [63:0] dispatch1_data_val,
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
    input flush_en,
    input [4:0] flush_rob,
    input [4:0] flush_tail,
    input clear_en0,
    input [4:0] clear_idx0,
    input clear_en1,
    input [4:0] clear_idx1,
    input issue_take0,
    input issue_take1,
    input [4:0] commit_idx,
    output reg [15:0] store_ready_bus,
    output reg issue_valid0,
    output reg [4:0] issue_rob0,
    output reg [4:0] issue_op0,
    output reg issue_has_dest0,
    output reg [5:0] issue_dest0,
    output reg [63:0] issue_addr0,
    output reg issue_forward_hit0,
    output reg [63:0] issue_forward_data0,
    output reg [4:0] issue_idx0,
    output reg issue_valid1,
    output reg [4:0] issue_rob1,
    output reg [4:0] issue_op1,
    output reg issue_has_dest1,
    output reg [5:0] issue_dest1,
    output reg [63:0] issue_addr1,
    output reg issue_forward_hit1,
    output reg [63:0] issue_forward_data1,
    output reg [4:0] issue_idx1,
    output reg [63:0] commit_addr,
    output reg [63:0] commit_data
);
    localparam SIZE = 16;
    reg valid [0:SIZE - 1];
    reg issued [0:SIZE - 1];
    reg [4:0] op [0:SIZE - 1];
    reg has_dest [0:SIZE - 1];
    reg [5:0] dest [0:SIZE - 1];
    reg addr_ready [0:SIZE - 1];
    reg [5:0] addr_tag [0:SIZE - 1];
    reg [63:0] addr_val [0:SIZE - 1];
    reg data_ready [0:SIZE - 1];
    reg [5:0] data_tag [0:SIZE - 1];
    reg [63:0] data_val [0:SIZE - 1];
    reg [11:0] imm [0:SIZE - 1];
    reg [63:0] pc [0:SIZE - 1];
    integer i;
    integer k;
    integer issue0_idx;
    integer issue1_idx;
    integer dc;
    integer du;
    reg can_issue;
    reg forward_found;
    reg [63:0] forward_value;

    function [63:0] signext12;
        input [11:0] imm_in;
        begin
            signext12 = {{52{imm_in[11]}}, imm_in};
        end
    endfunction

    function [63:0] effective_addr;
        input integer idx;
        begin
            effective_addr = live_src_value(addr_ready[idx], addr_val[idx], addr_tag[idx]) +
                ((op[idx] == `OP_CALL || op[idx] == `OP_RET) ? 64'hfffffffffffffff8 : signext12(imm[idx]));
        end
    endfunction

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

    function older_than;
        input integer cand;
        input integer cur;
        begin
            dc = cand - rob_head;
            du = cur - rob_head;
            if (dc < 0) dc = dc + SIZE;
            if (du < 0) du = du + SIZE;
            older_than = (dc < du);
        end
    endfunction

    function younger_than_flush;
        input integer rob_idx;
        begin
            dc = rob_idx - flush_rob;
            du = flush_tail - flush_rob;
            if (dc < 0) dc = dc + SIZE;
            if (du < 0) du = du + SIZE;
            younger_than_flush = (dc > 0) && (dc < du);
        end
    endfunction

    task wake_entry;
        input integer idx;
        input [5:0] wake_tag;
        input [63:0] wake_val;
        begin
            if (valid[idx] && !addr_ready[idx] && (addr_tag[idx] == wake_tag)) begin
                addr_ready[idx] <= 1'b1;
                addr_val[idx] <= wake_val;
            end
            if (valid[idx] && !data_ready[idx] && (data_tag[idx] == wake_tag)) begin
                data_ready[idx] <= 1'b1;
                data_val[idx] <= wake_val;
            end
        end
    endtask

    always @(*) begin
        for (i = 0; i < SIZE; i = i + 1) begin
            store_ready_bus[i] = valid[i] && ((op[i] == `OP_MOV_SM) || (op[i] == `OP_CALL)) &&
                live_src_ready(addr_ready[i], addr_tag[i]) && live_src_ready(data_ready[i], data_tag[i]);
        end

        issue0_idx = -1;
        issue1_idx = -1;
        issue_forward_hit0 = 1'b0;
        issue_forward_hit1 = 1'b0;
        issue_forward_data0 = 64'b0;
        issue_forward_data1 = 64'b0;

        for (i = 0; i < SIZE; i = i + 1) begin
            if (valid[i] && !issued[i] && ((op[i] == `OP_MOV_ML) || (op[i] == `OP_RET)) && live_src_ready(addr_ready[i], addr_tag[i])) begin
                can_issue = 1;
                forward_found = 0;
                forward_value = 64'b0;
                for (k = 0; k < SIZE; k = k + 1) begin
                    if (valid[k] && ((op[k] == `OP_MOV_SM) || (op[k] == `OP_CALL)) && older_than(k, i)) begin
                        if (!live_src_ready(addr_ready[k], addr_tag[k])) can_issue = 0;
                        else if (effective_addr(k) == effective_addr(i)) begin
                            if (!live_src_ready(data_ready[k], data_tag[k])) can_issue = 0;
                            else begin
                                forward_found = 1;
                                forward_value = live_src_value(data_ready[k], data_val[k], data_tag[k]);
                            end
                        end
                    end
                end
                if (can_issue) begin
                    if (issue0_idx == -1) begin
                        issue0_idx = i;
                        issue_forward_hit0 = forward_found;
                        issue_forward_data0 = forward_value;
                    end else if (issue1_idx == -1) begin
                        issue1_idx = i;
                        issue_forward_hit1 = forward_found;
                        issue_forward_data1 = forward_value;
                    end
                end
            end
        end

        issue_valid0 = (issue0_idx != -1);
        issue_idx0 = (issue0_idx != -1) ? issue0_idx[4:0] : 5'b0;
        issue_rob0 = (issue0_idx != -1) ? issue0_idx[4:0] : 5'b0;
        issue_op0 = (issue0_idx != -1) ? op[issue0_idx] : 5'b0;
        issue_has_dest0 = (issue0_idx != -1) ? has_dest[issue0_idx] : 1'b0;
        issue_dest0 = (issue0_idx != -1) ? dest[issue0_idx] : 6'b0;
        issue_addr0 = (issue0_idx != -1) ? effective_addr(issue0_idx) : 64'b0;

        issue_valid1 = (issue1_idx != -1);
        issue_idx1 = (issue1_idx != -1) ? issue1_idx[4:0] : 5'b0;
        issue_rob1 = (issue1_idx != -1) ? issue1_idx[4:0] : 5'b0;
        issue_op1 = (issue1_idx != -1) ? op[issue1_idx] : 5'b0;
        issue_has_dest1 = (issue1_idx != -1) ? has_dest[issue1_idx] : 1'b0;
        issue_dest1 = (issue1_idx != -1) ? dest[issue1_idx] : 6'b0;
        issue_addr1 = (issue1_idx != -1) ? effective_addr(issue1_idx) : 64'b0;

        commit_addr = valid[commit_idx] ? effective_addr(commit_idx) : 64'b0;
        commit_data = valid[commit_idx] ? live_src_value(data_ready[commit_idx], data_val[commit_idx], data_tag[commit_idx]) : 64'b0;
    end

    always @(posedge clk) begin
        if (reset) begin
            for (i = 0; i < SIZE; i = i + 1) begin
                valid[i] <= 1'b0;
                issued[i] <= 1'b0;
                op[i] <= 5'b0;
                has_dest[i] <= 1'b0;
                dest[i] <= 6'b0;
                addr_ready[i] <= 1'b0;
                addr_tag[i] <= 6'b0;
                addr_val[i] <= 64'b0;
                data_ready[i] <= 1'b0;
                data_tag[i] <= 6'b0;
                data_val[i] <= 64'b0;
                imm[i] <= 12'b0;
                pc[i] <= 64'b0;
            end
        end else begin
            if (flush_en) begin
                for (i = 0; i < SIZE; i = i + 1) begin
                    if (valid[i] && younger_than_flush(i)) begin
                        valid[i] <= 1'b0;
                        issued[i] <= 1'b0;
                    end
                end
            end
            if (clear_en0) begin
                valid[clear_idx0] <= 1'b0;
                issued[clear_idx0] <= 1'b0;
            end
            if (clear_en1) begin
                valid[clear_idx1] <= 1'b0;
                issued[clear_idx1] <= 1'b0;
            end
            if (issue_take0) issued[issue_idx0] <= 1'b1;
            if (issue_take1) issued[issue_idx1] <= 1'b1;

            for (i = 0; i < SIZE; i = i + 1) begin
                if (cdb0_en) wake_entry(i, cdb0_tag, cdb0_val);
                if (cdb1_en) wake_entry(i, cdb1_tag, cdb1_val);
                if (cdb2_en) wake_entry(i, cdb2_tag, cdb2_val);
                if (cdb3_en) wake_entry(i, cdb3_tag, cdb3_val);
                if (cdb4_en) wake_entry(i, cdb4_tag, cdb4_val);
                if (cdb5_en) wake_entry(i, cdb5_tag, cdb5_val);
            end

            if (dispatch0_valid) begin
                valid[dispatch0_rob] <= 1'b1;
                issued[dispatch0_rob] <= 1'b0;
                op[dispatch0_rob] <= dispatch0_op;
                has_dest[dispatch0_rob] <= dispatch0_has_dest;
                dest[dispatch0_rob] <= dispatch0_dest;
                addr_ready[dispatch0_rob] <= dispatch0_addr_ready;
                addr_tag[dispatch0_rob] <= dispatch0_addr_tag;
                addr_val[dispatch0_rob] <= dispatch0_addr_val;
                data_ready[dispatch0_rob] <= dispatch0_data_ready;
                data_tag[dispatch0_rob] <= dispatch0_data_tag;
                data_val[dispatch0_rob] <= dispatch0_data_val;
                imm[dispatch0_rob] <= dispatch0_imm;
                pc[dispatch0_rob] <= dispatch0_pc;
            end

            if (dispatch1_valid) begin
                valid[dispatch1_rob] <= 1'b1;
                issued[dispatch1_rob] <= 1'b0;
                op[dispatch1_rob] <= dispatch1_op;
                has_dest[dispatch1_rob] <= dispatch1_has_dest;
                dest[dispatch1_rob] <= dispatch1_dest;
                addr_ready[dispatch1_rob] <= dispatch1_addr_ready;
                addr_tag[dispatch1_rob] <= dispatch1_addr_tag;
                addr_val[dispatch1_rob] <= dispatch1_addr_val;
                data_ready[dispatch1_rob] <= dispatch1_data_ready;
                data_tag[dispatch1_rob] <= dispatch1_data_tag;
                data_val[dispatch1_rob] <= dispatch1_data_val;
                imm[dispatch1_rob] <= dispatch1_imm;
                pc[dispatch1_rob] <= dispatch1_pc;
            end
        end
    end
endmodule
