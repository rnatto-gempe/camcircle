# Teleprompter

Um painel escuro com o roteiro rolando, que **não aparece em gravação nem em
compartilhamento de tela**. Você lê, quem assiste não vê.

```bash
cam tp edit          # cria e abre o roteiro, e o painel
cam tp time 3:00     # calcula a velocidade para terminar em 3 minutos
cam tp play
```

## Comandos

```bash
cam tp                    # abre
cam tp edit               # abre o roteiro no editor padrão
cam tp load <arquivo>     # usa outro arquivo como roteiro
cam tp paste              # carrega o texto do clipboard
cam tp time 3:00          # velocidade derivada do tempo (aceita 3:00, 3m ou 180)
cam tp speed 60           # velocidade fixa em px/s
cam tp play | pause | toggle | top
cam tp faster | slower
cam tp font 40 | bigger | smaller
cam tp mirror             # espelha, para vidro de teleprompter
cam tp opacity 0.6        # opacidade (0.25 a 1, ou 25 a 100)
cam tp pass on|off        # cliques atravessam o painel
cam tp keys               # mostra a ajuda na tela
cam tp camera             # abre/fecha o círculo da câmera
cam tp hotkeys off        # desliga os atalhos globais
cam tp hide | show
cam tp stop
```

## Atalhos globais

Funcionam **com qualquer app em foco** — que é o ponto, já que durante a gravação você está no
navegador, não no teleprompter. Usam `RegisterEventHotKey` (Carbon), que não exige permissão
de Acessibilidade.

Todos em **`⌃⌥⌘`** de propósito: um atalho do Carbon tem precedência sobre o do sistema, então
usar `⌥⌘` sequestraria globalmente coisas como "Mover item aqui" (`⌥⌘V` no Finder) e a busca
do Finder (`⌥⌘Space`).

| | |
|---|---|
| `⌃⌥⌘Space` | play / pause |
| `⌃⌥⌘↑` `⌃⌥⌘↓` | mais rápido / mais lento |
| `⌃⌥⌘R` | volta ao início |
| `⌃⌥⌘V` | carrega o texto do clipboard |
| `⌃⌥⌘[` `⌃⌥⌘]` | menos / mais opaco |
| `⌃⌥⌘L` | cliques atravessam o painel |
| `⌃⌥⌘T` | esconde / mostra |
| `⌃⌥⌘/` | abre e fecha a ajuda na tela |
| `⌃⌥⌘C` | abre / fecha o círculo da câmera |
| `⌃⌥⌘⇧` setas | move o painel pelo teclado |

Se algum atalho já estiver tomado por outro app, o rodapé mostra `⚠ em conflito` com a
combinação. Para desligar todos: `cam tp hotkeys off`.

Com o mouse ativo: arrastar move, `⌥`+arrastar redimensiona, scroll rola à mão, espaço
play/pause, `H` ajuda, `+`/`−` fonte, `[` `]` opacidade, setas ajustam, `M` espelha, `R`
reinicia, `Q` sai.

## Como a invisibilidade funciona

```swift
window.sharingType = .none
```

Uma linha. O macOS exclui a janela de todas as APIs de captura — `Cmd+Shift+5`, QuickTime,
Zoom, Meet, OBS via ScreenCaptureKit. É o mesmo mecanismo que gerenciadores de senha usam
para não vazar em screenshot.

Verificado com teste controlado: com os dois apps abertos, o `screencapture` registra o
CamCircle e **não** registra o Teleprompter.

Isso esconde de captura *de software*. Uma câmera filmando o monitor continua vendo o texto.

## Cliques atravessando o painel

`⌃⌥⌘L` faz o painel ignorar o mouse por completo, então você clica em botões e diálogos que
estão **atrás** dele. A borda fica tracejada em azul, senão um painel que ignora o mouse
parece travado.

O toggle é atalho global por necessidade lógica: com os cliques atravessando, não haveria como
clicar no painel para desligar. `⌃⌥⌘⇧`+setas move o painel nesse modo, e `cam tp pass off` é a
saída pelo terminal.

## Onde o texto começa

O roteiro nasce **na linha de leitura**, não no topo — você já começa olhando para o lugar
certo, e o texto sobe a partir dali.

Feito com dois espaçadores de altura exata (uma quebra de linha com `minimumLineHeight` e
`maximumLineHeight` fixos): um antes do texto, do tamanho da distância entre o topo e a linha,
e outro depois, para a última frase conseguir subir até lá. As duas alturas dependem do
tamanho do painel, então são recalculadas a cada redimensionamento e a cada mudança de fonte.

A posição da linha é uma constante única (`readingLineFromTop = 0.38`), usada tanto para
desenhá-la quanto para dimensionar o espaçador — não há como as duas saírem de sincronia.

## Modo tempo

`cam tp time 3:00` não é cronômetro: mede a altura real do texto renderizado
(`NSLayoutManager.usedRect`) e resolve `velocidade = percurso ÷ tempo`. Mudar a fonte ou o
tamanho da janela recalcula sozinho. O rodapé mostra tempo restante, total e px/s. Mexer na
velocidade à mão abandona o modo tempo.
