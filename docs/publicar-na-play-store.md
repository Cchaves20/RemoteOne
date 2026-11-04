# Publicar o app Android na Play Store

O workflow `android-play` do `codemagic.yaml` gera um **.aab assinado com a
chave de envio**, que é o formato que a Play aceita. O workflow `android`
continua gerando o APK de teste, para instalar à mão.

## O nome do pacote: `com.deskside.deskside_client`

É o mesmo do APK de hoje, e é **definitivo** depois do primeiro envio à Play.

Não foi trocado por um nome mais bonito por um motivo concreto: o widget da
tela inicial é achado como `<nome do pacote>.DesksideWidgetProvider`, e a
classe mora no pacote gerado pelo Flutter. Trocar só o nome quebraria o widget
sem erro nenhum no build.

O servidor precisa saber o nome para conferir as compras. No `deploy/.env` do
servidor:
```
DESKSIDE_GOOGLE_PACKAGE=com.deskside.deskside_client
```

## 1. Criar a chave de envio (uma vez, no Dell)

**Dell, PowerShell, pasta `C:\Users\caiof_lv78yyf\RemoteOne`.** Primeiro,
confira se o `keytool` existe. Ele vem com o Java:
```powershell
keytool -help 2>$null; if ($?) { "keytool ok" } else { "falta o Java" }
```
Se faltar, instale o Java 17 e **abra outro PowerShell**:
```powershell
winget install --id EclipseAdoptium.Temurin.17.JDK -e
```

Crie a chave. O comando pergunta uma senha (duas vezes) e alguns dados de
identificação, como nome e cidade; pode responder só o nome e deixar o resto
em branco. No fim, responda `sim` (ou `yes`):
```powershell
keytool -genkeypair -v -keystore "$env:USERPROFILE\deskside-envio.jks" -alias deskside -keyalg RSA -keysize 2048 -validity 10000
```

Guarde **o arquivo `deskside-envio.jks` e a senha** num lugar seguro e fora do
Dell (gerenciador de senhas, ou pendrive guardado). Não mande a chave por
chat, e-mail ou Git.

Perder esta chave **não** é o fim do app: com a assinatura da Play (passo 4),
quem assina o que chega aos celulares é o Google, e esta é só a chave de
**envio**. Se ela se perder, o suporte da Play troca por uma nova. Leva alguns
dias.

## 2. Cadastrar a chave no Codemagic (uma vez)

**Team settings → codemagic.yaml settings → Code signing identities → Android
keystores → Add keystore:**

- **Keystore file:** o `deskside-envio.jks`;
- **Keystore password:** a senha do passo 1;
- **Key alias:** `deskside`;
- **Key password:** a mesma senha (o `keytool` usa a mesma quando não se pede outra);
- **Reference name:** `deskside_envio`, exatamente assim. É o nome que o
  workflow procura.

## 3. Gerar o .aab

No Codemagic: **Start new build → workflow "Android (Play Store, .aab
assinado)"** → a branch do projeto → **Start**.

O build:
- falha logo no começo, com a explicação, se a chave do passo 2 não chegou;
- confere que o .aab saiu assinado com a chave de envio, e não com a de
  depuração;
- usa o contador do Codemagic como número da versão, que cresce a cada build.
  A Play recusa um número repetido.

O arquivo sai como `Deskside-<número>-<commit>.aab`, nos artefatos do build e
no e-mail.

## 4. Play Console

1. **Criar app:** nome `Deskside`, idioma padrão Português (Brasil), **App**,
   **Gratuito**. Gratuito com assinatura dentro do app é o caso normal; "Pago"
   é para app que se compra para baixar.
2. **Teste interno → Criar versão → Upload do .aab.** Na primeira vez, aceite a
   **assinatura de apps do Google Play** (o padrão).
3. **Monetizar → Assinaturas:** criar `com.deskside.pro.mensal`. O console só
   libera esta tela depois que um .aab com a permissão de compra foi enviado,
   e o do passo 3 já tem.
4. Preencher a página da loja, a **classificação de conteúdo**, o formulário de
   **segurança dos dados** e o link da política de privacidade
   (`https://deskside.com.br/privacidade`).

**Conta pessoal:** contas de desenvolvedor pessoais criadas desde 2023 precisam
de um **teste fechado com pelo menos 12 testadores por 14 dias seguidos** antes
de liberar a produção. Conta de organização (com CNPJ) não precisa.

## Quem tem o APK instalado à mão

O APK de teste é assinado com a chave de depuração, e o da Play com outra.
O Android não deixa um substituir o outro: quem tem o APK precisa
**desinstalá-lo** antes de instalar pela Play. A conta e os computadores
pareados ficam no servidor, então nada se perde.
