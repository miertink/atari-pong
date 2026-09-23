# Atari 2600 — Pong

A from-scratch Pong clone for the Atari 2600 (NTSC), written entirely in
6502 assembly against the real TIA/RIOT hardware — no framebuffer, no
high-level engine, just a hand-counted display kernel building the image
line by line, the way it actually worked in 1977.

```
   1                                            0
┌──────────────────────────────────────────────────┐
│▓                                                  │
│▓                       ¦                          │
│▓                       ¦                          │
│▓                       ¦                          │
│                        ¦                       ▓  │
│                        ¦                       ▓  │
│                     o  ¦                       ▓  │
│                        ¦                       ▓  │
│                        ¦                          │
│                        ¦                          │
└──────────────────────────────────────────────────┘
```

## What it is

Classic 2-player Pong, playable in the [Stella](https://stella-emu.github.io/)
emulator or on real Atari 2600 hardware (the ROM is exactly 4096 bytes —
fits a 2732 EPROM or a flash cart like the Harmony/UnoCart).

- **Two paddles**, one joystick each, first to 5 points wins.
- **Ball physics with some texture, not just a bouncing square:**
  - Random serve direction *and* angle every point (3 angle profiles ×
    4 quadrants), so no two serves play the same.
  - Speed starts slow at serve, then climbs in small, even steps as a
    rally goes on — fast enough to feel earned, capped so it never
    catches up to the paddle's own speed.
  - Paddle "English": hit the ball while your paddle is moving and you
    add spin to the rebound angle, same idea as the real game.
- **Real Atari-style state machine:** the game sits frozen at power-up
  until you press GAME RESET; win a match and the screen freezes with
  the final score up and the background flashing until RESET starts a
  new one — RESET restarts instantly from *any* state, including
  mid-rally, matching how the real console switch behaves.
- **3-stage paddle-size difficulty**, cycled with GAME SELECT.
- **Big, classic-scale scoreboard** above the court, a dashed center
  net, and a hit/score beep on the 2600's own sound chip.

## Controls

| Input | Action |
|---|---|
| Joystick (left/right port) | Move that side's paddle up/down |
| GAME RESET | Start a new game / restart instantly at any time |
| GAME SELECT | Cycle paddle size (full → 3/4 → 2/3 → full) |

## Running it

**Windows:**

```powershell
.\build.ps1 run
```

Needs `dasm.exe` in `tools\` and Stella installed — see
[`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) for the one-time setup
(both are a few minutes, no Visual Studio or SDK required).

**macOS/Linux:** `brew install dasm stella`, then the reference `Makefile`
in `docs/DEVELOPMENT.md`.

**Real hardware:** `build/game.bin` is a plain 4K binary — write it to a
2732 EPROM (or a 2764 with the image duplicated twice) on a donor/generic
cartridge board, or just load it on a Harmony/UnoCart flash cart.

## How it's built

No engine, no assembler macros beyond register names — every frame is
262 scanlines, budgeted to the cycle, written by hand:

- **6502 assembly**, assembled with [DASM](https://dasm-assembler.github.io/).
- **128 bytes of RAM total** (the entire working memory of the machine).
- Paddles, ball and the center net are real TIA hardware objects
  (players/missile/ball), positioned with the classic divide-by-15
  routine; ball↔paddle collision uses the TIA's own hardware collision
  latches rather than software bounding-box checks.
- The digit font for the scoreboard is a hand-derived 7-segment design,
  scaled up via NUSIZ width-doubling and row-repeat to read at a
  classic-Pong scale instead of a thin sliver.
- Serve randomness comes from a software 8-bit Galois LFSR (the 2600 has
  no hardware RNG) — advanced every frame regardless of game state, so
  the exact value at any given serve depends on unpredictable human
  reaction time.

The full build process, hardware reference notes, and the running log of
engineering decisions (and the debugging sessions behind a few of them)
live in [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) and in `src/main.asm`'s
own header — this project was built iteratively, in public-style commits,
with [Claude Code](https://claude.com/claude-code) doing the assembly work
end to end.

## Status

Feature-complete as a 2-player game. Not yet done: an AI opponent, and
sound beyond the hit/score beeps. See
[`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md#7-status) for the detailed
checklist.

## License

[MIT](LICENSE) — use it, fork it, learn from it.
