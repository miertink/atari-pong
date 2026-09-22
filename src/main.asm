; Pong para Atari 2600 (NTSC)
; Marco 0, Incremento 2 (correcao): joystick move as raquetes (P0/P1).
; Base: Incremento 1 (raquetes e bola estaticas, validado no Stella em
; 2026-09-22). Correcoes de 2026-09-22 apos feedback:
;
; 1) "bola desloca sutilmente ao mover a raquete esquerda": nao ha, no
;    codigo, nenhum caminho logico entre P0Y/P0YEnd e a bola (RAM sem
;    sobreposicao, indices de SetHorizPos conferidos no .sym). O
;    reposicionamento horizontal (SetHorizPos + HMOVE) rodava todo frame
;    mesmo sem nada mudar de posicao horizontal ainda — reforcar o HMOVE a
;    toa expoe ao efeito "HMOVE comb" (artefato documentado da TIA: o
;    strobe pode deslocar 1 pixel um objeto mesmo com ajuste zero). Agora
;    o posicionamento horizontal roda uma unica vez, no Reset. Se o efeito
;    persistir mesmo assim, e mais provavel ilusao de otica (movimento
;    induzido por um objeto proximo se movendo) do que bug de posicao.
; 2) "pedaco da raquete direita aparece no topo quando encostada embaixo":
;    GRP0/GRP1/ENABL nunca eram zerados fora do kernel visivel, entao o
;    ultimo valor da linha 191 sobrevivia por todo o VSYNC/VBLANK do frame
;    seguinte. Agora sao zerados explicitamente ao fim da area visivel.
;
; Paredes topo/base ficam de fora desta passada de proposito: o kernel de
; 192 linhas tem orcamento de 76 ciclos de CPU por scanline. Com raquetes +
; bola o pior caso fica ~61 ciclos (folga de ~15). Empilhar tambem a logica
; de parede (COLUBK por linha) passaria de 76 no calculo a mao — melhor
; validar o nucleo primeiro e reintroduzir parede num incremento a parte,
; com folga para conferir.
;
; Leitura de joystick: feita durante o VBLANK (nao critico ciclo a ciclo como
; o kernel visivel), mas cada bloco (P0, P1) fica em sua propria linha com
; WSYNC proprio — sem isso, ~40 ciclos de logica por raquete podem passar de
; 76 ciclos e "vazar" para a linha seguinte, desalinhando as 37 linhas do
; VBLANK.

        processor 6502
        include "vcs.h"
        include "macro.h"

; ---- Constantes de geometria/cor ----
PADDLE_HT      = 16             ; altura da raquete, em scanlines
PADDLE_PATTERN = %00111100      ; padrao de bits da raquete (GRP0/GRP1)
PADDLE_SPEED   = 2              ; scanlines por frame, ao segurar o joystick
PADDLE_Y_MAX   = 192-PADDLE_HT  ; maior valor valido de P0Y/P1Y (base = linha 191)
BALL_SIZE      = %00010000      ; CTRLPF: bola com 2 color clocks de largura
COLOR_WHITE    = $0E

P0_X           = 4              ; posicao horizontal fixa da raquete esquerda
                                 ; (ajustado: 3x a largura da raquete a menos
                                 ; que os 16 originais, a pedido do usuario)
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

        ; Posicionamento horizontal: feito uma unica vez aqui. Neste
        ; incremento nada muda de posicao horizontal (raquetes so se movem
        ; na vertical, bola ainda parada); repetir isso todo frame so
        ; reforcaria o HMOVE sem necessidade. Quando a bola comecar a se
        ; mover (Incremento 3), o reposicionamento dela volta para o
        ; MainLoop (P0/P1 continuam fixos na horizontal).
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

MainLoop
        ; --- VSYNC: 3 linhas ---
        lda #2
        sta VSYNC
        sta WSYNC
        sta WSYNC
        sta WSYNC
        lda #0
        sta VSYNC

        ; --- VBLANK: 37 linhas (1 P0 + 1 P1 + 35 de espera) ---
        lda #2
        sta VBLANK

        ; --- move raquete P0 (joystick 0 = porta esquerda: bit4=Up, bit5=Down) ---
        sta WSYNC
        lda SWCHA
        and #%00010000
        bne SkipP0Up
        lda P0Y
        sec
        sbc #PADDLE_SPEED
        bcs P0UpOk
        lda #0
P0UpOk
        sta P0Y
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
SkipP0Down
        lda P0Y
        clc
        adc #PADDLE_HT
        sta P0YEnd

        ; --- move raquete P1 (joystick 1 = porta direita: bit0=Up, bit1=Down) ---
        sta WSYNC
        lda SWCHA
        and #%00000001
        bne SkipP1Up
        lda P1Y
        sec
        sbc #PADDLE_SPEED
        bcs P1UpOk
        lda #0
P1UpOk
        sta P1Y
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
SkipP1Down
        lda P1Y
        clc
        adc #PADDLE_HT
        sta P1YEnd

        ldx #35
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

        ; zera os objetos ao sair da area visivel: sem isso, o ultimo valor
        ; escrito na linha 191 (ex.: raquete encostada no limite inferior)
        ; sobrevive por todo o VSYNC/VBLANK do proximo frame.
        lda #0
        sta GRP0
        sta GRP1
        sta ENABL

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
