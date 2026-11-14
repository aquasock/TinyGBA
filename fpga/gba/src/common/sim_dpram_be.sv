// Dual-port byte enabled memory for simulation
module sim_dpram_be #(
    parameter WIDTH = 32,
    parameter DEPTH = 1024
)(
    input      rst,

    input      clka,
    input      [WIDTH-1:0] dina,
    input      [WIDTH-1:0] addra,
    input      wea,                 // write enable
    input      [WIDTH/8-1:0] bea,   // byte enable
    output reg [WIDTH-1:0] douta,

    input      clkb,
    input      [WIDTH-1:0] dinb,
    input      [WIDTH-1:0] addrb,
    input      web,
    input      [WIDTH/8-1:0] beb,
    output reg [WIDTH-1:0] doutb
);

reg [WIDTH-1:0] mem [0:DEPTH-1] /* verilator public */;

always @(posedge clka)
begin
    if (rst) begin
        for (int i = 0; i < DEPTH; i++)
            mem[i] <= 0;
    end else begin
        if (wea) begin
            for (int i = 0; i < WIDTH/8; i++)
                if (bea[i])
                    mem[addra][i*8 +: 8] <= dina[i*8 +: 8];
        end
        douta <= mem[addra];
    end
end

always @(posedge clkb)
begin
    if (rst) begin
        for (int i = 0; i < DEPTH; i++)
            mem[i] <= 0;
    end else begin
        if (web) begin
            for (int i = 0; i < WIDTH/8; i++)
                if (beb[i])
                    mem[addrb][i*8 +: 8] <= dinb[i*8 +: 8];
        end
        doutb <= mem[addrb];
    end
end

`ifdef TINYGBA_VRAMDBG
// Final contents, so the question "what did the cartridge actually put in
// memory" is answered from the memory rather than from a write-stream trace.
// Two earlier traces were misread: one sampled on the wrong clock and reported
// zeros, and one capped its log during the BIOS's VRAM clear and never reached
// the cartridge (TCL-024).  A final dump has neither failure mode.
final begin
    integer nz, g, h;
    nz = 0; g = 0; h = 0;
    for (int i = 0; i < DEPTH; i++) begin
        if (mem[i] != 0) nz++;
        if (mem[i][15:0] == 16'h03E0 || mem[i][31:16] == 16'h03E0) g++;
        if (mem[i][15:0] != 16'h0000 && mem[i][15:0] != 16'h03E0) h++;
    end
    $display("VRAMFINAL: depth=%0d nonzero=%0d greenwords=%0d otherlo=%0d",
             DEPTH, nz, g, h);
    for (int i = 0; i < 8; i++)
        $display("VRAMWORD[%0d]=%08x", i, mem[i]);
end
`endif

endmodule