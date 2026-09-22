; Pong para Atari 2600 (NTSC)
; Marco 0, Incremento 1: raquetes (P0/P1) e bola (BL) desenhadas e
; posicionadas, sem movimento ainda. Objetivo: validar o posicionamento
; horizontal (rotina SetHorizPos) e o desenho por comparacao de scanline
; antes de adicionar joystick, fisica da bola e colisao.
;
; Paredes topo/base ficam de fora desta passada de proposito: o kernel de
; 192 linhas tem orcamento de 76 ciclos de CPU por scanline. Com raquetes +
; bola o pior caso fica ~61 ciclos (folga de ~15). Empilhar tambem a logica
; de parede (COLUBK por linha) passaria de 76 no calculo a mao — melhor
; validar o nucleo primeiro e reintroduzir parede num incremento a parte,
; com folga para conferir.

        processor 6502
        include "vcs.h"
        include "macro.h"

; ---- Constantes de geometria/cor ----
PADDLE_HT      = 16             ; altura da raquete, em scanlines
PADDLE_PATTERN = %00111100      ; padrao de bits da raquete (GRP0/GRP1)
BALL_SIZE      = %00010000      ; CTRLPF: bola com 2 color clocks de largura
COLOR_WHITE    = $0E

P0_X           = 16             ; posicao horizontal fixa da raquete esquerda
P1_X           = 140            ; posicao horizontal fixa da raquete direita
BALL_X_INIT    = 80             ; posicao horizontal inicial da bola (centro)
P0_Y_INIT      = 88             ; topo da raquete esquerda (linha 0-191)
P1_Y_INIT      = 88
BALL_Y_INIT    = 96

        SEG.U vars
        ORG $80
Frame   ds 1                    ; contador de frames (para uso futuro)
P0Y     ds 1                    ; topo da raquete esquerda
P0YEnd  ds 1                    ; P0Y + PADDLE_HT (pre-calculado)
P1Y     ds 1                    ; topo da raquete direita
P1YEnd  ds 1                    ; P1Y + PADDLE_HT (pre-calculado)
BallY   ds 1                    ; linha da bola

        SEG code
        ORG $F000

Reset
        CLEAN_START

        ; esquema monocromatico classico: raquetes/bola brancas, fundo preto
        lda #COLOR_WHITE
        sta COLUP0
        sta COLUP1
        sta COLUPF

        lda #BALL_SIZE
        sta CTRLPF

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

        lda #BALL_Y_INIT
        sta BallY

MainLoop
        ; --- VSYNC: 3 linhas ---
        lda #2
        sta VSYNC
        sta WSYNC
        sta WSYNC
        sta WSYNC
        lda #0
        sta VSYNC

        ; --- VBLANK: 37 linhas (4 usadas p/ posicionamento horizontal, 33 de espera) ---
        lda #2
        sta VBLANK

        lda #P0_X
        ldx #0
        jsr SetHorizPos          ; P0
        lda #P1_X
        ldx #1
        jsr SetHorizPos          ; P1
        lda #BALL_X_INIT
        ldx #4
        jsr SetHorizPos          ; BL

        sta WSYNC
        sta HMOVE
        sta HMCLR

        ldx #33
VBlankLoop
        sta WSYNC
        dex
        bne VBlankLoop
        lda #0
        sta VBLANK

        ; --- Area visivel: 192 linhas ---
        inc Frame
        ldx #0
KernelLoop
        ; raquete esquerda (P0): acesa se P0Y <= X < P0YEnd
        lda #0
        cpx P0Y
        bcc SkipP0
        cpx P0YEnd
        bcs SkipP0
        lda #PADDLE_PATTERN
SkipP0
        sta GRP0

        ; raquete direita (P1)
        lda #0
        cpx P1Y
        bcc SkipP1
        cpx P1YEnd
        bcs SkipP1
        lda #PADDLE_PATTERN
SkipP1
        sta GRP1

        ; bola: 1 scanline de altura por enquanto
        lda #0
        cpx BallY
        bne SkipBall
        lda #%00000010           ; ENABL bit 1
SkipBall
        sta ENABL

        sta WSYNC
        inx
        cpx #192
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

; ---------------------------------------------------------------------------
; SetHorizPos - posiciona horizontalmente um objeto da TIA.
; Rotina padrao da comunidade Atari 2600 (divide-by-15 + fine adjust).
; IN: A = coluna desejada (0-159), X = indice do objeto
;     (0=P0, 1=P1, 2=M0, 3=M1, 4=BL — mesma ordem de RESP0..RESBL/HMP0..HMBL)
; Chamar sempre logo apos um WSYNC (ou seja, no inicio de uma linha) durante
; VSYNC/VBLANK; a propria rotina consome uma linha via WSYNC. Um HMOVE deve
; ser estrobado depois, na linha seguinte, para aplicar o ajuste fino.
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

        ORG $FFFC
        .word Reset
        .word Reset
