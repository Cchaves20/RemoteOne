# Atualizar tudo de um terminal só

O RemoteOne tem três partes que precisam andar juntas: o **agente** no Windows,
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

1. `git pull` do branch de trabalho;
2. **agente** — para o processo que estiver rodando (é ele que segura o `.exe`
   e causa o `Acesso negado (os error 5)`) e recompila em release;
3. **app** — `flutter pub get` e `flutter analyze`;
4. **VPS** — por SSH: busca o branch, força o código e sobe o `docker compose`;
5. **conferência** — pergunta ao `/health` o que o servidor tem e compara com o
   que este código espera.

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
