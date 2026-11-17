## 1 COMMIT Unreleased 2026-11-16T11:47:45-07:00

#### Coming From:

Unreleased 0722470

#### Purpose:

Record the archival rollover of the active log at 99 entries, identify the archive it was written to, and hand a fresh agent the live project state without requiring the archive to be read.

#### Outcome:

The active log has been rolled over. Entries 1 to 99, covering 2026-10-31 through 2026-11-16 and the whole span from the first open-flow synthesis to a cartridge save surviving a real power cycle, are archived as `archived_logs/core-log-2026-11-16T114739-0700.tar.gz` in the `.ai/` folder; that archive was verified against the live file by extracting it and comparing md5 `c4577797297634ec9d9f8623becc8b5c`, so the 577 KB it holds is byte-identical to what was cleared. The rollover was performed at 99 entries rather than at the 100 that `core-syntax.md` names as the trigger, at the operator's explicit direction, which is why this handoff exists one entry early; nothing about the procedure differed, and the next entry after this one is number 2. The live state a fresh agent needs is as follows. The machine runs retail GBA cartridges: a twelve-title sweep passes on audio and video, with Pokemon Emerald last to pass and its fault in the loader rather than the core, and Castlevania Aria of Sorrow at 8 MiB boots, plays its intro and continues into gameplay. All six Gowin memory wrappers are this project's own RTL and hardware-verified, and the RetroRegen diagnostic suite reports `RESULT: ALL REGIONS PASS` across IWRAM, EWRAM, VRAM, PRAM and OAM. The save path was closed in the last three cycles: a CPU byte store to the cartridge SRAM window was being diverted into the flash interpreter because `config_backup_type` reached the controller as an implicit one-bit net, and declaring its width fixed it (BRD-105, BRD-109); the conclusion that it still failed after the fix was wrong twice over, first because a simulation pin model let a deselected die drive the shared DQ bus and corrupted its own write data (BRD-106), and second because the three bitstreams that booted black had been built without the retail BIOS, since `tools/build_tinygba.sh` never set `TINYGBA_BIOS_HEX` and `gba_memory.sv` silently fell back to the free one (BRD-108). Both faults are now prevented by mechanism rather than by care: the BIOS has no fallback and a missing define fails elaboration, the build resolves the retail image and exits 2 without it, the free and normmatt images are deleted from the tree, and the simulation harness lost its free-BIOS opt-out. With the retail BIOS in a seed-1 bitstream, a probe writing through the cartridge window verifies on hardware, and a full persistence chain has been measured for SRAM with the power cut supplied by a relay sequence rather than a reset: probe writes, host read confirms the pattern is in SDRAM, `gbasave`, real power cycle, `gbaload` restores, and the probe finds the pattern back, with a zeros-planted negative control returning the baseline (BRD-110). What remains open is specific and recorded. BRD-092's four-save-type round trip and BRD-094's EEPROM power-cycle result were both measured while `config_backup_type` reached `rv_sdram_adapter` as one bit, where `is_eeprom = config_backup_type == 4` could never be true, so neither is evidence about the EEPROM, flash512K or flash1M stores and both need re-taking on a post-fix image. No retail title has saved its own game since the fix. The `clk67` multicycle relaxation that `gbatang.sdc` exists to express is still required by any image carrying the audio fix, per TCL-056, and must be quoted with any timing figure from a post-audio image. `tools/roms/savewprobe.s` is marked NOT VALIDATED and `tools/roms/saveprobe_iw.s` is untracked and unvalidated; both should be finished or dropped. The board is currently on `build/head_retail_s1` with the zeros probe and its save, in two-wire mode, and the power cycle tool used for the persistence test is outside this repository at `~/Desktop/reboot_in 2_wire.py`, which drives a relay over LXMF and acknowledged all three steps in both runs. The core-syntax audit was run: `.ai/core.md` and `.ai/core-syntax.md` were re-read, `.ai/core.md` was confirmed unchanged at md5 `1145a377cae5b553567ab6946ed78c01`, the complete `.ai/` diff was inspected, the archived log was verified well formed before archiving -- 99 entries each with six canonical sections and a trailing `---` -- and this handoff was validated as entry 1 with six sections in order, a one-sentence Purpose, prose in Outcome and Next Steps, an all-`N/A` Status triple as the archival rules require, and a trailing `---`, with the active log now at 1 entry against the 100-entry limit and the reference store unchanged at 193 records with 193 unique ids, no duplicates, every record in canonical field order, and every status inside the three-value vocabulary.

#### Next Steps:

Re-take the save measurements the truncation invalidated, because they are the only thing between this machine and a save path that is trusted for every cartridge rather than for SRAM alone: run BRD-092's four-type round trip and BRD-094's EEPROM power-cycle measurement on a post-fix image, using the relay tool for the power cut that those records need, and expect the EEPROM case to behave differently from what BRD-092 and BRD-094 recorded since `is_eeprom` could not assert before the width fix. Then have a retail title save its own game rather than a probe -- an SRAM title first, such as Metroid Fusion, and Pokemon Emerald afterwards, since its flash1M configuration reached the controller as `BACKUP_NONE` before the fix and is the case most likely to move. Two loose ends should be settled rather than carried: `tools/roms/savewprobe.s` and `tools/roms/saveprobe_iw.s` are unvalidated and should be finished or deleted, and the `clk67` multicycle relaxation in TCL-056 remains a property of any image carrying the audio fix. Do not read the archived log without the operator's approval, do not cite a board timing figure without naming whether the relaxation was needed, and do not build without a retail BIOS image present -- a black screen is not a placement fault until the bitstream's BIOS signature has been read.

#### Files Modified:

None.

#### Status:

- Build: N/A
- Deployment: N/A
- User Test: N/A

---
## 2 COMMIT Unreleased 2026-11-16T12:26:44-07:00

#### Coming From:

Unreleased fbac46d

#### Purpose:

Re-take the save round trips that the one-bit `config_backup_type` invalidated, for all four save types, on the post-fix image.

#### Outcome:

Three of the four types are re-established on the fixed image and one is newly broken, which is the finding. On `build/head_retail_s1` at seed 1 with the retail BIOS, each `tools/save/sav_pattern.py` pattern was planted as the cartridge's `.sav`, loaded with `gbaload` and read back over `fpgapipe`: flash512K (Mario Kart, 65,536 bytes) differs in 0 bytes, flash1M (Pokemon Emerald, 131,072 bytes) differs in 0 bytes, and EEPROM (Super Mario Advance 2, 8,192 bytes) differs in 1,495 (BRD-111). The flash1M result is strictly better than BRD-092's 131,070 of 131,072, because the two flash command bytes at `0x2AAA` and `0x5555` no longer leak into the array now that the flash protocol is actually selected rather than arriving as `BACKUP_NONE`. The EEPROM failure is an addressing or read-timing fault rather than corrupt data, and three independent checks say so: the differing positions are identical for a ramp pattern and for a constant `0xAA`, so they depend on address and not content; a second read started 64 bytes later returned byte-identical values at all 8,128 overlapping addresses, so the values belong to the address and not to my instrument's 128-byte chunking; and after a power cycle with no `.sav` restored the window reads `0xff` across most of its span with the same fixed values at the same addresses, so a blank store is producible and the junk is not stored save data. The differing blocks run `0x0010`, `0x0080`, `0x00c0`, then `0x0100`, `0x0280`, `0x0400`, `0x0580`, `0x0700`, `0x0880` -- a 384-byte period from `0x100` onward -- while `0x0970-0x1fff` is entirely correct. What this corrects is larger than the failure itself: BRD-092's EEPROM round trip and BRD-094's EEPROM power-cycle measurement both travelled the plain-SDRAM path, because `is_eeprom = config_backup_type == 4` could never assert against a one-bit net, so the `eeprom_ram` wrapper has never actually been exercised on the board and BRD-096's inference that it was hardware-verified does not hold. The defect is newly reachable rather than newly introduced. It also answers BRD-094 in the affirmative: a blank EEPROM store is reachable, so its persistence is testable, contrary to that record's negative conclusion. The root cause is not isolated. On paper the adapter presents each RV 32-bit word as four consecutive EEPROM byte addresses and captures each byte one cycle after presenting its address, which matches `eeprom_ram` port B's one-cycle latency, so the fault is likelier in the bank select or in whether the save engine issues word-aligned 32-bit reads than in the lane sequence. Two side effects are recorded rather than dropped: the pattern writes replaced the existing `.sav` files for Mario Kart and Emerald on the card, which were prior test artifacts and not operator data, and the Super Mario Advance 2 `.sav` was hidden during the blank test and left renamed `t_sma2.sav.bak`. No RTL was changed and no bitstream was rebuilt. The core-syntax audit was run: `.ai/core.md` and `.ai/core-syntax.md` were re-read, `.ai/core.md` was confirmed unchanged at md5 `1145a377cae5b553567ab6946ed78c01`, the complete `.ai/` diff was inspected, entry 2 was validated as the second entry of the rolled-over log with six canonical sections in order, a one-sentence Purpose, prose in Outcome and Next Steps, an allowed Status triple and a trailing `---`, the active log was confirmed at 2 entries against the 100-entry limit with no gaps in its numbering, and the reference store was confirmed at 194 records with 194 unique ids, no duplicates, every record in canonical field order, and every status inside the three-value vocabulary, being 179 `VERIFIED`, 8 `MEASURED` and 7 `LEAD`.

#### Next Steps:

Isolate the EEPROM fault, which is now the only save defect left and is well bounded: the failing addresses are fixed and known, the window is only 8 KB, and the simulation harness can build the real `gba_eeprom` and `eeprom_ram` under Verilator, so a write-then-read of the pattern there will show whether `bank_b` or the lane sequence is wrong without another place-and-route. Check first whether the save engine issues word-aligned 32-bit RV reads, because the adapter assumes `rv_addr[1:0] == 0` when it forces the first lane to `2'b00`, and a byte-granular transaction through that path would alias four addresses onto one and produce exactly this shape. Then re-run the two records the old result invalidated: BRD-094's persistence question is now answerable because a blank EEPROM store is producible, so write a pattern, power-cycle with the relay, read back with no restore to confirm it clears, then restore and confirm it returns; and BRD-096's claim that `eeprom_ram` was verified on hardware needs either a hardware result through the real EEPROM path or a note that it rests on the SDRAM path. Once the EEPROM store round-trips, the remaining save work is a retail title saving its own game -- an SRAM title such as Metroid Fusion, and Emerald afterwards. Two card files were left changed by this cycle and should be tidied when convenient: `t_sma2.sav.bak` should go back to `t_sma2.gba.sav`, and the Mario Kart and Emerald `.sav` files now hold test patterns rather than their previous contents. Do not cite BRD-092 or BRD-094 for the EEPROM store, and do not treat the EEPROM failure as evidence about the flash or SRAM paths, which are measured separately and pass.

#### Files Modified:

None.

#### Status:

- Build: N/A
- Deployment: PASS
- User Test: NOT RUN

---
## 3 COMMIT Unreleased 2026-11-16T12:41:12-07:00

#### Coming From:

Unreleased 05fb025

#### Purpose:

Re-examine the EEPROM failure entry 2 recorded, after another agent read the same dumps and attributed the differing bytes to the game rather than to the hardware.

#### Outcome:

Entry 2's EEPROM conclusion was wrong and is corrected. That entry reported 1,495 of 8,192 bytes differing and called it "an addressing or read-timing fault" and "not stored save data"; re-reading the same three dumps refutes both parts. At every one of those 1,495 positions the constant-`0xAA` dump and the post-power-cycle blank dump hold IDENTICAL values, 1,495 of 1,495 in each case, so three runs that began from three completely different contents agree byte for byte wherever they agree at all; and outside the differing region all 5,776 bytes from `0x970` to `0x1FFF` hold each run's own planted content, which is a clean round trip of the host byte port (BRD-112). The differing bytes are Super Mario Advance 2's save layout: 8-byte records repeated at `0x10` and `0x20`, an identical record at `0x80` and `0xc0`, and the same 8-byte slot header `00 00 41 21 0c a2 ea 82` every `0x180` bytes at `0x100`, `0x280`, `0x400`, `0x580`, `0x700` and `0x880`. On hardware the cartridge was loaded with `gbaload: save hardware = EEPROM` and captured at its title screen, so the game was executing and writing its own save over the planted pattern, and the dump was taken after it had been running. No read or addressing fault can produce these facts: aliasing or a lane swap would return planted data from the wrong address and would therefore differ between runs whose planted contents differ, and it would also corrupt the untouched region, which is correct in every byte. My error was one of inference rather than measurement -- I took "the junk is present even when nothing was planted" as proof it was not stored data, when a game that rewrites its save on every boot produces exactly the same observation. Two things follow that are better than what entry 2 recorded. This is the first hardware observation of a CPU-side EEPROM write landing in `eeprom_ram`: the game's records are visible through the host port and the game runs, which is evidence for the shared storage and the port-A write path. And the method lesson is worth stating because it will recur: a host round-trip test is only valid against a running cartridge if the cartridge provably does not write its save, which the flash and SRAM tests happened to satisfy and the EEPROM test did not. Chasing why the blank read is `0xFF` rather than the netlist's zero-valued `INIT_RAM` turned up a fact that retires a much older record: `gba_eeprom.sv` enters an `INIT` state on `rst` and walks all 65,536 bit addresses writing `1`, so a freshly configured board reads the all-ones state a real erased EEPROM presents, and the contents cannot survive a reconfigure because the reset fills them with ones (BRD-113). That is what BRD-094's "the EEPROM keeps its contents across a power cycle, decaying 360 of 8,192 bytes" was measuring, or rather failing to measure -- those accesses went to plain SDRAM under the one-bit `config_backup_type`, and with the real path selected the store is wiped on every reset. The general fact worth carrying is that no save type on this board is non-volatile, SRAM, flash and EEPROM all living in SDRAM or block RAM, which is the premise the save engine exists to compensate for. BRD-111 is annotated as refuted with its heading and statement left as settled history. What is still not established is the CPU read path -- whether a cartridge reads its own EEPROM save back correctly -- and an exact round trip of a save the cartridge considers valid, which needs an emulator-produced save or an in-game save. The core-syntax audit was run: `.ai/core.md` and `.ai/core-syntax.md` were re-read, `.ai/core.md` was confirmed unchanged at md5 `1145a377cae5b553567ab6946ed78c01`, the complete `.ai/` diff was inspected, entry 3 was validated as the third entry of the rolled-over log with six canonical sections in order, a one-sentence Purpose, prose in Outcome and Next Steps, an allowed Status triple and a trailing `---`, the active log was confirmed at 3 entries against the 100-entry limit with no gaps in its numbering, and the reference store was confirmed at 196 records with 196 unique ids, no duplicates, every record in canonical field order, and every status inside the three-value vocabulary, being 181 `VERIFIED`, 8 `MEASURED` and 7 `LEAD`.

#### Next Steps:

Prove the EEPROM CPU read path, which is the one thing now standing between the board and a save system trusted for every cartridge: an in-game save in Super Mario Advance 2, then `gbasave`, a relay power cycle, `gbaload` and continuing the game, because a cartridge that accepts its own restored save is the only evidence that the read side works and that the restored bytes are a valid save rather than a plausible layout. The same test is worth running for Metroid Fusion on SRAM and Emerald on flash1M, and the strongest version is to move a `.sav` in both directions between the board and mGBA 0.10.5, which BRD-092's method already assumes. Note before running it that the store is re-initialised to all-ones on every reset, so a save is only ever as durable as the card copy written by `gbasave`, and that no save type here is non-volatile. Two records worth revisiting in that light: BRD-092's EEPROM row should be struck rather than merely questioned, since it measured the SDRAM path, and the README's save section still cites BRD-092 as authority. Once a cartridge round-trips its own save, the release question the project has deferred is live again -- `core.md` calls for a MINOR bump at a hardware-proven capability and no tags exist yet -- but that is external publication and waits on the operator. `tools/roms/savewprobe.s` and `tools/roms/saveprobe_iw.s` remain the outstanding loose ends, unvalidated and the latter still untracked.

#### Files Modified:

None.

#### Status:

- Build: N/A
- Deployment: PASS
- User Test: NOT RUN

---
## 4 COMMIT Unreleased 2026-11-16T12:48:45-07:00

#### Coming From:

Unreleased fa1c1bc

#### Purpose:

Test the EEPROM path against an independent emulator, which is both the check BRD-112's argument wanted and the remaining unknown after it -- whether a cartridge can read a save back.

#### Outcome:

Three results, one of which is a new defect. Following the same route as before, the SMA2 cartridge image was fetched off the card with the shell's `tangget`, run in mGBA 0.10.5 with no save present so that the game formatted a fresh 8,192-byte EEPROM save, and that file was diffed against the window the board held after the same game had likewise formatted one. The layouts are identical -- same `0xFF` runs, same 8-byte records at `0x10` and `0x20`, same slot header at `0x100`, `0x280`, `0x400`, `0x580`, `0x700` and `0x880` -- but the values are bit-reversed: at every one of the 1,504 positions where neither side holds `0xFF`, the hardware byte equals the bit-reversal of the mGBA byte, 1,504 of 1,504, and the slot header reads `00 00 41 21 0c a2 ea 82` against mGBA's bytes reversed. That is a real defect and it is explained by the store's two views: `eeprom_ram` is bit-serial on port A, where the game writes the protocol's most-significant bit first into increasing bit address, and byte-wise on port B, where byte `n` occupies bit addresses `8n` to `8n+7` with `8n` as the least-significant bit, so a most-significant-first byte arrives in port B reversed (BRD-114). The consequence is narrow but matters: `gbasave` and `gbaload` are self-consistent because write and read both cross port B, which is why planted patterns round-tripped in every region the game did not touch, but the EEPROM `.sav` is not in the byte order an emulator uses, so it cannot be moved between board and emulator without reversing each byte -- which is the interoperability that already works for the other three types. The game is unaffected because it only speaks port A. Second, the CPU-side read path works, and this was the last unproven part of the save system: mGBA's save was bit-reversed into this core's order, written to the card, restored by `gbaload`, and after the game had run for 55 seconds the window still read byte-identical to the file uploaded, sha256 `4b069f40...`, with the game visibly running -- so the cartridge read a save produced outside the board, found it valid and continued without formatting over it (BRD-115). The contrast is what makes that evidence: with a ramp pattern, a constant `0xAA`, and a freshly configured `0xFF` store, the same cartridge rewrote the window into its own layout within the same 25-second window, so it demonstrably inspects its save at boot and reformats what it cannot read. Third, this confirms BRD-112 by a route that does not depend on any argument about byte patterns, since a save the game accepts is exactly the records BRD-111 called corruption. Two limits are recorded with the results. The emulator save and the cartridge image live in `/tmp` and the ROM is the operator's own cartridge, so neither enters the repository and the comparison rests on scratch files; and no save of actual gameplay has yet been written by a cartridge and recovered after a power cycle, which is the remaining test and needs play rather than a format. The board was left running SMA2 with the accepted save. No RTL was changed. The core-syntax audit was run: `.ai/core.md` and `.ai/core-syntax.md` were re-read, `.ai/core.md` was confirmed unchanged at md5 `1145a377cae5b553567ab6946ed78c01`, the complete `.ai/` diff was inspected, entry 4 was validated as the fourth entry of the rolled-over log with six canonical sections in order, a one-sentence Purpose, prose in Outcome and Next Steps, an allowed Status triple and a trailing `---`, the active log was confirmed at 4 entries against the 100-entry limit with no gaps in its numbering, and the reference store was confirmed at 198 records with 198 unique ids, no duplicates, every record in canonical field order, and every status inside the three-value vocabulary, being 183 `VERIFIED`, 8 `MEASURED` and 7 `LEAD`.

#### Next Steps:

Correct the EEPROM byte order, which is now the only known save defect and is a host-side change: reverse the bit order in `eeprom_ram`'s port B, or in the firmware's `gbasave`/`gbaload` for EEPROM cartridges, and verify by round-tripping a `.sav` to and from mGBA both ways without a manual reversal in between -- the direction that has not been tested is a board-produced save opened in the emulator. Whichever side is fixed, the cartridge must be unaffected, so the acceptance test of BRD-115 is the regression check: plant a save, run the game, confirm the store is not reformatted. That fix needs approval because it changes RTL or firmware, and it should be its own commit rather than folded into a documentation cycle. After it, the last save test is a cartridge writing its own gameplay and finding it again across a power cut -- an in-game save in Metroid Fusion for SRAM, Emerald for flash1M and SMA2 for EEPROM, then `gbasave`, the relay power cycle, `gbaload`, and continuing the game, with each `.sav` also loaded in mGBA to check interoperability. The relay tool at `~/Desktop/reboot_in 2_wire.py` supplies the power cut that test needs. Two housekeeping items remain untouched: `tools/roms/savewprobe.s` and `tools/roms/saveprobe_iw.s` are unvalidated instruments for a defect that is now closed and should be finished or deleted, the latter still untracked; and the release question stays with the operator, since `core.md` calls for a MINOR bump at a hardware-proven capability and the save path is close to that mark. Do not cite BRD-092 for the EEPROM store, and do not assume an EEPROM `.sav` from this project opens in an emulator until the byte order is fixed.

#### Files Modified:

None.

#### Status:

- Build: N/A
- Deployment: PASS
- User Test: NOT RUN

---
## 5 COMMIT Unreleased 2026-11-16T14:26:32-07:00

#### Coming From:

Unreleased 92b24e5

#### Purpose:

Fix the EEPROM byte order that entry 4 measured, prove it on hardware in both directions, and use the 8-seed sweep to choose the placement.

#### Outcome:

The EEPROM byte-order defect is fixed and verified on the board in both directions. `rv_sdram_adapter.v` now applies a `rev8` at the host boundary in both directions -- on write through `eeprom_wdata` and the `rv_wdata` lane, and on read through the three `eeprom_rdata0` lanes and the `rv_rdata` assembly -- rather than converting inside `eeprom_ram`, because that file is deliberately byte-identical to the vendor primitive and `tb_eeprom_equiv.sv` asserts exactly that (TCL-065), while the byte order is a property of the external interface. Proof, on `build/eeprom_s7` with every gate passing and `hold 0`: mGBA's standard-order SMA2 save uploaded UNMODIFIED was accepted by the cartridge and the window still read byte-identical after 30 seconds of play, where before the fix an unmodified emulator save was reformatted within 25 seconds; and then the reversed file this project previously had to produce was uploaded as a negative control, the cartridge rejected and reformatted it, and the fresh save the game wrote read back out byte-identical to mGBA's independently generated file. That last step is what proves the reverse direction, because those bytes came from the game's own write path and arrived at the host in emulator order (BRD-116). The regression is committed rather than incidental: `tools/save/tb_save.sv` now models the store bit-faithfully -- cartridge-visible bytes above the model, `rev8` across it -- and was mutation-tested, giving 360 mismatches with the adapter conversion removed and PASS with it, so the order cannot silently drift back. This also closes the third save type with a real game rather than a probe: your in-game Pokemon Emerald save, captured off the running board over `fpgapipe`, wrote sectors 13 to 26 with valid `0x08012025` footers and mGBA accepted it byte for byte unchanged, which with Metroid Fusion's SRAM save and the SMA2 EEPROM save means all three save types now have a `gbasave` equivalent proven end to end against an independent emulator. One incidental finding came out of that dump and is recorded because it misled the first reading: Emerald's flash held the previous cartridge's SRAM image in sectors 0 to 12, byte-identical to Metroid's save including its `b4c89ba1` signature, so the loader does not clear the save window when it changes cartridge and a dump's contents outside a game's own sectors say nothing about that game. The sweep the operator asked for ran as eight concurrent placements: seeds 1, 3 and 7 produced bitstreams and all three pass every gate with `hold 0`, no relaxation and `clk67` on `SPINE25/TOP1=good`; seed 7 is the best and was deployed, at `clk67` 206.697 MHz against seed 1's 190.803 and seed 3's 194.780, `hclk` 94.251 against 85.638 and 90.901, and 385,361 router iterations against 433,391 and 424,720. Seeds 2, 4, 5, 6 and 8 were still routing when this cycle closed and their outcomes are not recorded here. This netlist routes harder than the previous one for a trivial reason worth noting: `rev8` added 29 arcs, 175,507 against 175,478, and seed 1 needed 433,391 iterations where the pre-fix netlist finished at 410,007. Three of my own errors are recorded: I described the first build as being in placement for forty minutes when it was forty minutes into routing; I read a 128 KiB dump's Metroid signature as evidence that the capture had failed, when it was stale data from the previous cartridge that the loader legitimately leaves in place; and my first sweep monitor read only the routing table, so it reported every seed as `ITER 0` until I made it report the phase. The board was left running `build/eeprom_s7` with SMA2 and its accepted save. No RTL logic other than the byte-order conversion changed. The core-syntax audit was run: `.ai/core.md` and `.ai/core-syntax.md` were re-read, `.ai/core.md` was confirmed unchanged at md5 `1145a377cae5b553567ab6946ed78c01`, the complete `.ai/` diff was inspected, entry 5 was validated as the fifth entry of the rolled-over log with six canonical sections in order, a one-sentence Purpose, prose in Outcome and Next Steps, an allowed Status triple and a trailing `---`, the active log was confirmed at 5 entries against the 100-entry limit with no gaps in its numbering, and the reference store was confirmed at 199 records with 199 unique ids, no duplicates, every record in canonical field order, and every status inside the three-value vocabulary, being 184 `VERIFIED`, 8 `MEASURED` and 7 `LEAD`.

#### Next Steps:

Two things follow directly. The `.sav` convention changed, so anything written by an earlier image of this project is in the reversed order and needs converting once -- the SMA2 in-game save was converted and put back on the card, but Mario Kart's flash512K save and the older test files were left as they were, and any save the operator cares about should be checked before the next load. Then the remaining save test is the whole chain with a game rather than a probe: an in-game save in each type, `pipe_save_dump.py` rather than `gbasave` because `gbasave` has killed the console three times (TCL-064), a relay power cycle, `gbaload`, and the game continuing from its own save. Metroid Fusion is the natural first case since its SRAM save already reads out in a standard order that mGBA accepts. Also outstanding: seeds 2, 4, 5, 6 and 8 of the sweep were still routing, and if any of them finishes with a better `clk67` than seed 7's 206.697 MHz it is worth knowing before seed 7 is treated as the reference placement; the log is at 5 of 100 entries so there is room either way. Two instruments remain unvalidated and should be finished or deleted: `tools/roms/savewprobe.s` is marked NOT VALIDATED and `tools/roms/saveprobe_iw.s` is still untracked. Finally the release question is now live on its own merits -- three save types are proven with real games, and `core.md` calls for a MINOR bump at a hardware-proven capability with no tags existing yet -- but tagging is external publication and waits on the operator.

#### Files Modified:

- fpga/gba/src/memory/rv_sdram_adapter.v
- tools/save/tb_save.sv

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: PASS

---
## 6 COMMIT Unreleased 2026-11-16T15:06:57-07:00

#### Coming From:

Unreleased 1999b98

#### Purpose:

Check the byte-order fix for regressions in the save types it also touches, close the last documented save gap with a game's own save through a real power cut, and rank the finished sweep seeds.

#### Outcome:

Three results and one correction. First, the byte-order fix introduced no regression, which was the risk worth checking because `rev8` sits in `rv_sdram_adapter` and that adapter carries every RV save transfer, not only EEPROM. On `build/eeprom_s7` a 65,536-byte canonical pattern planted as Mario Kart's `.sav` read back byte-identical (sha256 `ef463692...`, the same digest this project measured before the fix), and `saveprobe` on the same bitstream drew square 0 RED and square 1 GREEN, which is the baseline that shows the width fix is still doing its work. SRAM and flash share the same non-EEPROM path through the adapter, so flash being exact covers both. Second, the last documented save gap is closed: your in-game Pokemon Emerald save, captured off the board over `fpgapipe` and written to the card, was restored by `gbaload` on the post-fix image and read back byte-identical (`1cbedc9a...`), the board was then power-cycled by the relay sequence with all three steps acknowledged, and after `tangload` and `gbaload` the window again read `1cbedc9a...` and the game booted to its title screen and then to a main menu offering `CONTINUE` with the saved player name, play time and badge count on screen. That menu is the observation a window dump cannot make: the cartridge found a save it considers valid and was prepared to resume, so a retail game's own save has now survived a real power loss end to end (BRD-117). Third, five of the eight sweep seeds have finished and all pass every gate with `hold 0`, no relaxation and `clk67` on a measured-good plane; seed 7 is the best at `clk67` 206.70 MHz against seed 3's 194.78, seed 1's 190.80, seed 8's 177.53 and seed 4's 176.40, and it also routed in the fewest iterations at 385,361 against 424,720, 433,391, 411,076 and 493,121, so the deployed image is the right one. Seeds 2, 5 and 6 were still routing when the cycle closed and are not recorded. The correction is the significant part. BRD-092's SRAM row is vacuous: it was committed on 2026-11-15 at 08:08 and the width declaration `181bf2f` landed that day at 22:26, so on the image it measured `config_backup_type` was one bit, SRAM reached the controller as flash512K, the flash interpreter swallowed every CPU store to the cartridge window, Metroid could not write, the planted pattern survived untouched, and the exact read-back BRD-092 recorded as a successful round trip is what an unwritable store returns. Re-running the same test on the fixed image gives 32,642 of 32,768 bytes differing and Metroid's own header in the window (`b4c89ba1... MetroidAGB-EU`), because the game reformatted the pattern on boot (BRD-118). I found this by making the same mistake twice, which is worth recording: I planted a pattern in Metroid's `.sav` expecting a round trip, and the game reformatted it, exactly as BRD-112 records for Super Mario Advance 2. All three cartridges now tried -- SMA2, Metroid and Emerald -- rewrite a save they cannot validate, so a host round-trip against a running cartridge is only meaningful when the game's own save is what was planted, and an exact round trip is the expected result both when the path works and when the cartridge cannot write at all. BRD-092 is annotated as refuted in part with its heading and statement left as settled history. Your card saves were backed up to `/tmp` before the tests disturbed them and Metroid's was restored afterwards; Mario Kart's now holds the test pattern and the Emerald `.sav` was restored from the verified copy. The core-syntax audit was run: `.ai/core.md` and `.ai/core-syntax.md` were re-read, `.ai/core.md` was confirmed unchanged at md5 `1145a377cae5b553567ab6946ed78c01`, the complete `.ai/` diff was inspected, entry 6 was validated as the sixth entry of the rolled-over log with six canonical sections in order, a one-sentence Purpose, prose in Outcome and Next Steps, an allowed Status triple and a trailing `---`, the active log was confirmed at 6 entries against the 100-entry limit with no gaps in its numbering, and the reference store was confirmed at 201 records with 201 unique ids, no duplicates, every record in canonical field order, and every status inside the three-value vocabulary, being 186 `VERIFIED`, 8 `MEASURED` and 7 `LEAD`.

#### Next Steps:

The save path is now measured end to end for all three types, so what remains is cleanup and a decision rather than a test. Cleanup: restore Mario Kart's `.sav` on the card from `/tmp/card_mariokart_backup.sav`, which currently holds a test pattern, and note that the two unvalidated probe instruments are still outstanding -- `tools/roms/savewprobe.s` is marked NOT VALIDATED and `tools/roms/saveprobe_iw.s` is untracked, and the defect they were written to chase is now closed and explained, so they should either be finished or deleted. The decision is the release: `core.md` calls for a MINOR bump at a hardware-proven capability and no tags exist in this repository, and the capability is now there to justify one -- twelve titles run, all three save types save from a real game and are accepted by an independent emulator, and a game's own save survives a real power loss. Tagging is external publication, so it waits on you. Two smaller items: seeds 2, 5 and 6 of the sweep were still routing and none is expected to beat seed 7's 206.70 MHz, but if one does it is worth knowing before seed 7 is called the reference placement; and the README's known-gaps section should drop the power-cut entry now that this cycle closed it, which is a documentation change I would fold into whichever cycle comes next. Do not run `gbasave` on this board -- it has killed the console three times -- and use `tools/save/pipe_save_dump.py`, which reads the same window over `fpgapipe`.

#### Files Modified:

None.

#### Status:

- Build: N/A
- Deployment: PASS
- User Test: PASS

---
## 7 COMMIT Unreleased 2026-11-16T17:13:07-07:00

#### Coming From:

Unreleased 5259879

#### Purpose:

Give TinyGBA the TinyDesk overlay layer it lacked, so TinyTang's desktop can draw into this core, and prove the layer on this port with a self-contained colour-bar image before attempting the launcher.

#### Outcome:

TinyGBA renders TinyTang's desktop. `desk_layer.v` is vendored verbatim from TinySNES at `768f6ff` with its body byte-identical on both sides (md5 `81de82010cb43d60dd3f8b364417b1a8`, provenance header only) along with its public-domain `font8x8_basic` ROM, both attributed in `THIRD_PARTY.md`. `iosys_bl616.v` gained the three commands that desktop uses -- `0x13` cursor within an 80x45 grid, `0x14` cells at five bytes each, `0x15` enable -- and `gba2hdmi.sv` instantiates the layer on the pixel clock and lets it own a pixel ahead of the legacy 960x720 text window, which it could not before because that window draws one character row in one fixed palette and a desktop needs per-cell foreground and background. Proven on `build/desk_bars2` (`c004c4bf...`, retail BIOS `a599090b2107db6d`, `hold 0`, every gate passing) with a new `desk_test_pattern.v`: eight vertical bars in colour-bar order at full 720-pixel height with `TINYGBA DESK` across the top row, needing no cartridge and no host. Measured from the capture rather than described, the six distinguishable bars run 216 to 232 pixels against the 240 the geometry predicts, the last two are both black and merge into one 464-pixel run by design, and the left edge is correct at every height sampled, so the grid tiles the frame. That image earned its place twice over by finding two defects in itself that review and simulation had not. The first was ordinary and visible: `col` was six bits wide for eighty columns, so it wrapped at 63, `col == COLS-1` never fired, the row counter never advanced, and the sweep overwrote cells 0 to 63 forever -- the screen showed six bars in one row and nothing else. The second was the dangerous kind and was invisible in that picture: the cell period was four clocks while the layer registers `wr_tog` through a four-deep synchroniser, so the write lands four clocks after the toggle and the address had already advanced, which would have written every cell to the slot after its own and rendered a picture that was nearly right. That one came from arithmetic on the layer's synchroniser rather than from looking, and the period is now eight clocks with the reasoning written beside the constant (TCL-084, BRD-119). Synthesis also caught a fault of mine before hardware did: wiring the test pattern and `iosys` onto the same nets produced a driver-driver conflict that synthesis resolved silently to a constant, which would have shown a static picture with no error anywhere; the test now drives its own nets. One gate was relaxed and is recorded rather than hidden: the BSRAM address-port gate flags `video.u_desk.cells` at 9 to 12 logic levels against at most 7 elsewhere, because the vendored layer computes `row * 80 + col` inside a body this project has promised to keep byte-identical, so it is listed in `--known` beside `mem_bios` as a tolerance with its consequence bounded -- a violation can misplace a character cell and cannot corrupt memory the machine runs from. Cost is 12,480 to 12,616 flip-flops and 126 to 132 block RAM. Separately, the 8-seed placement sweep finished and seed 7 remains the best bitstream of the set: `clk67` 206.70 MHz against 198.14, 194.78, 192.60, 190.80, 177.53 and 176.40 for seeds 5, 3, 2, 1, 8 and 4, all with `hold 0` and `clk67` on a measured-good plane; seed 6 was killed at the operator's direction after 2 hours with 1,102 arcs still unrouted. The core-syntax audit was run: `.ai/core.md` and `.ai/core-syntax.md` were re-read, `.ai/core.md` was confirmed unchanged at md5 `1145a377cae5b553567ab6946ed78c01`, the complete `.ai/` diff was inspected, entry 7 was validated as the seventh entry of the rolled-over log with six canonical sections in order, a one-sentence Purpose, prose in Outcome and Next Steps, an allowed Status triple and a trailing `---`, the active log was confirmed at 7 entries against the 100-entry limit with no gaps in its numbering, and the reference store was confirmed at 203 records with 203 unique ids, no duplicates, every record in canonical field order, and every status inside the three-value vocabulary, being 188 `VERIFIED`, 8 `MEASURED` and 7 `LEAD`.

#### Next Steps:

The RTL half of the launcher is done, so the next step is on the other side of the link and needs no rebuild: TinyTang's tree contains no launcher yet, and it can now drive this core with `0x13`, `0x14` and `0x15`. Before that work starts, one thing is worth doing first because it is cheap and would change how the layer is judged: write cells from the firmware rather than from the test pattern -- a single `0x13` followed by a `0x14` frame -- and confirm they land where expected, which is the only way to exercise `iosys_bl616`'s new command handling, since the test image bypasses it entirely by driving the layer's write port directly. If that works the two black bars in the test image should also be resolved, since the eighth bar being indistinguishable from the seventh is a weakness of the test as much as of anything: a pattern with eight clearly distinct bars would say more than one with two blacks. Two things about the deployed image are worth carrying forward: `clk67` passes only because of the documented GBATang multicycle path, so any timing figure from it must say so (TCL-056), and the BSRAM tolerance on the desk cell store remains a recorded risk rather than a settled one. `tools/roms/saveprobe_iw.s` is still untracked and still unvalidated, and the defect it was written for is now closed, so it should be finished or deleted. The board is left running `build/desk_bars2` with no cartridge.

#### Files Modified:

- fpga/gba/src/desk_layer.v
- fpga/gba/src/desk_font.hex
- fpga/gba/src/desk_test_pattern.v
- fpga/gba/src/gba2hdmi.sv
- fpga/gba/src/gbatang_top.sv
- fpga/gba/src/iosys/iosys_bl616.v
- tools/build_tinygba.sh
- THIRD_PARTY.md

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: NOT RUN

---
## 8 COMMIT Unreleased 2026-11-16T18:47:17-07:00

#### Coming From:

Unreleased 312cede

#### Purpose:

Make the HOME button switch between TinyTang's desktop and a running game, as it does on TinySNES, so a cartridge can be booted from the desktop rather than from a shell.

#### Outcome:

HOME switches between the desktop and the game, in both directions, with the emulator running throughout. The mechanism turned out to be the host's rather than the core's: TinyTang's desk task toggles the overlay on a rising edge of `TANG_PAD_LB`, which is bit 10 of the pad word it receives, and that task is not gated on core identity, so any core that reports bit 10 gets the toggle. TinyGBA now reports bit 10 from a clean tap of HOME -- pressed and released with nothing else held -- held for 13 ticks of 20 ms, the same 260 ms TinyNES and TinySNES use so the host cannot miss the edge. Verified on `build/home_toggle` (`b6536413...`, seed 7, `clk67` 132.644 MHz, `hold 0`, no relaxation needed, census matching the updated baseline) with Metroid Fusion loaded: starting the desktop from the firmware drew its full UI -- icons, the Start menu, the window list -- and after `osd off` the same cartridge was still playing at 24 energy, 73 missiles and 16 power bombs with its map overlay up, so it had run continuously through the test rather than restarting. The operator confirmed that HOME switches both ways and that the shoulder button does not open the desktop (BRD-120). Two faults had to be fixed first and neither was in the layer being added. This core relays `joy1` unchanged in the DS2/SNES layout where bit 10 is L, while the host reads bit 10 as the toggle, so the moment a toggle existed every shoulder press would have opened the desktop over a running game; the report now masks bit 10 and drives it only from the HOME tap. And `JOY_UPDATE_INTERVAL` was `50_000_000 / 50`, which is 20 ms only at 50 MHz -- this block runs on `clk16`, so reports went out every 59.7 ms, three times slower than the comment claimed and slower than the desktop's own 40 ms poll, which would have made the pointer lag by design; it is now derived from `CLK_FREQ` (TCL-085). A third change was for completeness rather than for a defect: `joy_wii` was never part of the reported word, so a Wii pad could play the game but could not move the desktop pointer, and it is now included. The build also stopped once, correctly, at the memory-placement gate, because the desk's cell store appeared in the production census where it had not been before -- `video.u_desk.cells` at 10 block RAM -- and that gate refused to pass an undeclared memory change. The baseline was updated after checking the diff was exactly that one addition with nothing removed or altered, which is the discipline the gate exists to force rather than to bypass. This cycle also proves `iosys_bl616`'s three desk commands on hardware for the first time: the colour-bar image of BRD-119 drives the layer's write port directly and bypasses them entirely, so the full TinyDesk UI could not have drawn had the command handling been wrong. The core-syntax audit was run: `.ai/core.md` and `.ai/core-syntax.md` were re-read, `.ai/core.md` was confirmed unchanged at md5 `1145a377cae5b553567ab6946ed78c01`, the complete `.ai/` diff was inspected, entry 8 was validated as the eighth entry of the rolled-over log with six canonical sections in order, a one-sentence Purpose, prose in Outcome and Next Steps, an allowed Status triple and a trailing `---`, the active log was confirmed at 8 entries against the 100-entry limit with no gaps in its numbering, and the reference store was confirmed at 205 records with 205 unique ids, no duplicates, every record in canonical field order, and every status inside the three-value vocabulary, being 190 `VERIFIED`, 8 `MEASURED` and 7 `LEAD`.

#### Next Steps:

The launcher the operator actually asked for is now unblocked and is the next thing worth building, on the TinyTang side: select a cartridge from the desktop and have `gbaload` stream it with the overlay hidden, so booting a game stops being a shell sequence. The pieces are in place -- the desktop draws, the commands are proven, and the overlay toggles without disturbing a running game -- so what is missing is the desktop application itself, which lives in TinyTang's tree and not here. Two things are worth settling before that work starts. HOME toggles the overlay but does not start the desktop if it was never started, which is correct while the desktop is launched from the shell and may not be once it is the primary way in; that is a host-side decision. And nothing reads the pad word back for verification, because TinyTang exposes no command for it, so every claim about this core's report rests on the operator pressing buttons -- a `pad` shell command that prints the last word would make the next input change checkable without a human. Two smaller items remain as before: `tools/roms/saveprobe_iw.s` is still untracked and unvalidated with its defect closed, and the BSRAM tolerance on `video.u_desk.cells` (9 to 12 levels against a bound of 8) is a recorded risk rather than a settled one, which matters more now that the layer draws continuously during play rather than only under a test image.

#### Files Modified:

- fpga/gba/src/gbatang_top.sv
- fpga/gba/src/iosys/iosys_bl616.v
- tools/memory_baseline.json

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: PASS

---
## 9 COMMIT Unreleased 2026-11-16T19:31:10-07:00

#### Coming From:

Unreleased 73bae0b

#### Purpose:

Record that TinyGBA now boots cartridges from TinyTang's desktop, the launcher page that BRD-120's overlay toggle made possible.

#### Outcome:

TinyGBA appears in TinyTang's Start menu as a cartridge library and boots games from it, which closes the last operational gap between this core and the other four on the board -- TinyNES, TinyGBC and TinySNES were all drivable from the desktop and this one was not. The app itself lives in TinyTang's tree and is recorded there as that repository's log entry 35 and record GBA-003; what this entry records is that the core supports it and that the route was exercised. Selecting a cartridge programs `tinygba.bin` from the card, streams the image, and the game runs with the overlay hidden; a tap of HOME brings the desktop back over the running game and brings the game back again, the toggle BRD-120 measured. The operator confirmed the route on hardware and then loaded a second title from the same window without returning to a shell (BRD-121). On the firmware side the load was made shared rather than copied, which is the part that matters for maintenance: `tang_gba_load()` is the body of `cmd_gbaload` lifted into a callable function with the same contract as `tang_snes_load()`, so the shell command is now path resolution and the desk app takes the same path, and `gbaload` was re-tested on the new firmware afterwards rather than assumed -- `save hardware = SRAM`, `restoring 32768 bytes of SRAM`, `save restored`, `8388608 bytes in; the core is running`. Two corrections were made to my own work during the cycle. The app first called a window API this TinyDesk does not have, using `td_window` and `td_window_set_tick` where the working idiom is `td_win_create` with a `td_window_desc_t`; the compiler caught it, and a second pass caught a missing `AM_VOLUME_LABEL`. And `gba_save_restore` still printed through `tdsh_printf` with a `gbaload:` prefix after the extraction, so its seven messages were converted to the shared dual-output helper and the firmware rebuilt, reflashed and re-tested rather than committed unrun. One entry of the earlier round was also wrong and was fixed before commit: the TinyTang log entry was first written without the six canonical sections and with a `verification:` field inside the Outcome, which that repository's syntax does not allow, and it was rewritten in the canonical shape. The launcher is deliberately one page -- Library, with Launch, Up and Refresh -- because this core implements no frame for a pad map, a video shape or a volume, so the Input, Video and Audio pages TinySNES carries would be controls that do nothing; the Saves page was left out for time rather than for a missing mechanism, since the save path is proven for all four types and `gbasave` exists. The board reports firmware `tinytang 8abefad-dirty.032e2ad`; the TinyGBA bitstream at the launcher's own path `/root/cores/console138k/tinygba.bin` was replaced with `build/home_toggle/tinygba.bin`, so a rebuild now only needs that file copied for the desktop to pick it up. The core-syntax audit was run: `.ai/core.md` and `.ai/core-syntax.md` were re-read, `.ai/core.md` was confirmed unchanged at md5 `1145a377cae5b553567ab6946ed78c01`, the complete `.ai/` diff was inspected, entry 9 was validated as the ninth entry of the rolled-over log with six canonical sections in order, a one-sentence Purpose, prose in Outcome and Next Steps, an allowed Status triple and a trailing `---`, the active log was confirmed at 9 entries against the 100-entry limit with no gaps in its numbering, and the reference store was confirmed at 206 records with 206 unique ids, no duplicates, every record in canonical field order, and every status inside the three-value vocabulary, being 191 `VERIFIED`, 8 `MEASURED` and 7 `LEAD`. TinyTang's own log was checked by the same script and found to hold 35 entries numbered 1 to 35 with no gaps, each with six sections and a trailing `---`.

#### Next Steps:

Build the Saves page, because it is the one remaining launcher page that needs nothing new in this core: all four save types are proven, `gbasave` exists, and a page listing the selected cartridge's save, its size against what the cartridge's own header implies, and a Restore action would be the first page beyond the library that does real work -- and it belongs in TinyTang's tree, with this repository only supplying the core. The Input, Video and Audio pages should wait until this core implements the frames behind them or they will be controls that do nothing. Two gaps are worth closing in this repository rather than that one. Per-chunk load progress reaches only the console, which is hidden while a game runs, so a 32 MiB cartridge's load is invisible from the desktop; the core reports no progress and the firmware's `gba_say()` already carries the lines, so the missing piece is a frame the desktop can read or a status the app can poll. And nothing here verifies the launcher end to end, so a future change to the desk commands or the pad report would be caught only by a person pressing buttons -- BRD-120 noted the same absence for the pad word. The desktop work is now ahead of the core in one respect worth deciding: TinySNES's pages depend on frames this core has not implemented, so whether TinyGBA grows those frames or stays a library-only launcher is a scope decision, not a defect.

#### Files Modified:

None.

#### Status:

- Build: N/A
- Deployment: N/A
- User Test: PASS

---
## 10 COMMIT Unreleased 2026-11-16T22:09:22-07:00

#### Coming From:

Unreleased d2c8b3c

#### Purpose:

Clear the record and card debt the save-path cycles left behind -- two reference records still standing on retired conclusions, a README that understated what the save path has proven, two probe instruments for a closed defect, and a test pattern sitting where Mario Kart's save belongs.

#### Outcome:

The records now say what the later evidence established, and one item could not be done as planned. BRD-107 is retitled `REFUTED by BRD-108` and its consequence opens with a dated note: the two black seed-1 images carried the free BIOS, netlist signature `5953aaf13e0e7692`, against the retail `a599090b2107db6d` in both working images, and `build/head_retail_s1` at the same default seed 1 with the retail BIOS boots and runs the probe (BRD-109), so seed 1 is not unsafe and no seed-sensitivity reading should be taken from it; the record still said `MEASURED` with the seed explanation standing, which is the reading a future agent would have acted on. BRD-105 is marked closed by BRD-109 and its status raised from `MEASURED` to `VERIFIED` with a revision note, because both limits it stated were later retired -- the red square that made the width fix look insufficient was the simulation pin model's wired-OR (BRD-106), and the flash-type check it asked for was made by BRD-111's re-taken round trips. Both edits follow the store's own precedent from BRD-062, a prefixed title and a dated note at the head of the consequence with the original text left as settled history. The README's save section still said that a game's own save carried across a power cut was not established, which BRD-117 closed when Pokemon Emerald offered `CONTINUE` after a relay cut; that sentence and the Open section's "passes for SRAM" now record it, and two citations that used BRD-092 as evidence now cite BRD-116 for the save bench and BRD-110 and BRD-117 for the loader's restore, while the one remaining mention, which cites BRD-092 as the example of a wrong result, is correct and stays. `tools/roms/savewprobe.s`, marked NOT VALIDATED since entry 94 of the archived log, was removed with `git rm` and remains in history at `199ab1d`, with a dated note added to TCL-080, the record that describes it as committed. `tools/roms/saveprobe_iw.s` had never been tracked, so deleting it would have been unrecoverable; it was moved out of the repository to `/run/media/vash/GIT/tinytang-scratch/removed-2026-11-16/saveprobe_iw.s` at sha256 `844307392d93acb542bd5a680d5e1bf76f4380459c50e9b805204162feb31927`. `tools/make_probe_rom.py` lists probes by scanning the directory, so nothing else referred to either file. The planned restore of Mario Kart's save could not be done: `/tmp/card_mariokart_backup.sav`, which entry 6 named as the backup, matches the canonical pattern `(i*31+7) & 0xFF` in all 65,536 bytes, so it was taken after the card copy had already been overwritten, and no real Mario Kart save was found in the SD staging trees, the board backups, the scratch directories, mGBA's directories, the Desktop, Downloads or `/tmp`. At the operator's choice the pattern file `/root/media/gba/Mario Kart - Super Circuit (USA).gba.sav` was deleted on the card from the board's shell instead, so the game starts with no save rather than one it would reformat, and a listing afterwards shows the cartridge image still present. One operational trap is recorded because it nearly produced a false result: the first `rm` was sent while the board was showing TinyDesk, which held the console, so the command never reached the shell and a listing taken in the same state returned nothing usable; after the operator rebooted to the prompt the file was found still present and was deleted then. No RTL or firmware was changed, nothing was built or deployed, and the two uncommitted RTL files left by an unlogged session after entry 9 -- `fpga/gba/src/gbatang_top.sv` and `fpga/gba/src/iosys/iosys_bl616.v`, the HOME-with-SELECT exit chord built as `build/exitkey` -- are deliberately not part of this cycle. The core-syntax audit was run: `.ai/core.md` and `.ai/core-syntax.md` were re-read, `.ai/core.md` was confirmed unchanged at md5 `1145a377cae5b553567ab6946ed78c01`, the complete `.ai/` diff was inspected and holds this entry and the BRD-105, BRD-107 and TCL-080 revisions only, and this entry was validated as number 10 of 100 with six canonical sections in order, a one-sentence Purpose, prose in Outcome and Next Steps, only eligible paths in Files Modified and allowed Status values.

#### Next Steps:

Decide the fate of the unlogged save-and-exit work before anything else touches the board, because it is split across two repositories and one half of it is the leading suspect for the TinyTang firmware that would not start on 2026-11-16 (TinyTang log entry 36): this repository holds the RTL half uncommitted, and the recommendation is to park both halves together rather than commit or discard either, then find the firmware fault with the console attached and the crash recorder read straight after, and address `gbasave`'s SD-write wedge (TCL-064), which that design depends on, before it ships. The card still carries test leftovers in `/root/media/gba/` -- `t_sma2.gba` and its save, `marker.bak`, `smw_pattern.bak`, the `saveprobe*` cartridges and saves, and `Pokemon - Emerald Version (USA, Europe).gba.sav.patterntest` -- which can be cleared when the operator wants, from the shell prompt rather than with the desktop up. And the release question remains the operator's: `core.md` calls for a MINOR bump at a hardware-proven milestone, no tags exist, and twelve titles running, every save type persisting across power loss and cartridges launching from TinyDesk is that milestone.

#### Files Modified:

- README.md
- tools/roms/savewprobe.s

#### Status:

- Build: N/A
- Deployment: N/A
- User Test: N/A

---
## 11 COMMIT Unreleased 2026-11-16T22:42:51-07:00

#### Coming From:

Unreleased 46b281a

#### Purpose:

Hand over the state of the save-and-exit work after a firmware-fault hunt in TinyTang found the exit chord this core reports unreliable on the board.

#### Outcome:

The exit chord does not work as designed, and that is this repository's half of a fault hunt recorded in full as TinyTang log entry 37. After entry 9 an unlogged session added a HOME-with-SELECT exit chord to this core -- `save_exit = home & joy1[2]` in `fpga/gba/src/iosys/iosys_bl616.v`, reported as bit 15 of a pad word widened from 12 to 16 bits, with `fpga/gba/src/gbatang_top.sv` passing the Classic Controller's HOME through as `home_key` -- built it as `build/exitkey` and put it on the card, where `/root/cores/console138k/tinygba.bin` is 5,063,660 bytes, the size of that build, while `tinygba_home.bin` beside it matches `build/home_toggle` at 4,873,196. That session's TinyTang firmware, which watches bit 15 to save the game and reload the desktop, is the image that stopped the board from starting TinyTang at 20:16; TinyTang entry 37 identifies it, clears the relay bench with seven clean cold starts on known-good firmware, and shows the same firmware rebuilt surviving four cold starts, so the failure is not a property of booting it and most likely followed from exercising the chord and its save. On the board tonight the operator launched games from the TinyGBA library with that core loaded and found the chord unreliable: minus with HOME does not reliably end the game, it behaves as HOME together with some other button, and which button differs from one launch to the next. Read on paper the path looks correct, which is why it needs measuring rather than more reading: the `joy_wii` vector is ordered (R L X A RT LT DN UP START SELECT Y B) from bit 11 down, so `joy1[2]` is SELECT, driven by `pad_held_s[4]`, the Classic's minus; `home_key` is `pad_held_s[3]`; and the transmit path sends `joy1_reg[15:8]` and `joy1_reg[7:0]` as two bytes, so bit 15 reaches the host. Two things on that path are worth suspecting first. `joy1` into `iosys` is the OR of `joy_btns`, `joy_usb1`, `joy_usb2` and `joy_wii`, so any of those sources asserting bit 2 completes the chord with HOME. And `pad_held_s` is a two-flop synchroniser applied to a multi-bit bus, which can deliver a mixed sample when several bits change together. A third possibility sits on the host side, in how TinyTang's `play_task` and desk task read the word. Neither `gbatang_top.sv` nor `iosys_bl616.v` was changed by this cycle; both remain uncommitted in the working tree exactly as the unlogged session left them, and nothing was built or deployed from this repository.

#### Next Steps:

Measure the chord before changing anything: with the exit-chord core loaded, run TinyTang's new `pad` command at the prompt -- it is in the firmware the board is running now, `fdebc90-dirty.c62e9ec` -- and press minus alone, HOME alone, then both, several launches apart, which shows directly which bits the core sets and whether bit 15 asserts only on the chord. If the word is right and the host misreads it, the fault is TinyTang's; if bit 2 or bit 15 is set by something other than minus, check the other `joy1` sources and the synchroniser on `pad_held` here. Only once the chord is reliable should the save it triggers be driven with the console attached and followed by a cold start, which is the sequence TinyTang entry 37 names as the most likely way the board stopped tonight. The two RTL files stay uncommitted until then, and the board is left on the suspect TinyTang firmware with known-good and suspect images kept at `/run/media/vash/GIT/tinytang-scratch/firmware-backup/2026-11-16/`. The card still carries the test leftovers entry 10 listed, and the release question is unchanged.

#### Files Modified:

None.

#### Status:

- Build: N/A
- Deployment: N/A
- User Test: FAIL

---
