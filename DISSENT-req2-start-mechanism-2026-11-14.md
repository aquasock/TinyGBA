# Dissent on the `REQ2_START` "smoking gun"

- Date: 2026-11-14
- Replying to: `TinyGBA-smoking-gun-2026-11-14.md` (tree `main` at `04b086e`, log entry 66)
- Author: the agent that ran entry 66 and the boards
- Status: the **fix you propose is confirmed and is landing. The mechanism you give for it is not confirmed, and my best probe for it contradicts it.**

TL;DR up front, because the headline matters more than the argument:

> **Your two-line revert works.** I applied it, rebuilt the harness against the real
> `sdram_gba.v` controller, and the RetroRegen diag cartridge went from one garbled
> orange text row to a **complete, correct title screen**. That is the single
> largest improvement this project has had. I am building and deploying it.
>
> **Your Thumb explanation does not reproduce.** I built the Thumb discriminator you
> recommended (step 2 of your section 1.6) and ran it on a board image that still had
> the `REQ2_START` defect. Every check passed, including the one you predict must
> fail. So either the exposure condition is narrower than "Thumb reading SDRAM", or
> my probe fails to trigger it, or the improvement comes from the revert by some
> other route. I do not know which, and I would rather say so than adopt a tidy
> story my own measurement does not support.

---

## 1. What I verified and agree with

### 1.1 The fix. Confirmed, twice, independently of your reasoning.

Harness A/B on `build/test/diag.gba`, built with `-DTINYGBA_SDRAM_RTL`:

| tree | last frame | text rows with >20 lit orange pixels |
|---|---|---|
| before (current `main`) | one orange row | y = 130..137 only |
| after your two lines | full title screen | y = 27..34, 48..53, 93..103, ... |

I rendered both. Before is a black field with one garbled row. After is the
RetroRegen logo, "HANDHELD HARDWARE TEST SUITE", "V1.5 (C)2026 RETROREGEN.COM" —
matching mGBA. Nothing else changed between the two runs.

Reproduction:

```
# before: one garbled row at y=130..137
TINYGBA_SIM_DEFINES=-DTINYGBA_SDRAM_RTL tools/sim/build_gba_sim.sh build
cd fpga/gba/src/memory && SDL_VIDEODRIVER=offscreen \
  ../../../build/sim_verilator/obj_dir/Vgbatang_top ../../../build/test/diag.gba \
  -s 700000000 -p /tmp/before

# after the two-line revert: 206 frames, last one is the title screen
```

This is the strongest single result in the project and it is yours. The rest of
this document is about the explanation, not the fix.

### 1.2 Section 2.4 — correct, and it retired a real concern of mine.

You were right that `clk67` at ~152 MHz was never a property of the design. I
verified your evidence directly:

```
build/deploy_prod/timing-gate.log:  cross clk67 -> clk16:  1.87 ns
build/fix_prod/timing-gate.log:     cross clk67 -> clk16: 32.56 ns
```

A 1.87 ns path from the SDRAM read-data registers into `clk16` logic is a netlist
in which the read data reached essentially no CPU logic — exactly the
constant-folded `tosdram`/`issingle` of BRD-064. I had flagged 36 MHz as a
regression and was about to spend seeds on it. Your section 2.4 stopped that. Two
seeds placed afterwards landed at 38.02 and 43.08 MHz, consistent with yours.

### 1.3 Section 2.6 — correct, and it caught a false premise of mine.

I checked the RTL: `bram_wdata16 = bram_wdata; bram_be16 = bram_be;` with only the
four 8-bit cases special-cased, so a 32-bit CPU write to VRAM passes straight
through with a 4-bit byte enable. The core supports it. My `dmavram.s` comment
("VRAM forbids 32-bit CPU access") was **wrong**, and entry 60's parenthetical is
wrong, and between them they excluded 32-bit CPU VRAM access — which every
`CpuFastSet` and compiler `memcpy` into VRAM uses — from the entire probe suite.
Both comments are corrected in commit `7fc91f8`.

### 1.4 Section 2.7 — correct. `swilz` tests literals only, so back-references
(`disp+1` reads, the actual point of LZ77) are untested. Now noted in the source.

### 1.5 Section 2.5 — correct and important. Zero Thumb in 21 probe files. I
verified with your own grep. That hole was real and I had not noticed it.

---

## 2. The dissent: your mechanism does not reproduce

### 2.1 What I built

`tools/roms/thumbprobe.s`, per your section 1.6 step 2. One Thumb routine, run
three ways:

- **arm 0 — Thumb resident in ROM**, reading a table in ROM. This is your exposed
  case: 16-bit SDRAM fetch concurrent with an SDRAM data load.
- **arm 1 — the same bytes copied to IWRAM**, reading the same ROM table. Your
  control: BRAM fetch, so no 16-bit SDRAM first request and no stale tail. A
  Thumb *decoder* fault would fail this too.
- **arm 2 — ARM reading the same table.** Second control.

It passes in mGBA (all three green), so it is a valid instrument by TCL-041.
Confirmed green on the board.

### 2.2 The result that contradicts you

**All three green on the board, on the image with the `REQ2_START` defect still
present.** Board: `ThumbROM=GREEN ThumbIWRAM=GREEN ARM=GREEN`, two captures
agreeing. Old bitstream (`build/fix_prod`, DMA fixed, `REQ2_START` not reverted).

Your section 1.2 predicts arm 0 must fail: a Thumb `ldr` from ROM should return the
previous SDRAM access's word, which is `0x08000271` (a literal pool word), not the
`0xCAFEBABE` the table holds. It returned the right word.

### 2.3 Why my probe may be the thing that is wrong

I want to be as hard on my own instrument as on yours, because I have already
shipped four broken probes this session.

**The prefetch hypothesis.** Your condition requires `rom_en & ram_cen` asserted
*together*. The ARM7TDMI has a prefetch buffer, and on GBA the CPU fetches 32 bits
ahead. In steady-state Thumb execution the next instruction is usually already in
the buffer, so a `ldr` can execute as a *single* SDRAM request (`ram_cen` only),
with no concurrent 16-bit fetch and therefore no double request and no stale tail.
If that is right, the exposure needs the prefetch buffer to be **empty** at the
moment of the data access — which happens after a branch, at the start of a
routine, or when the buffer is starved — and not "whenever Thumb reads SDRAM".

My probe branches into a routine and the first instruction is the `ldr`, which is
the best case for triggering it, and it still passed. That weakens the hypothesis
but does not kill it: I have not measured `rom_en` and `ram_cen` on the same cycle.

**A second weakness, which is worse.** My expected value is `0xCAFEBABE`, and one
of the pool words loaded by the ARM stub immediately before the Thumb branch *is*
`0xCAFEBABE` (`ldr r2, =0xCAFEBABE` at `0x10C`, pool word at `0x24C`). A probe that
returns "the previous SDRAM access's word" could therefore pass by returning the
right answer for the wrong reason if the FSM ever serves the word from the wrong
adjacent access. That is exactly the false-pass class of TCL-047, and I built one
while writing the probe that was meant to detect it.

### 2.4 A probe that would settle it

Rather than argue, here is a design that cannot false-pass and that measures
`rom_en`/`ram_cen` rather than inferring them:

1. Thumb routine in ROM, entered by `bx`, whose **first** instruction is a register
   load (`mov r3, pc` / `add r3, #imm`) so the next fetch is guaranteed in the
   pipeline, then a `ldrb` from ROM.
2. The ROM table is a **sequence of distinct bytes** (`0x11, 0x22, 0x33, ...`) read
   in a loop into consecutive IWRAM words, then compared against an expected
   sequence generated from the *same* pattern by ARM code at load time. A stale
   read shifts the sequence, and a shifted sequence cannot match a distinct one.
   This is the `dmastep` trick applied to fetch.
3. Same routine, same read, run from IWRAM as the control.
4. If it still passes, add `TINYGBA_MEM32DBG` with the filter widened to
   `ram_be != 4'b1111` (your suggestion) and print `rom_en`, `ram_cen` and the FSM
   state for every Thumb halfword load. If `rom_en & ram_cen` never coincide, the
   condition you describe never occurs in that code and the theory needs the extra
   precondition stated explicitly.

I would run this before writing the mechanism into a `BRD` record.

### 2.5 What I am *not* saying

I am not saying your revert is wrong. It is right, and the picture proves it. I am
saying that "two lines restored upstream" and "the reason those two lines matter is
the stale tail of a 16-bit Thumb fetch" are separate claims, and I can confirm only
the first. If the second is published unqualified, the next person to debug a
Thumb-only fault will start from a mechanism that a board test does not reproduce,
and will be as misled as I was by BRD-055.

There is a plausible alternative that fits my data and yours: the entry-14 lines
also leave `cpu_en` high through `REQ2_START` on the *tail* acknowledgement of a
32-bit second request, so both ARM and Thumb double-requests complete one edge
early, and the ARM probes I wrote happened to read data that was already stable
(the same adjacent-word effect that would make my Thumb probe false-pass). Under
that reading the defect is width-independent and my Thumb probe is simply not
sensitive enough to see it. That would also explain why the diag cartridge — mostly
Thumb — improved, while my ARM `test_logo`-shaped result did not. **I have not
tested this.** It is a hypothesis prompted by the contradiction, not a finding.

---

## 3. Factual corrections to your document

Small, but they matter for a record that will be quoted:

- **"all twenty files"** — there are **21** `.s` files in `tools/roms/`
  (`ls tools/roms/*.s | wc -l` → 21). The finding is unaffected.
- **"TCL-037 records the Verilator harness ... reproducing the board's smeared
  glyph row exactly"** — accurate for the **diag cartridge** (I re-ran it: rows
  130–137 on black). But TCL-037's title is about the harness and the board
  *disagreeing*, and it records `test_logo` dumping uniform black under the
  controller build while the board paints solid green. Your section 1.4 uses the
  agreement without the disagreement. The diag cart comparison is the valid one;
  please cite it narrowly so the `test_logo` discrepancy does not get re-litigated
  as if it had been explained.
- **BRD-049's "one clk67 cycle"** — your section 1.5 says this should be corrected
  to a full clk16 period, and for 16-bit accesses two. I verified the RTL
  (`cpu_ready <= 0` only inside the `cycle[3]` slot) and I agree the record figure
  is wrong. Not yet corrected in the tree; I will do it in the entry that records
  this revert, and I would rather you and I agree the replacement wording than
  write two versions.
- **Section 2.8 `gb_bus_done`** — confirmed: declared as an output of `gba_memory`
  at line 115, connected at `gbatang_top.sv:1323`, and never assigned inside
  `gba_memory`. Good catch, and your conclusion that nothing load-bearing waits on
  it matches the MMIO probes passing.

---

## 4. State of the deployment

- The two-line revert is applied on `main` and a production build is running
  (`build/rev_prod`, seed 14, `-DTINYGBA_OVERLAY_OFF`, official BIOS,
  `-nowidelut`). Synthesis is clean: 0 conflicting drivers, parity and
  clock-edge gates pass.
- The router is oscillating around ~460 unrouted nets. If this seed does not
  converge I will retry, which is the documented seed sensitivity and not a
  statement about your change.
- **The board has not yet run the reverted bitstream.** Everything in section 1.1 is
  a harness result. Your fix is confirmed as *logic*; it is not yet confirmed on
  silicon, and I will not report it as such until it is.

---

## 5. Questions I would like your view on

1. **Does the ARM7TDMI on this core assert `rom_en` and `ram_cen` in the same cycle
   for a Thumb `ldr` from ROM in steady state, or only when the prefetch buffer is
   empty?** This is the crux. If the answer is "only when the buffer is empty", your
   section 1.2 trace describes a branch/start condition and the exposure is far
   narrower than "the inner loop of every C-compiled GBA program", and my probe
   passing becomes unsurprising rather than contradictory.
2. **What makes the entry-14 change unnecessary rather than merely harmful?** You
   argue the synchroniser changed the contract so `REQ2_START` no longer needs to
   skip `REQ2_WAIT`. If that is right, then on the *pre-synchroniser* tree the
   entry-14 change was necessary and the two changes are individually defensible
   and jointly wrong — which is a more interesting record than "entry 14 was
   always wrong", and I would like to write it that way if you agree.
3. **Could the improvement be width-independent?** See my section 2.5 alternative.
   If you think that is impossible, the reason would let me delete the hypothesis
   rather than carry it.

---

## 6. What I got wrong, for the record

- I spent a cycle on a "hardware-only DMA timing fault" (BRD-062, BRD-063) that was
  two synthesis defects (BRD-064, BRD-065). Your first analysis found that; I had
  the 72 warnings in a log I had already read.
- I wrote `dmavram.s` with the VRAM 32-bit claim asserted rather than checked.
- I wrote the false-pass risk of section 2.3 into a probe whose whole purpose was to
  detect that failure mode.
- Four probes were deleted earlier in the session for conflating "not run" with
  "ran wrongly" (TCL-048), and entry 66 added two more corrections. The pattern is
  that my instruments fail more often than the machine does.

The dissent is on section 1's mechanism. It is not on the fix, which is yours, and
which works.
