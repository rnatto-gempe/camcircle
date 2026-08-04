# Captions

Legendas ao vivo em duas colunas — sua fala e a saída do sistema — transcritas
**inteiramente on-device** e **invisíveis na gravação**. Você lê as legendas, quem assiste não
vê.

```bash
cam cc              # abre e começa a escutar o microfone
cam cc system on    # liga também o áudio do sistema
cam cc copy         # copia a transcrição
cam cc h            # todos os comandos
```

Nenhum áudio sai da máquina: `requiresOnDeviceRecognition = true`, sem exceção.

## Requisito

O **Ditado** precisa estar ativo em Ajustes do Sistema › Teclado › Ditado, no idioma
escolhido — é de lá que vem o modelo local. Sem isso o reconhecedor responde
`"Siri and Dictation are disabled"`.

O **Siri não** precisa estar ligado. Testado com ele desativado.

## Comandos

```bash
cam cc                    # abre
cam cc start | stop | toggle      (microfone)
cam cc system on|off      # transcreve o áudio do sistema
cam cc clear
cam cc copy               # copia para o clipboard
cam cc save [arquivo]     # salva (padrão: ~/Desktop/transcricao.txt)
cam cc mode chunk|live    # blocos (qualidade) ou streaming (baixa latência)
cam cc chunk 20           # duração do bloco em segundos
cam cc locale en-US       # pt-BR, en-US, es-ES...
cam cc font 24
cam cc opacity 0.7
cam cc pass on|off        # cliques atravessam o painel
cam cc state [arquivo]    # despeja o estado interno, para diagnóstico
cam cc hide | show
cam cc quit
```

## Atalhos globais

| | |
|---|---|
| `⌃⌥⌘J` | escutar / parar o microfone |
| `⌃⌥⌘H` | liga / desliga o áudio do sistema |
| `⌃⌥⌘K` | limpa o texto |
| `⌃⌥⌘Y` | copia a transcrição |
| `⌃⌥⌘N` | cliques atravessam o painel |
| `⌃⌥⌘G` | esconde / mostra |
| `⌃⌥⌘-` `⌃⌥⌘=` | menos / mais opaco |

## Áudio do sistema

Capturado com **Core Audio process tap** (macOS 14.2+) — sem driver virtual, sem BlackHole ou
Loopback, e sem silenciar o que você ouve (`muteBehavior = .unmuted`).

Exemplo real capturado de um vídeo:

> *"...é um pedaço de silício que foi usado para fabricação de processadores... ele vem com um
> certificado dizendo olha, foi doação da Intel... um moleque que nasceu em Marechal Hermes um
> dia parar e se apaixonou por tecnologia, um dia parar no Vale do Silício e ver uma das
> maiores empresas do mundo"*

## Dois modos de reconhecimento

**`live` (padrão)** — segmentos curtos sequenciais. Baixa latência, texto aparecendo enquanto
a frase se forma.

**`chunk`** — acumula N segundos em disco e transcreve o arquivo inteiro. Latência de um bloco
em troca de qualidade, porque o reconhecedor é muito melhor com o contexto completo da frase.
**Incompleto** — ver [pendências](pendencias.md).

## Limites

**A precisão depende muito da qualidade do áudio.** Em velocidade normal, frases longas saem
quase literais. É legenda de apoio ao vivo, não transcrição fiel: palavras se perdem nas
viradas de segmento.

**Não sai pontuação em português.** A chave `addsPunctuation` é ignorada em pt-BR — é lacuna de
cobertura do modelo antigo, não erro de configuração. Ver [armadilhas](armadilhas.md).

**Em paralelo, cuidado com diafonia.** Se você ouvir em alto-falante, seu microfone captura as
duas vozes misturadas e o reconhecimento da sua fala degrada de verdade. Com fone não há esse
problema. Um modo de gating (silenciar o transcritor do microfone quando o sistema está falando
alto) está em [pendências](pendencias.md).

## Por que um app separado

O CamCircle pede câmera; o Teleprompter não pede nada. Juntar microfone e reconhecimento de
fala em qualquer um dos dois destruiria essa propriedade. As legendas moram no próprio bundle,
com as próprias permissões.

## Diagnóstico

Como o painel é invisível na captura, `cam cc state` é o único jeito de inspecioná-lo de fora.
Ele despeja permissões, disponibilidade do modelo, rastro de inicialização com o motivo de cada
parada, contadores por fonte (buffers, buffers no vão, pico de áudio, erros por código) e a
geometria real das views.

Essa última parte importa: ela distingue "não transcreveu" de "transcreveu e não tem onde
desenhar" — uma distinção que custou horas antes de existir.
