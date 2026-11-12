# Textos das lojas

O que vai na App Store Connect e no Play Console, pronto para colar. Os limites
de tamanho foram conferidos (`python3 scripts/conferir-textos-das-lojas.py`).
As imagens são geradas a partir de telas reais do app, com dados de exemplo
(Ana, PC-Escritório); ver "Imagens" no fim.

Tudo aqui tem de bater com o app e com `deploy/site/privacidade.html`. Se um
recurso mudar de plano, ou o preço mudar, muda aqui também.

---

## App Store (iPhone e iPad)

### Nome (até 30)
```
Deskside
```

### Subtítulo (até 30)
```
Seu computador no celular
```

### Texto promocional (até 170)
```
Veja a tela do computador ao vivo e use o celular como mouse e teclado. Desligue o PC que ficou ligado e deixe automações rodarem sozinhas na hora marcada.
```

### Palavras-chave (até 100, separadas por vírgula, sem espaço)
```
controle remoto,acesso remoto,pc,computador,mouse,teclado,windows,linux,desligar,automação,tela
```

### Descrição (até 4.000)
```
O Deskside transforma o celular no controle do seu computador. Veja a tela dele ao vivo, mexa no mouse, digite pelo teclado e rode automações, na mesma casa ou de longe, pela internet.

COMO FUNCIONA
Instale o Deskside no computador (Windows 10 ou 11, Mac ou Linux), pelo site deskside.com.br. Ele mostra um código de 9 caracteres. Digite o código no app, e o computador aparece na sua lista. Só controla um computador quem digitou o código que apareceu na tela dele.

O QUE DÁ PARA FAZER
• A tela do computador ao vivo, com lupa para ler o que está pequeno
• O celular como touchpad e teclado, com os atalhos do programa que está aberto
• Desligar, reiniciar ou suspender o computador
• Abrir e fechar programas e encaixar as janelas
• Automações: uma sequência de passos que um toque executa, como salvar tudo, fechar os programas, tirar o som e suspender
• Horário marcado: a automação roda sozinha, às 18h por exemplo, com o celular na gaveta. O computador avisa 5 minutos antes e deixa cancelar
• Arquivos nos dois sentidos, e copiar no celular para colar no computador
• Modo apresentação: a tela não apaga e as notificações não aparecem no meio da reunião
• O som do computador no celular, e vários monitores
• Widget na tela inicial e atalhos da Siri

SEGURANÇA
• Verificação em duas etapas e bloqueio do app com Face ID
• O que você digita e os seus arquivos não ficam guardados no servidor
• Baixe uma cópia dos seus dados ou exclua a conta pelo próprio app

PLANOS
O Deskside grátis não expira: 1 computador, com a tela ao vivo, mouse, teclado, programas, área de transferência e 1 automação. Toda conta começa com 30 dias do plano completo.

O Deskside completo libera computadores e automações ilimitados, horário marcado, arquivos, modo apresentação, som do computador, perfis de controle e vários monitores. É uma assinatura mensal com renovação automática.

O pagamento é cobrado na sua conta Apple ao confirmar a compra. A assinatura se renova automaticamente, a menos que seja cancelada pelo menos 24 horas antes do fim do período; a renovação é cobrada nas 24 horas anteriores. Gerencie ou cancele em Ajustes › seu nome › Assinaturas.

Termos de uso: https://deskside.com.br/termos
Privacidade: https://deskside.com.br/privacidade
```

### Novidades desta versão
```
Primeira versão na App Store.
```

### Endereços
- **Suporte:** `https://deskside.com.br` (o rodapé tem o e-mail de contato)
- **Marketing:** `https://deskside.com.br`
- **Política de privacidade:** `https://deskside.com.br/privacidade`
- **Termos (EULA):** em "Informações da licença", escolher o contrato padrão da
  Apple **ou** colar o link `https://deskside.com.br/termos`. A descrição já
  traz os dois links, que a Apple exige para app com assinatura.

### Categoria
- **Principal:** Produtividade
- **Secundária:** Utilitários

### Classificação etária
Responder "Nenhum" ou "Não" a tudo. O app não tem navegador próprio, chat entre
pessoas, compra de conteúdo para adultos nem conteúdo gerado por outros
usuários. Resultado esperado: **4+**.

### Assinatura (Monetização › Assinaturas)
- **Grupo:** `Deskside`
- **Nome de referência:** `Deskside completo mensal`
- **ID do produto:** `com.deskside.pro.mensal`, o mesmo da Play. Tem de ser
  **idêntico** ao que o app pede (`client/lib/services/compra.dart`)
- **Duração:** 1 mês
- **Preço:** R$ 30 (ver `docs/planos.md`)
- **Nome de exibição:** `Deskside completo`
- **Descrição (até 55):**
  ```
  Computadores ilimitados, horários, arquivos e mais
  ```

### Privacidade do app (as "etiquetas")
Nenhum dado é usado para rastrear a pessoa entre apps de terceiros, e não há
anúncios nem análise de uso. Os dados abaixo são **vinculados à pessoa** e
usados para **funcionalidade do app**:

| Categoria da Apple | O quê |
|---|---|
| Informações de contato › Nome | nome e sobrenome |
| Informações de contato › E-mail | e-mail da conta |
| Informações de contato › Telefone | só nas contas criadas por telefone |
| Identificadores › ID do usuário | o número da conta |
| Compras › Histórico de compras | a assinatura |
| Outros dados | dia e mês do aniversário (opcional), nomes dos computadores |

Não coletados: localização, contatos, fotos, áudio do microfone, histórico de
navegação, dados de saúde, diagnósticos, dados de uso.

### Notas para a revisão (em inglês: quem revisa lê inglês)
Antes de enviar, criar a **conta de demonstração** (ver abaixo) e deixar um
computador **ligado e online** com ela durante a revisão.
```
Deskside is a remote-control app for the user's OWN computers. It only controls a computer after the user types, in the app, a 9-character code shown on that computer's screen, so it cannot be used to access someone else's machine.

To review:
1. Sign in with the demo account below.
2. The account has a Windows computer named "PC-Revisao" paired to it, which we keep online during the review. Tap it, then "Continuar" (Continue), to see its screen live and control its mouse and keyboard.
3. Long-press the computer for power options, automations and files.

The full plan is already active on the demo account. The subscription is offered in Settings (gear icon) > plan card.

Pairing a new computer requires installing the desktop app from https://deskside.com.br on a Windows or Linux computer and typing the code it shows.

Demo account
Email: [preencher]
Password: [preencher]
```

---

## Google Play

### Nome do app (até 30)
```
Deskside: seu PC no celular
```

### Descrição curta (até 80)
```
Controle o computador pelo celular: tela ao vivo, mouse, teclado e automações.
```

### Descrição completa (até 4.000)
```
O Deskside transforma o celular no controle do seu computador. Veja a tela dele ao vivo, mexa no mouse, digite pelo teclado e rode automações, na mesma casa ou de longe, pela internet.

COMO FUNCIONA
Instale o Deskside no computador (Windows 10 ou 11, Mac ou Linux), pelo site deskside.com.br. Ele mostra um código de 9 caracteres. Digite o código no app, e o computador aparece na sua lista. Só controla um computador quem digitou o código que apareceu na tela dele.

O QUE DÁ PARA FAZER
• A tela do computador ao vivo, com lupa para ler o que está pequeno
• O celular como touchpad e teclado, com os atalhos do programa que está aberto
• Desligar, reiniciar ou suspender o computador
• Abrir e fechar programas e encaixar as janelas
• Automações: uma sequência de passos que um toque executa, como salvar tudo, fechar os programas, tirar o som e suspender
• Horário marcado: a automação roda sozinha, às 18h por exemplo, com o celular na gaveta. O computador avisa 5 minutos antes e deixa cancelar
• Arquivos nos dois sentidos, e copiar no celular para colar no computador
• Modo apresentação: a tela não apaga e as notificações não aparecem no meio da reunião
• O som do computador no celular, e vários monitores
• Widget na tela inicial, com três botões seus

SEGURANÇA
• Verificação em duas etapas e bloqueio do app com biometria
• O que você digita e os seus arquivos não ficam guardados no servidor
• Baixe uma cópia dos seus dados ou exclua a conta pelo próprio app

PLANOS
O Deskside grátis não expira: 1 computador, com a tela ao vivo, mouse, teclado, programas, área de transferência e 1 automação. Toda conta começa com 30 dias do plano completo.

O Deskside completo libera computadores e automações ilimitados, horário marcado, arquivos, modo apresentação, som do computador, perfis de controle e vários monitores. É uma assinatura mensal com renovação automática, que você gerencia ou cancela na Play Store, em Pagamentos e assinaturas.

Termos de uso: https://deskside.com.br/termos
Privacidade: https://deskside.com.br/privacidade
```

### Categoria e contato
- **Categoria:** Produtividade
- **E-mail:** `contato@deskside.com.br`
- **Site:** `https://deskside.com.br`
- **Política de privacidade:** `https://deskside.com.br/privacidade`

### Assinatura (Monetizar › Assinaturas)
- **ID do produto:** `com.deskside.pro.mensal` (ver `docs/publicar-na-play-store.md`)
- **Nome:** `Deskside completo`
- **Plano básico:** mensal, renovação automática, R$ 30
- **Benefícios** (até 4, 40 caracteres cada):
  ```
  Computadores ilimitados
  Automações no horário marcado
  Arquivos nos dois sentidos
  Modo apresentação e som do computador
  ```

### Segurança dos dados
- **Coleta ou compartilha dados?** Sim, coleta. **Não compartilha** com
  terceiros: o provedor de e-mail e a hospedagem processam dados em nosso nome,
  e a Play não conta isso como compartilhamento.
- **Criptografados em trânsito?** Sim.
- **A pessoa pode pedir a exclusão?** Sim, no app e em
  `https://deskside.com.br/excluir-conta`.

| Tipo de dado (Play) | Coletado | Obrigatório? | Para quê |
|---|---|---|---|
| Informações pessoais › Nome | sim | obrigatório | Funcionalidade do app, gerenciamento da conta |
| Informações pessoais › Endereço de e-mail | sim | obrigatório* | Gerenciamento da conta, comunicações |
| Informações pessoais › Número de telefone | sim | opcional* | Gerenciamento da conta |
| Informações pessoais › IDs de usuário | sim | obrigatório | Gerenciamento da conta |
| Informações pessoais › Outras informações (aniversário: dia e mês) | sim | opcional | Funcionalidade do app |
| Informações financeiras › Histórico de compras | sim | opcional | Funcionalidade do app (a assinatura) |

\* A conta é criada com e-mail; as contas antigas criadas com telefone guardam
o telefone.

Não coletados: localização, contatos, fotos e vídeos, áudio, arquivos (as
transferências vão direto entre celular e computador, sem ficar no servidor),
mensagens, histórico de navegação, atividade no app, diagnósticos.

### Classificação de conteúdo (questionário IARC)
Categoria **Utilitário, produtividade, comunicação ou outro**. Responder "Não" a
violência, sexo, linguagem, drogas, jogos de azar e conteúdo gerado por
usuários, e "Não" a compartilhar a localização. Resultado esperado: **Livre**.

### Público-alvo
**13 anos ou mais** (13 a 15, 16 a 17 e 18+). Não é um app para crianças: os
termos pedem pelo menos 13 anos.

### Anúncios
O app **não tem anúncios**.

### Acesso ao app
"Todas ou algumas funcionalidades são restritas": dar a mesma conta de
demonstração da Apple, com as instruções das notas da revisão.

---

## Conta de demonstração (as duas lojas pedem)

1. Criar uma conta nova no app, por exemplo com um apelido do Zoho
   (`revisao@deskside.com.br`).
2. Deixar o plano completo ativo nela.
3. Parear um computador Windows com o nome `PC-Revisao` e deixá-lo **ligado,
   online e sem dormir** durante a revisão (no app: segurar o computador ›
   Manter pronto).
4. Pôr o e-mail e a senha nas notas da revisão da Apple e no "Acesso ao app" da
   Play. Senha só para essa conta, sem reaproveitar nenhuma outra.

---

## Imagens

Geradas a partir de telas reais do app, capturadas pelo próprio Flutter com dados
de exemplo, e montadas com uma frase em cima:

| Loja | Tamanho | Quantidade |
|---|---|---|
| App Store, iPhone 6,9" | 1320 × 2868 | 5 |
| App Store, iPad 13" | 2752 × 2064 | 1 |
| Play, celular | 1080 × 1920 | 5 |
| Play, imagem de destaque | 1024 × 500 | 1 |
| Play, ícone | 512 × 512 | 1 |

A tela remota (a do computador ao vivo) **não** está entre elas: ela só existe
com um computador de verdade do outro lado. Tirar o print num iPhone com um
computador pareado, de preferência com o teclado aberto, e ela entra como a
segunda imagem.
