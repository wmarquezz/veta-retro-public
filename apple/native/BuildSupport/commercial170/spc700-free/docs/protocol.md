# The boot protocol

What this ROM does, as the CPU sees it through the four ports ($2140-$2143 on the CPU side,
$F4-$F7 on the SPC700 side). Written from public descriptions of the protocol; this is
also the specification the ROM was written to.

## At reset

1. The stack pointer is set to `$EF` (the stack at `$01EF`).
2. `$00-$EF` are cleared to zero.
3. Port 0 reads `$AA` and port 1 `$BB`: ready.

## Commands

The CPU waits for `$AA $BB`, then writes ports 1-3 and, last, port 0:

- port 2-3: an address (low, high);
- port 1: zero to jump to the address, nonzero to send a block of data to it;
- port 0: `$CC` for the first command.

The ROM echoes port 0's value on port 0. If port 1 was zero it jumps to the address (the
CPU should expect the echo to be short-lived: the program it jumped to takes the ports
over). Otherwise a block follows.

## Blocks

Each byte: the CPU writes it to port 1, then its index in the block (0, 1, 2, ..., as an
8-bit counter) to port 0. The ROM stores the byte at the address plus the index and
echoes the counter on port 0; the CPU waits for the echo before the next byte. Blocks may
be longer than 256 bytes (the counter wraps).

The block ends with the next command: the CPU writes a new address (ports 2-3), port 1
(zero: jump there; nonzero: another block there), then a port 0 value more than one
ahead of the last counter (and not more than 127 ahead), conventionally the last counter
plus 2. The ROM sees a counter ahead of the one it expects, echoes it, and carries on as
for any command.

## What it leaves

At the jump: the program's bytes where the CPU sent them, `$00-$01` holding the jump
address (the ROM's pointer), port 0 showing the last command's value, port 1 `$BB`. The
A, X, Y registers and flags aren't specified (no game tested relied on them).

## Sources

- SNESLab, "SPC700/IPL ROM": https://sneslab.net/wiki/SPC700/IPL_ROM
- SNESdev wiki, "S-SMP": https://snes.nesdev.org/wiki/S-SMP
- Wikibooks, "Super NES Programming/Loading SPC700 programs":
  https://en.wikibooks.org/wiki/Super_NES_Programming/Loading_SPC700_programs
