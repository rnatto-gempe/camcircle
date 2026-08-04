# Pesquisa: o que existe de melhor para transcrição local

Duas frentes de pesquisa, ambas com **medição na máquina alvo** (MacBook Air M3, 8 GB, macOS
26.3.1) em vez de benchmark de terceiro. Agosto de 2026.

A conclusão curta: **tudo que nos travou é limitação do `SFSpeechRecognizer`, não do sistema.**

---

## Apple SpeechAnalyzer (macOS 26)

A API nova, apresentada na WWDC 2025. Substitui o `SFSpeechRecognizer` e resolve na raiz cada
problema que enfrentamos.

### Medido nesta máquina

| Questão | Resultado |
|---|---|
| Sessões simultâneas | **10 sessões concorrentes, zero erros** |
| Sessão longa | **4min49s com quatro silêncios de 60s — nenhum erro, nenhuma reciclagem** |
| Formato exigido | **16 kHz, mono, Int16** |
| Pontuação pt-BR | tokens `.` `,` `?` `!` `:` `;` presentes no vocabulário do modelo novo |

A concorrência é a diferença categórica: o `SFSpeechRecognizer` não sustenta tarefas
sobrepostas, e o `SpeechAnalyzer` sustenta dez. Um analisador para o microfone e outro para o
sistema é trivial.

E silêncio não é erro: o modelo tem **VAD interno** (`voice-activity-gating`), então não existe
equivalente ao `kAFAssistantErrorDomain 1110` e não é preciso reciclar segmento.

### Dois modelos no sistema

| Asset | Cobertura | Usado por |
|---|---|---|
| `com.apple.siri.asr.hammer` | 43 locales, incl. pt-BR | `SFSpeechRecognizer`, `DictationTranscriber` |
| `com.apple.speech.asr.transcription` | 10 idiomas, incl. `pt` | **`SpeechTranscriber`** |

Ambos já estão instalados. O modelo novo tem pontuação no vocabulário; o antigo, medido, sai
pontuado em inglês e **sem pontuação em português** — nosso sintoma exato.

Ressalva honesta: a verificação da pontuação em pt-BR no modelo *novo* não foi possível, porque
o caminho de teste disponível carrega o modelo antigo. É a suposição de maior risco e deve ser
o primeiro teste depois de atualizar o toolchain.

### Requisitos derrubados

- **Apple Intelligence: não é necessário.**
- **Ditado/Siri: não é necessário.** Citação da Apple na WWDC: *"você **não** precisará dizer
  aos usuários para ir aos Ajustes e ligar Siri ou ditado do teclado"*.
- **Xcode completo: não é necessário.** Basta o **Command Line Tools for Xcode 26** — cerca de
  1 GB, em developer.apple.com/download/all buscando "command line tools". Um projeto que usa
  `SpeechAnalyzer` (o `ohr`) documenta compilar com `swift build`, sem Xcode.

### O bloqueio atual

O CLT instalado traz o **SDK 15.5**, e o `SpeechAnalyzer` é um `actor` Swift com genéricos
`AsyncSequence` — depende do `.swiftinterface` do SDK 26. Verificado:

```
$ swiftc t.swift
error: cannot find 'SpeechTranscriber' in scope
```

Existe uma classe ObjC privada (`SFSpeechAnalyzer`) já declarada no `Speech.tbd` do SDK 15.5,
e ela funciona. **Não é o caminho:** é API privada, incompatível com distribuição na loja,
quebrável em qualquer atualização, e carrega o modelo antigo — justamente o que não tem
pontuação em português. O valor dela é provar que o sistema não é o bloqueio, só o toolchain.

---

## Alternativas locais

Medido no mesmo M3, clipe de 48s em pt-BR, Metal, 4 threads:

| Motor | Disco | Tempo | ×tempo real | WER |
|---|---|---|---|---|
| **Parakeet TDT v3 q8_0** | 638 MB | **0,92s** | **52×** | **3,4%** |
| Parakeet v3 f16 | 1198 MB | 1,69s | 28× | 3,4% |
| whisper tiny | 74 MB | 0,96s | 50× | 5,1% |
| whisper base | 141 MB | 1,52s | 32× | 11,0% |
| whisper small | 465 MB | 4,18s | 11,5× | 4,2% |

A quantização q8_0 custou **zero** precisão contra f16. E o Parakeet emite pontuação e
maiúsculas nativamente, o que o whisper com `-nt` não faz.

### Dois fluxos em paralelo

Medido com um harness em C contra `parakeet.h`:

- **Dois processos:** 1,43s → 3,23s concorrente, pesos duplicados na RAM.
- **Um `parakeet_context` + dois `parakeet_state`, duas threads:** 920ms para um → **1495ms
  para os dois**, pico de **757 MB total**.

**Compartilhe um modelo, dois estados.** O segundo fluxo é quase de graça. O `whisper.h` expõe
o mesmo padrão (`whisper_init_state` / `whisper_full_with_state`).

Detalhe para uso como biblioteca: é preciso chamar `ggml_backend_load_all_from_path()`, senão o
registro de backends reporta zero dispositivos e aborta. As ferramentas de linha de comando
fazem isso por você; um cliente linkado não.

### VAD é o ganho mais barato

Silero v6.2.0 vem embutido no whisper.cpp 1.9.1 (0,88 MB, CPU). Num arquivo com 29% de
silêncio:

- whisper small **sem** VAD: **12,7% WER** — degrada ao longo dos silêncios
- **com** VAD: **2,5% WER** — cinco vezes menos erro, por **+90ms**

O Parakeet não precisou de VAD para manter coerência no silêncio (5,9% no mesmo arquivo), porque
arquiteturas TDT/CTC não têm o laço de alucinação em silêncio do whisper.

### Rejeitados

sherpa-onnx (sem modelo de streaming em português), Moonshine (focado em inglês), Kyutai
(inglês e francês). Core ML é indisponível aqui — o `coremlc` vem só com o Xcode completo; use
Metal, que é o padrão.

---

## Ressalva sobre os números de precisão

Os WER acima vêm de **um clipe de 48 segundos de fala sintética, 118 palavras**. É benchmark de
velocidade com sanidade de precisão, não benchmark de precisão. O `base` pontuar pior que o
`tiny` é artefato de amostra pequena, não ordenação real.

Fala espontânea real em pt-BR é dramaticamente mais difícil: o
[ICAART 2026](https://www.scitepress.org/Papers/2026/146373/146373.pdf) mediu whisper-large em
**46% de WER médio no CORAA** (fala espontânea) contra 16% no Common Voice. Espere várias vezes
esses números em produção e valide nas suas próprias gravações antes de decidir.

---

## Recomendação, em ordem

**1. Instalar o Command Line Tools for Xcode 26 e migrar para `SpeechTranscriber`.**
Resolve fragmentação, paralelismo e pontuação de uma vez, sem modelo para distribuir. Custo:
1 GB de download, e o mínimo do sistema sobe de macOS 13 para 26. O tap, as colunas, os
atalhos e o CLI já estão prontos — só a camada de reconhecimento muda.

**2. Parakeet q8_0 + Silero VAD via `libparakeet`,** se quiser precisão acima do nativo. C
puro, linka com `swiftc`. Custo: 638 MB para distribuir, licença CC-BY (exige atribuição), e o
modelo foi treinado em português **europeu**.

**3. Híbrido** — Parakeet no microfone, `SpeechTranscriber` no sistema. Contorna qualquer limite
de concorrência. É o que o app open-source Scripta faz (whisper.cpp + `SFSpeechRecognizer`),
justamente para driblar esse tipo de erro.

**4. whisper small + VAD,** como alternativa se o português europeu do Parakeet atrapalhar.

---

## Fontes

**Apple** — [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer) ·
[SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber) ·
[AssetInventory](https://developer.apple.com/documentation/speech/assetinventory) ·
[WWDC25 sessão 277](https://developer.apple.com/videos/play/wwdc2025/277/) ·
Fóruns [790108](https://developer.apple.com/forums/thread/790108),
[818005](https://developer.apple.com/forums/thread/818005),
[819555](https://developer.apple.com/forums/thread/819555)

**Core Audio** —
[Capturing System Audio on macOS in 2026 (DGR Labs)](https://dgrlabs.co/blog/2026-04-25-capturing-system-audio-on-macos-in-2026.html) ·
[AudioCap](https://github.com/insidegui/AudioCap) ·
[CoreAudioTaps deep-dive (Recall.ai)](https://www.recall.ai/blog/core-audio-taps)

**Modelos** — [whisper.cpp](https://github.com/ggml-org/whisper.cpp) ·
[parakeet-GGUF](https://huggingface.co/ggml-org/parakeet-GGUF) ·
[parakeet-tdt-0.6b-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) ·
[FluidAudio](https://github.com/FluidInference/FluidAudio) ·
[ohr — SpeechAnalyzer sem Xcode](https://github.com/Arthur-Ficial/ohr)

**Comparações** — [Argmax vs Apple](https://www.argmaxinc.com/blog/apple-and-argmax) ·
[Apple vs Whisper WER](https://www.metatalks.ai/apples-new-on-device-speech-engine-tops-whisper-on-english-accuracy-benchmark-finds/) ·
[Scripta, arquitetura de dois motores](https://dev.to/thehwang/building-a-100-local-meeting-transcription-app-for-macos-with-whispercpp-and-screencapturekit-33m7)
