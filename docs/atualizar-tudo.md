# Atualizar tudo de um terminal só

O Deskside tem três partes que precisam andar juntas: o **agente** no Windows,
o **app** no iPhone e o **backend** no VPS. Atualizar uma e esquecer as outras
foi a causa da maioria dos defeitos que investigamos — componente novo
conversando com componente velho, com sintoma que não parece ter nada a ver
(um botão que não responde, uma tela preta, uma sugestão que não troca a
palavra).

`scripts\atualizar.ps1` faz as três de uma vez.

## Uso

No PowerShell, na pasta do projeto:

```powershell
.\scripts\atualizar
```

Repare que é `atualizar`, sem o `.ps1`: quem responde é o `atualizar.cmd`, um
atalho de três linhas. Ele existe porque o Windows **bloqueia qualquer `.ps1`
por padrão** (a política de execução). O `.cmd` não passa por essa política e
chama o PowerShell já com a exceção — assim o comando funciona em qualquer
máquina sem afrouxar a política do sistema inteiro, que é a solução que se
costuma dar e que baixa a guarda para todo script, não só para este.

Chamar o `.ps1` direto funciona igual, desde que a política permita:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\atualizar.ps1
```

Isso faz, em ordem:

1. `git pull` do branch de trabalho. Se o pull trouxer uma versão nova **deste
   script**, ele avisa e recomeça em processo novo — o PowerShell lê o arquivo
   inteiro antes de executar a primeira linha, então a correção baixada só
   valeria na próxima vez;
2. **agente** — para o processo que estiver rodando (é ele que segura o `.exe`
   e causa o `Acesso negado (os error 5)`), recompila em release e, **se o
   agente estava instalado, reinstala com o binário novo** (ver abaixo);
3. **app** — `flutter pub get` e `flutter analyze --fatal-infos`;
4. **VPS** — por SSH: busca o branch, força o código e sobe o `docker compose`;
5. **conferência** — pergunta ao `/health` o que o servidor tem e compara com o
   que este código espera. Com paciência: o `docker compose up` volta quando o
   contêiner **inicia**, não quando a aplicação está pronta, então a checagem
   tenta algumas vezes antes de desistir.

## O agente instalado volta sozinho

Parar o agente para compilar é obrigatório: rodando, ele segura o próprio
`.exe`. Mas parar e não levantar deixava o computador **fora do ar até o
próximo login** — e ninguém associa "sumiu do app" a "rodei o atualizar".

Por isso, terminada a compilação, o script reinstala com o binário novo quando
detecta que já havia instalação (`%LOCALAPPDATA%\Programs\Deskside`). O
`install` vai sem URL de propósito: atualizar não é hora de reescrever
configuração, e o backend gravado continua valendo.

Se o agente **não** estava instalado, ele diz isso e não faz nada — quem roda
sem instalar costuma querer o agente à vista, com `-Rodar`.

`-Ocultar` e `-Rodar` desligam essa parte: nos dois casos você pediu outra
coisa, e subir um segundo agente oculto disputaria o mesmo `device_id` com o
primeiro.

## Variações

```powershell
.\scripts\atualizar -Agente -Rodar    # só o agente, e o deixa rodando à vista
.\scripts\atualizar -Vps              # só o servidor
.\scripts\atualizar -App              # só o app
.\scripts\atualizar -Ocultar          # atualiza tudo e instala o agente para subir no logon
```

Se a sua chave SSH não estiver em `Downloads` (o script pega o `.key` mais
recente de lá), passe o caminho:

```powershell
.\scripts\atualizar.ps1 -ChaveSsh C:\caminho\sua-chave.key
```

## Compilar o agente no Windows ARM64

Um Windows em ARM (Surface, Copilot+ PC, uma VM num MateBook Fold) precisa de
três coisas que o x86-64 não precisa. As três dão erros que não dizem que o
problema é a arquitetura — por isso ficam registradas aqui.

1. **O linker da Microsoft**, com o componente ARM64. Sem ele: `linker link.exe
   not found`.

   ```powershell
   $opcoes = '--quiet --wait --add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.VC.Tools.ARM64 --includeRecommended'
   winget install --id Microsoft.VisualStudio.2022.BuildTools -e --override $opcoes
   ```

   O instalador do Visual Studio **recusa `--quiet`/`--passive` sem elevação** e
   sai com código 5007 — precisa de um terminal já aberto como Administrador.
   Ele não pede UAC no meio do caminho.

2. **O clang.** O `ring` (criptografia, sob o TLS) tem trechos em assembly que
   neste alvo não compilam com o `cl.exe`. Sem ele: `failed to find tool
   "clang"`.

   ```powershell
   winget install --id LLVM.LLVM -e
   ```

   O instalador costuma não pôr o clang no PATH. O `atualizar.ps1` procura nos
   lugares conhecidos e aponta o compilador pela variável do alvo
   (`CC_aarch64_pc_windows_msvc`) só durante o build — ver
   `PrepararClangArm64`.

3. **Paciência.** São 434 dependências, e algumas são grandes (`webrtc`,
   `wgpu`, `rav1e`). A primeira compilação leva dezenas de minutos numa VM ARM.

Confira a arquitetura com `rustc -vV`, linha `host`. E lembre que **o binário
não atravessa arquiteturas**: o agente compilado no ARM64 não roda no Dell, e
vice-versa. Cada computador controlado compila o seu.

## A conferência do fim

Esta é a parte que economiza mais tempo. O script tem a lista do que este
código espera do servidor e a compara com o que o `/health` responde:

```
=== Conferência ===
  O servidor não tem: file-transfer
  (é ele que está velho, não o app nem o agente)
```

Quando um recurso novo entra no backend, o nome dele entra nessa lista — e o
script passa a acusar servidor desatualizado sozinho, em vez de a gente
descobrir depois de meia hora procurando defeito no lugar errado.

## Uma etapa que falha não derruba as outras

Se o `cargo build` quebrar, o app e o VPS ainda são atualizados, e o resumo do
fim diz o que ficou pendente:

```
=== Resumo ===
  Pendências: agente
```

É de propósito: quando algo dá errado, a informação mais útil é o quadro
inteiro, não o primeiro erro.
