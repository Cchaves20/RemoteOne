# Estratégia de testes multiplataforma

Como testar todas as plataformas-alvo do RemoteOne com os aparelhos
disponíveis: **iPhone, iPad, Surface Book 3, Huawei MateBook Fold e
Dell G5 5590** — sem possuir dispositivo Android nem Mac.

## Matriz dispositivo → plataforma

| Dispositivo disponível | Plataforma do projeto que ele cobre |
|---|---|
| iPhone | Cliente iOS |
| iPad | Cliente iPadOS (orientações, tablet) |
| Surface Book 3 | Cliente Windows Tablet (touch) e agente Windows |
| MateBook Fold | Agente Windows em tela dobrável (DPI alto, resolução que muda ao abrir/fechar) |
| Dell G5 5590 | Agente Windows/Linux, backend (Docker), emulador Android e máquina controlada nos testes ponta a ponta |

## Lacunas e soluções

### Android (sem aparelho físico)

- **Android Emulator (AVD)** no Dell G5 com aceleração de hardware — cobre o
  desenvolvimento diário. A CI também gera um APK de debug a cada push
  ([`client.yml`](../.github/workflows/client.yml)).
- **Firebase Test Lab** (cota gratuita diária) roda o app em dispositivos
  Android físicos na nuvem — usar nos marcos de versão.
- Limitação: sensores, vibração e desempenho real de vídeo (espelhamento de
  tela, Etapa 7) devem ser validados no Test Lab, não no emulador.

### iOS/iPadOS (sem Mac para compilar)

- **Codemagic** ([`codemagic.yaml`](../codemagic.yaml)) compila em Macs na
  nuvem e, quando ativado, publica no **TestFlight** para instalar no
  iPhone/iPad. Plano gratuito: 500 min/mês de macOS.
- Pré-requisito inevitável: conta **Apple Developer (US$ 99/ano)**.
- No dia a dia, iterar rodando o app Flutter **como aplicativo Windows** no
  Dell/Surface (hot reload) e enviar ao TestFlight só nos marcos.

### Agente macOS (sem Mac)

- A matriz da CI ([`agent.yml`](../.github/workflows/agent.yml)) compila e
  testa o agente Rust em `macos-latest` a cada push — pega a maior parte dos
  problemas de portabilidade.
- Captura de tela, injeção de entrada e permissões (Acessibilidade/Gravação
  de Tela) exigem sessão gráfica real: alugar Mac na nuvem pontualmente
  (MacinCloud ~US$ 30/mês) ou adiar o agente macOS para a versão 4.0,
  como o próprio plano do projeto já sugere.

### Linux

- VM (VirtualBox/Hyper-V) com Ubuntu desktop completo, ou dual boot, no
  Dell G5. **Não** usar WSL2 para o agente: sem sessão gráfica real não há
  captura de tela nem injeção de entrada.
- Testar X11 **e** Wayland — o comportamento de captura de tela é
  completamente diferente entre os dois.

### ChromeOS (segunda fase)

O agente rodará via Crostini (container Linux), então o agente Linux adianta a
maior parte; validar com ChromeOS Flex em VM.

**HarmonyOS ficou fora do projeto.** O MateBook Fold é o único aparelho da
casa que o roda, e ele também roda Windows — que já é uma plataforma
suportada. Flutter não tem suporte oficial a HarmonyOS NEXT (só um port da
comunidade), então cada tela custaria uma cadeia de build própria para cobrir
um aparelho que já está coberto por outro caminho.

### Código só de Windows, escrito num Linux

O agente tem partes que só existem no Windows (injeção de entrada, captura de
tela, captura de som, janela em foco). Elas não compilam na máquina onde o
código é escrito, e o primeiro sinal de erro costuma vir do `cargo build` do
usuário - tarde demais.

O que fecha parte dessa lacuna: `cargo check --target x86_64-pc-windows-msvc`.
Ele **tipa** o código do Windows sem precisar de Windows. No agente inteiro ele
não passa (o `openh264` compila C++ e precisa do `lib.exe`), mas passa num
projeto à parte com os módulos em questão e as dependências deles.

Duas regras, aprendidas errando:

1. **Copiar os arquivos de verdade**, não escrever substitutos. Uma vez montei
   o módulo `apps` à mão no projeto de teste, com os itens no lugar errado -
   a checagem passou enquanto o agente real não compilava, justamente por
   causa da estrutura que o substituto não tinha.
2. **Conferir a conferência.** Plantar um erro de propósito e ver se ele
   aparece. Uma checagem que não checa nada também termina em verde.

O que isso *não* cobre: comportamento. Se o loopback capta o som certo, se o
ícone extraído é o do programa certo - isso só a máquina do usuário responde.

Vale para tudo o que só existe no Windows — e foi por isso que a instalação em
segundo plano saiu de um `.ps1` e entrou no executável, em `setup.rs`. Um script
de PowerShell não é compilado, não é tipado e não é testado aqui; o mesmo código
em Rust tem as partes puras cobertas (o escape de aspas do launcher, os caminhos
de instalação, o texto do `status`) e o resto passa pela checagem cruzada.

E, mais escorregadio, **pré-condição não é tipo**. Os arquivos copiados voltavam
sempre vazios porque o código chamava `clipboard_win::get` em vez de
`get_clipboard`: a primeira exige que a área de transferência já esteja aberta,
a segunda abre. Mesma assinatura, mesmo tipo de retorno, verificação verde,
recurso morto. Contra esse tipo de erro só há um antídoto barato: **não engolir
o erro**. Um `Err(_) => return vazio` transforma uma falha em um resultado
plausível, e um resultado plausível não vira relato de bug - vira "não está
funcionando", semanas depois.

## Princípios de arquitetura que sustentam a estratégia

1. **Camada de abstração de plataforma no agente**
   ([`agent/src/platform/`](../agent/src/platform/)): a lógica portável
   (pareamento, protocolo, sessões) fica em código puro coberto por testes
   unitários em qualquer sistema; só a camada fina de SO precisa de teste
   manual por plataforma.
2. **CI como laboratório de plataformas desde o primeiro commit**: matriz
   Windows/Linux/macOS para o agente + Codemagic para iOS. Todo push valida
   as plataformas que não estão em mãos.

## Roteiro alinhado ao MVP

1. Backend + agente Windows + cliente Windows — tudo local no Dell/Surface.
2. iPhone/iPad controlando o Dell na mesma rede Wi-Fi (builds do TestFlight)
   — teste ponta a ponta real do produto.
3. Android via emulador no Dell + Firebase Test Lab nos marcos.
4. Linux via VM no Dell, controlado pelo iPhone.
5. macOS/ChromeOS: compilação contínua na CI; validação funcional
   nas versões 3.0/4.0.

Único custo inevitável: Apple Developer (US$ 99/ano). Todo o resto tem
camada gratuita suficiente para o desenvolvimento.
