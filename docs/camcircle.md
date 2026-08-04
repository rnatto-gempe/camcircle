# CamCircle

Sua webcam num círculo flutuante, sempre por cima — o overlay de câmera do Loom ou do mmhmm,
nativo.

```bash
cam            # abre
cam all        # abre com todos os efeitos visuais
cam all --voice # idem, com o anel reagindo à voz (pede microfone)
cam clean      # versão discreta, sem anel
cam stop
```

## Atalhos

Funcionam com o círculo em foco — clique nele uma vez. Depois de clicar em outro app, use o
**clique direito**, que funciona sempre. `H` abre a lista na tela.

| Ação | Como |
|---|---|
| Fechar com o mouse | passe o mouse sobre o círculo → clique no **X** |
| Ver os atalhos | `H` |
| Mover | arrastar (encaixa no canto se soltar perto) |
| Redimensionar | scroll, pinça, `+` `-`, ou `1` `2` `3` |
| **Centralizar em um ponto** | `P` e clique no ponto, ou `⌥` + clique direto |
| Ajuste fino do enquadramento | setas |
| Zoom | `⌥` + scroll, ou `Z` para ciclar |
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
| Abrir/fechar o teleprompter | `⌃⌥⌘P`, de qualquer app |
| Menu completo | clique direito |
| Sair | `Q` ou `Esc` |

Tamanho, posição, formato, zoom, enquadramento, efeitos e câmera escolhida ficam salvos entre
execuções.

## Efeitos

| | |
|---|---|
| Anel gradiente animado | gradiente cônico girando, com glow na cor do tema |
| Temas de cor | Aurora, Ember, Mint, Studio |
| Profundidade | sombra suave e vinheta interna |
| Realce studio | ganho leve de contraste, saturação e vibrance |
| Borda esfumaçada | alternativa ao corte duro, sem anel |
| Anel reage à voz | o glow pulsa com o nível do microfone |
| Enquadramento automático | Center Stage, quando a câmera suporta |
| Zoom, pan e clique-para-centralizar | recorte manual, sem depender do Center Stage |
| Animações | entrada com spring, resize suave, encaixe magnético nos cantos |

## Enquadramento por clique

O Center Stage da Apple só existe em algumas câmeras — quando a sua não suporta, o item do
menu aparece desabilitado. O clique-para-centralizar resolve manualmente: `P`, clique no seu
rosto, e aquele ponto vira o centro.

A camada de vídeo é dimensionada pelo aspecto real da câmera e o deslocamento é limitado ao
que existe de imagem, então nunca sobra borda vazia.

## Desfoque de fundo

O macOS já faz nativo: com o CamCircle aberto, **Central de Controle › Efeitos de Vídeo ›
Retrato**. Funciona na câmera embutida e no iPhone via Continuity, sem código nosso.

## Gravando a tela

1. `cam all` e posicione o círculo.
2. Grave com `Cmd + Shift + 5` — o círculo aparece na gravação.

O fundo fora do círculo é realmente transparente, não fica retângulo preto. Para gravar sem o
círculo, grave só uma região da tela fora dele.

## Detalhe de implementação que custou um bug

A janela é **12% maior que o círculo** em cada lado. Sem esse respiro, a sombra e o glow batem
no limite da janela e viram um halo cinza quadrado nos cantos.
