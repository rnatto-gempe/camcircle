# Pendências

O que está incompleto, com o estado real da medição. Nada aqui é suposição: cada item diz o que
foi verificado e o que não foi.

---

## Modo blocos: caminho do áudio do sistema

**Estado:** funciona no microfone, quebrado no sistema.

`cam cc mode chunk` acumula N segundos em WAV e transcreve o arquivo inteiro, o que dá muito
mais qualidade que o streaming. No microfone rendeu texto coerente. No sistema, os blocos
fecham em **2,3s em vez de 20s**.

Medido:

```
blocos: 15 prontos · bytes do último bloco: 217088  (= 2,26s a 48kHz)
falhas de escrita: 0
flush por duração: 0 · por formato: 0
```

As duas rotas de `flush` que eu instrumentei marcaram **zero**, e ainda assim 15 blocos
fecharam. Então a chamada vem de um caminho não mapeado.

**Suspeita concreta:** `openChunk` é invocado em duplicata. Tanto `flush()` (via
`openChunkFromTail`) quanto `feed()` (quando `file == nil`) o chamam, e o segundo sobrescreve
`file`/`fileURL`, órfão o primeiro. Vale instrumentar `openChunk` com um contador e comparar com
`chunkIndex`.

Enquanto não estiver resolvido, o padrão é `live`, que funciona nos dois lados.

---

## Diafonia em paralelo

**Estado:** não reproduzido, hipótese não testada.

Falando ao mesmo tempo que o áudio do sistema toca, a qualidade cai. Duas causas possíveis:

1. **Diafonia acústica** — em alto-falante, o microfone captura as duas vozes misturadas e o
   reconhecimento da fala do usuário degrada de verdade. Com fone não acontece.
2. **Contenção de recursos** — dois reconhecedores se degradando.

A causa 2 foi parcialmente descartada: com o microfone comprovadamente parado, o sistema
transcreve normalmente. Mas o inverso (medir a qualidade do sistema com o microfone ativo
ouvindo silêncio) não foi isolado.

**Próximo passo:** confirmar se o teste é feito com fone ou alto-falante. Se for alto-falante, a
causa é diafonia e a correção é *gating* — silenciar o transcritor do microfone quando o nível
do sistema está alto, aproveitando que temos os dois sinais.

Vale notar que em reunião real as pessoas se alternam, então o caso simultâneo pode não
importar na prática.

---

## Pontuação em português

**Estado:** causa identificada, correção depende do toolchain.

O modelo antigo (usado pelo `SFSpeechRecognizer`) não tem tokens de pontuação para português —
inglês sai pontuado, português não. O modelo novo tem. Migrar para `SpeechTranscriber` deve
resolver, mas **isso não foi verificado**: o caminho de teste disponível carrega o modelo
antigo. É a suposição de maior risco da [pesquisa](pesquisa.md).

---

## Fragmentação nas viradas de segmento

**Estado:** muito melhorado, teto atingido nesta API.

A espera adaptativa entre segmentos levou o áudio descartado de **48% para 0,7%**, e a
confirmação do parcial em todas as quatro saídas do segmento parou de perder frases. Ainda se
perdem palavras nas viradas.

Isso é limite do `SFSpeechRecognizer`, que obriga o ciclo de abrir e fechar. O
`SpeechTranscriber` sustenta sessão contínua e não tem esse ciclo.

---

## App Store

Ver [STORE.md](../STORE.md). Resumo: exige Developer Program pago e certificados que só o dono
da conta emite, e o sandbox obrigatório invalida a leitura de `~/Documents`, o arquivo de
controle, a CLI inteira e um app encerrando o outro.

A recomendação segue sendo **distribuição direta com notarização**, não a loja.

---

## Menor, mas anotado

- **`cam cc start` precisou virar reinício.** O start puro retornava sucesso com a fonte
  parada. Hoje ele para antes de subir, o que é idempotente — mas a causa original nunca foi
  encontrada.
- **Watchdog do microfone.** Um timer de 3s religa a fonte se ela cair sozinha e conta as
  recuperações. É rede de segurança, não conserto: se `revividas pelo watchdog` subir, há uma
  causa a investigar.
- **`Daylog Capture`.** O sistema tem um aggregate device criado por outro app, além de
  BlackHole, Loopback e Microsoft Teams Audio. Se algum capturar ao mesmo tempo, pode haver
  disputa pelo mesmo hardware independente do nosso código.
- **Ícones não foram revisados em tamanho pequeno.** Foram gerados e conferidos a 320px; a
  legibilidade a 16px e 32px não foi verificada.
