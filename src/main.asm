; Pong para Atari 2600 (NTSC)
;
; Estado atual (2026-09-22): Marco 0, Incremento 3.
;   - P0/P1 (raquetes): joystick move na vertical; posicao horizontal fixa,
;     definida uma unica vez no Reset.
;   - BL (bola): se move e quica no topo/base (regra definitiva). Tambem
;     quica nas laterais por enquanto — placeholder ate colisao com raquete
;     e pontuacao (Incrementos 4/5), que vao substituir o quique lateral.
;
; Historico de bugs corrigidos (Incremento 2, 2026-09-22):
;   1) Deslocamento subito de ~1px em objetos ao mexer no joystick: causa
;      mais provavel era reforcar HMOVE todo frame sem necessidade (efeito
;      "HMOVE comb" da TIA). Resolvido ao reposicionar P0/P1 uma unica vez
;      no Reset em vez de todo frame. Residual de ~1px aceito pelo usuario
;      como particularidade do emulador, sem impacto pratico.
;   2) Fragmento de raquete "vazando" para o topo da tela quando encostada
;      no limite inferior: GRP0/GRP1/ENABL nao eram zerados fora do kernel
;      visivel, entao o ultimo valor da linha 191 sobrevivia pelo
;      VSYNC/VBLANK do frame seguinte. Corrigido zerando os tres ao sair da
;      area visivel.
;   3) Bola sumindo com as raquetes na metade superior da tela: causa era a
;      bola ter so 1 scanline de altura (objeto fino demais para renderizar
;      de forma confiavel). Corrigido aumentando para 2 scanlines.
;
; Paredes topo/base (visuais) ficam de fora desta passada de proposito: o
; kernel de 192 linhas tem orcamento de 76 ciclos de CPU por scanline, e ja
; esta perto do limite so com raquetes + bola. Reintroduzir num incremento a
; parte, com folga para conferir.
;
; Timing do VBLANK: usa o timer de hardware do RIOT (TIMER_SETUP/TIMER_WAIT,
; do macro.h) em vez de contar WSYNCs a mao. Motivo (bug real encontrado em
; 2026-09-22, reportado como "movimento da bola sofrivel/picotado"):
; SetHorizPos usa um loop de "subtrai 15 ate estourar" cujo numero de
; iteracoes varia com o valor de X. Para X pequeno (~4) custa ~30 ciclos; para
; X grande (~150-159) passa de 80 ciclos — acima do orcamento de 76/scanline.
; Contar WSYNCs a mao so funciona para custo CONSTANTE por linha; para custo
; variavel, o timer de hardware absorve a variacao automaticamente.
;
; HMOVE precisa de WSYNC logo antes (requisito de hardware, janela de ~24
; ciclos, nao so orcamento) — regressao real cometida e corrigida na mesma
; investigacao (raquetes chegaram a se mover sozinhas por causa disso).
;
; Gangueira residual apos os fixes acima ("para e pula"/"galopa em vez de
; deslizar", salto maior que o passo normal, a cada ~7-8 frames):
; diagnosticada empiricamente (fundo da tela piscando com Frame e depois
; com BallX) como NAO sendo bug de dados/timing geral — RAM e frame rate
; confirmados corretos a cada frame. Primeira hipotese (bola fina demais
; pro passo de 2px aparecer) testada e DESCARTADA — aumentar a largura para
; 8 color clocks nao mudou nada, provando que o movimento era mesmo
; discreto, nao so dificil de perceber.
;
; Causa raiz real: no bloco "move a bola" do MainLoop, HMCLR era estrobado
; so 3 ciclos depois do HMOVE. Suspeita: a injecao do ajuste fino do HMOVE
; nao e instantanea, e zerar HMBL cedo demais cortava essa injecao antes de
; completar — so o reposicionamento grosso (RESBL, que nao depende do
; HMOVE) sobrevivia, dando saltos de ~15 unidades a cada ~7-8 frames em vez
; de deslizar 2px por vez. Remover o HMCLR dali (nao e necessario — HMBL e
; reescrito do zero pelo SetHorizPos antes do PROXIMO HMOVE) resolveu,
; confirmado pelo usuario. O mesmo HMCLR no Reset (que posiciona P0/P1/BL
; uma unica vez) provavelmente causava o residual de ~1px aceito la atras
; como "particularidade do emulador" — mantido ali, mas com um WSYNC extra
; de folga antes de zerar (nao pode ser removido, senao o HMOVE da bola no
; MainLoop reaplicaria o HMP0/HMP1 do Reset a cada frame — o bug das
; raquetes se movendo sozinhas, ja corrigido antes).

        processor 6502
        include "vcs.h"
        include "macro.h"

; ---- Constantes de geometria/cor ----
PADDLE_HT      = 16             ; altura da raquete, em scanlines
PADDLE_PATTERN = %00111100      ; padrao de bits da raquete (GRP0/GRP1)
PADDLE_SPEED   = 3              ; scanlines por frame, ao segurar o joystick
                                 ; (era 2, igual a BALL_SPEED — usuario pediu
                                 ; a bola pelo menos 1/3 mais lenta que a
                                 ; raquete: (3-2)/3 = 33%)
PADDLE_Y_MAX   = 192-PADDLE_HT  ; maior valor valido de P0Y/P1Y (base = linha 191)
BALL_HT        = 4              ; altura da bola, em scanlines (era 2)
BALL_SIZE      = %00100000      ; CTRLPF: bola com 4 color clocks de largura
                                 ; (era 8 — testado largo demais depois do
                                 ; fix do HMCLR; ajuste cosmetico: mais
                                 ; estreita e mais alta, a pedido do usuario)
COLOR_WHITE    = $0E

; limites de quique da bola (0-159 horizontal, mesma escala usada por
; SetHorizPos; verticais em linhas de scanline, 0-191). A deteccao de
; quique compara IGUALDADE EXATA com esses limites (nao "<=") — por isso
; eles precisam ter a mesma paridade de BALL_X_INIT/BALL_Y_INIT e serem
; alcancaveis em passos de BALL_SPEED, senao a bola pula por cima do
; limite sem nunca bater exatamente nele. Com BALL_X_INIT=80 (par) e
; BALL_SPEED=2 (par), a posicao da bola e sempre par — por isso os limites
; abaixo tambem sao pares. Se mudar BALL_SPEED/BALL_X_INIT/BALL_Y_INIT,
; conferir essa paridade de novo (ou trocar por comparacao "<=").
BALL_X_MIN     = 2
BALL_X_MAX     = 158
BALL_Y_MIN     = 0
BALL_Y_MAX     = 192-BALL_HT
BALL_SPEED     = 2              ; pixels/frame em cada eixo. Teste: 1px/frame
                                 ; parecia "aos saltos" em monitor/emulador
                                 ; (sem persistencia de fosforo de um CRT).
                                 ; Usado tanto na velocidade inicial quanto
                                 ; nos quiques (ver blocos abaixo) — nao
                                 ; mexer so na constante inicial, tem que
                                 ; trocar os dois em conjunto.
BALL_DX_INIT   = BALL_SPEED
BALL_DY_INIT   = BALL_SPEED

; colisao bola<->raquete (hardware CXP0FB/CXP1FB, bit 6 = colisao com a bola;
; bit 7 seria colisao com playfield, nao usado aqui) + bip curto
COLLISION_BL   = %01000000
SOUND_HIT_TONE = 4              ; AUDC0: "pure tone" (onda quadrada limpa).
                                 ; Era 8 ("9-bit poly" = ruido branco/chiado
                                 ; na TIA — nao e tom, e a tabela de valores
                                 ; que eu assumi errado).
SOUND_HIT_FREQ = 4              ; AUDF0: agudo (valor baixo = frequencia alta)
SOUND_HIT_VOL  = 12             ; AUDV0: volume (0-15)
SOUND_HIT_LEN  = 4              ; duracao do bip, em frames

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
BallX   ds 1                    ; coluna da bola (escala 0-159, mesma do SetHorizPos)
BallY   ds 1                    ; topo da bola
BallYEnd ds 1                   ; BallY + BALL_HT (pre-calculado)
BallDX  ds 1                    ; velocidade horizontal: +-BALL_SPEED
BallDY  ds 1                    ; velocidade vertical: +-BALL_SPEED
SoundTimer ds 1                 ; frames restantes do bip de colisao (0 = silencio)

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

        lda #BALL_X_INIT
        sta BallX
        lda #BALL_Y_INIT
        sta BallY
        clc
        adc #BALL_HT
        sta BallYEnd
        lda #BALL_DX_INIT
        sta BallDX
        lda #BALL_DY_INIT
        sta BallDY

        ; Posicionamento horizontal inicial (uma vez). P0/P1 nunca mais se
        ; reposicionam na horizontal (so se movem na vertical). A bola e
        ; reposicionada de novo a cada frame no MainLoop, ja que agora ela
        ; se move (ver bloco "move a bola" abaixo).
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
        ; HMCLR NAO estrobado logo em seguida (mesma causa raiz do "desliza"
        ; corrigido no MainLoop, ver comentario la): zerar HMOVE 3 ciclos
        ; depois pode cortar a injecao do ajuste fino antes de completar.
        ; Aqui a diferenca e que P0/P1/BL nao vao ser reposicionados de novo
        ; tao cedo (P0/P1 nunca mais; a bola so no proximo frame), entao
        ; HMP0/HMP1/HMBL PRECISAM ser zerados em algum momento — senao o
        ; HMOVE da bola no MainLoop reaplicaria o valor de HMP0/HMP1 do
        ; Reset a cada frame (foi exatamente o bug das raquetes se movendo
        ; sozinhas, corrigido antes). Por isso aqui so adiamos o HMCLR (mais
        ; um WSYNC de folga) em vez de tira-lo — o Reset roda uma vez so,
        ; entao gastar uma linha extra nao custa nada.
        sta WSYNC
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

        ; --- VBLANK: 37 linhas, reservadas via timer de hardware (ver nota
        ; no cabecalho do arquivo) ---
        lda #2
        sta VBLANK
        TIMER_SETUP 37

        ; --- move raquete P0 (joystick 0 = porta esquerda: bit4=Up, bit5=Down) ---
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

        ; --- move a bola: quique vertical (topo/base) ---
        lda BallY
        cmp #BALL_Y_MIN
        bne NoTopBounce
        lda BallDY
        bpl NoTopBounce          ; ja indo pra baixo (>=0), nada a fazer
        lda #BALL_SPEED
        sta BallDY
NoTopBounce
        lda BallY
        cmp #BALL_Y_MAX
        bne NoBottomBounce
        lda BallDY
        bmi NoBottomBounce       ; ja indo pra cima (<0), nada a fazer
        lda #-BALL_SPEED
        sta BallDY
NoBottomBounce
        lda BallY
        clc
        adc BallDY
        sta BallY
        clc
        adc #BALL_HT
        sta BallYEnd

        ; --- move a bola: quique horizontal (placeholder ate paddle/pontuacao) ---
        lda BallX
        cmp #BALL_X_MIN
        bne NoLeftBounce
        lda BallDX
        bpl NoLeftBounce         ; ja indo pra direita (>=0), nada a fazer
        lda #BALL_SPEED
        sta BallDX
NoLeftBounce
        lda BallX
        cmp #BALL_X_MAX
        bne NoRightBounce
        lda BallDX
        bmi NoRightBounce        ; ja indo pra esquerda (<0), nada a fazer
        lda #-BALL_SPEED
        sta BallDX
NoRightBounce
        lda BallX
        clc
        adc BallDX
        sta BallX

        ; reposiciona a bola na horizontal (unico objeto que ainda se move
        ; na horizontal neste incremento). SetHorizPos faz seu proprio
        ; WSYNC interno, necessario para o calculo de posicao.
        ;
        ; O "sta WSYNC" abaixo, antes do HMOVE, NAO e sobre orcamento de
        ; ciclos (o timer ja cobre isso) — e um requisito de hardware:
        ; HMOVE precisa ser estrobado logo no inicio de uma scanline (~24
        ; ciclos de janela). Sem isso, como SetHorizPos pode levar ate ~80
        ; ciclos para retornar (dependendo do X), o HMOVE ficava sendo
        ; estrobado tarde demais na linha — e um HMOVE fora da janela pode
        ; aplicar deslocamento incorreto/espurio a QUALQUER objeto, nao so
        ; ao que acabou de ser reposicionado. Isso explicava tanto a
        ; gangueira (piorada) quanto as raquetes se deslocando na horizontal
        ; mesmo com HMP0/HMP1 zerados. Bug introduzido na refatoracao do
        ; timer (removi este WSYNC achando que era so questao de orcamento).
        ldx #4
        jsr SetHorizPos
        sta WSYNC
        sta HMOVE
        ; SEM HMCLR aqui — confirmado pelo usuario que resolve a "gangueira"
        ; (bola "galopando" em vez de deslizar). Causa raiz: HMCLR estrobado
        ; so 3 ciclos depois do HMOVE cortava a injecao do ajuste fino antes
        ; de completar; so o reposicionamento grosso (RESBL, que nao
        ; depende do HMOVE) sobrevivia, dando saltos de ~15 unidades a cada
        ; ~7-8 frames em vez de deslizar 2px por vez. Nao precisamos de
        ; HMCLR aqui de qualquer forma: HMBL e reescrito do zero pelo
        ; SetHorizPos antes do PROXIMO HMOVE, entao nao ha valor obsoleto
        ; para vazar de um frame pro outro. (HMP0/HMP1 continuam OK porque
        ; ja foram zerados uma vez no Reset — ver comentario la.)

        TIMER_WAIT
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

        ; bola: acesa se BallY <= X < BallYEnd (BALL_HT scanlines)
        lda #0
        cpx BallY
        bcc SkipBall
        cpx BallYEnd
        bcs SkipBall
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

        ; --- colisao bola<->raquete (hardware) ---
        ; CXP0FB/CXP1FB acumulam colisoes durante toda a area visivel que
        ; acabou de rodar; ler agora pega o resultado do frame inteiro.
        ; CXCLR no final limpa os latches pro proximo frame (sao "sticky",
        ; nao zeram sozinhos).
        lda CXP0FB
        and #COLLISION_BL
        beq NoHitP0
        lda #BALL_SPEED          ; bateu na raquete esquerda -> bola vai pra direita
        sta BallDX
        jsr StartHitSound
NoHitP0
        lda CXP1FB
        and #COLLISION_BL
        beq NoHitP1
        lda #-BALL_SPEED         ; bateu na raquete direita -> bola vai pra esquerda
        sta BallDX
        jsr StartHitSound
NoHitP1
        sta CXCLR

        ; --- som: decrementa o timer do bip, silencia quando chega a 0 ---
        lda SoundTimer
        beq SoundDone
        dec SoundTimer
        bne SoundDone
        lda #0
        sta AUDV0
SoundDone

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

; ---------------------------------------------------------------------------
; StartHitSound - inicia o bip de colisao (AUDC0/AUDF0/AUDV0 + SoundTimer).
; O som e desligado automaticamente apos SOUND_HIT_LEN frames (ver bloco
; "som" no MainLoop, que decrementa SoundTimer e zera AUDV0 quando chega a 0).
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

        ORG $FFFC
        .word Reset
        .word Reset
