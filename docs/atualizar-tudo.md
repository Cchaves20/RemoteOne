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
.\scripts\atualizar.ps1
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
.\scripts\atualizar.ps1 -Agente -Rodar    # só o agente, e o deixa rodando à vista
.\scripts\atualizar.ps1 -Vps              # só o servidor
.\scripts\atualizar.ps1 -App              # só o app
.\scripts\atualizar.ps1 -Ocultar          # atualiza tudo e instala o agente para subir no logon
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
