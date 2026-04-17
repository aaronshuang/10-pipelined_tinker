module FPU (
    input [63:0] a,
    input [63:0] b,
    input [4:0] op,
    output reg [63:0] res
);
    reg sign_a;
    reg sign_b;
    reg sign_res;
    reg [10:0] exp_a;
    reg [10:0] exp_b;
    reg [10:0] exp_res;
    reg [10:0] eff_exp_a;
    reg [10:0] eff_exp_b;
    reg [55:0] frac_a;
    reg [55:0] frac_b;
    reg [56:0] frac_add_res;
    reg [52:0] m_a;
    reg [52:0] m_b;
    reg signed [12:0] signed_exp;
    reg [106:0] raw_mul_res;
    reg [107:0] div_num;
    reg [56:0] raw_div_res;
    reg [10:0] exp_diff;
    reg [5:0] shift_amt;
    reg [55:0] shift_mask;
    reg [106:0] mul_shift_mask;
    reg G;
    reg R;
    reg S;
    reg LSB;
    reg round_up;
    reg a_is_nan;
    reg b_is_nan;
    reg a_is_inf;
    reg b_is_inf;
    reg a_is_zero;
    reg b_is_zero;
    integer i;

    always @(*) begin
        res = 64'b0;

        sign_a = a[63];
        sign_b = b[63];
        exp_a = a[62:52];
        exp_b = b[62:52];
        eff_exp_a = (exp_a == 0) ? 11'd1 : exp_a;
        eff_exp_b = (exp_b == 0) ? 11'd1 : exp_b;
        frac_a = {(exp_a != 0), a[51:0], 3'b000};
        frac_b = {(exp_b != 0), b[51:0], 3'b000};

        a_is_nan = (exp_a == 11'h7ff) && (a[51:0] != 0);
        b_is_nan = (exp_b == 11'h7ff) && (b[51:0] != 0);
        a_is_inf = (exp_a == 11'h7ff) && (a[51:0] == 0);
        b_is_inf = (exp_b == 11'h7ff) && (b[51:0] == 0);
        a_is_zero = (exp_a == 0) && (a[51:0] == 0);
        b_is_zero = (exp_b == 0) && (b[51:0] == 0);

        case (op)
            5'h14, 5'h15: begin
                if (op == 5'h15) sign_b = ~sign_b;

                if (eff_exp_a > eff_exp_b) begin
                    exp_diff = eff_exp_a - eff_exp_b;
                    exp_res = eff_exp_a;
                    if (exp_diff > 55) begin
                        frac_b = {55'b0, |frac_b};
                    end else begin
                        shift_mask = (56'd1 << exp_diff) - 56'd1;
                        frac_b = (frac_b >> exp_diff) | {55'b0, |(frac_b & shift_mask)};
                    end
                end else if (eff_exp_b > eff_exp_a) begin
                    exp_diff = eff_exp_b - eff_exp_a;
                    exp_res = eff_exp_b;
                    if (exp_diff > 55) begin
                        frac_a = {55'b0, |frac_a};
                    end else begin
                        shift_mask = (56'd1 << exp_diff) - 56'd1;
                        frac_a = (frac_a >> exp_diff) | {55'b0, |(frac_a & shift_mask)};
                    end
                end else begin
                    exp_res = eff_exp_a;
                end

                if (sign_a == sign_b) begin
                    frac_add_res = frac_a + frac_b;
                    sign_res = sign_a;
                end else if (frac_a >= frac_b) begin
                    frac_add_res = frac_a - frac_b;
                    sign_res = sign_a;
                end else begin
                    frac_add_res = frac_b - frac_a;
                    sign_res = sign_b;
                end

                if (frac_add_res == 0) begin
                    res = 64'b0;
                end else begin
                    if (frac_add_res[56]) begin
                        frac_add_res = (frac_add_res >> 1) | {56'b0, frac_add_res[0]};
                        exp_res = exp_res + 1;
                    end else begin
                        for (i = 0; i < 56; i = i + 1) begin
                            if ((frac_add_res[55] == 0) && (exp_res > 0)) begin
                                frac_add_res = frac_add_res << 1;
                                exp_res = exp_res - 1;
                            end
                        end
                    end

                    LSB = frac_add_res[3];
                    G = frac_add_res[2];
                    R = frac_add_res[1];
                    S = frac_add_res[0];
                    round_up = G & (R | S | LSB);
                    if (round_up) begin
                        frac_add_res = frac_add_res + 4'b1000;
                        if (frac_add_res[56]) begin
                            frac_add_res = frac_add_res >> 1;
                            exp_res = exp_res + 1;
                        end
                    end

                    res = {sign_res, exp_res, frac_add_res[54:3]};
                end
            end

            5'h16: begin
                sign_res = sign_a ^ sign_b;
                m_a = {(exp_a != 0), a[51:0]};
                m_b = {(exp_b != 0), b[51:0]};

                if (a_is_nan || b_is_nan) begin
                    res = {1'b0, 11'h7ff, 52'h8000000000000};
                end else if ((a_is_inf && b_is_zero) || (a_is_zero && b_is_inf)) begin
                    res = {1'b0, 11'h7ff, 52'h8000000000000};
                end else if (a_is_inf || b_is_inf) begin
                    res = {sign_res, 11'h7ff, 52'b0};
                end else if (a_is_zero || b_is_zero) begin
                    res = {sign_res, 63'b0};
                end else begin
                    signed_exp = eff_exp_a + eff_exp_b - 1023 + 1;
                    raw_mul_res = m_a * m_b;
                    if (raw_mul_res != 0) begin
                        for (i = 0; i < 106; i = i + 1) begin
                            if ((raw_mul_res[105] == 0) && (signed_exp > 1)) begin
                                raw_mul_res = raw_mul_res << 1;
                                signed_exp = signed_exp - 1;
                            end
                        end
                        if (signed_exp < 1) begin
                            shift_amt = 1 - signed_exp;
                            if (shift_amt > 106) begin
                                raw_mul_res = 0;
                            end else begin
                                mul_shift_mask = (107'd1 << shift_amt) - 1;
                                S = |(raw_mul_res & mul_shift_mask);
                                raw_mul_res = (raw_mul_res >> shift_amt) | {106'b0, S};
                            end
                            signed_exp = 0;
                        end else if (raw_mul_res[105] == 0) begin
                            signed_exp = 0;
                        end
                    end

                    LSB = raw_mul_res[53];
                    G = raw_mul_res[52];
                    R = raw_mul_res[51];
                    S = |raw_mul_res[50:0];
                    round_up = G & (R | S | LSB);
                    if (round_up) begin
                        raw_mul_res = raw_mul_res + (107'b1 << 53);
                        if (raw_mul_res[106]) begin
                            raw_mul_res = raw_mul_res >> 1;
                            signed_exp = signed_exp + 1;
                        end
                    end

                    if (signed_exp >= 2047) exp_res = 11'h7ff;
                    else if (signed_exp < 0) exp_res = 0;
                    else exp_res = signed_exp[10:0];

                    res = {sign_res, exp_res, raw_mul_res[104:53]};
                end
            end

            5'h17: begin
                sign_res = sign_a ^ sign_b;
                m_a = {(exp_a != 0), a[51:0]};
                m_b = {(exp_b != 0), b[51:0]};

                if (a_is_nan || b_is_nan) begin
                    res = {1'b0, 11'h7ff, 52'h8000000000000};
                end else if ((a_is_inf && b_is_inf) || (a_is_zero && b_is_zero)) begin
                    res = {1'b0, 11'h7ff, 52'h8000000000000};
                end else if (a_is_inf || b_is_zero) begin
                    res = {sign_res, 11'h7ff, 52'b0};
                end else if (b_is_inf || a_is_zero) begin
                    res = {sign_res, 63'b0};
                end else begin
                    signed_exp = eff_exp_a - eff_exp_b + 1023;
                    div_num = {m_a, 55'b0};
                    raw_div_res = div_num / m_b;

                    if (raw_div_res != 0) begin
                        for (i = 0; i < 56; i = i + 1) begin
                            if ((raw_div_res[55] == 0) && (signed_exp > 1)) begin
                                raw_div_res = raw_div_res << 1;
                                signed_exp = signed_exp - 1;
                            end
                        end
                        if (signed_exp < 1) begin
                            shift_amt = 1 - signed_exp;
                            if (shift_amt > 56) begin
                                raw_div_res = 0;
                            end else begin
                                shift_mask = (57'd1 << shift_amt) - 1;
                                S = |(raw_div_res & shift_mask);
                                raw_div_res = (raw_div_res >> shift_amt) | {56'b0, S};
                            end
                            signed_exp = 0;
                        end else if (raw_div_res[55] == 0) begin
                            signed_exp = 0;
                        end
                    end

                    LSB = raw_div_res[3];
                    G = raw_div_res[2];
                    R = raw_div_res[1];
                    S = |(div_num % m_b) | raw_div_res[0];
                    round_up = G & (R | S | LSB);
                    if (round_up) begin
                        raw_div_res = raw_div_res + 4'b1000;
                        if (raw_div_res[56]) begin
                            raw_div_res = raw_div_res >> 1;
                            signed_exp = signed_exp + 1;
                        end
                    end

                    if (signed_exp >= 2047) exp_res = 11'h7ff;
                    else if (signed_exp < 0) exp_res = 0;
                    else exp_res = signed_exp[10:0];

                    res = {sign_res, exp_res, raw_div_res[54:3]};
                end
            end

            default: res = 64'b0;
        endcase
    end
endmodule
