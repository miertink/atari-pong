# Atari 2600 — Pong — development notes

Anchor document for the project. Seeds context when opening this folder in
VS Code with Claude Code, so no session starts from zero. (The root
`README.md` is the public-facing one — game description, controls, how to
build. This file is process/toolchain.)

> **Game:** Pong.
> **Target:** NTSC. Switching to PAL requires kernel changes — see
> *Hardware reference*.
> **Dev environment:** Windows 11 (PowerShell).

---

## 1. Goal and workflow

Build a complete Atari 2600 game in 6502 assembly, assembled with DASM and
validated in the Stella emulator.

Agreed split of responsibilities:

- **VS Code (Claude Code)** — where development happens: editing files,
  project structure, git.
- **Chat (claude.ai)** — design discussion, kernel technique, unblocking
  specific timing questions.

**Constraint that shapes the workflow:** the assistant assembles the ROM but
can't *see* it running. The cycle is always `edit → assemble → you run it in
Stella → you report back`. The more precise your feedback (jitter, sprite
position, color, sound), the faster we converge. Fine timing sometimes needs
a first-pass adjustment — that's expected cost, not a wrong turn.

---

## 2. Toolchain

| Tool | Role |
|------|------|
| DASM | 6502 assembler |
| Stella | Emulator / debugger |
| `vcs.h`, `macro.h` | TIA/RIOT register headers and macros |
| git | Version control (essential for timing-sensitive kernels) |

**Install on Windows 11**

```powershell
winget install TheStellaTeam.Stella
```

- **Stella:** via winget (`TheStellaTeam.Stella`). `build.ps1` looks for
  `Stella.exe` on PATH and under `Program Files`.
- **DASM:** not on winget. Uses `dasm.exe` from release v2.20.17
  (`dasm-assembler/dasm` on GitHub, `windows` zip), copied into `tools/`.
  `tools/` is gitignored: on a new machine, download the zip and extract
  just `dasm.exe` to `tools\dasm.exe`.
- **Headers:** the Windows zip does **not** include `vcs.h`/`macro.h`. They
  come from `machines/atari2600/` in the DASM repo (tag v2.20.17) and are
  versioned under `include/`, so the build doesn't depend on an install path.

**macOS/Linux:** `brew install dasm stella`. `build.ps1` is Windows-only; on
Mac use the reference Makefile in section 4 (untested).

---

## 3. Repository layout

```
atari-pong/
├── README.md             ← public-facing: what the game is, how to run it
├── docs/
│   └── DEVELOPMENT.md    ← this file
├── build.ps1             ← build/run/clean on Windows
├── .gitignore            ← build/ and tools/
├── include/
│   ├── vcs.h             ← TIA/RIOT registers (vendored)
│   └── macro.h           ← DASM macros (vendored)
├── tools/                 ← dasm.exe (gitignored)
├── src/
│   └── main.asm          ← entry point, vectors, main loop
└── build/                 ← output (gitignored)
    ├── game.bin           ← ROM
    ├── game.lst           ← listing
    └── game.sym           ← symbols
```

Only `src/main.asm` exists today. When the code grows, split into
`constants.asm` (constants, RAM map) and `kernel.asm` (display kernel).
Bank switching adds files under `src/` once the game passes 4K.

---

## 4. Build and run

**Windows:**

```powershell
.\build.ps1          # assembles the ROM to build\game.bin
.\build.ps1 run      # assembles and opens it in Stella
.\build.ps1 clean    # removes build artifacts
```

Note: DASM's flags (`-obuild\game.bin`, `-Iinclude`, ...) must be passed as
an array in PowerShell; passed loose, DASM rejects the command line
("Check command-line format").

**macOS/Linux — reference Makefile (untested in this project):**

```make
ASM      = dasm
SRC      = src/main.asm
OUT      = build/game.bin
INCLUDES = -Iinclude

$(OUT): $(SRC)
	@mkdir -p build
	$(ASM) $(SRC) -f3 -o$(OUT) $(INCLUDES) -lbuild/game.lst -sbuild/game.sym

run: $(OUT)
	stella $(OUT)

clean:
	rm -rf build

.PHONY: run clean
```

Usage: `make`, `make run`, `make clean`. On Mac, `tools/` isn't needed (DASM
comes from brew); adjust `.gitignore` accordingly.

---

## 5. Development loop

1. Assistant edits `src/*.asm`.
2. You run `.\build.ps1 run`.
3. You observe and report: **what you saw vs. what was expected**. Useful
   details — sprite jitter, object shifted horizontally, wrong color,
   missing/wrong sound, rolling screen.
4. We iterate.

**Git discipline:** commit at every working milestone, and always *before*
touching a timing kernel that's already correct. Good timing is fragile;
git is the reliable undo.

---

## 6. Hardware reference (NTSC)

Quick lookup, so we don't have to leave the repo.

**CPU — MOS 6507**
- 6502 core, ~1.19 MHz.
- 13 address lines → 8 KB space (hence bank switching above 4K).
- No exposed IRQ/NMI.

**Memory**
- **128 bytes of RAM** (inside the RIOT/6532). All the working space there is.
- Cartridge ROM: 2K/4K base.

**Chips**
- **TIA** — graphics and sound. No framebuffer: the image is built line by
  line.
- **RIOT (6532)** — RAM, timer, and I/O (joysticks, console switches).

**Frame timing (NTSC convention)**
- 262 scanlines: 3 VSYNC + 37 VBLANK + **192 visible** + 30 overscan.
- **76 CPU cycles per scanline** (228 color clocks ÷ 3).
- 1 CPU cycle = 3 pixels. Tight budget — the kernel is counted cycle by
  cycle.

**TIA objects**
- 2 players (P0, P1), 2 missiles (M0, M1), 1 ball (BL).
- Playfield: PF0/PF1/PF2 = 20 bits, with an option to mirror or reflect on
  the right half of the screen.
- Hardware collisions (CXxx registers) — use these instead of computing
  overlap in software whenever possible.

**Key strobes / registers**
- `WSYNC` — halts the CPU until the start of the next scanline.
- `VSYNC`, `VBLANK` — vertical sync and blanking control.
- `RESP0`/`RESP1`, `HMOVE`, `HMCLR` — horizontal object positioning.
- `CXCLR` — clears collision registers.

**Sound**
- 2 channels: `AUDC0/1` (waveform), `AUDF0/1` (frequency), `AUDV0/1`
  (volume).

**PAL — differences (if we ever switch)**
- 312 scanlines, 50 Hz, ~228 visible lines.
- Kernel and color palette change; that's why the target is locked in
  before writing the kernel.

---

## 7. Status

**Marco 0 (the original spike) is complete.** Two paddles moved by
joystick, a ball that bounces off walls, hardware collision, scoring, sound,
and a randomized serve — all working and validated in Stella.

- [x] Target: **NTSC**. Game: **Pong**. Toolchain and repo set up.
- [x] **Marco -1 — skeleton:** stable 262-line frame, validated in Stella.
- [x] **Marco 0 — minimal Pong:**
  - [x] Increment 1 — static objects (paddles + ball drawn and positioned).
  - [x] Increment 2 — joystick moves the paddles.
  - [x] Increment 3 — ball moves and bounces off top/bottom.
  - [x] Increment 4 — hardware ball↔paddle collision + beep.
  - [x] Increment 5 — walls redrawn; real score detection (ball passing a
        paddle awards a point and resets the rally).
- [x] Gameplay tuning after Marco 0: bigger/faster paddles, slower two-phase
  ball speed (serve vs. rally), randomized serve direction and angle
  (8-bit LFSR), paddle-movement "English" on the rebound, an 8-level speed
  ramp after Marco 0's single acceleration step.
- [x] **On-screen scoreboard:** a dedicated score row at the top of the
  frame (P0/P1 draw digits there instead of paddles — paddles are clamped
  out of that row, since the score display and the paddle graphics both
  need the same two hardware objects).
- [x] **Game state machine (ATTRACT/PLAYING/GAMEOVER):** matches real
  Atari 2600 convention. At power-up and after a match ends, the game
  freezes (paddles/ball stop) with the final score held on screen and the
  background flashing during game-over; GAME RESET (re)starts a fresh
  game immediately, from any state, including mid-rally. Paddle-size
  difficulty moved from GAME RESET to GAME SELECT to free up RESET for
  this role.
- [ ] AI opponent, sound beyond the hit/score beeps.

See `src/main.asm`'s header for the engineering notes worth remembering
(hardware-timer VBLANK, WSYNC-before-HMOVE, HMCLR truncating fine motion,
inequality-based bounds checks) — several were found through real,
sometimes lengthy debugging sessions; only the lasting lessons are kept
there, not the blow-by-blow.

### Complexity candidates (kept for reference)

| Level | Scope | Examples |
|-------|-------|----------|
| Low | Single screen, 1–2 players + playfield, joystick, basic sound | **Pong (chosen)**, Breakout, fixed shooter, Combat-style |
| Medium | Multiplexed sprites (>2 objects/scanline), scrolling, bank switching, score kernel | — |
| High | Elaborate physics, many game states, music | — |

---

## 8. Decisions

Game = Pong; target = NTSC; controls = joystick; modes = 2 players (AI
opponent later); score to 5; no continuous ball acceleration (a stepped
ramp — one jump on the first hit, then finer 0.25 steps every 5 hits — is
the deliberate exception). Nothing open right now.
