# Armadilhas

Cada item aqui custou horas e foi confirmado por medição, não por leitura de
documentação. O padrão comum é cruel: **quase tudo falha retornando sucesso.**

---

## Core Audio: process tap

### A referência de clock não pode dividir codec com o microfone

**Sintoma:** com as duas fontes ligadas, o áudio "dá split de canal" e o microfone perde
sinal.

O aggregate device do tap precisa de um dispositivo de saída real como referência de clock.
Usar a saída padrão parece óbvio — e é errado quando ela compartilha hardware com a
entrada. No conector de fone do Mac:

```
Microfone Externo         uid: BuiltInHeadphoneInputDevice   modelo: Codec Input
Fones de Ouvido Externos  uid: BuiltInHeadphoneOutputDevice  modelo: Codec Output
```

São o **mesmo codec**. Colocar essa saída no aggregate faz o Core Audio tomar conta do
hardware e derrubar o lado da entrada.

**Correção:** o tap é *global* — captura toda a saída do sistema independente de qual
dispositivo entra no aggregate. Então compare o `ModelUID` da saída com o da entrada e, se
forem o mesmo codec, escolha outra saída embutida como clock.

Medida que comprova: `religadas: 0`. Antes o `AVAudioEngine` era derrubado e religado; agora
não é nem perturbado.

### O aggregate precisa de um dispositivo real, não só o tap

Tap como main sub-device com lista de sub-devices vazia entrega **zero amostras em
silêncio**. A forma correta:

```swift
kAudioAggregateDeviceMainSubDeviceKey: outputUID
kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]]
kAudioAggregateDeviceTapListKey:       [[kAudioSubTapUIDKey: tapUID,
                                         kAudioSubTapDriftCompensationKey: true]]
kAudioAggregateDeviceTapAutoStartKey:  true
kAudioAggregateDeviceIsPrivateKey:     true
```

### Não toque em `isExclusive`

Depois de `init(stereoGlobalTapButExcludeProcesses:)`, o flag já está configurado. Ele é a
**direção**: mexer nele inverte "excluir estes PIDs" para "incluir só estes", produzindo
áudio silencioso com todos os status retornando sucesso.

### O `AVAudioEngine` para sozinho quando o hardware muda

Criar o aggregate device é uma mudança de configuração de áudio. O `AVAudioEngine` **para** e
não volta por conta própria. Sem observar `AVAudioEngineConfigurationChange` e religar
reinstalando o tap com o formato atual, ligar o áudio do sistema mata o microfone.

O `AVAudioEngine` também **não pode ser redirecionado** para um aggregate com tap: definir
`kAudioOutputUnitProperty_CurrentDevice` retorna `noErr` e o engine segue lendo a entrada
padrão. Leia o tap com `AudioDeviceCreateIOProcIDWithBlock` direto no aggregate.

---

## SFSpeechRecognizer

### Recusa estéreo entrelaçado dizendo que não há fala

O tap entrega **48kHz estéreo float32 entrelaçado**. Entregar isso ao reconhecedor devolve
`kAFAssistantErrorDomain:1110 No speech detected` — **18 de 18 vezes com sinal forte**
(pico 0,2356). Nenhum erro de formato, nenhum aviso.

**Correção:** mono não-entrelaçado, na mesma taxa. É o que o `AVAudioEngine` entrega para o
microfone e o que sempre funcionou. Não precisa reamostrar.

### Suprimir o erro 1110 esconde a única pista que existe

O 1110 aparece em qualquer pausa da fala, então é tentador classificá-lo como rotina e
ocultá-lo. Fazendo isso, o diagnóstico dizia `erro: nenhum` enquanto **18 de 18 callbacks
eram erro**. Contar e exibir os erros — inclusive os esperados — foi o que destravou o
problema de formato acima.

### Duas permissões distintas, e faltar a do microfone é silencioso

`SFSpeechRecognizer.requestAuthorization` cobre reconhecimento de fala.
`AVCaptureDevice.requestAccess(for: .audio)` cobre o microfone. Sem a segunda, o
`AVAudioEngine` entrega buffers vazios **sem erro nenhum**: o app se diz escutando e nunca
transcreve.

### Exige o Ditado ativo, mas não o Siri

Sem Ditado ligado em Ajustes do Sistema › Teclado, o reconhecedor responde
`"Siri and Dictation are disabled"` mesmo no modo on-device. Testado com Siri desligado
(`Assistant Enabled = 0`): **só o Ditado é necessário**.

### `addsPunctuation` é ignorado em pt-BR

Existem dois modelos no sistema: o antigo (`com.apple.siri.asr.hammer`, usado por este
reconhecedor) e o novo (`com.apple.speech.asr.transcription`, do `SpeechTranscriber`). O
vocabulário do modelo novo tem `.` `,` `?` `!` `:` `;` como tokens de saída; o antigo não
tem para português. Inglês sai pontuado, português não — é lacuna de cobertura do modelo,
não erro de configuração.

### Sessão longa devolve só uma janela do áudio

Uma requisição com 100s de áudio devolveu **89 palavras** — menos que as 118 dos primeiros
25s, e de outro trecho. Ela cobre uma janela, não o todo. É preciso segmentar.

### O TCC olha o processo responsável, não o seu bundle

Rodar o binário pelo shell atribui a responsabilidade ao terminal, cujo `Info.plist` não tem
`NSSpeechRecognitionUsageDescription` — e o processo é **abortado** (SIGABRT), não recebe um
erro tratável. Lance com `open` para o LaunchServices atribuir a responsabilidade ao app.

---

## Ciclo de segmentos

### Parcial exibido não é parcial guardado

Sintoma: a transcrição parecia boa ao vivo e sumia. Medido: **163 parciais, 5 caracteres
guardados**. O texto na tela vinha do parcial em curso e era descartado ao fim do segmento.

Um segmento tem **quatro** saídas: resultado final, erro, cancelamento na abertura do
próximo, e o timer de segurança. Confirmar o parcial só nas duas primeiras perde texto nas
outras duas. Use uma função única chamada em todas.

### Esperar para reabrir descarta metade do áudio

Espera fixa de 0,7s antes de reabrir: **48% dos buffers** chegavam sem requisição aberta.
Reabrir sempre na hora, por outro lado, vira laço no silêncio — 92 segmentos em 26s.

**Correção:** espera adaptativa. Se o segmento que morreu viu algum parcial, a frase está em
curso e reabre em 0,02s; se morreu sem nenhum parcial, é silêncio e recua para 0,5s. O que
ainda cai no vão é guardado e devolvido na abertura seguinte.

Resultado: de 48% para **0,7%** de áudio no vão, e frases longas em vez de fragmentos.

---

## AppKit

### `needsLayout` só agenda — e a coluna nasce sem tamanho

**Sintoma:** a transcrição do áudio do sistema só aparecia depois de esconder e mostrar a
janela.

A coluna nascia com frame `0x0` e só ganhava tamanho quando algo forçava um novo passe de
layout. Esconder e mostrar fazia exatamente isso. **O texto estava sendo transcrito o tempo
todo; não havia onde ele caber.**

Use `layoutSubtreeIfNeeded()` para forçar na hora, e tenha uma rede no caminho de desenho
que refaça o layout se a largura estiver zerada.

### `NSTextView()` sem frame não desenha nada

Criado sem frame, ele nasce com tamanho zero, o container de texto fica com largura zero e o
texto nunca é desenhado. Dê frame explícito, `autoresizingMask`, e
`textContainer?.widthTracksTextView = true`.

### Posição salva sobrevive ao monitor que não existe mais

**Sintoma:** o app abre, o processo roda, e não se vê nada na tela.

A posição da janela é persistida entre execuções. Gravada com um monitor externo conectado,
ela aponta para coordenadas que deixam de existir quando ele é desconectado:

```
originX = 2969        em uma tela de 1440 pontos de largura
```

**Correção:** validar a posição salva contra as telas atuais antes de usá-la
(`ScreenGuard.isReachable`, exigindo um terço da área dentro de alguma tela), e **regravar** a
posição corrigida — senão o valor inválido fica guardado e o descarte se repete a cada
abertura.

### A sombra é cortada pelo limite da janela

Uma janela do tamanho exato do conteúdo faz a sombra e o glow baterem na borda e virarem um
halo cinza quadrado nos cantos. A janela precisa ser **maior que o conteúdo** — no CamCircle
são 12% de respiro em cada lado.

### Atalho do Carbon rouba o atalho do sistema

`RegisterEventHotKey` tem precedência sobre o atalho do sistema. Usar `⌥⌘` sequestra
globalmente coisas como "Mover item aqui" (`⌥⌘V` no Finder) e a busca do Finder
(`⌥⌘Space`). Use **`⌃⌥⌘`**, que o macOS praticamente não reivindica, e registre a falha de
registro em vez de silenciá-la.

### `ignoresMouseEvents` precisa de saída por atalho global

Um painel que ignora o mouse não pode ser clicado para voltar ao normal. O toggle **tem** de
ser atalho global, e o modo precisa de sinal visual — aqui, borda tracejada — senão o painel
parece travado.

---

## Método

Três lições sobre como investigar, todas aprendidas do jeito difícil.

**Instrumente antes de teorizar.** Cada avanço real veio de um contador novo, não de uma
hipótese. `erro: nenhum` com 18 erros suprimidos, `transcrevendo: true` sem texto saindo,
`scroll 0x0` ignorado num relatório que eu mesmo criei — todos foram tempo perdido por
adivinhar em vez de medir.

**Um painel invisível na captura precisa de um jeito de ser inspecionado.** Como
`sharingType = .none` impede screenshot, `cam cc state` despeja o estado interno num arquivo.
Sem isso não há como saber nada de fora.

**Cuidado com o material de teste.** Boa parte de uma investigação sobre "fragmentação" foi
gasta com um arquivo acelerado em 2x, gerado para outra finalidade. Em velocidade normal a
qualidade era outra. E um teste acústico "microfone ouvindo o alto-falante" é inválido quando
a saída padrão é o fone.
