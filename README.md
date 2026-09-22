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
      joystick, bola (BL), paredes em playfield, colisão por hardware e bip.
      Aqui o spike e o núcleo do jogo coincidem.
- [ ] Placar, saque, IA/modo 1 jogador, som e variações de velocidade.

### Candidatos por complexidade

| Nível | Escopo | Exemplos |
|-------|--------|----------|
| Baixo | Tela única, 1–2 players + playfield, joystick, som básico | **Pong (escolhido)**, Breakout, shooter fixo, estilo Combat |
| Médio | Sprites multiplexados (>2 objetos/scanline), scrolling, bank switching, kernel de score | — |
| Maior | Física elaborada, muitos estados de jogo, música | — |

---

## 8. Decisões em aberto

Resolvidas em 2026-09-21: jogo = Pong; alvo = NTSC.

1. **Controle:** joystick ou paddle (controle rotativo, o do Pong original)?
   Paddle é mais fiel ao original e lê via `INPT0/INPT1` (ADC por
   capacitor), com tratamento diferente do joystick.
2. **Modos:** 2 jogadores apenas, ou também 1 jogador contra IA no Marco 0?
3. **Ponto de vitória / regras:** pontuação até quanto? Aceleração da bola?
