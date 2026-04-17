`ifndef TINKER_DEFS_SVH
`define TINKER_DEFS_SVH

`define OP_AND    5'h00
`define OP_OR     5'h01
`define OP_XOR    5'h02
`define OP_NOT    5'h03
`define OP_SHFTR  5'h04
`define OP_SHFTRI 5'h05
`define OP_SHFTL  5'h06
`define OP_SHFTLI 5'h07
`define OP_BR     5'h08
`define OP_BRR_R  5'h09
`define OP_BRR_L  5'h0A
`define OP_BRNZ   5'h0B
`define OP_CALL   5'h0C
`define OP_RET    5'h0D
`define OP_BRGT   5'h0E
`define OP_PRIV   5'h0F
`define OP_MOV_ML 5'h10
`define OP_MOV_RR 5'h11
`define OP_MOV_L  5'h12
`define OP_MOV_SM 5'h13
`define OP_ADDF   5'h14
`define OP_SUBF   5'h15
`define OP_MULF   5'h16
`define OP_DIVF   5'h17
`define OP_ADD    5'h18
`define OP_ADDI   5'h19
`define OP_SUB    5'h1A
`define OP_SUBI   5'h1B
`define OP_MUL    5'h1C
`define OP_DIV    5'h1D

`endif
