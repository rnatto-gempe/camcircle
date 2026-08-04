# Arquitetura

Três apps `LSUIElement` independentes, um comando de terminal, zero dependências externas.
Tudo compilado com o `swiftc` do Command Line Tools.

```
CamCircle.app     câmera em círculo flutuante
Teleprompter.app  roteiro rolando, invisível na captura
Captions.app      legendas ao vivo de duas fontes, invisíveis na captura
cam               CLI que controla os três
```

## Por que três apps e não um

Os perfis de permissão são incompatíveis:

| App | Permissões |
|---|---|
| CamCircle | câmera, microfone (opcional, só para o anel reativo) |
| Teleprompter | **nenhuma** |
| Captions | microfone, reconhecimento de fala |

Juntar tudo destruiria a propriedade mais valiosa do Teleprompter: ele pode ser auditado em
cinco minutos porque não pede nada. E o Captions traria reconhecimento de fala para um app
de overlay de câmera sem necessidade.

## A técnica comum: janela flutuante

Os três usam a mesma base:

```swift
NSWindow(styleMask: [.borderless], ...)     // ou NSPanel + .nonactivatingPanel
window.isOpaque = false
window.backgroundColor = .clear
window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
```

- **`.borderless` + fundo transparente** — nada de moldura; o formato vem dos `CALayer`.
- **`.nonactivatingPanel`** (Teleprompter e Captions) — clicar no painel não tira o foco do
  app que você está usando.
- **`.overlayWindow`** — acima de janelas normais.
- **`canJoinAllSpaces` + `fullScreenAuxiliary`** — aparece em todos os Spaces e sobre apps em
  tela cheia.
- **`sharingType = .none`** (Teleprompter e Captions) — invisível para toda API de captura.

## CamCircle: árvore de camadas

```
container        sombra externa
├── clip         cornerRadius + masksToBounds → recorta o formato
│   ├── preview  AVCaptureVideoPreviewLayer, maior que o clip (zoom e pan)
│   ├── vignette gradiente radial
│   └── crosshair alvo do modo de mira
├── glow         CAShapeLayer com sombra colorida
├── ringHolder   gradiente cônico girando, mascarado em anel
├── rim          aro de vidro interno
└── closeButton  disco com X, aparece no hover
```

A janela é **12% maior que o círculo** em cada lado. Sem esse respiro, a sombra e o glow
batem no limite da janela e viram um halo cinza quadrado.

O zoom e o pan funcionam dimensionando a `preview` pelo aspecto real da câmera e deslizando
dentro do `clip`. O deslocamento é limitado ao excedente de imagem, então nunca sobra borda
vazia.

## Captions: fontes de áudio e reconhecimento

```
MicrophoneSource ──┐                    ┌── Transcriber (streaming)
                   ├── AudioSource ─────┤
SystemAudioSource ─┘                    └── ChunkTranscriber (blocos)
```

`AudioSource` é o contrato comum: `onBuffer`, `start`, `stop`. O pipeline de reconhecimento
não sabe de onde o som veio, o que permite o mesmo código servir às duas entradas.

**`MicrophoneSource`** usa `AVAudioEngine` com tap no `inputNode`, e observa
`AVAudioEngineConfigurationChange` para religar quando o hardware muda.

**`SystemAudioSource`** usa Core Audio process tap (macOS 14.2+):

```
CATapDescription(stereoGlobalTapButExcludeProcesses: [])
  → AudioHardwareCreateProcessTap
  → aggregate device privado (tap + dispositivo de clock)
  → AudioDeviceCreateIOProcIDWithBlock
  → desentrelaça para mono → onBuffer
```

Sem driver virtual e sem silenciar a saída (`muteBehavior = .unmuted`).

### Dois modos de reconhecimento

**`Transcriber` (streaming)** — segmentos curtos sequenciais, um por frase. Baixa latência.
Cada requisição encerra no silêncio; o parcial é confirmado em todas as quatro saídas do
segmento, e o áudio que cai entre segmentos é guardado e devolvido.

**`ChunkTranscriber` (blocos)** — acumula N segundos em WAV no disco e transcreve o arquivo
inteiro. Latência de um bloco em troca de qualidade: o reconhecedor é muito melhor com o
contexto completo de uma frase. Blocos vizinhos se sobrepõem 2s e a sobreposição é removida
por casamento de palavras.

Alterna com `cam cc mode chunk|live`. **O modo blocos está incompleto** — funciona no
microfone, e o caminho do sistema tem um bug de flush prematuro (ver
[pendências](pendencias.md)).

## A ponte entre os apps

`Companion.swift` é compilado nos três binários. Ele localiza o bundle irmão procurando
primeiro **ao lado do app em execução** — o que cobre tanto os três instalados em
`~/Applications` quanto os três no diretório do fonte — e depois nos caminhos padrão.

Abre com `activates = false`, para não tirar o foco do app em uso. E alterna: abre se estiver
fechado, encerra se estiver aberto.

Cada app registra o atalho global que controla **os outros**, nunca o próprio, então não há
disputa pela mesma combinação.

## O CLI e o arquivo de controle

`cam` conversa com os apps por **arquivo de controle**, um por app:

```
~/.teleprompter/control            (700, arquivo 600)
~/.teleprompter/captions-control
```

O app observa o `mtime` quatro vezes por segundo. O CLI escreve o comando na primeira linha e
um número aleatório na segunda, para o `mtime` mudar mesmo repetindo o mesmo comando.

O diretório é `700` e a escrita recusa symlink: sem isso, qualquer processo do usuário leria
os comandos, e um symlink plantado ali transformaria o envio de comando em escrita arbitrária.

## O build

`build.sh` monta os bundles na mão — sem projeto Xcode, sem `xcodebuild`:

1. Cria a estrutura `.app/Contents/{MacOS,Resources}`
2. Copia o `.icns` gerado por `MakeIcons.swift`
3. Escreve o `Info.plist` com `LSUIElement`, as usage descriptions e as chaves da loja
4. Compila com `swiftc -O`, incluindo `Companion.swift` nos três e os fontes de áudio só no
   Captions
5. Assina ad-hoc **com hardened runtime** e entitlements mínimas

O hardened runtime não é burocracia: sem ele o `dyld` honra `DYLD_INSERT_LIBRARIES`, e
qualquer processo do usuário poderia injetar código no app e herdar a permissão de câmera já
concedida. Verificado com uma dylib de teste — a assinatura só ad-hoc era injetável, a atual
não.

## Diagnóstico

Como os painéis do Teleprompter e do Captions são invisíveis à captura, não há como
inspecioná-los por screenshot. O comando `cam cc state [arquivo]` despeja o estado interno:

- permissões e disponibilidade do modelo on-device
- rastro de inicialização, com o motivo de cada parada
- por fonte: buffers recebidos, buffers no vão, pico de áudio, contagem de erros por código
- geometria real das views, para distinguir "não transcreveu" de "não tem onde desenhar"

Foi essa instrumentação, e não hipóteses, que resolveu cada defeito difícil deste projeto.
