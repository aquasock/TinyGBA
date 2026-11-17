// IOSys_bl616 - BL616-based IO system
// 
// This manages UART connection to the companion bl616 MCU, accepts ROM loading and other requests,
// and display the text overlay when needed.
// 
// Author: nand2mario, 2/2025

`define MCU_BL616

module iosys_bl616 #(
    parameter FREQ=21_477_000,
    parameter [14:0] COLOR_LOGO=15'b00000_10101_00000,
    parameter [15:0] CORE_ID=1,     // 1: nestang, 2: snestang
    parameter [7:0] LOADING_STATE=0
)
(
    input clk,                      // main logic clock
    // input clk50,                    // 50mhz clock for UART
    input hclk,                     // hdmi clock
    input resetn,

    // OSD display interface
    output overlay,
    input [7:0] overlay_x,          // 0-255
    input [7:0] overlay_y,          // 0-223
    output [14:0] overlay_color,    // BGR5

    // TinyDesk overlay (vendored desk_layer.v).  TinyTang's desktop draws an
    // 80x45 character grid into whichever core is loaded; these are the cell
    // writes it sends.  `desk_on` gates the whole layer, and `desk_wr_tog` marks
    // one completed cell with `desk_wr_addr`/`desk_wr_data` already stable.
    output            desk_on,
    output reg        desk_wr_tog,
    output reg [11:0] desk_wr_addr,
    output reg [36:0] desk_wr_data, // {char[6:0], fg[14:0], bg[14:0]}, colours {b,g,r}
    input [11:0] joy1,              // DS2/SNES joystick 1: (R L X A RT LT DN UP START SELECT Y B)
    input        home,              // Wii Classic HOME, 1 = pressed (TinyDesk toggle)
    input [11:0] joy2,              // DS2/SNES joystick 2
    output reg [15:0] hid1,         // USB HID joystick 1
    output reg [15:0] hid2,         // USB HID joystick 2

    // ROM loading interface
    output [7:0] rom_loading,   // 0-to-1 loading starts, 1-to-0 loading is finished
    output reg [7:0] rom_do,        // first 64 bytes are snes header + 32 bytes after snes header 
    output reg rom_do_valid,        // strobe for rom_do

    // Save persistence (see fpga/gba/src/memory/gba_save.v).  One request moves
    // 128 bytes; the address is a byte address in the window the save engine
    // understands.  Read commands are answered with a run of data frames, write
    // commands carry their own data and are answered with one acknowledgement.
    output reg         save_start,
    output reg         save_start_we,
    output reg  [22:0] save_start_addr,
    input  wire        save_busy,
    input  wire        save_d_valid,
    input  wire [7:0]  save_d_byte,
    output reg         save_d_ready,
    output wire        save_w_valid,
    output wire [7:0]  save_w_byte,
    input  wire        save_w_ready,
    input  wire        save_err,     // sticky: a restore byte had nowhere to go

    // PCXT management interface
    output reg [15:0] mgmt_address,
    output reg        mgmt_read,
    input      [15:0] mgmt_readdata,
    output reg        mgmt_write,
    output reg [15:0] mgmt_writedata,
    input      [1:0]  fdd_request,      // [1]: write, [0]: read

    // Keyboard interface
    // TinyGBA: `kbd_data` is written from the UART command handler below and
    // never read, and gbatang_top leaves the port unconnected.  Upstream
    // declares it `input reg` and then assigns it procedurally, which slang
    // rejects ("cannot assign to a net within a procedural context") and Gowin
    // EDA tolerates.  Same change TinySNES carries.
    output reg       kbd_data_valid,
    
    output reg [31:0] core_config,

    // UART interface
    input  uart_rx,
    output uart_tx
);

reg [7:0] kbd_data;

localparam integer STR_LEN = 73; // number of characters in the config string
localparam [8*STR_LEN-1:0] CONF_STR = "Tangcores;-;O12,OSD key,Right+Select,Select+Start,Select+RB;-;V,v20240101";

// Remove SPI parameters and add UART parameters
localparam CLK_FREQ = FREQ;
localparam BAUD_RATE = 2_000_000;

reg overlay_reg = 1;
assign overlay = overlay_reg;

// TinyDesk cell state.  `desk_on` follows the firmware's 0x08 overlay command
// AND its 0x15 enable, which is what TinyNES/TinyGBC/TinySNES do: the desktop
// raises the overlay first and enables cells once it has painted them, so a
// half-drawn grid is never shown over the game.
localparam integer DESK_CELLS = 80 * 45;
reg        desk_overlay = 1'b0;
reg        desk_enable  = 1'b0;
reg [11:0] desk_cursor  = 12'd0;
reg [7:0]  desk_x       = 8'd0;
reg [2:0]  desk_nth     = 3'd0;    // byte index within the current 0x14 cell
// The 0x14 frame carries five bytes per cell and `data_reg` keeps only three,
// so the cell bytes are accumulated separately here.
reg [31:0] desk_shift   = 32'd0;
assign desk_on = desk_overlay & desk_enable;

reg [7:0] rom_loading_reg = LOADING_STATE;
assign rom_loading = rom_loading_reg;

// UART receiver signals
wire [7:0] rx_data;
wire rx_valid;

// UART transmitter signals
reg [7:0] tx_data;
reg tx_valid;
wire tx_ready;

// synchronize uart_rx to clk
reg uart_rx_r = 1, uart_rx_rr = 1;
always @(posedge clk) begin
    uart_rx_r <= uart_rx;
    uart_rx_rr <= uart_rx_r;
end

// Instantiate UART modules
async_receiver #(
    .ClkFrequency(CLK_FREQ),
    .Baud(BAUD_RATE)
) uart_receiver (
    .clk(clk),
    .RxD(uart_rx_rr),
    .RxD_data(rx_data),
    .RxD_data_ready(rx_valid)
);

async_transmitter #(
    .ClkFrequency(CLK_FREQ),
    .Baud(BAUD_RATE)
) uart_transmitter (
    .clk(clk),
    .TxD(uart_tx),
    .TxD_data(tx_data),
    .TxD_start(tx_valid),
    .TxD_busy(tx_busy)
);
assign tx_ready = ~tx_busy;

// Command processing state machine
localparam RECV_IDLE         = 7'b0000001; // waiting for command
localparam RECV_LEN1         = 7'b0000010; // receiving length msb
localparam RECV_LEN2         = 7'b0000100; // receiving length lsb
localparam RECV_CMD          = 7'b0001000; // receiving command
localparam RECV_PARAM        = 7'b0010000; // receiving parameters
localparam RECV_RESPONSE_REQ = 7'b0100000; // sending response
localparam RECV_RESPONSE_ACK = 7'b1000000; // waiting for response sending to finish 
reg [6:0] recv_state = RECV_IDLE;

// UART command buffer
reg [7:0] cmd_reg;
reg [15:0] len_reg;
reg [31:0] data_reg;
reg [23:0] rom_remain;
reg [15:0] data_cnt;
reg [3:0] kbd_len;

// Add new registers for textdisp interface
reg [7:0] x_wr;
reg [7:0] y_wr;
reg [7:0] char_wr;
reg we;

// Add these registers for cursor management
reg [7:0] cursor_x;
reg [7:0] cursor_y;

reg [7:0] response_type;
reg response_req;
reg response_ack;

// Save persistence.  `save_addr` accumulates the 24-bit address over the
// command's first three parameter bytes; `save_tx_pending` is what the transmit
// side waits on, so a response is only started once the whole command arrived.
// `save_started` records whether the engine actually took the request: it is
// latched from `~save_busy` at the moment the start is pulsed, which is exactly
// the condition the engine accepts on.  A request that could not be taken is
// reported rather than waited on, and its data bytes are dropped instead of
// being left in the pipe for the next transfer to inherit.
reg  [22:0] save_addr;
reg         save_tx_we;
reg         save_started;

// `save_tx_pending` and `save_d_ready` are owned by the transmit process alone.
// The receive process used to write them too, which made two always blocks drive
// one register -- the fault class BRD-064 records, where synth_gowin resolves a
// conflict arbitrarily and the gate at step 1a refuses the build.  The receive
// side now signals completion by toggling `save_req_tog`, which only it writes,
// and the transmit side latches that into `save_tx_pending`, which only it
// writes.  Both live in clk16, so the toggle needs no synchroniser.
reg         save_tx_pending;
reg         save_req_tog;
reg         save_req_ack;

// The restore stream is combinational rather than a registered pulse: a byte is
// offered on exactly the cycle the receiver delivers it, so the FIFO in the
// engine either takes it or the UART's own backpressure path is irrelevant.
// Registering it would put the write one cycle after the check, which is the
// mistake that lost 39 of 128 bytes in the dump direction during development.
//
// The acceptance test is combinational for the same reason and in the same
// place: `save_started` is latched on the cycle the *first* data byte arrives,
// so reading it there would test the previous command's outcome and drop that
// byte. At that one byte the live `~save_busy` is the same condition.
wire save_accepting = (data_cnt == 16'd3) ? ~save_busy : save_started;
assign save_w_byte  = rx_data;
assign save_w_valid = rx_valid & (recv_state == RECV_PARAM) &
                      (cmd_reg == 8'h0f) & (data_cnt >= 16'd3) &
                      save_accepting & save_w_ready;

// mgmt_* multiplex
reg mgmt_rx;
reg [15:0] mgmt_address_rx;
reg [15:0] mgmt_address_tx;
assign mgmt_address = mgmt_rx ? mgmt_address_rx : mgmt_address_tx;

localparam FDD_READY = 0;
localparam FDD_READ_WAIT = 1;
localparam FDD_DONE_WAIT = 2;

reg [1:0] fdd_state;
reg fdd_read_start, fdd_read_finish, fdd_write_finish;

// The TangCore bl616-fpga UART protocol
//
// Since 0.9, we've introduce a data frame to avoid spurious messages:
//
//         0xAA frame_len[15:0] payload_of_frame_len_bytes
//
// Command payloads from BL616 to FPGA:
// 0x01                       get core ID (response type 0x01, see below), frame_len = 1
// 0x02                       get core config string (response type 0x02, see below)
// 0x03 x[31:0]               set core config status
// 0x04 x[7:0] y[7:0]         move overlay text cursor to (x, y)
// 0x05 <string>              display string from cursor (len implied by frame header, =frame_len-1)
// 0x06 loading_state[7:0]    set loading state (0: core running, non-0: loading)
// 0x07 <data>                load data to rom_do (len implied by frame header)
// 0x08 x[7:0]                x[0]: turn overlay on/off
// 0x09 hid1[15:0] hid2[15:0] send USB joystick state to FPGA
// 0x0a <data_sector>         send a sector (512 bytes) of data to floppy data FIFO
// 0x0b addr[15:0] data[15:0] write to disk management interface (mgmt_address and mgmt_writedata)
// 0x0c <scancode>            send PS/2 scancode (len specified by frame header)
// 0x0d <string>              debug printf. core ignores this.
// 0x0e addr[23:0]            read 128 bytes of save memory at addr (response type 0x10)
// 0x0f addr[23:0] <data>     write 128 bytes of save memory at addr (response type 0x11)
//
// The save pair is a strict request/response exchange: the host asks for one
// 128-byte chunk at a time and waits for the answer, so nothing has to be
// paced, buffered or retried in flight.  A dump of the largest save a GBA
// cartridge can carry -- 128 KB of flash -- is 1024 exchanges.
//
// Response payloads from FPGA to BL616:
// 0x01 core_id[7:0]          core ID
// 0x02 <string>              core config string (len specified by frame header)
// 0x03 joy1[15:0] joy2[15:0] every 20ms, send DS2/SNES joypad state to BL616
// 0x04 lba[15:0] <data_512>  write a sector to disk
// 0x05 lba[15:0]             read a sector from disk (followed by command 0x0a)
// 0x10 addr[23:0] <data_128> 128 bytes of save memory
// 0x11 addr[23:0] status[7:0] save write accepted (status 0)

// UART RX: command processing
always @(posedge clk) begin
    if (!resetn) begin
        recv_state <= RECV_IDLE;
        cmd_reg <= 0;
        data_reg <= 0;
        rom_loading_reg <= 0;
        rom_remain <= 0;
        core_config <= 0;
        data_cnt <= 0;
        x_wr <= 0;
        y_wr <= 0;
        char_wr <= 0;
        we <= 0;
        cursor_x <= 0;
        cursor_y <= 0;
        save_addr <= 23'd0;
        save_tx_we <= 0;
        save_started <= 0;
        save_start <= 0;
        save_start_we <= 0;
        save_start_addr <= 23'd0;
        save_req_tog <= 0;
    end else begin
        rom_do_valid <= 0;
        we <= 0;
        mgmt_write <= 0;
        fdd_read_finish <= 0;
        mgmt_rx <= 0;
        kbd_data_valid <= 0;
        save_start <= 0;

        case (recv_state)

            RECV_IDLE: if (rx_valid && rx_data == 8'hAA) begin
                recv_state <= RECV_LEN1;
            end

            RECV_LEN1: if (rx_valid) begin
                len_reg[15:8] <= rx_data;
                if (rx_data < 8)                      // max frame length 2047
                    recv_state <= RECV_LEN2;
                else
                    recv_state <= RECV_IDLE;
            end

            RECV_LEN2: if (rx_valid) begin
                len_reg[7:0] <= rx_data;
                recv_state <= RECV_CMD;
            end

            RECV_CMD: if (rx_valid) begin
                cmd_reg <= rx_data;
                if (rx_data == 1 || rx_data == 2) 
                    recv_state <= RECV_RESPONSE_REQ;    // request sending core id / config string
                else if (len_reg > 1)
                    recv_state <= RECV_PARAM;
                else
                    recv_state <= RECV_IDLE;
                data_cnt <= 0;
                desk_nth <= 0;      // a cell never spans two frames
            end
            
            RECV_PARAM: if (rx_valid) begin
                data_reg <= {data_reg[23:0], rx_data};
                data_cnt <= data_cnt + 1;
                // e.g. set_overlay x[7:0], the 1st param byte is the last 
                //      (data_cnt == 0, len_reg == 2)
                if (data_cnt + 2 == len_reg) begin
                    recv_state <= RECV_IDLE;
                    // A save write is answered once its last byte is in, not
                    // when the first one is: the acknowledgement then doubles as
                    // proof that the engine has drained the whole chunk.
                    if (cmd_reg == 8'h0f && data_cnt >= 16'd3) begin
                        save_tx_we  <= 1'b1;
                        save_req_tog <= ~save_req_tog;
                    end
                end
                
                case (cmd_reg)
                    3: begin
                        if (data_cnt == 3) begin    // Received 4 bytes
                            core_config <= {data_reg[23:0], rx_data};
                        end
                    end
                    4: case (data_cnt)              // cursor
                        0: cursor_x <= rx_data;
                        1: cursor_y <= rx_data;
                        default: ;
                    endcase
                    5: begin                        // print
                        x_wr <= cursor_x;
                        y_wr <= cursor_y;
                        char_wr <= rx_data;
                        if (cursor_x < 32) begin
                            cursor_x <= cursor_x + 1;
                            we <= 1;
                        end
                    end
                    6: begin
                        rom_loading_reg <= rx_data;
                        recv_state <= RECV_IDLE;    // Single byte command
                    end
                    7: begin
                        rom_do <= rx_data;
                        rom_do_valid <= 1;      // pulse data valid
                    end
                    8: begin
                        // Overlay show/hide.  Drives the desk as well as the
                        // legacy text page: the desktop raises this first, then
                        // paints cells, then enables them with 0x15.
                        overlay_reg  <= rx_data[0];
                        desk_overlay <= rx_data[0];
                    end
                    8'h13: case (data_cnt)          // TinyDesk: cursor to (x, y) of 80x45
                        0: desk_x <= rx_data;
                        1: desk_cursor <= (desk_x < 80 && rx_data < 45) ?
                                          {rx_data[5:0], 6'd0} + {2'd0, rx_data[5:0], 4'd0} + {4'd0, desk_x} :
                                          DESK_CELLS[11:0];
                        default: ;
                    endcase
                    8'h14: begin                    // TinyDesk: cells, five bytes each
                        desk_nth <= desk_nth == 3'd4 ? 3'd0 : desk_nth + 3'd1;
                        if (desk_nth == 3'd4 && desk_cursor < DESK_CELLS) begin
                            // Bytes arrive char, fg[14:8], fg[7:0], bg[14:8], bg[7:0];
                            // data_reg holds the first four and rx_data the fifth.
                            desk_wr_addr <= desk_cursor;
                            desk_wr_data <= {data_reg[30:24], data_reg[22:16], data_reg[15:8],
                                             data_reg[6:0], rx_data};
                            desk_wr_tog  <= ~desk_wr_tog;
                            desk_cursor  <= desk_cursor + 12'd1;
                        end
                    end
                    8'h15: if (data_cnt == 0)       // TinyDesk: enable cell drawing
                        desk_enable <= rx_data[0];
                    9: begin
                        case (data_cnt)
                            0: hid1[15:8] <= rx_data;
                            1: hid1[7:0] <= rx_data;
                            2: hid2[15:8] <= rx_data;
                            3: hid2[7:0] <= rx_data;
                            default: ;
                        endcase
                    end
                    'ha: begin                      // send read data to disk controller
                        mgmt_rx <= 1;
                        mgmt_address_rx <= 16'hf20f;
                        mgmt_writedata <= rx_data;
                        mgmt_write <= '1;
                        if (data_cnt == 511) 
                            fdd_read_finish <= 1;
                    end
                    'hb: begin                      // write disk controller register
                        mgmt_rx <= 1;
                        case (data_cnt)
                            0: mgmt_address_rx[15:8] <= rx_data;
                            1: mgmt_address_rx[7:0] <= rx_data;
                            2: mgmt_writedata[15:8] <= rx_data;
                            3: begin
                                mgmt_writedata[7:0] <= rx_data;
                                mgmt_write <= '1;
                            end
                            default: ;
                        endcase
                    end
                    'hc: begin                      // send PS/2 scancode to PCXT
                        kbd_data <= rx_data;
                        kbd_data_valid <= 1;
                    end
                    8'h0e: case (data_cnt)          // read 128 bytes of save memory
                        0: save_addr[22:16] <= rx_data;
                        1: save_addr[15:8]  <= rx_data;
                        2: begin
                            save_addr[7:0] <= rx_data;
                            save_start_addr <= {save_addr[22:8], rx_data};
                            save_start_we   <= 1'b0;
                            save_start      <= ~save_busy;
                            save_started    <= ~save_busy;
                            save_tx_we      <= 1'b0;
                            save_req_tog    <= ~save_req_tog;
                        end
                        default: ;
                    endcase
                    8'h0f: case (data_cnt)          // write 128 bytes of save memory
                        0: save_addr[22:16] <= rx_data;
                        1: save_addr[15:8]  <= rx_data;
                        2: save_addr[7:0]   <= rx_data;
                        3: begin
                            // first data byte: hand the address to the engine, which
                            // then drains the FIFO as the rest of the frame arrives
                            save_start_addr <= save_addr;
                            save_start_we   <= 1'b1;
                            save_start      <= ~save_busy;
                            save_started    <= ~save_busy;
                        end
                        default: ;
                    endcase
                    default: begin
                        // unknown command: consume all data and return
                    end
                endcase
            end

            RECV_RESPONSE_REQ:                      // request to send config string
                case (cmd_reg)
                    1,2: begin                      // 1: core ID, 2: config string
                        response_type <= cmd_reg;
                        response_req ^= 1;
                        recv_state <= RECV_RESPONSE_ACK;
                    end
                    default:
                        recv_state <= RECV_IDLE;
                endcase

            RECV_RESPONSE_ACK:                      // wait for TX to finish
                if (response_req == response_ack) begin
                    recv_state <= RECV_IDLE;
                end
        endcase
        
    end
end

localparam SEND_IDLE = 0;

localparam SEND_CORE_ID = 1;        // doubles as response type in message header
localparam SEND_CONFIG_STRING = 2;
localparam SEND_JOYPAD = 3;
localparam SEND_FDD_WRITE = 4;
localparam SEND_FDD_READ = 5;

localparam SEND_HEADER = 6;
localparam SEND_DONE = 7;

// Save responses.  These are numbered from 0x10 rather than continuing 6 and 7
// because the response type is the state number itself (see SEND_HEADER), and 6
// and 7 are already SEND_HEADER and SEND_DONE.
localparam SEND_SAVE_DATA = 8'h10;  // 3 address bytes + 128 data bytes
localparam SEND_SAVE_ACK  = 8'h11;  // 3 address bytes + status byte

reg [4:0] send_state, send_state_next;
reg [7:0] send_idx;
// Empty transmit slots tolerated inside one save data frame; see SEND_SAVE_DATA.
reg [12:0] save_stall;
// TinyGBA: this was `50_000_000 / 50`, which is 20 ms only if the block runs at
// 50 MHz.  It runs on clk16, so the same constant gave a report every 59.7 ms --
// three times slower than the comment claimed, and slower than the desktop's own
// 40 ms poll, which made a pointer driven from this word feel laggy.  Deriving
// it from CLK_FREQ (the FREQ parameter, 16.65 MHz here) makes the interval what
// it says it is whatever clock the core is given.
localparam JOY_UPDATE_INTERVAL = CLK_FREQ / 50; // 20 ms
// A HOME tap is reported as a press of bit 10 for this many ticks: 13 x 20 ms =
// 260 ms, the same duration TinyNES and TinySNES use, long enough that the host
// cannot miss the edge and short enough not to look stuck.
localparam [7:0] TAP_TICKS = 8'd13;
reg [$clog2(JOY_UPDATE_INTERVAL+1)-1:0] joy_timer;
reg [15:0] joy1_reg;

// ---------------------------------------------------------------- HOME tap --
//
// TinyTang's desk task toggles the desktop on a rising edge of TANG_PAD_LB,
// which is bit 10 of the pad word it receives (tang_pad.h).  This core's joy
// word uses bit 10 for L, so L must NOT reach the host: leaving it in would make
// the shoulder button open the desktop mid-game.  It is masked here and bit 10
// is driven only by a tap of HOME, which is exactly the arrangement TinySNES
// uses on the same host.
//
// A tap is HOME pressed and released with nothing else held; HOME with SELECT
// is the exit-and-save gesture on TinySNES and is deliberately not reused here,
// because this core has no save-on-exit and a combined gesture that did nothing
// would be worse than none.
reg [7:0] home_tap = 8'd0;
reg home_prev = 1'b0, home_alone = 1'b0;
wire [11:0] joy1_report = (joy1 & 12'hFFF & ~12'h400)
                        | (home_tap != 8'd0 ? 12'h400 : 12'h000);
// A report is repeated every JOY_REFRESH_TICKS even when nothing changed: a
// dropped UART frame would otherwise leave a button stuck low-side forever, and
// a stuck bit 10 would hold the desktop over the game with no way back.
localparam [4:0] JOY_REFRESH_TICKS = 5'd25;   // 500 ms
reg [4:0] joy_refresh = 5'd0;
reg [15:0] joy2_reg;
reg [15:0] resp_frame_len;

// UART TX: command responses, joystick updates and FDD requests
always @(posedge clk) begin
    if (!resetn) begin
        joy_timer <= 0;
        home_tap <= 8'd0;
        home_prev <= 1'b0;
        home_alone <= 1'b0;
        joy_refresh <= 5'd0;
        send_state <= 0;
        save_stall <= 0;
        save_tx_pending <= 0;
        save_req_ack <= 0;
        save_d_ready <= 0;
    end else begin
        tx_valid <= 0;
        mgmt_read <= 0;
        fdd_read_start <= 0;
        fdd_write_finish <= 0;
        // Take a dump byte only when nothing is queued and nothing is in
        // flight.  A frame cut short leaves a byte in the pipe, and it would
        // arrive as the first data byte of the next frame -- but draining too
        // eagerly is far worse, because the popped byte is discarded rather than
        // transmitted.
        //
        // Two versions of this line were wrong on hardware.  "Whenever not
        // sending data" was high through SEND_HEADER, so it consumed the
        // engine's 128 bytes and threw them away before SEND_SAVE_DATA ran; the
        // frame stalled, was cut short, and the host reported the core stopped
        // answering at offset 0.  Gating on the idle state alone still left a
        // window, because the receive side sets `save_req_tog` the cycle it
        // parses the command while this block needs one more cycle to notice.
        save_d_ready <= (send_state == SEND_IDLE) && !save_tx_pending &&
                        (save_req_tog == save_req_ack);

        // Latch a completed save command from the receive side.  One cycle
        // later than the old shared-register version and in the same domain, so
        // it costs nothing and removes the second driver.
        if (save_req_tog != save_req_ack) begin
            save_req_ack    <= save_req_tog;
            save_tx_pending <= 1'b1;
        end
        
        // Joypad state transmission logic.  `joy_timer` free-runs rather than
        // stopping at zero, so it is a real 20 ms tick: the tap has to age on the
        // tick whether or not a report went out, and a timer that only restarted
        // on a send would age the tap once per clock while idle.
        joy_timer <= joy_timer == 0 ? JOY_UPDATE_INTERVAL : joy_timer - 1;

        // Age the HOME tap and the refresh counter on each tick, and arm a tap
        // on a clean release.  This sits outside the send decision so the tap
        // runs down even if nothing else is moving.
        if (joy_timer == 0) begin
            if (home_tap != 8'd0)
                home_tap <= home_tap - 8'd1;
            joy_refresh <= joy_refresh == JOY_REFRESH_TICKS - 1 ? 5'd0 : joy_refresh + 5'd1;
        end
        home_prev <= home;
        if (home && !home_prev)
            home_alone <= joy1 == 12'd0;
        else if (home && joy1 != 12'd0)
            home_alone <= 1'b0;
        if (!home && home_prev && home_alone)
            home_tap <= TAP_TICKS;

        // UART transmission state machine
        case (send_state)
            SEND_IDLE: begin
                send_idx <= 0;
                if (joy_timer == 0 &&
                    (joy1_report != joy1_reg[11:0] || joy2 != joy2_reg[11:0] ||
                     joy_refresh == JOY_REFRESH_TICKS - 1)) begin
                    joy1_reg <= joy1_report;
                    joy2_reg <= joy2;
                    send_state_next <= SEND_JOYPAD;
                    send_state <= SEND_HEADER;
                    resp_frame_len <= 5;
                end else if (fdd_request[1] && fdd_state == FDD_READY) begin
                    send_state_next <= SEND_FDD_WRITE;
                    send_state <= SEND_HEADER;
                    mgmt_address_tx <= 16'hf200;    // read {drive, sector}
                    resp_frame_len <= 515;
                end else if (fdd_request[0] && fdd_state == FDD_READY) begin
                    send_state_next <= SEND_FDD_READ;
                    send_state <= SEND_HEADER;
                    mgmt_address_tx <= 16'hf200;    // read {drive, sector}
                    resp_frame_len <= 3;
                end else if (response_req != response_ack) begin
                    if (response_type == 2) begin
                        send_state_next <= SEND_CONFIG_STRING;
                        send_state <= SEND_HEADER;
                        resp_frame_len <= STR_LEN + 1;
                    end else if (response_type == 1) begin
                        send_state_next <= SEND_CORE_ID;
                        send_state <= SEND_HEADER;
                        resp_frame_len <= 2;
                    end
                end else if (save_tx_pending && (save_tx_we == 1'b0 || save_busy == 1'b0)) begin
                    // A read starts as soon as the engine has anything; a write
                    // is acknowledged only once the engine has finished it.
                    if (save_tx_we) begin
                        send_state_next <= SEND_SAVE_ACK;
                        resp_frame_len  <= 5;        // type + 3 addr + status
                    end else begin
                        send_state_next <= SEND_SAVE_DATA;
                        resp_frame_len  <= 132;      // type + 3 addr + 128 data
                    end
                    send_state <= SEND_HEADER;
                    save_tx_pending <= 1'b0;
                    save_stall <= 13'd0;
                end
            end

            SEND_HEADER: begin              // 4 byte header: 0xAA, resp_frame_len[15:0], resp_type[7:0]
                if (tx_ready && ~tx_valid) begin
                    tx_valid <= 1;
                    send_idx <= send_idx + 1;
                    case (send_idx[1:0])
                        0: tx_data <= 8'hAA;
                        1: tx_data <= resp_frame_len[15:8];
                        2: tx_data <= resp_frame_len[7:0];
                        3: begin
                            tx_data <= send_state_next;
                            send_state <= send_state_next;
                            send_idx <= 0;
                        end
                        default: ;
                    endcase
                end
            end

            SEND_CORE_ID: begin
                if (tx_ready && ~tx_valid) begin
                    tx_data <= CORE_ID[7:0];
                    tx_valid <= 1;
                    send_state <= SEND_IDLE;
                    response_ack <= response_req;
                end
            end

            SEND_CONFIG_STRING: begin
                if (tx_ready && ~tx_valid) begin
                    tx_data <= CONF_STR[8*(STR_LEN - send_idx - 1) +: 8];
                    tx_valid <= 1;
                    send_idx <= send_idx + 1;
                    if (send_idx == STR_LEN-1) begin
                        send_state <= SEND_IDLE;
                        response_ack <= response_req;
                    end
                end
            end

            SEND_JOYPAD: begin
                if (tx_ready && ~tx_valid) begin
                    case (send_idx)
                        0: tx_data <= joy1_reg[15:8]; // Joy1 high byte
                        1: tx_data <= joy1_reg[7:0];  // Joy1 low byte
                        2: tx_data <= joy2_reg[15:8]; // Joy2 high byte
                        3: tx_data <= joy2_reg[7:0];  // Joy2 low byte
                        default: ;
                    endcase
                    tx_valid <= 1;
                    send_idx <= send_idx + 1;
                    if (send_idx == 3) begin
                        send_state <= SEND_IDLE;
                        response_ack <= response_req;
                    end
                end
            end

            // fdd write. Send {drive, sector} followed by 512 bytes data to bl616
            SEND_FDD_WRITE: begin
                if (tx_ready && ~tx_valid) begin
                    case (send_idx)
                        0: tx_data <= mgmt_readdata[15:8];  // sector number
                        1: begin
                            tx_data <= mgmt_readdata[7:0];  // sector number
                            mgmt_address_tx <= 16'hf20f;    // start reading FIFO data
                        end
                        default: begin 
                            tx_data <= mgmt_readdata[7:0];  // send FIFO data
                            mgmt_read <= '1;                // advance FIFO pointer
                        end
                    endcase
                    tx_valid <= 1;
                    send_idx <= send_idx + 1;
                    if (send_idx == 511+2) begin
                        send_state <= SEND_DONE;
                        response_ack <= response_req;
                        fdd_write_finish <= 1;              // notify FDD state machine
                    end
                end
            end

            // FDD read. Just second the sector number. BL616 will send the data later via command 0x0b.
            SEND_FDD_READ: begin
                if (tx_ready && ~tx_valid) begin
                    case (send_idx)
                        0: tx_data <= mgmt_readdata[15:8];
                        1: tx_data <= mgmt_readdata[7:0];
                        default: ;
                    endcase
                    tx_valid <= 1;
                    send_idx <= send_idx + 1;
                    if (send_idx == 1) begin
                        send_state <= SEND_DONE;
                        response_ack <= response_req;
                        fdd_read_start <= 1;                // notify FDD state machine
                    end
                end
            end

            SEND_DONE: send_state <= SEND_IDLE;     // extra state for fdd_state to transition

            // Save read: 3 address bytes then 128 bytes from the engine, one per
            // transmit slot.  A byte that has not arrived yet holds the state
            // rather than padding or truncating the frame, so a full chunk is
            // always 132 bytes on the wire -- unless the engine stops answering
            // altogether, in which case the frame is cut short after `save_stall`
            // empty transmit slots.  That bound matters: without it, an engine
            // that never produced a byte would wedge this state machine and with
            // it the whole link, joypad reports included.  A short frame is
            // unambiguous to the host, which checks the length.
            SEND_SAVE_DATA: begin
                if (tx_ready && ~tx_valid) begin
                    if (send_idx < 8'd3) begin
                        case (send_idx)
                            0: tx_data <= save_addr[22:16];
                            1: tx_data <= save_addr[15:8];
                            default: tx_data <= save_addr[7:0];
                        endcase
                        tx_valid <= 1;
                        send_idx <= send_idx + 8'd1;
                    end else if (save_d_valid) begin
                        tx_data      <= save_d_byte;
                        save_d_ready <= 1'b1;       // take it from the engine
                        tx_valid     <= 1;
                        send_idx     <= send_idx + 8'd1;
                        save_stall   <= 13'd0;
                        if (send_idx == 8'd130) begin
                            send_state   <= SEND_DONE;
                            response_ack <= response_req;
                        end
                    end else if (save_stall == 13'h1FFF) begin
                        send_state   <= SEND_DONE;
                        response_ack <= response_req;
                    end else
                        save_stall <= save_stall + 13'd1;
                end
            end

            // Save write acknowledgement: the address echoed back plus a status
            // byte -- 0 when the engine took the request, 1 when it was busy and
            // the chunk was dropped.  The host refuses a non-zero status instead
            // of recording a save it did not write.
            SEND_SAVE_ACK: begin
                if (tx_ready && ~tx_valid) begin
                    case (send_idx)
                        0: tx_data <= save_addr[22:16];
                        1: tx_data <= save_addr[15:8];
                        2: tx_data <= save_addr[7:0];
                        // Status 0 only when the engine both took the request
                        // and moved every byte.  A non-zero status makes the
                        // host refuse the chunk rather than record a save it
                        // did not write.
                        default: tx_data <= (!save_started) ? 8'h01 :
                                             (save_err)     ? 8'h02 : 8'h00;
                    endcase
                    tx_valid <= 1;
                    send_idx <= send_idx + 8'd1;
                    if (send_idx == 8'd3) begin
                        send_state   <= SEND_DONE;
                        response_ack <= response_req;
                    end
                end
            end
        endcase
    end
end

// FDD state machine. UART TX only serves FDD requests when fdd_state == FDD_READY.
reg [3:0] fdd_cnt;
always @(posedge clk) begin
    if (!resetn) begin
        fdd_state <= FDD_READY;
    end else case (fdd_state)
        FDD_READY: begin
            if (fdd_read_start) begin
                fdd_state <= FDD_READ_WAIT;
            end else if (fdd_write_finish) begin
                fdd_state <= FDD_DONE_WAIT;
                fdd_cnt <= 15;
            end
        end
        FDD_READ_WAIT: begin
            if (fdd_read_finish) begin
                fdd_state <= FDD_DONE_WAIT;
                fdd_cnt <= 15;
            end
        end
        FDD_DONE_WAIT: begin            // delay 15 cycles before we serve floppy requests again
            fdd_cnt <= fdd_cnt - 1;
            if (fdd_cnt == 0) begin
                fdd_state <= FDD_READY;
            end
        end
    endcase
end

// text display
`ifndef SIM
wire [31:0] reg_char_di = {8'b0, x_wr, y_wr, char_wr};
wire [3:0] reg_char_we = {4{we}};

textdisp #(.COLOR_LOGO(COLOR_LOGO)) disp (
    .clk(clk), .hclk(hclk), .resetn(resetn),
    .x(overlay_x), .y(overlay_y), .color(overlay_color),
    .reg_char_di(reg_char_di), .reg_char_we(reg_char_we)
);
`endif

endmodule
