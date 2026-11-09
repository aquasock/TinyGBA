#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Decode a TINYGBA_FETCHTRACE capture back into CPU memory cycles.

The instrument exists for BRD-022: the BIOS completes its intro, accepts the
cartridge header and jumps to 0x08000000, but neither the test cartridge nor a
retail one reaches its own first DISPCNT write.  TINYGBA_FETCHTRACE records the
first sixteen completed CPU memory cycles at and after that jump and draws them
as bit cells; this script reads them back so the question "did the CPU receive
the right instruction words" is answered by a tool rather than by eye (TCL-010).

Geometry, derived from the RTL rather than assumed:

  fpga/gba/src/gbatang_top.sv   the recorder and its four words per entry
  fpga/gba/src/gba2hdmi.sv      the renderer (ft_colour and the ft_x/ft_y sweep)

Source pixels are 240x160, scaled 4.5x into a 1080x720 video window inside the
720p letterbox, so the window is located in the capture and checked.  Within the
source frame:

  x   0..223   32 bit cells of 7 px, bit 31 on the LEFT
  x 224..231   entry-valid strip: white = that entry was recorded
  x 232..235   page bit 0
  x 236..239   page bit 1
  y   e*20+r*5..+4   entry e (0..7), row r (0..3) = word 0..3 of that entry

Four pages cycle in order, so a capture has to be read with the page it landed
on rather than assumed to be page 0:

  page 0  completed-cycle trace, entries 0..7    (first cycles from the cart)
  page 1  completed-cycle trace, entries 8..15
  page 2  IO write ring: 8 slots of address / data / byte-enables
  page 3  status: live GPU DISPCNT, sticky DISPCNT writes, trace count, halt

Page 3 word 0 is read from the GPU drawer's own registers, not from the CPU
bus, so comparing it with page 2's IO writes separates "the CPU never issued the
write" from "the write was issued and did not land in the register".

A set bit is white.  A clear bit is black or dark grey in an address word
(0 and 2) and dark blue in a data word (1 and 3), alternating shade per nibble
so a row reads as hex.  Every pixel carries a one-LSB tint from the GPU's pixel
stream, which is why nothing here compares colours for equality.

Layout v5 (TINYGBA_STALLTRACE, core-log entry 41) adds a stall "tail": pages
0 and 2 are a sixteen-slot ring of the LAST completed CPU memory cycles before
the machine stopped, page 1 keeps the status entries and carries a freeze
snapshot of the memory controller in entries 5..7, and page 3 holds live
counters.  A ring needs pages 0, 1 and 2 together, so with v5 the captures are
also ASSEMBLED: give the frames of one load in time order and the decoder
drops each frame that is the first after a page change (TCL-019), takes a
per-word majority over the rest, reports any disagreement, and prints the ring
oldest-first.

Usage:
    tools/decode_fetchtrace.py CAPTURE.png [CAPTURE.png ...]
    tools/decode_fetchtrace.py --layout v5 --expect ROM.gba FRAME*.png
    tools/decode_fetchtrace.py --layout v3 CAPTURE.png    # pre-trim builds
    tools/decode_fetchtrace.py --window 420,180 CAPTURE.png
    tools/decode_fetchtrace.py --expect tools/../build/test/test_logo.gba CAPTURE.png

Exit codes: 0 decoded, 2 usage or unreadable input, 3 geometry check failed.
"""

import sys
import os

GOOD, BAD, UNSURE = "good", "bad", "unsure"

# Source-frame geometry, from the renderer.
SOURCE_W, SOURCE_H = 240, 160
SCALE = 4.5
CELL_W = 7                       # source px per bit cell
CELLS = 32                       # bits per word
ENTRY_LINES = 20                 # source lines per entry (4 rows x 5)
ROW_LINES = 5
PAGES = 2
ENTRIES_PER_PAGE = 8


def load_png(path):
    from PIL import Image
    im = Image.open(path).convert("RGB")
    return im.size, im.load()


def locate_window(size, px, override=None):
    """Return (x0, y0, w, h) of the 1080x720 video window inside the capture."""
    W, H = size
    if override is not None:
        x0, y0, w, h = override
        return x0, y0, w, h

    # The letterbox is a flat grey and nothing the trace draws uses it: a set
    # bit is 63-grey, a clear bit is 0..24.  So the boundary is the first and
    # last column, and the first and last row, whose average differs from the
    # corner colour by more than a few counts.
    corner = px[0, H // 2]
    tol = 6

    def is_bar(x, y):
        r, g, b = px[x, y]
        return abs(r - corner[0]) <= tol and abs(g - corner[1]) <= tol and abs(b - corner[2]) <= tol

    # Column profile over the interior rows, to survive JPEG ringing on edges.
    ys = [y for y in range(int(H * 0.1), int(H * 0.9), 7)]
    col_is_bar = []
    for x in range(W):
        n = sum(1 for y in ys if is_bar(x, y))
        col_is_bar.append(n > len(ys) * 0.9)
    xs = [x for x in range(W) if not col_is_bar[x]]
    if not xs:
        raise SystemExit("could not find the video window: no column differs from the letterbox")
    x0, x1 = xs[0], xs[-1]

    xprobe = [x for x in range(x0, x1 + 1, 13)]
    row_is_bar = []
    for y in range(H):
        n = sum(1 for x in xprobe if is_bar(x, y))
        row_is_bar.append(n > len(xprobe) * 0.9)
    ys_found = [y for y in range(H) if not row_is_bar[y]]
    if not ys_found:
        raise SystemExit("could not find the video window: no row differs from the letterbox")
    y0, y1 = ys_found[0], ys_found[-1]
    return x0, y0, x1 - x0 + 1, y1 - y0 + 1


def sample(size, px, win, sx, sy):
    """Average a small patch of display pixels covering one source pixel."""
    W, H = size
    x0, y0, w, h = win
    kx = w / SOURCE_W
    ky = h / SOURCE_H
    xa = int(x0 + sx * kx)
    xb = max(xa + 1, int(x0 + (sx + 1) * kx))
    ya = int(y0 + sy * ky)
    yb = max(ya + 1, int(y0 + (sy + 1) * ky))
    # Take the middle half of the block, so a scaled edge does not blend two
    # neighbouring cells together.
    xa2 = xa + (xb - xa) // 4
    xb2 = max(xa2 + 1, xb - (xb - xa) // 4)
    ya2 = ya + (yb - ya) // 4
    yb2 = max(ya2 + 1, yb - (yb - ya) // 4)
    n = 0
    sr = sg = sb = 0
    for y in range(ya2, min(yb2, H)):
        for x in range(xa2, min(xb2, W)):
            r, g, b = px[x, y]
            sr += r
            sg += g
            sb += b
            n += 1
    if n == 0:
        return (0, 0, 0)
    return (sr / n, sg / n, sb / n)


def classify(rgb):
    """-> (bit, is_data_shade).  White is 1; the blue-ish darks are data words."""
    r, g, b = rgb
    if r >= 45 and g >= 45 and b >= 45:
        return 1, None
    if b - r >= 5.0:
        return 0, True
    return 0, False


def read_word(size, px, win, entry_line_base, row):
    """32 bits of one cell row, bit 31 first, as an integer."""
    word = 0
    data_votes = addr_votes = 0
    for c in range(CELLS):
        sx = c * CELL_W + CELL_W // 2
        sy = entry_line_base + row * ROW_LINES + ROW_LINES // 2
        rgb = sample(size, px, win, sx, sy)
        bit, is_data = classify(rgb)
        if is_data is True:
            data_votes += 1
        elif is_data is False:
            addr_votes += 1
        if bit:
            word |= 1 << (CELLS - 1 - c)
    shade = None
    if data_votes > addr_votes * 3:
        shade = "data"
    elif addr_votes > data_votes * 3:
        shade = "addr"
    return word, shade


def decode_page(size, px, win, page, base=None):
    if base is None:
        base = page * ENTRIES_PER_PAGE
    entries = []
    for e in range(ENTRIES_PER_PAGE):
        ybase = e * ENTRY_LINES
        words = []
        shades = []
        for row in range(4):
            w, shade = read_word(size, px, win, ybase, row)
            words.append(w)
            shades.append(shade)
        # Validity strip at x 224..231.
        v = sample(size, px, win, 226, ybase + ENTRY_LINES // 2)
        valid = classify(v)[0] == 1
        entries.append({"index": base + e, "words": words,
                        "shades": shades, "valid": valid})
    return entries


def page_index(size, px, win):
    """Two-bit page number: x 232..235 is bit 0, x 236..239 is bit 1."""
    lo = classify(sample(size, px, win, 233, SOURCE_H // 2))[0]
    hi = classify(sample(size, px, win, 237, SOURCE_H // 2))[0]
    return lo | (hi << 1)


# Two page layouts exist in capture history, and a decoder that guesses between
# them mislabels every page -- the failure TCL-010 and TCL-019 both describe.
# The layout is therefore named on the command line, never inferred.
#
#   v3  pages 0,1 = boot trace (entries 0..15); 2 = MMIO ring; 3 = status
#       build/mm_s* and build/mm2_s* -- the boot trace was still compiled in
#   v4  page 0 = MMIO ring; 1 = status; 2,3 unused
#       build/fast_s* -- boot trace behind its own TINYGBA_BOOTTRACE define
LAYOUTS = {
    "v3": {
        0: "boot trace, entries 0..7",
        1: "boot trace, entries 8..15",
        2: "MMIO write ring, entries 0..7",
        3: "status pages",
    },
    "v4": {
        0: "MMIO write ring, entries 0..7",
        1: "status pages",
        2: "unused in this layout",
        3: "unused in this layout",
    },
    #   v5  pages 0,2 = stall tail ring slots 0..7 / 8..15; 1 = status +
    #       freeze snapshot (entries 5..7); 3 = live stall counters
    #       build/stl_s* -- TINYGBA_FETCHTRACE + TINYGBA_STALLTRACE
    "v5": {
        0: "stall tail ring, slots 0..7",
        1: "status pages + freeze snapshot",
        2: "stall tail ring, slots 8..15",
        3: "live stall counters",
    },
}
LAYOUT = "v4"
PAGE_NAMES = LAYOUTS[LAYOUT]

# Which page carries the MMIO ring and which carries the status entries, per layout.
MMIO_PAGE = {"v3": 2, "v4": 0, "v5": None}
STATUS_PAGE = {"v3": 3, "v4": 1, "v5": 1}
# Status entries per layout: v3 had four; entry 4 (IWRAM) arrived with v4.
STATUS_ENTRIES = {"v3": 4, "v4": 5, "v5": 5}
RING_BASE = {0: 0, 2: 8}            # v5 ring page -> first slot
STALL_MARKER = 0x57A1

MEM_STATES = {0: "MAIN", 1: "REQ1_START", 2: "REQ1_WAIT", 3: "REQ2_BRAM",
              4: "REQ2_START", 5: "REQ2_WAIT", 6: "?6", 7: "?7"}
PORTS = {0: "NONE", 1: "ROM", 2: "RAM", 3: "DMA"}
FLAG_NAMES = ["gbaon", "dma_done", "dma_rnw", "ram_wen", "thumb", "sdram_ready",
              None, None, "mem_wr", "mem_rd", "halt", "cpu_en", "ram_cen",
              "rom_en", "dma_ena", "dma_on"]     # bit 0 first; 7:6 is mem_port


def decode_mem_state(m):
    """gba_memory {dma_on_r, double_req, dma_sdram, 2'b00, state}."""
    return (f"FSM state={m & 7} ({MEM_STATES[m & 7]}) dma_on_r={(m >> 7) & 1} "
            f"double_req={(m >> 6) & 1} dma_sdram={(m >> 5) & 1}")


def decode_flags(f):
    on = [n for i, n in enumerate(FLAG_NAMES) if n and (f >> i) & 1]
    off = [n for i, n in enumerate(FLAG_NAMES) if n and not (f >> i) & 1]
    port = (f >> 6) & 3
    return f"high: {' '.join(on) or '-'} | low: {' '.join(off)} | sdram_port={PORTS[port]}"


def decode_debug_dma(d):
    """gba_dma debug_dma[15:0]."""
    on = [i for i in range(4) if (d >> (3 + i)) & 1]
    allow = [i for i in range(4) if (d >> (8 + i)) & 1]
    idle = [i for i in range(4) if (d >> (12 + i)) & 1]
    return (f"arbiter idle={d & 1} switch=ch{(d >> 1) & 3} channels on={on} "
            f"allow_on={allow} module idle={idle}")


def decode_snapshot(e5, e6, e7):
    """Page 1 entries 5..7 of layout v5: the freeze snapshot."""
    w = e5[0]
    marker = w >> 16
    if marker != STALL_MARKER:
        raise AssertionError(f"stall marker reads 0x{marker:04X}, expected "
                             f"0x{STALL_MARKER:04X}; packing or word order is wrong")
    frz = (w >> 12) & 1
    cause = (w >> 8) & 3
    full = (w >> 4) & 1
    wp = w & 0xF
    causes = {0: "none", 1: "stall (no completed CPU cycle for 2^22 clk16)",
              2: "time (2^27 clk16 after gbaon)", 3: "stall and time together"}
    m = e5[1] >> 24
    flags = e5[1] & 0xFFFF
    lines = [
        f"frozen={frz} cause={causes[cause]} ring full={full} write pointer={wp}",
        f"at freeze: {decode_mem_state(m)}",
        f"at freeze: {decode_flags(flags)}",
        f"at freeze: dma_addr=0x{e5[2] & 0x0FFFFFFF:08X} rom_addr=0x{e5[3] & 0x0FFFFFFF:08X}",
        f"at freeze: ram_be={e6[0] >> 28:04b} ram_addr=0x{e6[0] & 0x0FFFFFFF:08X} "
        f"sdram byte addr=0x{e6[1] & 0x03FFFFFC:07X}",
        f"at freeze: sdram_ready pulses since last completed cycle={e6[2] >> 16} "
        f"(65535 = saturated), since FSM state change={e6[2] & 0xFFFF}",
        f"at freeze: clk16 in current FSM state={e6[3] >> 16} (65535 = saturated), "
        f"FSM state changes since last completed cycle={e6[3] & 0xFFFF}",
        f"at freeze: {decode_debug_dma(e7[0] & 0xFFFF)}",
        f"DMA beats before freeze: reads={e7[1]} writes={e7[2]}",
        f"longest gap ended by a completed cycle before freeze: {e7[3] & 0xFFFFFF} clk16",
    ]
    return lines, {"frozen": frz, "cause": cause, "full": full, "wp": wp}


def decode_live(entries):
    """Page 3 of layout v5: counters that keep running after the freeze."""
    e0, e1, e2 = (entries[i]["words"] for i in range(3))
    return [
        f"completed CPU cycles before freeze: {e0[0]}",
        f"clk16 since last completed cycle (live): {e0[1]}",
        f"completed CPU cycles after freeze (live): {e0[2]}",
        f"live: {decode_mem_state(e0[3] >> 24)}",
        f"live: {decode_flags(e0[3] & 0xFFFF)}",
        f"last DMA read addr=0x{e1[0] & 0x0FFFFFFF:08X} last DMA write addr=0x{e1[1] & 0x0FFFFFFF:08X}",
        f"DMA beats (live): reads={e1[2]} writes={e1[3]}",
        f"live: sdram_ready since last cycle={e2[0] >> 16} since state change={e2[0] & 0xFFFF}; "
        f"clk16 in state={e2[1] >> 16} state changes={e2[1] & 0xFFFF}",
        f"live: {decode_debug_dma(e2[2] & 0xFFFF)}",
        f"DMA3 transfer count (dma_eepromcount)={e2[3] & 0x1FFFF}",
    ]


def decode_mmio(words):
    """Page entry: what the register file saw, against both candidate CPU addresses.

    Word order is fixed by how a concatenation packs: the leftmost term of
    `{a, b, c, d}` lands in the most significant bits, so the word selected by
    the lowest index is the RIGHTMOST term.  The failing build packed

        {4'h0, 16'hA5C3, gb_bus_adr[11:0],   // word 3
         gb_bus_din,                          // word 2
         4'h0, ram_addr[27:0],                // word 1
         4'h0, ram_addr_d1[27:0]}             // word 0

    and this function originally read it in the source order, which inverted
    every field.  The marker caught it, which is the whole reason it is there.

    `gb_memory` has two paths to the register file, one cycle apart: in state
    MAIN `bram_addr` is `ram_addr` combinationally, and in every other state it
    is the registered `bram_addr_buf`, loaded one cycle earlier.  Both CPU
    addresses are therefore in the entry and this reports which one the register
    file's address agrees with instead of assuming it.

    The comparison is on the low 12 bits because that is all `gb_bus_adr` carries:
    `{bram_addr[11:2], 2'b0}` is the offset inside the 1 KB IO window, never a
    0x04xxxxxx address.
    """
    w_prev, w_cpu, w_data, w_reg = words
    # Word 0 is {4'h0, 16'hA5C3, gb_bus_adr[11:0]}, so the marker occupies bits
    # [27:12] and the IO offset bits [11:0].  A first version of this masked at
    # [31:16] and read 0x0A5C, one nibble low; the field position is part of the
    # packing and must be read off it, not guessed.
    marker = (w_reg >> 12) & 0xFFFF
    if marker != 0xA5C3:
        raise AssertionError(
            f"marker reads 0x{marker:04X}, expected 0xA5C3; the ring's word "
            f"packing or this decoder's word order is wrong")
    reg_off = w_reg & 0xFFF
    cpu_addr = w_cpu & 0x0FFFFFFF
    prev_addr = w_prev & 0x0FFFFFFF
    # `gb_bus_adr` is `{bram_addr[11:2], 2'b0}`, so the register file's address is
    # word-aligned and the low two bits of the CPU's are not carried.  Compare on
    # the word, or a correct halfword store to 0x06 reads as a mismatch against
    # the register file's 0x04.
    cpu_off = cpu_addr & 0xFFC
    prev_off = prev_addr & 0xFFC
    if reg_off == cpu_off and (cpu_addr >> 24) == 0x4:
        align = "same cycle"
    elif reg_off == prev_off and (prev_addr >> 24) == 0x4:
        align = "buffered, 1 cycle"
    elif reg_off == cpu_off or reg_off == prev_off:
        align = "matches, but CPU address was not IO space"
    else:
        align = "NEITHER -- misrouted"
    return (f"reg got IO+0x{reg_off:03X} <= 0x{w_data:08X} | "
            f"cpu 0x{cpu_addr:08X} / prev 0x{prev_addr:08X}  -> {align}")


def decode_status(w0, w1, w2, w3):
    fb = w0 & 1
    bgs = (w0 >> 1) & 0xF
    bld = (w0 >> 5) & 0x3
    io_n = w1 & 0x7
    wrapped = (w1 >> 3) & 1
    s_dc = (w1 >> 4) & 0x7
    trace_n = w2 & 0x1F
    gbaon = w3 & 1
    halted = (w3 >> 1) & 1
    bld_names = {0: "none", 1: "alpha", 2: "brighten", 3: "darken"}
    return [
        f"DISPCNT (GPU register): forced_blank={fb} BG0={bgs & 1} BG1={(bgs >> 1) & 1} "
        f"BG2={(bgs >> 2) & 1} BG3={(bgs >> 3) & 1} BLDCNT={bld_names[bld]}",
        f"IO ring position {io_n}, wrapped={wrapped}, "
        f"DISPCNT written with 0x0000 {s_dc & 1}, 0x0403 {(s_dc >> 1) & 1}, "
        f"0xFFE0 {(s_dc >> 2) & 1}",
        f"writes to 0x04000000: {trace_n}",
        f"CPU: gbaon={gbaon} halt={halted}",
    ]


def decode_counts(w0, w1, w2, w3):
    gap = w0 - w2
    return [
        f"CPU stores decoded as IO : {w0}",
        f"VRAM writes              : {w1}",
        f"writes the register file received: {w2}"
        + (f"   <-- {gap} CPU IO stores never became register writes" if gap else ""),
        f"completed cartridge fetches: {w3}",
    ]


def decode_fetch_and_phases(w0, w1, w2, w3):
    thumb = (w0 >> 28) & 1
    addr = w0 & 0x0FFFFFFF
    names = ["0x03E0 fill green", "0x001F fill red", "0xFFE0 failure column",
             "0x7FFF blink white", "0x0000 blink black"]
    parts = [f"{n} {1 if (w1 >> i) & 1 else 0}" for i, n in enumerate(names)]
    return [
        f"last cartridge fetch: rom_addr=0x{addr:08X} thumb={thumb}",
        "VRAM writes ever carried: " + ", ".join(parts),
    ]


def decode_iwram(w0, w1, w2, w3):
    """IWRAM execution.  A retail cartridge copies itself to 0x03000000 and runs
    from there, so these fields answer 'is the game actually executing' where the
    cartridge-fetch counter cannot."""
    seen = (w0 >> 28) & 1
    addr = w0 & 0x0FFFFFFF
    return [
        f"IWRAM execution seen: {seen}"
        + (f", last fetch 0x{addr:08X}" if seen else ""),
        f"IWRAM instruction fetches: {w1}",
        f"IWRAM data writes: {w2}",
        f"IWRAM data reads:  {w3}",
    ]


def decode_last_vram(w0, w1, w2, w3):
    return [
        f"last VRAM store address : 0x{w0 & 0x0FFFFFFF:08X}",
        f"last VRAM store data    : 0x{w1:08X}",
    ]



def field_of(word, kind):
    if kind == "addr":
        rom_en = (word >> 31) & 1
        thumb = (word >> 30) & 1
        addr = word & 0x0FFFFFFF
        return f"rom_en={rom_en} thumb={thumb} rom_addr=0x{addr:08X}"
    if kind == "data32":
        return f"rom_data=0x{word:08X}"
    if kind == "ramctl":
        ram_cen = (word >> 31) & 1
        ram_wen = (word >> 30) & 1
        be = (word >> 26) & 0xF
        # ram_addr[27:24] is drawn in word bits 25:22 and ram_addr[21:0] in bits
        # 21:0, so the high nibble goes back to bit 24 and not to bit 22.  This
        # was got wrong once and turned a 0x04000000 DISPCNT write into a
        # plausible 0x01000000, which is why the width test below exists.
        addr = (((word >> 22) & 0xF) << 24) | (word & 0x3FFFFF)
        assert 0 <= addr <= 0x0FFFFFFF, addr
        return f"ram_cen={ram_cen} ram_wen={ram_wen} be={be:04b} ram_addr=0x{addr:08X}"
    return f"0x{word:08X}"


KINDS = ["addr", "data32", "ramctl", "ramdata"]


def report(name, capture):
    size, px = capture
    win = locate_window(size, px, WINDOW_OVERRIDE)
    W, H = size
    problems = []
    # The capture card rescales the board's 1280x720 output to 1920x1080, so the
    # window's pixel size is not fixed -- only its aspect ratio is.  A 3:2 window
    # is the 240x160 source; anything else means the window was located wrongly
    # or the picture is not the trace at all.
    aspect = win[2] / win[3]
    if abs(aspect - SOURCE_W / SOURCE_H) > 0.02:
        problems.append(
            f"video window measured {win[2]}x{win[3]} at ({win[0]},{win[1]}), "
            f"aspect {aspect:.3f}, expected {SOURCE_W / SOURCE_H:.3f}")
    print(f"=== {name}")
    print(f"capture {W}x{H}, window {win[2]}x{win[3]} at ({win[0]},{win[1]})")

    pg = page_index(size, px, win)
    print(f"page {pg}: {PAGE_NAMES[pg]}")
    entries = None

    if pg == MMIO_PAGE[LAYOUT]:
        # Ring entries carry no order of their own; each is self-describing.
        entries = decode_page(size, px, win, pg, base=0)
        for ent in entries:
            words = ent["words"]
            flag = "V" if ent["valid"] else "-"
            if not ent["valid"]:
                print(f"  [{flag}] slot {ent['index']}")
                continue
            print(f"  [{flag}] slot {ent['index']}  {decode_mmio(words)}")
    elif pg == STATUS_PAGE[LAYOUT]:
        entries = decode_page(size, px, win, pg, base=0)
        for ent in entries[:STATUS_ENTRIES[LAYOUT]]:
            words = ent["words"]
            flag = "V" if ent["valid"] else "-"
            idx = ent["index"]
            print(f"  [{flag}] " + ("status" if idx == 0 else "counters" if idx == 1
                                     else "last cart fetch / VRAM phases" if idx == 2
                                     else "IWRAM execution" if idx == 4
                                     else "last VRAM store"))
            if idx == 0:
                for line in decode_status(*words):
                    print(f"        {line}")
            elif idx == 1:
                for line in decode_counts(*words):
                    print(f"        {line}")
            elif idx == 2:
                for line in decode_fetch_and_phases(*words):
                    print(f"        {line}")
            elif idx == 4:
                for line in decode_iwram(*words):
                    print(f"        {line}")
            else:
                for line in decode_last_vram(*words):
                    print(f"        {line}")
            if not ent["valid"]:
                problems.append(f"status page entry {idx} is not marked valid")
        if LAYOUT == "v5":
            print("  freeze snapshot (entries 5..7)" +
                  ("" if entries[5]["valid"] else "  [strip dark: not frozen]"))
            try:
                lines, _ = decode_snapshot(entries[5]["words"], entries[6]["words"],
                                           entries[7]["words"])
                for line in lines:
                    print(f"        {line}")
            except AssertionError as exc:
                problems.append(str(exc))
    elif LAYOUT == "v5" and pg in RING_BASE:
        entries = decode_page(size, px, win, pg, base=RING_BASE[pg])
        for ent in entries:
            flag = "V" if ent["valid"] else "-"
            w = ent["words"]
            print(f"  [{flag}] slot {ent['index']:2d}  {field_of(w[0], 'addr')}  "
                  f"rom_data=0x{w[1]:08X}  {field_of(w[2], 'ramctl')}  data=0x{w[3]:08X}")
    elif LAYOUT == "v5" and pg == 3:
        entries = decode_page(size, px, win, pg, base=0)
        for line in decode_live(entries):
            print(f"        {line}")
        for i in range(3):
            if not entries[i]["valid"]:
                problems.append(f"live page entry {i} is not marked valid")
    elif LAYOUT == "v3" and pg <= 1:
        problems.append(f"page {pg} is the boot trace, which this decoder does "
                        f"not render; the boot trace answered its question in BRD-023")
    else:
        problems.append(f"page {pg} is not used by layout {LAYOUT}")
    if problems:
        print("--- problems")
        for p in problems:
            print(f"  ! {p}")
    else:
        print("internal consistency: OK")
    FRAMES.append({"name": name, "page": pg, "entries": entries,
                   "problems": list(problems)})
    return problems


FRAMES = []


def majority(values):
    best = max(set(values), key=values.count)
    return best, values.count(best), len(values)


def assemble(rom):
    """Layout v5: combine the frames of one load into the ordered tail.

    Frames are taken in the order given.  A frame whose page differs from the
    previous frame's is the first after a page change and may tear (TCL-019),
    so it is dropped.  Each remaining word is a majority over its page's frames
    and every disagreement is reported, because the ring and the snapshot are
    frozen and must read identically in every frame."""
    problems = []
    use = {}
    prev = None
    for fr in FRAMES:
        if fr["page"] != prev:
            prev = fr["page"]
            continue
        if not fr["problems"]:
            use.setdefault(fr["page"], []).append(fr)
    print("=== assembled (layout v5)")
    print("frames used per page: " + ", ".join(
        f"page {p}: {len(use.get(p, []))}" for p in range(4)))

    def words_of(page):
        frs = use.get(page, [])
        if not frs:
            return None
        out = []
        for e in range(ENTRIES_PER_PAGE):
            row = []
            for wd in range(4):
                vals = [f["entries"][e]["words"][wd] for f in frs]
                v, n, tot = majority(vals)
                if n != tot and not (page == 3 or (page == 1 and e < 5)):
                    problems.append(f"page {page} entry {e} word {wd}: {n}/{tot} frames agree "
                                    f"on 0x{v:08X}")
                row.append(v)
            valid = majority([f["entries"][e]["valid"] for f in frs])[0]
            out.append({"words": row, "valid": valid})
        return out

    p1 = words_of(1)
    if p1 is None:
        problems.append("no settled page-1 frame: cannot order the ring")
        return problems
    try:
        lines, snap = decode_snapshot(p1[5]["words"], p1[6]["words"], p1[7]["words"])
    except AssertionError as exc:
        problems.append(str(exc))
        return problems
    print("freeze snapshot:")
    for line in lines:
        print(f"  {line}")
    p3 = words_of(3)
    if p3 is not None:
        print("live counters (page 3):")
        for line in decode_live([{"words": e["words"]} for e in p3]):
            print(f"  {line}")
    slots = {}
    for page in (0, 2):
        pw = words_of(page)
        if pw is None:
            problems.append(f"no settled frame of ring page {page}")
            continue
        for e in range(ENTRIES_PER_PAGE):
            slots[RING_BASE[page] + e] = pw[e]
    if len(slots) != 16:
        return problems
    order = list(range(snap["wp"], 16)) + list(range(snap["wp"])) if snap["full"] \
        else list(range(snap["wp"]))
    print(f"tail, oldest first ({len(order)} cycles; the last line is the last "
          f"completed CPU memory cycle before the freeze):")
    for k, s_ in enumerate(order):
        ent = slots[s_]
        w = ent["words"]
        if not ent["valid"]:
            problems.append(f"ring slot {s_} is in the ordered range but not valid")
        rom_en = (w[0] >> 31) & 1
        thumb = (w[0] >> 30) & 1
        addr = w[0] & 0x0FFFFFFF
        insn = ""
        if rom_en:
            if thumb:
                hw = (w[1] >> 16) if addr & 2 else (w[1] & 0xFFFF)
                insn = f" thumb insn=0x{hw:04X}"
            else:
                insn = f" arm insn=0x{w[1]:08X}"
            if rom is not None and addr >> 24 in (8, 9):
                off = addr & 0x01FFFFFF
                if thumb:
                    ref = int.from_bytes(rom[off & ~1:(off & ~1) + 2], "little") \
                        if off + 2 <= len(rom) else None
                    got = (w[1] >> 16) if addr & 2 else (w[1] & 0xFFFF)
                else:
                    ref = int.from_bytes(rom[off & ~3:(off & ~3) + 4], "little") \
                        if off + 4 <= len(rom) else None
                    got = w[1]
                if ref is None:
                    insn += " (beyond ROM)"
                elif ref == got:
                    insn += " = ROM"
                else:
                    insn += f" != ROM 0x{ref:0{4 if thumb else 8}X}"
                    problems.append(f"slot {s_}: fetch 0x{addr:08X} returned 0x{got:X}, "
                                    f"ROM has 0x{ref:X}")
        ram_cen = (w[2] >> 31) & 1
        ram = ""
        if ram_cen:
            ram = f" | {field_of(w[2], 'ramctl')} data=0x{w[3]:08X}"
        print(f"  {k - len(order) + 1:3d} slot {s_:2d}: rom_en={rom_en} addr=0x{addr:08X}{insn}{ram}")
    return problems


WINDOW_OVERRIDE = None


def main(argv):
    global WINDOW_OVERRIDE, LAYOUT, PAGE_NAMES
    args = argv[1:]
    expect = None
    if not args:
        print(__doc__)
        return 2
    while args and args[0].startswith("--"):
        flag = args.pop(0)
        if flag == "--window":
            x0, y0, w, h = (int(v) for v in args.pop(0).split(","))
            WINDOW_OVERRIDE = (x0, y0, w, h)
        elif flag == "--layout":
            name = args.pop(0)
            if name not in LAYOUTS:
                print(f"unknown layout {name}; known: {', '.join(LAYOUTS)}", file=sys.stderr)
                return 2
            LAYOUT = name
            PAGE_NAMES = LAYOUTS[name]
        elif flag == "--expect":
            expect = args.pop(0)
        else:
            print(f"unknown option {flag}", file=sys.stderr)
            return 2
    if not args:
        print("no capture named", file=sys.stderr)
        return 2

    bad = 0
    for path in args:
        if not os.path.isfile(path):
            print(f"missing {path}", file=sys.stderr)
            return 2
        problems = report(path, load_png(path))
        if problems:
            bad = 3

    rom = None
    if expect:
        with open(expect, "rb") as f:
            rom = f.read()
    if LAYOUT == "v5":
        aproblems = assemble(rom)
        if aproblems:
            print("--- assembly problems")
            for p in aproblems:
                print(f"  ! {p}")
            bad = 3
        else:
            print("assembly: OK")
    if expect:
        print(f"--- cartridge reference {expect} ({len(rom)} bytes)")
        for off in (0x00, 0xC0, 0xC4, 0xC8):
            if off + 4 <= len(rom):
                word = int.from_bytes(rom[off:off + 4], "little")
                print(f"  0x{off:08X} -> 0x{word:08X}")
    return bad


if __name__ == "__main__":
    sys.exit(main(sys.argv))
