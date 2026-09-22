# Atari 2600 — Pong

Documento âncora do projeto. Serve para seedar o contexto ao abrir a pasta no
VS Code com o Claude Code, para que nenhuma sessão comece do zero.

> **Jogo:** Pong (decidido em 2026-09-21).
> **Alvo:** NTSC (confirmado). Trocar para PAL exige ajuste do kernel — ver
> seção *Referência de hardware*.
> **Ambiente de desenvolvimento:** Windows 11 (PowerShell). O README original
> assumia macOS; os passos abaixo são os do Windows.

---

## 1. Objetivo e regras de trabalho

Construir um jogo completo para o Atari 2600 em assembly 6502, montado com DASM
e validado no emulador Stella.

Divisão de responsabilidades acordada:

- **VS Code (Claude Code)** — lar do desenvolvimento. Edição dos arquivos,
  estrutura de projeto, git.
- **Chat (claude.ai)** — discussão de design, técnica de kernel, destravar
  pontos específicos de timing.

**Restrição que molda o fluxo:** o assistente monta a ROM, mas não *vê* a tela
rodando. Portanto o ciclo é sempre `editar → montar → você roda no Stella →
você reporta`. Quanto mais preciso o seu retorno (jitter, posição de sprite,
cor, som), mais rápido convergimos. Timing fino às vezes precisa de um ajuste
na primeira passada — é o custo esperado, não um erro de rota.

---

## 2. Toolchain

| Ferramenta | Função |
|------------|--------|
| DASM | Assembler 6502 |
| Stella | Emulador / debugger |
| `vcs.h`, `macro.h` | Headers com registradores da TIA/RIOT e macros |
| git | Versionamento (essencial para kernels de timing) |

**Instalação no Windows 11**

```powershell
winget install TheStellaTeam.Stella
```

- **Stella:** via winget (`TheStellaTeam.Stella`). O `build.ps1` procura o
  `Stella.exe` no PATH e em `Program Files`.
- **DASM:** não está no winget. Usamos o `dasm.exe` da release v2.20.17
  (`dasm-assembler/dasm` no GitHub, zip `windows`), copiado para `tools/`.
  `tools/` está no `.gitignore`: em máquina nova, baixar o zip e extrair só o
  `dasm.exe` para `tools\dasm.exe`.
- **Headers:** o zip do Windows **não** inclui `vcs.h` e `macro.h`. Eles vêm de
  `machines/atari2600/` no repositório do DASM (tag v2.20.17) e ficam versionados
  em `include/`, para não depender de caminho de instalação.

**macOS/Linux (Mac pessoal):** `brew install dasm stella`. O `build.ps1` é
específico de Windows; no Mac usar o Makefile da seção 4 (mantido como
referência, ainda não testado).

---

## 3. Estrutura do repositório

```
atari-pong/
├── README.md            ← este arquivo
├── build.ps1            ← build/run/clean no Windows
├── .gitignore           ← build/ e tools/
├── include/
│   ├── vcs.h            ← registradores TIA/RIOT (vendorado)
│   └── macro.h          ← macros DASM (vendorado)
├── tools/               ← dasm.exe (gitignored)
├── src/
│   └── main.asm         ← ponto de entrada, vetores, loop principal
└── build/               ← saída (gitignored)
    ├── game.bin         ← ROM
    ├── game.lst         ← listing
    └── game.sym         ← símbolos
```

Hoje só existe `src/main.asm`. Quando o código crescer, separar em
`constants.asm` (constantes, RAM map) e `kernel.asm` (kernel de display).
Bancos (bank switching) entram como arquivos adicionais em `src/` quando o jogo
passar de 4K.

---

## 4. Build e execução

**Windows (usado neste projeto):**

```powershell
.\build.ps1          # monta a ROM em build\game.bin
.\build.ps1 run      # monta e abre no Stella
.\build.ps1 clean    # limpa artefatos
```

Observação: os flags do DASM (`-obuild\game.bin`, `-Iinclude`...) precisam ser
passados como array no PowerShell; passados soltos, o DASM recusa a linha de
comando ("Check command-line format").

**macOS/Linux — Makefile de referência (não testado neste projeto):**

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

Uso: `make`, `make run`, `make clean`. No Mac, `tools/` não é necessário
(DASM vem do brew); ajustar o `.gitignore` se for o caso.

---

## 5. Loop de desenvolvimento

1. Assistente edita `src/*.asm`.
2. Você roda `.\build.ps1 run`.
3. Você observa e reporta: **o que viu vs. o esperado**. Detalhes úteis —
   sprite tremendo (jitter), objeto deslocado horizontalmente, cor incorreta,
   som ausente/errado, tela rolando (rolling).
4. Iteramos.

**Disciplina de git:** commit a cada marco que funciona, e obrigatoriamente
*antes* de mexer num kernel de timing que já está correto. Timing bom é frágil;
git é o desfazer confiável.

---

## 6. Referência de hardware (NTSC)

Consulta rápida para não sair do repositório.

**CPU — MOS 6507**
- Núcleo 6502, ~1,19 MHz.
- 13 linhas de endereço → 8 KB de espaço (daí o bank switching acima de 4K).
- Sem IRQ/NMI expostos.

**Memória**
- **128 bytes de RAM** (dentro do RIOT/6532). É todo o espaço de trabalho.
- ROM de cartucho: 2K/4K base.

**Chips**
- **TIA** — gráficos e som. Sem framebuffer: a imagem é montada linha a linha.
- **RIOT (6532)** — RAM, timer e I/O (joysticks, switches do console).

**Temporização do frame (convenção NTSC)**
- 262 scanlines: 3 VSYNC + 37 VBLANK + **192 visíveis** + 30 overscan.
- **76 ciclos de CPU por scanline** (228 color clocks ÷ 3).
- 1 ciclo de CPU = 3 pixels. Orçamento apertado — o kernel é contado ciclo a
  ciclo.

**Objetos da TIA**
- 2 players (P0, P1), 2 missiles (M0, M1), 1 ball (BL).
- Playfield: PF0/PF1/PF2 = 20 bits, com opção de espelhar ou refletir na
  metade direita da tela.
- Colisões por hardware (registradores CXxx) — usar em vez de calcular por
  software sempre que possível.

**Strobes / registradores-chave**
- `WSYNC` — trava a CPU até o início da próxima scanline.
- `VSYNC`, `VBLANK` — controle do sync vertical e do blanking.
- `RESP0`/`RESP1`, `HMOVE`, `HMCLR` — posicionamento horizontal dos objetos.
- `CXCLR` — limpa registradores de colisão.

**Som**
- 2 canais: `AUDC0/1` (tipo de onda), `AUDF0/1` (frequência), `AUDV0/1`
  (volume).

**PAL — diferenças (se trocarmos o alvo)**
- 312 scanlines, 50 Hz, ~228 linhas visíveis.
- Kernel e paleta de cores mudam; por isso o alvo é fixado antes de escrever o
  kernel.

---

## 7. Status e próximos passos

- [x] Confirmar alvo: **NTSC**.
- [x] Definir o jogo: **Pong**.
- [x] Toolchain: `dasm.exe` v2.20.17 em `tools/`, headers em `include/`,
      `build.ps1` funcionando (ROM de 4096 bytes gerada).
- [x] Estrutura do repositório criada e `git init` feito.
- [ ] Instalar o Stella (`winget install TheStellaTeam.Stella`) e confirmar que
      `.\build.ps1 run` abre a ROM. **Pendente, depende de você.**
- [x] **Marco -1 — validar o esqueleto:** confirmado em 2026-09-22 — tela
      estável no Stella, sem rolling, degradê vertical correto. Loop de 262
      linhas validado.
- [ ] **Marco 0 — Pong mínimo (spike):** 2 raquetes (P0/P1) movidas por
      joystick, bola (BL), colisão por hardware e bip. Regras: placar até 5,
      sem aceleração da bola. Dividido em incrementos:
  - [x] **Incremento 1 — objetos estáticos:** raquetes e bola desenhadas e
        posicionadas (sem movimento, sem paredes ainda — ver nota de
        orçamento de ciclos no `main.asm`). Validado no Stella em 2026-09-22;
        ajuste cosmético aplicado (raquete esquerda `P0_X` 16→4).
  - [x] **Incremento 2 — joystick move as raquetes:** validado em 2026-09-22.
        Três bugs reportados e corrigidos: (1) objeto deslocando ~1px ao
        mexer no joystick — causa real identificada só no Incremento 3 (ver
        abaixo): `HMCLR` estrobado cedo demais depois do `HMOVE`; residual
        eliminado quando o mesmo fix foi aplicado ao `Reset`; (2) fragmento
        de raquete vazando para o topo da tela — `GRP0/GRP1/ENABL` não eram
        zerados fora do kernel visível; (3) bola sumindo com raquetes no
        topo — bola tinha só 1 scanline de altura, aumentada.
  - [x] **Incremento 3 — bola se move e quica nas bordas:** implementado em
        2026-09-22. Quique real no topo/base; quique nas laterais por
        enquanto é placeholder (substituído pela colisão com raquete e
        detecção de ponto nos incrementos 4/5). Sem aceleração, conforme
        regra definida.
        **Depuração de movimento "picotado"/"galopando" em vez de deslizar**
        (a mais longa do projeto até aqui, várias hipóteses testadas e
        descartadas com evidência antes de achar a causa real):
        1. `SetHorizPos` tem custo variável (loop de "subtrai 15"); corrigido
           trocando contagem manual de `WSYNC` por timer de hardware
           (`TIMER_SETUP`/`TIMER_WAIT`) no VBLANK — real, mas não era a
           causa principal do picotamento.
        2. Regressão própria: `WSYNC` removido antes do `HMOVE` fazia as
           raquetes se moverem sozinhas na horizontal — corrigido restaurando
           o `WSYNC` (requisito de hardware, não só orçamento de ciclos).
        3. Hipótese "bola muito fina pro passo de 2px aparecer" — testada
           (aumentar largura para 8 color clocks) e **descartada**: não mudou
           nada.
        4. **Causa raiz real:** `HMCLR` estrobado só 3 ciclos depois do
           `HMOVE` cortava a injeção do ajuste fino antes de completar — só
           o reposicionamento grosso (`RESBL`) sobrevivia, dando saltos
           grandes a cada ~7-8 frames em vez de deslizar. Corrigido removendo
           o `HMCLR` do bloco por-frame da bola (não é necessário ali) e
           dando folga extra antes do `HMCLR` no `Reset` (esse é necessário,
           por isso não foi removido, só adiado). Confirmado pelo usuário.
        Diagnóstico usado: piscar o fundo da tela com o contador de frame e
        depois com o valor de `BallX` em RAM, para isolar timing global vs.
        aritmética vs. posicionamento na tela antes de mexer em código.
  - [ ] Incremento 4 — colisão bola↔raquete (hardware, `CXP0FB`/`CXP1FB`) + bip.
  - [ ] Incremento 5 — paredes topo/base (reintroduzir, com orçamento de
        ciclos ok) e detecção de ponto (bola passa da raquete, substituindo
        o quique lateral provisório do Incremento 3).
- [ ] Placar em tela (dígitos), IA como oponente, som além do bip de colisão.

### Candidatos por complexidade

| Nível | Escopo | Exemplos |
|-------|--------|----------|
| Baixo | Tela única, 1–2 players + playfield, joystick, som básico | **Pong (escolhido)**, Breakout, shooter fixo, estilo Combat |
| Médio | Sprites multiplexados (>2 objetos/scanline), scrolling, bank switching, kernel de score | — |
| Maior | Física elaborada, muitos estados de jogo, música | — |

---

## 8. Decisões em aberto

Resolvidas em 2026-09-21/22: jogo = Pong; alvo = NTSC; controle = joystick
(paddle fica para depois, se fizer sentido); modos = 2 jogadores no Marco 0,
IA como oponente entra depois; placar até 5; bola não acelera.

Nenhuma em aberto no momento.
