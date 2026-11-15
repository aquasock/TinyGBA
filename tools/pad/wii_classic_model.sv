// SPDX-License-Identifier: GPL-3.0-only
// TinyGBA: vendored from TinyNES `tests/wii_pads_tb.sv` (module
// `wii_classic_model`, GPL-3.0-only, https://github.com/aquasock/TinyNES at
// 7013393).  The module below is byte-identical to upstream; only this header
// is added.  It is a byte-level model of a Wii Classic Controller on an
// open-drain bus, including the format-1/format-3 switch and 8BitDo's Retro
// Receiver behaviour, and it is the model TinyNES's own testbench uses.
//
// Used here as the other end of `tools/pad/tb_pad.sv`, which checks that the
// vendored `wii_pad_master` plus this project's button mapping and clk16
// synchroniser turn a controller report into the right GBA keypad bits.  It is
// a simulation-only file: no synthesised build compiles it.
module wii_classic_model #(
    parameter integer INDEX = 0,
    parameter bit RECEIVER = 1'b0
) (
    input wire clk,
    input wire attached,
    input wire scl,
    input wire sda,
    output reg scl_low = 1'b0,
    output reg sda_low = 1'b0,
    output reg [15:0] polls = 16'd0,
    output reg [7:0] wakes = 8'd0,
    output reg stretched = 1'b0
);
    reg woke_f0 = 1'b0, woke_fb = 1'b0;
    reg [7:0] pointer = 8'hff;
    reg [7:0] format = 8'h01;      // 0xFE, back to 1 at power-up
    wire fmt3 = RECEIVER || format == 8'h03;
    integer nbytes;
    reg [7:0] byte_in;
    reg ack_in;
    integer i;

    task receive_byte(output reg [7:0] value, input reg acknowledge);
        begin
            value = 8'd0;
            for (integer bit_index = 7; bit_index >= 0; bit_index = bit_index - 1) begin
                @(posedge scl);
                value[bit_index] = sda;
                @(negedge scl);
            end
            sda_low = acknowledge;
            @(posedge scl);
            @(negedge scl);
            sda_low = 1'b0;
            if (INDEX == 1 && !stretched && acknowledge) begin
                // Keep SCL low beyond the master's own low half once.
                scl_low = 1'b1;
                repeat (35) @(posedge clk);
                scl_low = 1'b0;
                stretched = 1'b1;
            end
        end
    endtask

    function automatic [7:0] read_byte(input [7:0] ptr, input integer index);
        if (ptr == 8'hfa)
            case (index)
                0: read_byte = INDEX == 0 ? 8'h00 : 8'h01;
                1: read_byte = 8'h00;
                2: read_byte = 8'ha4;
                3: read_byte = 8'h20;
                4: read_byte = RECEIVER ? 8'h01 : format;
                default: read_byte = 8'h01;
            endcase
        else if (fmt3)
            // LX RX LY RY LT RT, then the buttons with Up held: the
            // receiver's and a Classic Controller's reports as read on the
            // board, and the latter's format-1 report below packs to
            // a0 1f 10 62.
            case (index)
                0: read_byte = RECEIVER ? 8'h84 : 8'h80;
                1: read_byte = RECEIVER ? 8'h86 : 8'h83;
                2: read_byte = RECEIVER ? 8'h86 : 8'h7f;
                3: read_byte = RECEIVER ? 8'h86 : 8'h85;
                4: read_byte = RECEIVER ? 8'h00 : 8'h1a;
                5: read_byte = RECEIVER ? 8'h00 : 8'h11;
                6: read_byte = 8'hff;
                default: read_byte = 8'hfb;
            endcase
        else
            case (index)
                0: read_byte = 8'h20 + INDEX;
                1: read_byte = 8'h21 + INDEX;
                2: read_byte = 8'h22 + INDEX;
                3: read_byte = 8'h23 + INDEX;
                4: read_byte = 8'hff;
                default: read_byte = 8'hfb; // Up held, all others released.
            endcase
    endfunction

    task send_byte(input [7:0] value, input reg last);
        begin
            for (integer bit_index = 7; bit_index >= 0; bit_index = bit_index - 1) begin
                sda_low = !value[bit_index];
                @(posedge scl);
                @(negedge scl);
            end
            sda_low = 1'b0;
            @(posedge scl);
            if (last ? sda !== 1'b1 : sda !== 1'b0)
                $fatal(1, "pad %0d: master ACK/NACK wrong on byte %0d", INDEX, value);
            @(negedge scl);
        end
    endtask

    initial forever begin
        @(negedge sda);
        if (scl === 1'b1) begin
            @(negedge scl);
            receive_byte(byte_in, attached);
            if (attached) begin
                if (byte_in == 8'ha4) begin
                    receive_byte(byte_in, 1'b1);
                    pointer = byte_in;
                    if (pointer == 8'hf0 || pointer == 8'hfb || pointer == 8'hfe) begin
                        receive_byte(byte_in, 1'b1);
                        if (pointer == 8'hfe) begin
                            if (!woke_fb)
                                $fatal(1, "FE written before the wake");
                            format = byte_in;
                        end else if (pointer == 8'hf0) begin
                            if (byte_in != 8'h55)
                                $fatal(1, "bad F0 wake value %02x", byte_in);
                            woke_f0 = 1'b1;
                            woke_fb = 1'b0;
                            wakes = wakes + 1'b1;
                        end else begin
                            if (!woke_f0 || byte_in != 8'h00)
                                $fatal(1, "bad FB wake sequence");
                            woke_fb = 1'b1;
                        end
                    end else if (pointer != 8'hfa && pointer != 8'h00) begin
                        $fatal(1, "unexpected pointer %02x", pointer);
                    end
                end else if (byte_in == 8'ha5) begin
                    if (!woke_fb || (pointer != 8'hfa && pointer != 8'h00))
                        $fatal(1, "read before wake or pointer");
                    nbytes = pointer == 8'h00 && fmt3 ? 8 : 6;
                    for (i = 0; i < nbytes; i = i + 1)
                        send_byte(read_byte(pointer, i), i == nbytes - 1);
                    if (pointer == 8'h00)
                        polls = polls + 1'b1;
                end else begin
                    $fatal(1, "unexpected I2C address %02x", byte_in);
                end
            end else begin
                woke_f0 = 1'b0;
                woke_fb = 1'b0;
                format = 8'h01;
            end
        end
    end
endmodule
