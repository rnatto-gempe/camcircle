# Prompt: dicionário personalizado no Captions

Copie o bloco abaixo inteiro para uma janela nova. Ele é autossuficiente.

---

Trabalhe em `/Users/startse/Documents/Projects/camcircle`. É um projeto de três apps nativos
macOS em Swift, compilados sem Xcode (só Command Line Tools, SDK 15.5). Um deles, o
`Captions.app`, transcreve microfone e áudio do sistema on-device e mostra em duas colunas num
painel invisível a gravação de tela.

**Antes de escrever código, leia `docs/armadilhas.md` inteiro.** Ele documenta os defeitos que
custaram horas neste projeto, e o padrão dominante é que quase tudo falha retornando sucesso.
Leia também `docs/arquitetura.md` para entender as peças. Não confie na sua memória sobre essas
APIs — o documento tem medições reais.

## A tarefa

Adicionar **dicionário personalizado** ao reconhecimento, usando
`SFCustomLanguageModelData` + `SFSpeechAudioBufferRecognitionRequest.customizedLanguageModel`.

Já verifiquei nesta máquina que a API existe e funciona no SDK 15.5: `SFCustomLanguageModelData`
monta um modelo pt-BR sem erro, e a propriedade `customizedLanguageModel` existe na request.
Não perca tempo checando disponibilidade.

## Por que, com dados reais

Transcrevi um vídeo interno de 4 minutos com o reconhecedor atual (810 palavras). A transcrição
está em `~/Desktop/transcricao-completa.txt` e o vídeo em
`~/Desktop/versao final completa.mov`. Os erros são sistematicamente de vocabulário próprio:

| Saiu | Deveria ser |
|---|---|
| "Starts" | StartSe |
| "Frey Uki", "fêmur", "freme Work" | framework |
| "Roy" | ROI |
| "uso diário de ar" | uso diário de IA |
| "sites" (no contexto de dados) | insights |
| "fontes taxas" | fontes citadas |

Termos que devem entrar no vocabulário: StartSe, Journey, Concierge, LMS, roadmap, diagnóstico,
pilares, framework, ROI, IA, insights, gap.

## Como validar, e isto é obrigatório

O ganho tem de ser **medido**, não afirmado. Use o mesmo vídeo como referência:

1. A transcrição atual já está salva em `~/Desktop/transcricao-completa.txt` — é a linha de base.
2. Depois de implementar, transcreva o mesmo vídeo de novo e compare.
3. Conte quantos dos erros da tabela acima desapareceram. Reporte o número.

Para transcrever um arquivo, o caminho que funciona é: extrair áudio com
`ffmpeg -i video.mov -ac 1 -ar 16000 -c:a pcm_s16le saida.wav`, fatiar em blocos de ~25s com 2s
de sobreposição, e rodar `SFSpeechURLRecognitionRequest` com `requiresOnDeviceRecognition = true`
em cada bloco, costurando as sobreposições por casamento de palavras. O `ChunkTranscriber.swift`
já tem a função de costura (`trimOverlap`) testada em 8 casos.

**Atenção com o TCC:** um binário rodado pelo shell é abortado com SIGABRT porque a
responsabilidade recai no terminal. Empacote num `.app` com
`NSSpeechRecognitionUsageDescription` no `Info.plist` e lance com `open`. Como o processo lançado
por `open` não devolve stdout, escreva o resultado num arquivo.

## Build e teste

```bash
./build.sh                  # compila e assina os três apps
cam build                   # instala em ~/Applications e atualiza o CLI
cam cc                      # abre as legendas
cam cc state /tmp/e.txt     # despeja o estado interno num arquivo
```

O painel do Captions é invisível à captura de tela, então **screenshot não serve para
inspecioná-lo**. O `cam cc state` é o único jeito de ver o que está acontecendo: permissões,
rastro de inicialização, contadores por fonte, e a geometria real das views.

Requisito de ambiente: o Ditado precisa estar ativo em Ajustes do Sistema › Teclado › Ditado, em
pt-BR. Já está nesta máquina.

## Convenções do projeto

- Comentários em português, e só onde explicam **por que** — nunca o que a linha faz. O código
  tem vários exemplos de comentários que registram a armadilha que motivou a linha.
- Mensagens de commit em português, explicando a causa e a medição que a comprovou. Ao usar
  heredoc no shell, **não use backticks na mensagem** — o shell os interpreta como substituição
  de comando e come o texto. Já aconteceu duas vezes aqui.
- Instrumente antes de teorizar. Todo avanço real neste projeto veio de um contador novo, não de
  uma hipótese. Se algo não funciona e não há erro, adicione a medição que distingue as causas.
- Não afirme que funciona sem medir. `transcrevendo: true` já significou "flag ligada e nenhum
  texto saindo".

## Depois

Se sobrar tempo, o próximo item da lista em `docs/ditado.md` é a limpeza de muletas por regra:
remover "né", "tá", "então" em início de frase e colapsar repetições. A transcrição de referência
tem exemplos reais, incluindo a repetição literal "A gente tá então um baita / A gente tá então
um baita".

Atualize `docs/ditado.md` marcando o que ficou pronto, e `docs/pendencias.md` se descobrir algo
novo que fique em aberto.
