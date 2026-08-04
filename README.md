# CamCircle

Três overlays nativos para gravar a tela no macOS, controlados por um comando de terminal.
Nada de terceiros instalado.

| | |
|---|---|
| **CamCircle** | sua webcam num círculo flutuante, sempre por cima |
| **Teleprompter** | roteiro rolando na tela, **invisível na gravação** |
| **Captions** | legendas ao vivo da sua fala e do áudio do sistema, on-device e também invisíveis |

Zero dependências: só AppKit, AVFoundation, Core Audio e Speech do próprio macOS, compilados
com o `swiftc` que já vem no **Command Line Tools**. Não precisa do Xcode.

## Requisitos

macOS 13 ou mais recente e o Command Line Tools da Apple:

```bash
xcode-select --install   # se ainda não tiver
swiftc --version         # deve responder
```

Para as legendas, o **Ditado** precisa estar ativo em Ajustes do Sistema › Teclado › Ditado, no
idioma que você for usar.

## Instalar

```bash
git clone https://github.com/rnatto-gempe/camcircle.git
cd camcircle
./install.sh
```

Compila os três apps, instala em `~/Applications` e coloca o comando `cam` em `~/.local/bin`.
Se esse diretório não estiver no seu PATH, adicione ao `~/.zshrc`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

## Uso rápido

```bash
cam                # círculo da câmera
cam tp             # teleprompter
cam cc             # legendas do microfone
cam cc system on   # legendas também do áudio do sistema
cam both           # câmera e teleprompter juntos
cam h              # ajuda completa
```

Um app abre o outro sem terminal: `⌃⌥⌘P` alterna o teleprompter, `⌃⌥⌘C` alterna a câmera,
`⌃⌥⌘H` liga o áudio do sistema nas legendas. Todos funcionam de qualquer app em foco.

## Documentação

| | |
|---|---|
| [CamCircle](docs/camcircle.md) | efeitos, enquadramento por clique, atalhos |
| [Teleprompter](docs/teleprompter.md) | modo tempo, cliques atravessando, como a invisibilidade funciona |
| [Captions](docs/captions.md) | duas colunas, áudio do sistema, modos de reconhecimento |
| [Arquitetura](docs/arquitetura.md) | como as peças se encaixam e por que são três apps |
| [Armadilhas](docs/armadilhas.md) | **o documento mais útil daqui** — cada defeito que custou horas, e a medição que o revelou |
| [Pesquisa](docs/pesquisa.md) | o que existe de melhor em transcrição local, medido nesta máquina |
| [Pendências](docs/pendencias.md) | o que está incompleto, com o estado real de cada medição |
| [App Store](STORE.md) | por que a loja não é o caminho, e o que seria preciso |

## Segurança e privacidade

Os três apps são assinados com **hardened runtime** e entitlements mínimas:

```bash
codesign -dv ~/Applications/CamCircle.app   # flags=0x10002(adhoc,runtime)
```

Isso não é burocracia. Sem o hardened runtime, o `dyld` honra `DYLD_INSERT_LIBRARIES`:
qualquer processo rodando como o seu usuário poderia injetar uma dylib no app e **herdar a
permissão de câmera já concedida**, capturando vídeo sem disparar nenhum novo pedido de
autorização. Verificado com uma dylib de teste — a assinatura só ad-hoc era injetável, a atual
não é.

Outras decisões:

- **Nenhuma rede.** Não há `URLSession`, socket ou telemetria no código.
- **Nada é gravado.** Sem `AVAssetWriter` ou `AVCaptureMovieFileOutput` — os apps só exibem.
- **Reconhecimento só local.** `requiresOnDeviceRecognition = true`, sem exceção. Nenhum áudio
  sai da máquina.
- **Permissões separadas por app.** O Teleprompter não pede nenhuma. O CamCircle pede câmera. As
  legendas pedem microfone e reconhecimento de fala. Ver
  [arquitetura](docs/arquitetura.md).
- **Microfone opt-in no CamCircle.** O anel reativo à voz só liga com `cam all --voice` ou `V`.
- **Sem `sudo`.** A instalação escreve apenas em `~/Applications` e `~/.local/bin`.
- **Arquivos de controle em `700`**, com escrita recusada em symlink.
- O `.app` compilado não é distribuído neste repositório — você compila do fonte.

## Estrutura

```
CamCircle.swift        overlay de webcam
Teleprompter.swift     teleprompter invisível na captura
Captions.swift         legendas ao vivo, duas colunas
AudioSources.swift     microfone (AVAudioEngine) e sistema (Core Audio tap)
ChunkTranscriber.swift transcrição por blocos gravados em disco
Companion.swift        ponte entre os apps, compilada nos três
MakeIcons.swift        gera os .icns
build.sh               monta e assina os três bundles
install.sh             build, instala e cria o comando cam
cam                    CLI de controle
```

## Licença

MIT
