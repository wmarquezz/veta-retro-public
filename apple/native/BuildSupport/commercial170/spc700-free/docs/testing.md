# Testing against the original

How this ROM was compared with the original without the original being copied anywhere
(the test reads it from the emulator, which embeds it, at run time). Done in StackBlender's
Super Apollo, on ares' SNES core; the method works with any emulator that can load a boot
ROM of your choosing.

1. **The conversation.** Run each game twice from power-on, once with each boot ROM, and
   log every write the CPU makes to ports $2140-$2143 and every new value it reads back
   (hook the CPU's bus at those addresses). The two logs should be the same sequence.
   This is the strongest check: a game that uploads its driver the same way and gets the
   same replies behaves the same.
2. **The sound.** Record each run's audio for a minute, unattended (no input; most games
   reach an attract demo), and compare the two recordings window by window (5 s windows,
   spectral similarity allowing a small time shift). Identical behaviour scores 1.00; a
   few milliseconds of timing difference can move when an attract demo's sounds happen.
3. **The timing.** Line the two recordings up (cross-correlate their loudness envelopes)
   and measure the offset. Uploads run at the boot ROM's pace (games wait for each
   echo), so a slower receive loop shows up as a delay that grows with the size of the
   upload; it should be near zero.
4. **No original in what you ship.** Search the built program for the original's bytes
   (read from the emulator at run time, never printed or stored) and fail if they're
   found.

Results for this ROM are in the README.
