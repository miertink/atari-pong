; Pong para Atari 2600 (NTSC) - esqueleto
; Marco -1: frame NTSC valido (262 linhas) com fundo colorido, so para provar o build.

        processor 6502
        include "vcs.h"
        include "macro.h"

        SEG.U vars
        ORG $80
Frame   ds 1                    ; contador de frames

        SEG code
        ORG $F000

Reset
        CLEAN_START             ; zera RAM e TIA, SP=$FF

MainLoop
        ; --- VSYNC: 3 linhas ---
        lda #2
        sta VSYNC
        sta WSYNC
        sta WSYNC
        sta WSYNC
        lda #0
        sta VSYNC

        ; --- VBLANK: 37 linhas ---
        lda #2
        sta VBLANK
        ldx #37
VBlankLoop
        sta WSYNC
        dex
        bne VBlankLoop
        lda #0
        sta VBLANK

        ; --- Area visivel: 192 linhas ---
        inc Frame
        ldx #192
KernelLoop
        stx COLUBK              ; degrade vertical simples (X = cor)
        sta WSYNC
        dex
        bne KernelLoop

        ; --- Overscan: 30 linhas ---
        lda #2
        sta VBLANK
        ldx #30
OverscanLoop
        sta WSYNC
        dex
        bne OverscanLoop

        jmp MainLoop

        ORG $FFFC
        .word Reset
        .word Reset
