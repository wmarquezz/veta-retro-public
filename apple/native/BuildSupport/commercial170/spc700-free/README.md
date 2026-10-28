# snes-spc700-boot-rom

A free replacement for the boot ROM of the SPC700, the sound processor of the Super
Nintendo Entertainment System: 64 bytes, mapped at `$FFC0-$FFFF`, that every game relies on
to install its sound driver. Free software under the GPL, so emulators can ship it
instead of the original, which is the console maker's code.

- `spc700-boot-rom.bin`: the 64 bytes.
- `spc700_boot_rom.h`: the same, as a C array.
- `listing.txt`: the program, with addresses and comments.
- `src/assemble.py`: its source; `python3 src/assemble.py` writes the three files above.

Made by [StackBlender](https://stackblender.com) for Super Apollo, an emulator that plays
SNES games fast with their music at normal speed.

## What it does

The same as the original as games see it ([docs/protocol.md](docs/protocol.md)):
clears `$00-$EF`, sets the stack to `$01EF`, posts `$AA $BB` on ports 0 and 1, waits for the
CPU's `$CC`, then takes blocks of data over the standard handshake (each byte's counter
echoed on port 0) and jumps to the address the CPU gives. Entry at `$FFC0` (the reset
vector); a driver that jumps back there to receive a new program works as with the
original.

## How it was made

Clean room: written from public descriptions of the boot protocol's behaviour (the
SNESLab and SNESdev wikis), never from the original ROM's bytes or a disassembly of it,
which nobody on this project has read. The only things it shares with the original are
what games depend on: the entry address, the protocol and the state it leaves.

## How well it matches

Tested in the [ares](https://github.com/ares-emulator/ares) emulator against the original
(which the test reads from the emulator at run time; it isn't in this repository), with
seven commercial games covering ordinary carts and the SA-1, Super FX and DSP-1 chips
([docs/testing.md](docs/testing.md)):

- **The same conversation:** each game's writes to the sound processor and the replies it
  reads are identical, event for event, with this ROM and the original.
- **The same sound:** over 60 seconds per game at normal speed, 0.99-1.00 spectral
  similarity in five games; 0.89-1.00 in two, where a few milliseconds of timing shift
  when an attract demo plays its sounds.
- **The same speed:** games' uploads run at the boot ROM's pace. The receive loop echoes
  each byte as soon as it's read and takes no branch in the common case; uploads finish
  at the same time as with the original in four games and within 18 ms in the others.

Not covered: anything a game might do beyond the protocol (reading the ROM's bytes,
jumping into the middle of it, relying on its exact cycle timing). None of the games
tested did.

## Using it

Map the 64 bytes at `$FFC0` while the SPC700's control register (`$F1`) bit 7 is set, as
the original. In ares, give the Super Famicom system pak an `ipl.rom` with these bytes.

## License

GNU General Public License, version 3 or (at your option) any later version; see
[LICENSE](LICENSE). For other terms, contact [StackBlender](https://stackblender.com).
