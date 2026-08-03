# CamCircle

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
CamCircle.swift   o app inteiro
build.sh          monta e assina o .app
install.sh        build + instala + cria o comando cam
cam               CLI de controle
```

## Licença

MIT
