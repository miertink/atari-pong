; Pong for Atari 2600 (NTSC)
;
; Current state: Marco 0 complete (paddles, ball, wall bounce, hardware
; collision, scoring, sound, randomized serve).
;   - P0/P1 (paddles): joystick moves them vertically; horizontal position
;     fixed, set once in Reset.
;   - BL (ball): moves, bounces off the walls, collides with paddles via
;     hardware, and awards a point when it passes a paddle uncontested.
;     Speed has two phases: BALL_SERVE_SPEED at serve, a step up to rally
;     speed on the first paddle hit. Rally speed then creeps up 10% every
;     HITS_PER_LEVEL hits (LevelSpeedTable), capped at MAX_HIT_LEVEL —
;     with PADDLE_SPEED only 1 above the starting rally speed, there's no
;     integer room for more than one real step before the ball would
;     reach the paddle's own speed, so growth stops there (see the
;     constants note near HITS_PER_LEVEL). Serve direction and angle are
;     randomized (8-bit LFSR); a moving paddle at the moment of contact
;     nudges the ball's vertical angle (English/spin). The speed
;     progression resets on every point (ResetBall), not just a match
;     win — each rally starts back at BALL_SERVE_SPEED.
;   - Score (ScoreP0/ScoreP1) shown on screen (DigitFont), reset to 0/0 on
;     a match win (SCORE_TO_WIN).
;
; Engineering notes worth keeping in mind when touching this code:
;
; - VBLANK timing uses the RIOT hardware timer (TIMER_SETUP/TIMER_WAIT from
;   macro.h) instead of hand-counted WSYNCs. SetHorizPos's cost depends on
;   its input (divide-by-15 loop): ~30 cycles for small X, >80 for X near
;   150-159 — over the 76-cycle/scanline budget if counted by hand. The
;   timer absorbs that variance automatically.
;
; - HMOVE must be strobed right after a WSYNC (hardware requirement, ~24
;   cycle window) — not just a matter of budget. Skipping this once made
;   the paddles drift sideways on their own.
;
; - HMCLR must NOT be strobed immediately (3 cycles) after HMOVE for an
;   object that keeps moving: the fine-motion injection isn't
;   instantaneous, and clearing HMBL too soon truncates it, leaving only
;   the coarse RESBL reposition — the ball "galloped" in ~15-unit jumps
;   instead of sliding. Fixed by dropping HMCLR from the ball's per-frame
;   reposition (HMBL gets overwritten fresh next frame anyway) and adding
;   slack before it in Reset (where it's still needed once, to zero
;   HMP0/HMP1 so the ball's later HMOVE calls don't reapply them).
;
; - Bounce/score bounds are checked with inequalities (>=/<=), not exact
;   equality: BallX/BallY can take different step sizes during the game
;   (serve vs. rally speed, skip-frame angle), so an exact-match boundary
;   check would occasionally get stepped over and missed.

        processor 6502
        include "vcs.h"
        include "macro.h"

; ---- Geometry / color constants ----
PADDLE_HT      = 32             ; paddle height, in scanlines
PADDLE_PATTERN = %00111100      ; paddle bit pattern (GRP0/GRP1)
PADDLE_SPEED   = 3              ; scanlines/frame while holding the joystick
FONT_ROWS      = 5              ; DigitFont height, in raw font rows
SCORE_SCALE    = 3              ; each font row is drawn for this many
                                 ; scanlines — makes the digits big, closer
                                 ; to classic Pong's scale (5x1 looked tiny)
SCORE_HT       = FONT_ROWS*SCORE_SCALE  ; total score row height, in scanlines
WALL_HT        = 8              ; top/bottom wall thickness, in scanlines
PADDLE_Y_MIN   = WALL_HT+SCORE_HT  ; lowest valid P0Y/P1Y — paddles can't
                                 ; reach into the top wall or the score row
                                 ; (both come before the play area — see
                                 ; the visible-area zone order in MainLoop)
PADDLE_Y_MAX   = 192-PADDLE_HT  ; highest valid P0Y/P1Y (bottom = line 191)
BALL_HT        = 4              ; ball height, in scanlines
BALL_SIZE      = %00100000      ; CTRLPF: ball width = 4 color clocks
COLOR_WHITE    = $0E

; Ball bounce/score bounds (0-159 horizontal, same scale as SetHorizPos;
; vertical in scanlines, 0-191). Checked by inequality, not exact match —
; see engineering notes above.
BALL_X_MIN     = 2
BALL_X_MAX     = 158
BALL_Y_MIN     = SCORE_HT+WALL_HT     ; bounces off the wall's inner face,
BALL_Y_MAX     = 192-WALL_HT-BALL_HT  ; not the screen's absolute edge

; Ball speed: slow at serve, one step up to rally speed on the first
; paddle hit. Serve(1) < Rally(2) < Paddle(3).
BALL_SERVE_SPEED = 1
BALL_RALLY_SPEED = 2

; Rally speed then creeps up: +10% every HITS_PER_LEVEL paddle hits (across
; the whole match, not reset per point — only on a match win). With
; PADDLE_SPEED=3 and rally speed starting at 2, there is NO integer value
; strictly between them — compounding 2.0 -> 2.2 -> 2.42 -> 2.66 (rounds
; to 3) reaches the paddle's own speed after 3 levels and has nowhere
; left to go, so growth stops there (matches, never exceeds, the paddle).
; LevelSpeedTable holds these hand-computed, pre-rounded values — no
; runtime multiply/divide needed for something this small.
HITS_PER_LEVEL = 10
MAX_HIT_LEVEL  = 3              ; LevelSpeedTable has MAX_HIT_LEVEL+1 entries

; Serve angle: 3 profiles, picked by FREQUENCY (which axis, if any, skips
; odd frames) rather than by step magnitude — magnitude-based profiles
; changed the total diagonal speed between angles, which wasn't intended.
BALL_SKIP_NONE = 0               ; 45 degrees: both axes move every frame
BALL_SKIP_Y    = 1               ; shallow (~27 deg): Y skips odd frames
BALL_SKIP_X    = 2               ; steep (~63 deg): X skips odd frames

; Paddle English: a moving paddle at the moment of contact nudges BallDY
; by +-BALL_SPIN in its own direction. Combined with the current rally
; speed (2-3, see LevelSpeedTable), final BallDY magnitude lands in
; [1,4] at most — never zero, never wildly out of proportion.
BALL_SPIN      = 1

; Ball<->paddle collision (hardware CXP0FB/CXP1FB, bit 6 = ball collision;
; bit 7 would be playfield, unused here) + short beep.
COLLISION_BL   = %01000000
SOUND_HIT_TONE = 4               ; AUDC0: pure tone (clean square wave)
SOUND_HIT_FREQ = 4               ; AUDF0: high pitch (low value = high freq)
SOUND_HIT_VOL  = 12              ; AUDV0: volume (0-15)
SOUND_HIT_LEN  = 4               ; beep duration, in frames

; Score sound: lower and longer than the hit beep, so the two are
; distinguishable from each other.
SOUND_SCORE_TONE = 12            ; AUDC0: div-6 pure tone (lower pitch)
SOUND_SCORE_FREQ = 20
SOUND_SCORE_VOL  = 12
SOUND_SCORE_LEN  = 15

; On-screen score: P0/P1 (the only two objects available) draw the digits,
; so they can't also be showing the paddles on those same lines. Solved the
; classic Pong way — a dedicated SCORE_HT-line row at the very top of the
; frame, before the wall/play zones, where paddles never appear (clamped
; via PADDLE_Y_MIN above). Digits are drawn big (SCORE_SCALE vertical
; repeat + double width via NUSIZ0/NUSIZ1 during the score row only), to
; read closer to classic Pong's scale rather than a thin sliver. DigitFont
; holds 10 digits x FONT_ROWS bytes each (0-9), one byte per row, pattern
; centered in the byte the same way PADDLE_PATTERN is (bits 5-2) — same
; safe horizontal margin already validated for the paddles at P0_X/P1_X.
;
; SCORE_TO_WIN resets both scores to 0 once reached — not just a nicety:
; without a cap, a long session could push a score past 9 and index off
; the end of DigitFont, corrupting the display.
SCORE_TO_WIN   = 5

; Score digits use their own colors (not the paddle/ball white) — COLUP0/
; COLUP1 swapped in for the score row only, then restored. Exact hues are
; easy to retune here if they don't read as intended on screen.
SCORE_P0_COLOR = $2E            ; warm orange/gold
SCORE_P1_COLOR = $9E            ; cool blue

; NUSIZ0 packs two unrelated things in one register: player-0 copy/size
; (bits 0-2) and missile-0 width (bits 4-5). Two combined values, since
; both P0 and the missile-0 net line share it at different points in the
; frame:
NUSIZ0_SCORE   = %00010101      ; double-width P0 (score row) + net width
NUSIZ0_PLAY    = %00010000      ; normal-width P0 (paddle) + net width
NUSIZ1_SCORE   = %00000101      ; double-width P1 (score row only; P1 has
                                 ; no missile, so no width bits needed)

; Center net: a dashed vertical line down the middle of the play area
; (classic tennis-net look), drawn with the otherwise-unused missile 0.
; Toggled on/off via bit 1 of the scanline counter — 2 lines on, 2 off —
; which conveniently IS ENAM0's enable bit, so no branching is needed per
; line (see MidLoop).
NET_X          = 80             ; horizontal center, same column as the ball

P0_X           = 4              ; left paddle's fixed horizontal position
P1_X           = 140            ; right paddle's fixed horizontal position
BALL_X_INIT    = 80             ; ball's initial horizontal position (center)
P0_Y_INIT      = 80             ; left paddle's top (line 0-191); centered
P1_Y_INIT      = 80             ; for PADDLE_HT=32
BALL_Y_INIT    = 96

        SEG.U vars
        ORG $80
Frame   ds 1                    ; frame counter
P0Y     ds 1                    ; left paddle's top
P0YEnd  ds 1                    ; P0Y + PADDLE_HT (precomputed)
P1Y     ds 1                    ; right paddle's top
P1YEnd  ds 1                    ; P1Y + PADDLE_HT (precomputed)
BallX   ds 1                    ; ball column (0-159 scale, same as SetHorizPos)
BallY   ds 1                    ; ball's top
BallYEnd ds 1                   ; BallY + BALL_HT (precomputed)
BallDX  ds 1                    ; horizontal speed: +-BALL_SERVE_SPEED or
                                 ; +-BALL_RALLY_SPEED (+-BALL_SPIN on BallDY)
BallDY  ds 1                    ; vertical speed, same scale as BallDX
SoundTimer ds 1                 ; frames left on the current beep (0 = silent)
ScoreP0 ds 1                    ; left player's score (0-9, capped/reset at
ScoreP1 ds 1                    ; SCORE_TO_WIN)
RandomSeed ds 1                 ; LFSR state (must never be 0 — see AdvanceRandom)
P0Dir   ds 1                    ; this frame's paddle direction: -1 (up),
P1Dir   ds 1                    ; 0 (still), +1 (down) — used for ball English
BallSkipMode ds 1                ; BALL_SKIP_NONE/Y/X — which axis (if any)
                                 ; skips odd frames for the serve angle.
                                 ; Reset to BALL_SKIP_NONE on the first
                                 ; paddle hit (rally only uses the spin
                                 ; effect).
P0FontPtr ds 2                  ; pointer into DigitFont for this frame's
P1FontPtr ds 2                  ; score row (computed once, read per line)
HitLevel ds 1                   ; 0..MAX_HIT_LEVEL — indexes LevelSpeedTable
HitsSinceLevelUp ds 1           ; 0..HITS_PER_LEVEL-1, counts toward the
                                 ; next level. Both reset to 0 on a match win.

        SEG code
        ORG $F000

Reset
        CLEAN_START

        ; classic monochrome look: white paddles/ball, black background
        lda #COLOR_WHITE
        sta COLUP0
        sta COLUP1
        sta COLUPF

        lda #BALL_SIZE
        sta CTRLPF

        lda #NUSIZ0_PLAY         ; missile-0 (net) width; player width stays
        sta NUSIZ0               ; normal until the score row overrides it

        lda #P0_Y_INIT
        sta P0Y
        clc
        adc #PADDLE_HT
        sta P0YEnd

        lda #P1_Y_INIT
        sta P1Y
        clc
        adc #PADDLE_HT
        sta P1YEnd

        ; PRNG seed (must never be 0 — see AdvanceRandom). The exact value
        ; barely matters: the real "randomness" comes from how many frames
        ; have ticked by whenever a serve actually happens (which depends
        ; on player reaction time), not from the seed itself.
        lda #$2B
        sta RandomSeed

        jsr ResetBall            ; center the ball, random direction/angle

        ; One-time horizontal positioning. P0/P1 never reposition
        ; horizontally again (only move vertically); the ball is
        ; repositioned every frame in MainLoop since it moves.
        lda #P0_X
        ldx #0
        jsr SetHorizPos          ; P0
        lda #P1_X
        ldx #1
        jsr SetHorizPos          ; P1
        lda #NET_X
        ldx #2
        jsr SetHorizPos          ; M0 (center net)
        lda #BALL_X_INIT
        ldx #4
        jsr SetHorizPos          ; BL
        sta WSYNC
        sta HMOVE
        ; HMCLR is deliberately NOT strobed right after HMOVE here — see
        ; the header note. P0/P1/BL won't reposition again for a while
        ; (P0/P1 never; the ball not until next frame), but HMP0/HMP1/HMBL
        ; still need clearing eventually so the ball's later HMOVE calls
        ; don't reapply them (that's what made the paddles drift on their
        ; own). Reset only runs once, so an extra line of slack costs
        ; nothing.
        sta WSYNC
        sta HMCLR

MainLoop
        ; --- VSYNC: 3 lines ---
        lda #2
        sta VSYNC
        sta WSYNC
        sta WSYNC
        sta WSYNC
        lda #0
        sta VSYNC

        ; --- VBLANK: 37 lines, reserved via the hardware timer (see header) ---
        lda #2
        sta VBLANK
        TIMER_SETUP 37

        jsr AdvanceRandom        ; every frame, unconditionally — keeps the
                                 ; LFSR "spinning" independent of gameplay,
                                 ; so it looks random whenever a serve happens

        ; --- move paddle P0 (joystick 0 = left port: bit4=Up, bit5=Down) ---
        ; P0Dir records this frame's direction (-1/0/+1), used for ball
        ; English if a collision happens in this same window.
        lda #0
        sta P0Dir
        lda SWCHA
        and #%00010000
        bne SkipP0Up
        lda P0Y
        sec
        sbc #PADDLE_SPEED
        cmp #PADDLE_Y_MIN
        bcs P0UpOk
        lda #PADDLE_Y_MIN
P0UpOk
        sta P0Y
        lda #-1
        sta P0Dir
SkipP0Up
        lda SWCHA
        and #%00100000
        bne SkipP0Down
        lda P0Y
        clc
        adc #PADDLE_SPEED
        cmp #PADDLE_Y_MAX+1
        bcc P0DownOk
        lda #PADDLE_Y_MAX
P0DownOk
        sta P0Y
        lda #1
        sta P0Dir
SkipP0Down
        lda P0Y
        clc
        adc #PADDLE_HT
        sta P0YEnd

        ; --- move paddle P1 (joystick 1 = right port: bit0=Up, bit1=Down) ---
        lda #0
        sta P1Dir
        lda SWCHA
        and #%00000001
        bne SkipP1Up
        lda P1Y
        sec
        sbc #PADDLE_SPEED
        cmp #PADDLE_Y_MIN
        bcs P1UpOk
        lda #PADDLE_Y_MIN
P1UpOk
        sta P1Y
        lda #-1
        sta P1Dir
SkipP1Up
        lda SWCHA
        and #%00000010
        bne SkipP1Down
        lda P1Y
        clc
        adc #PADDLE_SPEED
        cmp #PADDLE_Y_MAX+1
        bcc P1DownOk
        lda #PADDLE_Y_MAX
P1DownOk
        sta P1Y
        lda #1
        sta P1Dir
SkipP1Down
        lda P1Y
        clc
        adc #PADDLE_HT
        sta P1YEnd

        ; --- move the ball: vertical bounce (top/bottom) ---
        ; Bounds checked by inequality (BallY <= MIN / >= MAX), not exact
        ; match — see header note. On bounce, NEGATE BallDY's sign while
        ; keeping its current magnitude (NegateBallDY) rather than writing
        ; a fixed constant — speed can be BALL_SERVE_SPEED or
        ; BALL_RALLY_SPEED depending on whether the ball's been hit yet,
        ; and bouncing shouldn't change that.
        lda BallY
        cmp #BALL_Y_MIN+1
        bcs NoTopBounce          ; BallY > BALL_Y_MIN, not there yet
        lda BallDY
        bpl NoTopBounce          ; already heading down (>=0), nothing to do
        jsr NegateBallDY
NoTopBounce
        lda BallY
        cmp #BALL_Y_MAX
        bcc NoBottomBounce       ; BallY < BALL_Y_MAX, not there yet
        lda BallDY
        bmi NoBottomBounce       ; already heading up (<0), nothing to do
        jsr NegateBallDY
NoBottomBounce
        ; apply the vertical move, unless the angle profile is BALL_SKIP_Y
        ; and this is an odd frame (shallow serve angle)
        lda BallSkipMode
        cmp #BALL_SKIP_Y
        bne DoMoveY
        lda Frame
        and #1
        bne SkipMoveY
DoMoveY
        lda BallY
        clc
        adc BallDY
        sta BallY
SkipMoveY
        lda BallY
        clc
        adc #BALL_HT
        sta BallYEnd

        ; --- move the ball: horizontal — score detection ---
        ; If the ball reaches (or passes) BALL_X_MIN/MAX, it went by a
        ; paddle uncontested (a real collision would already have flipped
        ; BallDX earlier, in the post-kernel collision block). Same
        ; inequality-based check as the vertical bounce.
        lda BallX
        cmp #BALL_X_MIN+1
        bcs NoScoreP1            ; BallX > BALL_X_MIN, not there yet
        inc ScoreP1              ; ball passed the left paddle -> right player scores
        lda ScoreP1
        cmp #SCORE_TO_WIN
        bne SkipWinP1
        lda #0                   ; match point reached -> new game
        sta ScoreP0
        sta ScoreP1
SkipWinP1
        jsr StartScoreSound
        jsr ResetBall
        jmp BallMoveDone
NoScoreP1
        lda BallX
        cmp #BALL_X_MAX
        bcc NoScoreP0            ; BallX < BALL_X_MAX, not there yet
        inc ScoreP0              ; ball passed the right paddle -> left player scores
        lda ScoreP0
        cmp #SCORE_TO_WIN
        bne SkipWinP0
        lda #0
        sta ScoreP0
        sta ScoreP1
SkipWinP0
        jsr StartScoreSound
        jsr ResetBall
        jmp BallMoveDone
NoScoreP0
        ; same skip logic as the vertical block, for the X axis this time
        ; (BALL_SKIP_X = steep serve angle)
        lda BallSkipMode
        cmp #BALL_SKIP_X
        bne DoMoveX
        lda Frame
        and #1
        bne BallMoveDone         ; odd frame -> skip X, jump straight to the end
DoMoveX
        lda BallX
        clc
        adc BallDX
        sta BallX
BallMoveDone
        ; explicit reload: on the score paths, A came out of
        ; ResetBall/StartScoreSound holding something other than BallX
        lda BallX

        ; Reposition the ball horizontally (the only object that still
        ; moves horizontally here). SetHorizPos does its own internal
        ; WSYNC, needed for the position math.
        ;
        ; The "sta WSYNC" below, before HMOVE, is NOT about cycle budget
        ; (the timer already covers that) — it's a hardware requirement:
        ; HMOVE must be strobed right at the start of a scanline (~24
        ; cycle window). See header note.
        ldx #4
        jsr SetHorizPos
        sta WSYNC
        sta HMOVE
        ; No HMCLR here — see header note (a truncated fine-motion
        ; injection was the root cause of the ball "galloping" instead of
        ; sliding). Not needed anyway: HMBL gets overwritten fresh by
        ; SetHorizPos before the next HMOVE, so nothing stale carries over
        ; between frames. (HMP0/HMP1 stay fine — already zeroed once in
        ; Reset.)

        TIMER_WAIT
        lda #0
        sta VBLANK

        ; --- Visible area: 192 lines, in 4 zones (score row / top wall /
        ; middle / bottom wall). The score sits in its own row above the
        ; top wall, outside the court, rather than inside it: with the
        ; score inside the (otherwise fully black) court, there was no
        ; visual cue for where the paddles' reach actually stops, which
        ; read as confusing — the wall line now marks that boundary
        ; clearly. The walls are just background color (COLUBK), not real
        ; objects — no hardware collision with the ball (bouncing near
        ; them is handled via BALL_Y_MIN/MAX in the VBLANK move block).
        ;
        ; Why separate zones instead of checking "which zone is this line
        ; in?" inside a single loop: that costs extra cycles per line,
        ; blowing the 76-cycle/scanline budget on top of paddles+ball
        ; (~61, already tight). Each zone fixes its own per-line behavior
        ; once, outside its loop, and the shared body (~61 cycles) stays
        ; unchanged, just repeated in source.
        inc Frame

        ; --- score row: SCORE_HT lines, above the top wall. P0/P1 draw
        ; digits instead of paddles here. Font pointers computed once
        ; (score*FONT_ROWS + table base), then just indexed by row inside
        ; the loop. Double width (NUSIZ0/NUSIZ1) applies only here — reset
        ; to normal before the paddles draw below, or PADDLE_PATTERN would
        ; come out double size too.
        lda ScoreP0
        asl
        asl
        clc
        adc ScoreP0              ; A = ScoreP0*5 (FONT_ROWS)
        clc
        adc #<DigitFont
        sta P0FontPtr
        lda #>DigitFont
        adc #0
        sta P0FontPtr+1

        lda ScoreP1
        asl
        asl
        clc
        adc ScoreP1
        clc
        adc #<DigitFont
        sta P1FontPtr
        lda #>DigitFont
        adc #0
        sta P1FontPtr+1

        lda #NUSIZ0_SCORE        ; double-width P0 + net width (net isn't
        sta NUSIZ0               ; drawn here, but its width bits live here)
        lda #NUSIZ1_SCORE        ; double-width P1
        sta NUSIZ1
        lda #SCORE_P0_COLOR
        sta COLUP0
        lda #SCORE_P1_COLOR
        sta COLUP1

        lda #0
        sta COLUBK
        ldy #0                   ; font row (0..FONT_ROWS-1)
ScoreRowLoop
        lda (P0FontPtr),y
        sta GRP0
        lda (P1FontPtr),y
        sta GRP1
        ldx #SCORE_SCALE         ; hold this row for SCORE_SCALE scanlines
ScoreRepeatLoop
        sta WSYNC
        dex
        bne ScoreRepeatLoop
        iny
        cpy #FONT_ROWS
        bne ScoreRowLoop

        lda #NUSIZ0_PLAY         ; normal-width P0, keep the net's width
        sta NUSIZ0
        lda #0                   ; normal-width P1
        sta NUSIZ1
        lda #COLOR_WHITE         ; paddles/ball/net go back to white
        sta COLUP0
        sta COLUP1

        ; --- top wall: WALL_HT lines, right below the score row ---
        sta COLUBK               ; COLOR_WHITE, already in A from above
        ldx #SCORE_HT            ; ScoreRowLoop counted rows with Y, not X
TopWallLoop
        lda #0
        cpx P0Y
        bcc SkipTP0
        cpx P0YEnd
        bcs SkipTP0
        lda #PADDLE_PATTERN
SkipTP0
        sta GRP0

        lda #0
        cpx P1Y
        bcc SkipTP1
        cpx P1YEnd
        bcs SkipTP1
        lda #PADDLE_PATTERN
SkipTP1
        sta GRP1

        lda #0
        cpx BallY
        bcc SkipTBall
        cpx BallYEnd
        bcs SkipTBall
        lda #%00000010
SkipTBall
        sta ENABL

        sta WSYNC
        inx
        cpx #SCORE_HT+WALL_HT
        bne TopWallLoop

        lda #0
        sta COLUBK
MidLoop
        lda #0
        cpx P0Y
        bcc SkipMP0
        cpx P0YEnd
        bcs SkipMP0
        lda #PADDLE_PATTERN
SkipMP0
        sta GRP0

        lda #0
        cpx P1Y
        bcc SkipMP1
        cpx P1YEnd
        bcs SkipMP1
        lda #PADDLE_PATTERN
SkipMP1
        sta GRP1

        lda #0
        cpx BallY
        bcc SkipMBall
        cpx BallYEnd
        bcs SkipMBall
        lda #%00000010
SkipMBall
        sta ENABL

        ; center net: 2 lines on / 2 off. Bit 1 of the scanline counter IS
        ; ENAM0's enable bit, so this needs no branch — see NET_X's note.
        txa
        and #%00000010
        sta ENAM0

        sta WSYNC
        inx
        cpx #192-WALL_HT
        bne MidLoop

        lda #0
        sta ENAM0                ; net stops at the bottom of the play area
        lda #COLOR_WHITE
        sta COLUBK
BottomWallLoop
        lda #0
        cpx P0Y
        bcc SkipBP0
        cpx P0YEnd
        bcs SkipBP0
        lda #PADDLE_PATTERN
SkipBP0
        sta GRP0

        lda #0
        cpx P1Y
        bcc SkipBP1
        cpx P1YEnd
        bcs SkipBP1
        lda #PADDLE_PATTERN
SkipBP1
        sta GRP1

        lda #0
        cpx BallY
        bcc SkipBBall
        cpx BallYEnd
        bcs SkipBBall
        lda #%00000010
SkipBBall
        sta ENABL

        sta WSYNC
        inx
        cpx #192
        bne BottomWallLoop

        ; clear the objects when leaving the visible area: without this,
        ; the last value written on line 191 (e.g. a paddle against the
        ; bottom edge) survives through VSYNC/VBLANK into the next frame.
        lda #0
        sta GRP0
        sta GRP1
        sta ENABL
        sta ENAM0

        ; --- ball<->paddle collision (hardware) ---
        ; CXP0FB/CXP1FB accumulate collisions across the whole visible
        ; frame that just ran; reading now picks up the full result.
        ; CXCLR at the end clears the latches for next frame (they're
        ; sticky, they don't clear themselves).
        ; On a hit, the ball goes to (or stays at) the current rally speed
        ; (GetRallySpeed/LevelSpeedTable — starts at BALL_RALLY_SPEED, then
        ; creeps up every HITS_PER_LEVEL hits, see the constants note) — on
        ; the serve's first hit this "accelerates" the ball once
        ; (BALL_SERVE_SPEED -> rally speed); later hits just reaffirm the
        ; current value. BallDY's magnitude is also set to the same rally
        ; speed, keeping its sign (vertical direction doesn't change on a
        ; paddle hit) — then gets the paddle's English: if P0/P1Dir shows
        ; the paddle was moving at the moment of contact, that direction is
        ; added to BallDY, closing or opening the angle (never reaching 0
        ; — see the BALL_SPIN constant).
        lda CXP0FB
        and #COLLISION_BL
        beq NoHitP0
        jsr AdvanceHitLevel
        jsr GetRallySpeed        ; hit the left paddle -> ball heads right
        sta BallDX
        lda #BALL_SKIP_NONE      ; serve angle (skip mode) ends here; only
        sta BallSkipMode         ; the spin effect below applies in a rally
        jsr SetBallDYToRallySpeed
        lda P0Dir
        beq NoSpinP0
        clc
        adc BallDY
        sta BallDY
NoSpinP0
        jsr StartHitSound
NoHitP0
        lda CXP1FB
        and #COLLISION_BL
        beq NoHitP1
        jsr AdvanceHitLevel
        jsr GetRallySpeed        ; hit the right paddle -> ball heads left
        sta BallDX
        lda #0
        sec
        sbc BallDX               ; negate: BallDX = -GetRallySpeed
        sta BallDX
        lda #BALL_SKIP_NONE
        sta BallSkipMode
        jsr SetBallDYToRallySpeed
        lda P1Dir
        beq NoSpinP1
        clc
        adc BallDY
        sta BallDY
NoSpinP1
        jsr StartHitSound
NoHitP1
        sta CXCLR

        ; --- sound: count down the beep timer, silence it at 0 ---
        lda SoundTimer
        beq SoundDone
        dec SoundTimer
        bne SoundDone
        lda #0
        sta AUDV0
SoundDone

        ; --- Overscan: 30 lines ---
        lda #2
        sta VBLANK
        ldx #30
OverscanLoop
        sta WSYNC
        dex
        bne OverscanLoop

        jmp MainLoop

; ---------------------------------------------------------------------------
; LevelSpeedTable - rally speed at each HitLevel (0..MAX_HIT_LEVEL), hand-
; computed by compounding BALL_RALLY_SPEED(2) by 10% per level and rounding
; to the nearest integer at each step (rounding the RUNNING value, not a
; freshly-rounded one each time, so the fractional part isn't lost):
;   L0: 2.000            -> 2
;   L1: 2.000*1.1=2.200  -> 2
;   L2: 2.200*1.1=2.420  -> 2
;   L3: 2.420*1.1=2.662  -> 3  (= PADDLE_SPEED; capped here, see constants
;                               note near HITS_PER_LEVEL for why)
; ---------------------------------------------------------------------------
LevelSpeedTable
        .byte 2,2,2,3

; ---------------------------------------------------------------------------
; DigitFont - 10 digits (0-9) x FONT_ROWS(5) bytes, one byte per font row
; (each drawn SCORE_SCALE scanlines tall on screen — see ScoreRowLoop),
; top row first. Each byte's pattern is centered in bits 5-2, the same
; alignment as PADDLE_PATTERN, so the digits sit at the same safe
; horizontal margin already validated for the paddles at P0_X/P1_X.
; Derived from standard 7-segment digit shapes (not copied from an
; unverified reference), so its correctness can be checked by hand:
; segments a(top)/b(upper-right)/c(lower-right)/d(bottom)/e(lower-left)/
; f(upper-left)/g(middle) map to rows top,upper,middle,lower,bottom.
; ---------------------------------------------------------------------------
DigitFont
        .byte $3C,$24,$00,$24,$3C  ; 0
        .byte $00,$04,$00,$04,$00  ; 1
        .byte $3C,$04,$3C,$20,$3C  ; 2
        .byte $3C,$04,$3C,$04,$3C  ; 3
        .byte $00,$24,$3C,$04,$00  ; 4
        .byte $3C,$20,$3C,$04,$3C  ; 5
        .byte $3C,$20,$3C,$24,$3C  ; 6
        .byte $3C,$04,$00,$04,$00  ; 7
        .byte $3C,$24,$3C,$24,$3C  ; 8
        .byte $3C,$24,$3C,$04,$3C  ; 9

; ---------------------------------------------------------------------------
; SetHorizPos - horizontally positions a TIA object.
; Standard Atari 2600 community routine (divide-by-15 + fine adjust).
; IN: A = desired column (0-159), X = object index
;     (0=P0, 1=P1, 2=M0, 3=M1, 4=BL — same order as RESP0..RESBL/HMP0..HMBL)
; Always call right after a WSYNC (i.e. at the start of a line) during
; VSYNC/VBLANK; the routine itself consumes one line via WSYNC. An HMOVE
; must be strobed afterward, on the following line, to apply the fine
; adjustment.
; ---------------------------------------------------------------------------
SetHorizPos
        sta WSYNC
        sec
DivideLoop
        sbc #15
        bcs DivideLoop
        eor #7
        asl
        asl
        asl
        asl
        sta HMP0,x
        sta RESP0,x
        rts

; ---------------------------------------------------------------------------
; StartHitSound - starts the collision beep (AUDC0/AUDF0/AUDV0 + SoundTimer).
; Turns itself off after SOUND_HIT_LEN frames (see the "sound" block in
; MainLoop, which counts SoundTimer down and zeroes AUDV0 at 0).
; ---------------------------------------------------------------------------
StartHitSound
        lda #SOUND_HIT_TONE
        sta AUDC0
        lda #SOUND_HIT_FREQ
        sta AUDF0
        lda #SOUND_HIT_VOL
        sta AUDV0
        lda #SOUND_HIT_LEN
        sta SoundTimer
        rts

; ---------------------------------------------------------------------------
; StartScoreSound - starts the "point scored" sound (lower/longer than the
; hit beep, see StartHitSound). Same self-off mechanism via SoundTimer.
; ---------------------------------------------------------------------------
StartScoreSound
        lda #SOUND_SCORE_TONE
        sta AUDC0
        lda #SOUND_SCORE_FREQ
        sta AUDF0
        lda #SOUND_SCORE_VOL
        sta AUDV0
        lda #SOUND_SCORE_LEN
        sta SoundTimer
        rts

; ---------------------------------------------------------------------------
; NegateBallDY - flips BallDY's sign while keeping its current magnitude
; (BALL_SERVE_SPEED or BALL_RALLY_SPEED, whichever currently applies).
; Used on vertical bounce, where only the direction changes, never speed.
; ---------------------------------------------------------------------------
NegateBallDY
        lda #0
        sec
        sbc BallDY               ; A = 0 - BallDY = -BallDY
        sta BallDY
        rts

; ---------------------------------------------------------------------------
; SetBallDYToRallySpeed - sets BallDY's MAGNITUDE to the current rally speed
; (GetRallySpeed), keeping its current sign (vertical direction doesn't
; change on a paddle hit, only the speed "accelerates" to the rally value).
; ---------------------------------------------------------------------------
SetBallDYToRallySpeed
        lda BallDY
        bmi SetBallDYNegRally
        jsr GetRallySpeed
        sta BallDY
        rts
SetBallDYNegRally
        jsr GetRallySpeed
        sta BallDY
        lda #0
        sec
        sbc BallDY
        sta BallDY
        rts

; ---------------------------------------------------------------------------
; GetRallySpeed - returns the current rally speed in A, looked up from
; LevelSpeedTable by HitLevel. See the constants note (near HITS_PER_LEVEL)
; for how the table was computed.
; ---------------------------------------------------------------------------
GetRallySpeed
        ldx HitLevel
        lda LevelSpeedTable,x
        rts

; ---------------------------------------------------------------------------
; AdvanceHitLevel - counts one more paddle hit toward the next speed level;
; every HITS_PER_LEVEL hits, bumps HitLevel by one, capped at MAX_HIT_LEVEL.
; Called once per paddle hit (see the collision block in MainLoop).
; ---------------------------------------------------------------------------
AdvanceHitLevel
        inc HitsSinceLevelUp
        lda HitsSinceLevelUp
        cmp #HITS_PER_LEVEL
        bne AdvanceHitLevelDone
        lda #0
        sta HitsSinceLevelUp
        lda HitLevel
        cmp #MAX_HIT_LEVEL
        bcs AdvanceHitLevelDone  ; already capped, stay there
        inc HitLevel
AdvanceHitLevelDone
        rts

; ---------------------------------------------------------------------------
; AdvanceRandom - advances the 8-bit LFSR in RandomSeed by one step. Called
; once per frame (see VBLANK), unconditionally — keeps the value "spinning"
; independent of gameplay, so the exact moment a serve happens (which
; depends on player reaction time) samples an unpredictable value. The
; Atari 2600 has no hardware RNG; this is the standard community technique
; (Galois LFSR, 8-bit, cycles through up to 255 nonzero states).
; ---------------------------------------------------------------------------
AdvanceRandom
        lda RandomSeed
        lsr
        bcc NoRandomTap
        eor #$B4
NoRandomTap
        sta RandomSeed
        rts

; ---------------------------------------------------------------------------
; ResetBall - returns the ball to center screen with a random serve ANGLE
; AND DIRECTION (from RandomSeed bits), after a point or at Reset. Doesn't
; touch P0/P1 (paddles stay where they were). Also resets the speed
; progression (HitLevel/HitsSinceLevelUp) — every new rally starts back at
; BALL_SERVE_SPEED, not wherever the previous rally's hits had accelerated
; to. This runs on every point, not just a match win: ResetBall is called
; from both the regular score path and the match-win path, so a single
; reset here covers both (no need to duplicate it at each call site).
;
; BallDX/BallDY always have FIXED magnitude (BALL_SERVE_SPEED) on both
; axes — the angle comes from BallSkipMode (RandomSeed bits 2-3), which
; makes one axis skip odd frames (see the move block in MainLoop), not
; from different magnitudes (see the constants note: that changed the
; total diagonal speed between profiles). Bits 0-1 pick each axis's sign
; (quadrant) — 3 profiles x 4 quadrants = up to 12 possible serve
; trajectories.
; ---------------------------------------------------------------------------
ResetBall
        lda #0
        sta HitLevel
        sta HitsSinceLevelUp

        lda #BALL_X_INIT
        sta BallX
        lda #BALL_Y_INIT
        sta BallY
        clc
        adc #BALL_HT
        sta BallYEnd

        ; pick the angle profile (BallSkipMode) from RandomSeed bits 2-3
        ; (value 0-3; 0 and 3 both land on BALL_SKIP_NONE — a small bias,
        ; acceptable to keep the logic simple)
        lda RandomSeed
        lsr
        lsr
        and #%00000011
        cmp #1
        beq ServeSkipY
        cmp #2
        beq ServeSkipX
        lda #BALL_SKIP_NONE      ; 0 or 3 -> 45 degrees
        jmp ServeSkipDone
ServeSkipY
        lda #BALL_SKIP_Y
        jmp ServeSkipDone
ServeSkipX
        lda #BALL_SKIP_X
ServeSkipDone
        sta BallSkipMode

        ; RandomSeed bit 0 picks BallDX's sign (magnitude always
        ; BALL_SERVE_SPEED)
        lda RandomSeed
        lsr
        lda #-BALL_SERVE_SPEED
        bcc RandDXStore
        lda #BALL_SERVE_SPEED
RandDXStore
        sta BallDX

        ; RandomSeed bit 1 picks BallDY's sign
        lda RandomSeed
        lsr
        lsr
        lda #-BALL_SERVE_SPEED
        bcc RandDYStore
        lda #BALL_SERVE_SPEED
RandDYStore
        sta BallDY
        rts

        ORG $FFFC
        .word Reset
        .word Reset
