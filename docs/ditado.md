# Ditado: o que dá para fazer com o que já temos

Análise das capacidades do [Wispr Flow](https://wisprflow.ai/) mapeadas contra a base deste
projeto. Cada item traz o custo real: horas, permissão nova, ou download de toolchain.

O que o Wispr faz: você fala e o texto aparece no app em foco, já limpo de muletas, formatado
conforme o contexto, com dicionário pessoal e snippets. Cobra assinatura e **não declara onde
processa o áudio**.

## O que já está verificado nesta máquina

Testei antes de listar, não presumi:

| API | Estado |
|---|---|
| `SFCustomLanguageModelData` | **funciona no SDK 15.5** — montou modelo pt-BR sem erro |
| `SFSpeechAudioBufferRecognitionRequest.customizedLanguageModel` | propriedade existe |
| `NSWorkspace.frontmostApplication` | funciona **sem permissão nenhuma** |
| Reconhecimento on-device pt-BR | funciona, com as ressalvas em [armadilhas](armadilhas.md) |
| Atalho global sem Acessibilidade | funciona (`RegisterEventHotKey`, nos três apps) |
| Leitura do clipboard | funciona (`NSPasteboard`, já usado no Teleprompter) |

---

## Fácil hoje — horas, e nenhuma permissão nova

### Dicionário personalizado

**A de maior retorno.** O reconhecedor errou exatamente onde vocabulário resolve. Erros reais
medidos na transcrição de um vídeo interno:

| Saiu | Deveria ser |
|---|---|
| "Starts" | StartSe |
| "Frey Uki", "fêmur", "freme Work" | framework |
| "Roy" | ROI |
| "uso diário de ar" | uso diário de IA |
| "25 Players" | 25 players |

Cadastrando os termos da casa — StartSe, Journey, Concierge, LMS, roadmap, pilares, diagnóstico
— a transcrição para de errar o que mais importa numa comunicação interna. Equivale ao
*Personal Dictionary* do Wispr.

### Ditado para o clipboard

Você fala, o texto vai para o clipboard, você cola com `⌘V`. O `⌃⌥⌘Y` do Captions já copia a
transcrição. Não é injeção automática, mas cobre a maior parte do uso sem pedir permissão.

### Limpeza de muletas por regra

Sem LLM: remover "né", "tá", "então" em início de frase, colapsar repetições, tirar hesitações.
A transcrição real tinha exatamente esses padrões, incluindo a repetição literal
*"A gente tá então um baita / A gente tá então um baita"*. É o *Auto Edits* numa versão 80/20.

### Snippets de voz

Substituição no texto reconhecido: falar "assinatura padrão" e sair o bloco inteiro. Trivial
sobre o que existe.

### Estilo por app em foco

Com `frontmostApplication` dá para formatar conforme o destino: Slack com `*negrito*` e emoji,
editor de código sem pontuação de prosa, e-mail em parágrafos. É o *Writing Detection*, e não
custa permissão.

### Push-to-talk

Segurar um atalho global para ditar. A infraestrutura Carbon já está pronta.

---

## Custa uma permissão nova: inserir texto no app em foco

O "dita em qualquer aplicativo" exige **Acessibilidade**, concedida uma vez em Ajustes do
Sistema. Sem ela não há como injetar texto nem simular `⌘V` — vale para todo app desta
categoria, o Wispr incluído.

Pesar o custo antes: hoje o Teleprompter não pede permissão alguma e o Captions pede microfone e
reconhecimento de fala. Acessibilidade é um salto de perfil — dá ao app o direito de controlar
outros apps. Se for feito, que seja em **app separado e opcional**, como as legendas foram.

---

## Precisa do Command Line Tools for Xcode 26 (~1 GB)

- **Limpeza com LLM on-device** (`FoundationModels`) — o *Auto Edits* de verdade: reescrever
  divagação em texto limpo, adaptar tom, resumir. A alternativa é mandar o áudio para uma API,
  o que quebra a propriedade que este projeto preserva.
- **Pontuação em pt-BR e sessão contínua** (`SpeechTranscriber`) — ver [pesquisa](pesquisa.md).

---

## O que temos e o Wispr não tem

Vale enxergar antes de correr atrás de paridade:

- **Áudio do sistema.** Transcrever a outra pessoa numa reunião. O Wispr transcreve só você.
- **Invisível na gravação de tela.** Nenhuma ferramenta de ditado faz isso.
- **On-device verificável.** `requiresOnDeviceRecognition = true` está no código e dá para
  auditar. O site do Wispr não declara onde processa, e "100+ idiomas com baixa latência"
  sugere nuvem.
- **Controlável por terminal.** O `cam` permite automação que app comercial não expõe.

---

## Ordem recomendada

1. **Dicionário personalizado** — maior ganho de qualidade por hora, e conserta erros já
   observados na prática.
2. **Limpeza por regra** e **ditado para clipboard** — juntos entregam a experiência central.
3. **Estilo por app** e **snippets** — refinamento barato.
4. **Acessibilidade** só depois que o básico estiver bom.
5. **LLM** só depois do CLT 26, porque a alternativa manda áudio para fora.

O prompt para começar pelo item 1 está em [prompt-dicionario.md](prompt-dicionario.md).
