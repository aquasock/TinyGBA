`define CONFIG_H

`define M138K

// TinyGBA: USB HID is not built.  GBATang's own console138k board file defines
// both USB hosts, and they cost two usb_hid_host instances and a 12 MHz PLL --
// a whole extra clock domain -- for pads that reach the core over the BL616 link
// anyway.  TinySNES removed the same blocks from SNESTang's console138k build
// for the same reason, and on this device the clock domains are what the placer
// is short of: with USB enabled, pll12 (clk12) had 372 sinks that fell back to
// general routing, and every place-and-route seed from 1 to 16 came back with
// hold violations on clk16.
//
// The four USB pins stay constrained in fpga/gba/tinygba.cst because the ports
// are still in gbatang_top.sv's port list; they are simply undriven.
//
// `define USB1
// `define USB2

package configPackage;
endpackage
