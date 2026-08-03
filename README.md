# CamCircle + Teleprompter

Dois overlays nativos para gravar a tela no macOS, sem instalar nada de terceiros:

- **CamCircle** — sua webcam num círculo flutuante, sempre por cima
- **Teleprompter** — roteiro rolando na tela, **invisível na gravação e no
  compartilhamento de tela**
- **Captions** — legendas ao vivo da sua fala, transcritas **on-device**, também
  invisíveis na gravação

Webcam num círculo flutuante, sempre por cima de tudo, para gravar a tela com seu rosto —
tipo o overlay de câmera do Loom ou do mmhmm, mas nativo e sem instalar nada de terceiros.

Zero dependências: só AppKit + AVFoundation do próprio macOS, compilado com o `swiftc` que
já vem no **Command Line Tools** (não precisa do Xcode). O app inteiro é um arquivo Swift.

- Fundo realmente transparente — círculo limpo, sem retângulo preto
- Sempre por cima, em todos os Spaces, inclusive sobre apps em tela cheia
- Anel gradiente animado, glow, vinheta, realce de imagem
- Enquadramento por clique: você aponta o ponto e ele vira o centro
- Tudo controlado por um comando de terminal: `cam`

## Requisitos

macOS 13 ou mais recente e o Command Line Tools da Apple:

```bash
xcode-select --install   # se ainda não tiver
swiftc --version         # deve responder
```

## Instalar

```bash
git clone https://github.com/rnatto-gempe/camcircle.git
cd camcircle
./install.sh
```

O `install.sh` compila, instala em `~/Applications/CamCircle.app`, coloca o comando `cam`
em `~/.local/bin` e liga todos os efeitos.

Se `~/.local/bin` não estiver no seu PATH, adicione ao `~/.zshrc`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Na primeira execução o macOS pede acesso à **câmera** e, se o efeito de voz estiver ligado,
ao **microfone**. Negou por engano? Ajustes do Sistema › Privacidade e Segurança › Câmera
(ou Microfone) › CamCircle.

## Comando de terminal

```bash
cam                # abre o círculo
cam all            # liga os efeitos visuais e abre
cam all --voice    # idem, com o anel reativo à voz (pede microfone)
cam clean          # versão discreta (sem anel, sem voz)
cam stop           # fecha
cam restart
cam zoom 1.5       # define o zoom do enquadramento
cam size 320       # define o diâmetro em px
cam build          # recompila do fonte e reinstala
cam reset          # apaga as preferências
cam status         # mostra se está rodando e as configurações
cam both           # abre o círculo e o teleprompter
cam h              # ajuda
```

## Atalhos

Funcionam com o círculo em foco (clique nele uma vez). Depois de clicar em outro app, use o
**clique direito** — o menu funciona sempre. Dentro do app, `H` abre a lista de atalhos.

| Ação | Como |
|---|---|
| Fechar com o mouse | passe o mouse sobre o círculo → clique no **X** |
| Ver os atalhos | `H` |
| Mover | arrastar (encaixa no canto se soltar perto) |
| Redimensionar | scroll / pinça, `+` `-`, ou `1` `2` `3` |
| **Centralizar em um ponto** | `P` e clique no ponto — ou `option` + clique direto |
| Ajuste fino do enquadramento | setas ← → ↑ ↓ |
| Zoom | `option` + scroll, ou `Z` para ciclar |
| Voltar ao enquadramento padrão | `0` |
| Formato: círculo / squircle / quadrado | `S` |
| Anel: nenhum / sólido / gradiente | `B` |
| Cor do anel | `T` |
| Sombra | `D` |
| Borda esfumaçada | `F` |
| Realce studio | `L` |
| Anel reage à voz | `V` |
| Enquadramento automático (Center Stage) | `A` |
| Espelhar imagem | `M` |
| Trocar de câmera | `C` |
| Abrir/fechar o teleprompter | `⌃⌥⌘P` (funciona de qualquer app) |
| Menu completo | clique direito |
| Sair | `Q` ou `Esc` |

Tudo fica salvo entre execuções: tamanho, posição, formato, zoom, enquadramento, efeitos e
câmera escolhida.

## Efeitos

| | |
|---|---|
| Anel gradiente animado | gradiente cônico girando + glow na cor do tema |
| Temas de cor | Aurora, Ember, Mint, Studio |
| Profundidade | sombra suave + vinheta interna |
| Realce studio | leve ganho de contraste, saturação e vibrance |
| Borda esfumaçada | alternativa ao corte duro, sem anel |
| Anel reage à voz | o glow pulsa com o nível do microfone |
| Enquadramento automático | Center Stage, quando a câmera suporta |
| Zoom, pan e clique-para-centralizar | recorte manual, sem depender do Center Stage |
| Animações | entrada com spring, resize suave, encaixe magnético nos cantos |

### Enquadramento por clique

O Center Stage (enquadramento automático da Apple) só existe em algumas câmeras — quando a
sua não suporta, o item do menu aparece desabilitado. O clique-para-centralizar resolve isso
manualmente: `P`, clique no seu rosto, e aquele ponto vira o centro do círculo.

A camada de vídeo é dimensionada pelo aspecto real da câmera e o deslocamento é limitado ao
que existe de imagem, então nunca sobra borda vazia.

### Desfoque de fundo

O macOS já faz nativo: com o CamCircle aberto, **Central de Controle › Efeitos de Vídeo ›
Retrato**. Funciona na câmera embutida e no iPhone via Continuity, sem código nosso.

## Gravando a tela

1. `cam all` e posicione o círculo.
2. Grave com `Cmd + Shift + 5` — o círculo aparece na gravação.

Para gravar sem o círculo, grave só uma região da tela (`Cmd + Shift + 5` › gravar porção
selecionada) fora dele.

## Abrir no login

Ajustes do Sistema › Geral › Itens de Início › adicione `~/Applications/CamCircle.app`.

## Como funciona

Uma `NSWindow` borderless e transparente, no nível `overlayWindow`, com
`collectionBehavior` incluindo `canJoinAllSpaces` e `fullScreenAuxiliary`. Dentro dela, uma
árvore de `CALayer`:

```
container        sombra externa
├── clip         cornerRadius + masksToBounds → recorta o formato
│   ├── preview  AVCaptureVideoPreviewLayer, maior que o clip (zoom/pan)
│   ├── vignette gradiente radial
│   └── crosshair alvo do modo de mira
├── glow         CAShapeLayer com sombra colorida
├── ringHolder   gradiente cônico girando, mascarado em anel
└── rim          aro de vidro interno
```

Detalhe que custou um bug: a janela é **maior que o círculo** (12% de respiro em cada lado).
Sem isso, a sombra e o glow batem no limite da janela e viram um halo cinza quadrado nos
cantos.

O `build.sh` monta o `.app` na mão — `Info.plist` com `LSUIElement`,
`NSCameraUsageDescription` e `NSMicrophoneUsageDescription` — e assina ad-hoc com
`codesign -s -` para o macOS manter a permissão de câmera entre builds.

## Teleprompter

Um painel escuro com o roteiro rolando, que **não aparece em gravação nem em
compartilhamento de tela**. Você lê, quem assiste não vê.

```bash
cam tp edit          # cria/abre o roteiro e o painel (recarrega ao salvar)
cam tp time 3:00     # calcula a velocidade para terminar em 3 minutos
cam tp play
```

### Comandos

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
cam tp dimmer | brighter  # opacidade em passos
cam tp pass on|off        # cliques atravessam o painel
cam tp keys               # mostra a ajuda na tela
cam tp hotkeys off        # desliga os atalhos globais
cam tp hide | show
cam tp stop
cam tp h                  # ajuda no terminal
```

### Atalhos globais

Funcionam **com qualquer app em foco** — que é o ponto, já que durante a gravação você
está no navegador, não no teleprompter. Usam `RegisterEventHotKey` (Carbon), que não
exige permissão de Acessibilidade.

Todos em **`⌃⌥⌘`** (control+option+command), de propósito: um atalho registrado pelo
Carbon tem precedência sobre o do sistema, então usar `⌥⌘` sequestraria globalmente coisas
como "Mover item aqui" (`⌥⌘V` no Finder) e a busca do Finder (`⌥⌘Space`). `⌃⌥⌘` é a
combinação que o macOS praticamente não reivindica.

| | |
|---|---|
| `⌃⌥⌘Space` | play / pause |
| `⌃⌥⌘↑` `⌃⌥⌘↓` | mais rápido / mais lento |
| `⌃⌥⌘R` | volta ao início |
| `⌃⌥⌘V` | carrega o texto do clipboard |
| `⌃⌥⌘[` `⌃⌥⌘]` | menos / mais opaco |
| `⌃⌥⌘L` | cliques atravessam o painel |
| `⌃⌥⌘T` | esconde / mostra o painel |
| `⌃⌥⌘/` | abre e fecha a ajuda na tela |
| `⌃⌥⌘⇧` setas | move o painel pelo teclado |

Se algum atalho já estiver tomado por outro app, o rodapé do painel mostra
`⚠ em conflito` com a combinação — em vez de o atalho simplesmente não funcionar sem
explicação. Para desligar todos: `cam tp hotkeys off`.

Com o mouse ativo: arrastar move, `option`+arrastar redimensiona, scroll rola à mão,
espaço play/pause, `H` ajuda, `+`/`−` fonte, `[` `]` opacidade, setas ajustam velocidade
e posição, `M` espelha, `R` reinicia, `Q` sai.

### Cliques atravessando o painel

`⌃⌥⌘L` faz o painel ignorar o mouse por completo (`ignoresMouseEvents`), então você clica
em botões, diálogos e menus que estão **atrás** dele. A borda fica tracejada em azul para
você nunca ficar sem entender por que o painel parou de responder ao mouse.

O toggle é atalho global por necessidade: com os cliques atravessando, não haveria como
clicar no painel para desligar. `⌃⌥⌘⇧`+setas move o painel nesse modo, e `cam tp pass off`
é a saída pelo terminal.

### Onde o texto começa

O roteiro nasce **na linha de leitura**, não no topo do painel — então você já
começa olhando para o lugar certo, e o texto só sobe a partir dali.

Isso é feito com dois espaçadores de altura exata (uma quebra de linha com
`minimumLineHeight`/`maximumLineHeight` fixos): um antes do texto, do tamanho da
distância entre o topo e a linha, e outro depois, para a última frase conseguir subir
até a linha em vez de parar no meio do painel. Como as duas alturas dependem do tamanho
do painel, são recalculadas a cada redimensionamento e a cada mudança de fonte.

A posição da linha é uma constante só (`readingLineFromTop = 0.38`), usada tanto para
desenhá-la quanto para calcular o espaçador — não há como as duas saírem de sincronia.

### Modo tempo

`cam tp time 3:00` não é um cronômetro — ele mede a altura real do texto renderizado
(`NSLayoutManager.usedRect`) e resolve `velocidade = percurso ÷ tempo`. Mudar a fonte ou o
tamanho da janela recalcula sozinho. O rodapé do painel mostra tempo restante, total e
px/s. Mexer na velocidade à mão abandona o modo tempo.

### Como a invisibilidade funciona

```swift
window.sharingType = .none
```

Uma linha. O macOS exclui a janela de todas as APIs de captura — `Cmd+Shift+5`,
QuickTime, Zoom, Meet, OBS via ScreenCaptureKit. É o mesmo mecanismo que gerenciadores de
senha usam para não vazar em screenshot.

Verificado neste projeto com um teste controlado: com os dois apps abertos, o
`screencapture` registra o CamCircle e **não** registra o Teleprompter. O teste cobre o
caminho do CoreGraphics/ScreenCaptureKit, que é o mesmo usado por `Cmd+Shift+5` e pelos
apps de videochamada.

Óbvio, mas para não haver dúvida: isso esconde de captura *de software*. Uma câmera
filmando o monitor continua vendo o texto.

## Um app abre o outro

Cada app registra o atalho global que controla **o outro** — assim não há disputa pela
mesma combinação, e você nunca precisa voltar ao terminal:

| | |
|---|---|
| `⌃⌥⌘P` | abre / fecha o **teleprompter** (de qualquer app) |
| `⌃⌥⌘C` | abre / fecha o **círculo da câmera** (de qualquer app) |

No círculo, o clique direito também traz "Abrir teleprompter". Pelo terminal:

```bash
cam both          # abre os dois
cam tp camera     # do teleprompter, alterna o círculo
```

O `Companion.swift` é compilado nos dois binários. Ele procura o bundle irmão primeiro ao
lado do app que está rodando — o que cobre tanto os dois instalados em `~/Applications`
quanto os dois no diretório do fonte — e depois em `~/Applications` e `/Applications`.
Abre com `activates = false`, para não tirar o foco do app que você está usando.

## Captions — legendas ao vivo

Transcreve o que você fala em tempo real, **inteiramente on-device**, e mostra num painel
que **não aparece na gravação nem no compartilhamento de tela**. Você lê as legendas, quem
assiste não vê.

```bash
cam cc            # abre e começa a escutar
cam cc copy       # copia a transcrição
cam cc h          # todos os comandos
```

Nenhum áudio sai da máquina: `requiresOnDeviceRecognition = true`, sem exceção.

### Requisito

O Ditado precisa estar ativo em **Ajustes do Sistema › Teclado › Ditado**, no idioma
escolhido — é de lá que vem o modelo local. Sem isso o reconhecedor responde
`"Siri and Dictation are disabled"`. O Siri **não** precisa estar ligado; testei com ele
desativado e funciona.

### Atalhos globais

| | |
|---|---|
| `⌃⌥⌘J` | escutar / parar |
| `⌃⌥⌘K` | limpar o texto |
| `⌃⌥⌘Y` | copiar a transcrição |
| `⌃⌥⌘N` | cliques atravessam o painel |
| `⌃⌥⌘G` | esconde / mostra |
| `⌃⌥⌘-` `⌃⌥⌘=` | menos / mais opaco |

### O problema difícil: sessões longas

O `SFSpeechRecognizer` não sustenta uma sessão contínua. Medi: uma requisição com 100s de
áudio devolveu **89 palavras**, menos que as 118 que os primeiros 25s renderam, e de um
trecho diferente — ou seja, ela cobre só uma janela, não o todo.

A saída é rotacionar a requisição, e é aí que implementações ingênuas falham: encerrar a
antiga e abrir a nova em sequência perde o áudio do vão, e não tratar a emenda duplica
palavras na tela.

Aqui a virada usa **sobreposição**: a requisição nova começa a receber áudio 2 segundos
**antes** de a antiga ser encerrada, então nada cai no vão. O trecho que as duas ouviram é
removido por casamento de palavras, comparando sem caixa, sem acento e sem pontuação —
porque o reconhecedor varia justamente esses detalhes entre duas passadas pelo mesmo áudio.
O casamento maior tem preferência: repetir palavra na tela é pior que perder uma que já
havia sido entregue.

A função de costura tem teste próprio, cobrindo os casos que quebram a versão ingênua:
acento divergente, pontuação divergente, repetição legítima de palavra na fala
(`"ficou muito muito bom"`) e sobreposição total.

### Limites que você deve conhecer

- **A precisão é média.** Serve muito bem como legenda de apoio ao vivo. Não serve para
  transcrição publicável sem revisão.
- **Não sai pontuação.** Liguei `addsPunctuation = true` e a saída em pt-BR continuou sem
  pontuação alguma — a chave parece valer só para inglês ou só no modo servidor.
- **Silêncio não é erro.** O reconhecedor devolve `No speech detected` (código 1110) em
  qualquer pausa; o app trata isso como estado normal e sobe outra requisição, em vez de
  encher o rodapé de avisos.
- **Áudio do sistema ainda não.** Só microfone. A captura da saída do sistema é a próxima
  etapa, via Core Audio process tap — que traz permissão de Gravação de Tela junto, e por
  isso vive num app separado deste.

### Por que um app separado

O CamCircle pede câmera; o Teleprompter não pede nada. Juntar microfone e reconhecimento
de fala em qualquer um dos dois destruiria essa propriedade — o Teleprompter hoje pode ser
auditado em cinco minutos. As legendas moram no próprio bundle, com as próprias permissões.

## Segurança e privacidade

O app é assinado com **hardened runtime** (`--options runtime`) e entitlements mínimas —
só `device.camera` e `device.audio-input`:

```bash
codesign -dv ~/Applications/CamCircle.app   # flags=0x10002(adhoc,runtime)
```

Isso não é detalhe burocrático. Sem o hardened runtime, o `dyld` honra
`DYLD_INSERT_LIBRARIES`: qualquer processo rodando como o seu usuário poderia injetar uma
dylib no app e **herdar a permissão de câmera já concedida**, capturando vídeo sem disparar
nenhum novo pedido de autorização. Com o runtime ligado, o dyld ignora as variáveis `DYLD_*`
e a library validation bloqueia dylibs de outra origem.

Outras decisões:

- **Nenhuma rede.** Não há `URLSession`, socket ou telemetria no código.
- **Nada é gravado.** Não existe `AVAssetWriter` nem `AVCaptureMovieFileOutput` — o app só
  exibe o vídeo. Os frames vivem na camada de preview e morrem nela.
- **Microfone desligado por padrão.** O efeito de voz é opt-in (`cam all --voice` ou `V`).
  Quando ligado, só o nível RMS é calculado em memória; o áudio não é gravado nem enviado.
- **Sem `sudo`.** A instalação escreve apenas em `~/Applications` e `~/.local/bin`.
- O `.app` compilado não é distribuído neste repo — você compila do fonte.

## Estrutura

```
CamCircle.swift     o overlay de webcam
Teleprompter.swift  o teleprompter invisível na captura
build.sh            monta e assina os dois .app
install.sh          build + instala + cria o comando cam
cam                 CLI de controle (cam … e cam tp …)
```

O `Teleprompter.app` não pede nenhuma permissão: não acessa câmera, microfone, rede nem
disco protegido. É assinado com hardened runtime e sem entitlements.

## Licença

MIT
