# Caminho para a Mac App Store — análise honesta

Estado atual: **os dois apps funcionam bem para distribuição direta, mas não estão
prontos para a Mac App Store**, e a maior parte do que falta não é código.

## O que já está feito

| | |
|---|---|
| Hardened runtime | `flags=0x10002(adhoc,runtime)`, verificado contra injeção de dylib |
| Entitlements mínimas | só `device.camera` e `device.audio-input`, no CamCircle |
| Teleprompter sem permissões | não acessa câmera, microfone, rede nem disco protegido |
| Ícones | `.icns` completo, 16px a 1024px, nos dois bundles |
| Chaves da loja | `CFBundleIconFile`, `LSApplicationCategoryType`, `ITSAppUsesNonExemptEncryption` |
| Item na barra de menus | nos dois — exigência prática da revisão para agentes `LSUIElement` |
| Sem rede, sem telemetria | nenhum `URLSession` no código |
| Nada é gravado | sem `AVAssetWriter`/`AVCaptureMovieFileOutput` |
| Diretório de controle | `700`, arquivo `600`, escrita recusada em symlink |
| Sem execução por env var | `cam build` usa caminho fixo |

## Bloqueadores que só você resolve

1. **Apple Developer Program** — US$ 99/ano. Sem isso não existe certificado de
   distribuição, nem App Store Connect, nem submissão.
2. **Certificados e provisioning profile** — `Apple Distribution` + `Mac Installer
   Distribution`, emitidos na sua conta. A assinatura ad-hoc atual (`codesign -s -`)
   serve para uso local e não é aceita pela loja.
3. **Registro do bundle ID** — `com.startse.camcircle` e `com.startse.teleprompter`
   precisam existir na sua conta de desenvolvedor.
4. **Ficha na loja** — screenshots, descrição, política de privacidade (obrigatória por
   causa do acesso à câmera), classificação.

## Bloqueadores técnicos: o sandbox quebra a arquitetura

A App Store **exige** `com.apple.security.app-sandbox`. Isso invalida quatro decisões
centrais do projeto:

| O que hoje funciona | Por que o sandbox impede |
|---|---|
| Ler `~/Documents/teleprompter.txt` | Sandbox só dá acesso a arquivos escolhidos pelo usuário. Exige `NSOpenPanel` + `com.apple.security.files.user-selected.read-only`, e um security-scoped bookmark para o hot reload sobreviver a reinícios |
| Comandos via `~/.teleprompter/control` | Caminhos são redirecionados para o container. A CLI fora do sandbox e o app dentro não se encontram |
| **A CLI `cam` inteira** | Um app da loja não pode instalar executáveis em `~/.local/bin`. Todo o controle por terminal deixa de existir |
| Um app abrir e encerrar o outro | `NSRunningApplication.terminate()` em outro processo e lançar app por caminho são bloqueados. Precisaria de dois targets num app só, ou de app groups |

Além disso:

- **`RegisterEventHotKey` (Carbon)** funciona sob sandbox, mas atalhos globais fixos e não
  configuráveis são atrito conhecido na revisão. Precisaria de uma tela de preferências
  para o usuário remapear.
- **`sharingType = .none`** é legítimo (gerenciadores de senha usam), mas a Apple tem
  olhado com atenção apps que se escondem de compartilhamento de tela. Vale descrever o
  caso de uso — teleprompter — de forma explícita na submissão.
- **Sem tela de preferências e sem onboarding.** Hoje a descoberta é `H`/`⌃⌥⌘/`. Para a
  loja, o esperado é uma janela de ajustes de verdade.

### Teste de sandbox: inconclusivo

Assinei uma cópia do Teleprompter com `app-sandbox` e rodei, mas minha instrumentação
estava errada — procurei mensagens no stdout, e o app escreve na janela. **Não há
evidência de que passe nem de que falhe.** O teste correto é rodar sandboxado e verificar
com `log stream --predicate 'subsystem == "com.apple.sandbox"'` se a leitura de
`~/Documents` é negada.

## Recomendação

**Distribuição direta é o caminho certo para este projeto.** O que falta para ficar
profissional fora da loja é pequeno:

1. **Notarização** (precisa do Developer Program, mas não da loja): `xcrun notarytool`
   + `stapler`. Elimina o aviso do Gatekeeper e permite distribuir o `.app` pronto, em
   vez de exigir que cada pessoa compile.
2. **Tela de preferências** — útil de qualquer forma, e pré-requisito se um dia for para
   a loja.
3. **Um único app com dois modos**, em vez de dois bundles se controlando. Simplifica
   sandbox, notarização e a experiência.

Se a loja for uma meta real, a ordem é: Developer Program → notarização e distribuição
direta → tela de preferências → migrar o controle da CLI para dentro da interface →
sandbox → submissão.
