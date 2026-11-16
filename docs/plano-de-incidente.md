# Plano de incidente

O que fazer se houver invasão, vazamento ou suspeita de qualquer um dos dois.
Escrito para ser seguido sob pressão: comandos prontos, na ordem, e o porquê só
onde ele muda a decisão.

**Lembrete do que está em jogo.** O servidor do Deskside manda teclas e cliques
para todos os computadores pareados. Quem controla o servidor controla todos
eles. Na dúvida entre "parar tudo" e "esperar para ver", pare tudo.

Todos os comandos de VPS abaixo são **no VPS, na pasta `deploy` do clone**:

```bash
cd ~/Deskside/deploy 2>/dev/null || cd ~/RemoteOne/deploy
```

---

## Antes de precisar (fazer uma vez, agora)

- [ ] **MFA na conta da Oracle** (Perfil → Segurança → Autenticação de vários
      fatores). Quem toma a conta da Oracle toma o servidor.
- [ ] **`DESKSIDE_TOTP_KEY` e `DESKSIDE_BACKUP_KEY` no `deploy/.env`**, cada uma
      com `openssl rand -base64 48`, e **cópia das duas fora da VM**
      (gerenciador de senhas).
- [ ] **Cópia do `deploy/.env` inteiro fora da VM**, no mesmo gerenciador de
      senhas. Sem ele, um servidor restaurado não abre o 2FA de ninguém.
- [ ] **Monitor externo** em `https://deskside.com.br/health` (ver
      `deploy-vps-oracle.md`, "Monitoramento").
- [ ] Saber onde estão: este arquivo, o último backup
      (`.\scripts\atualizar.cmd -Backup`) e o formulário de comunicação de
      incidente da ANPD (gov.br/anpd).

---

## 1. Conter (primeira hora)

Do mais forte para o mais fraco. Escolha conforme o que se sabe.

**a) Parar todo controle remoto.** Nenhum computador recebe nada; o app mostra
"sem conexão". Use quando houver qualquer suspeita de que alguém controla o
servidor ou manda comandos indevidos.

```bash
sudo docker compose -f docker-compose.lite.yml stop api
```

**b) Derrubar todas as sessões.** Todo token emitido para de valer e cada pessoa
entra de novo com senha (e 2FA). Use quando tokens podem ter vazado.

```bash
sudo docker compose -f docker-compose.lite.yml exec -T api python -m app.incidente derrubar-sessoes
sudo docker compose -f docker-compose.lite.yml restart api
```

> **Não troque o `DESKSIDE_JWT_SECRET` para isso.** Os códigos de recuperação
> do 2FA são resumos feitos com ele, e, se `DESKSIDE_TOTP_KEY` não estiver
> definida, a própria chave do 2FA também sai dele. Trocá-lo tranca do lado de
> fora quem usa 2FA. Troque-o só se ele próprio vazou, e só depois de confirmar
> que `DESKSIDE_TOTP_KEY` existe.

**c) Exigir o segredo de todo agente.** Fecha a porta de quem conhece o
identificador de um computador mas não o segredo dele (agentes antigos param de
conectar até atualizar):

```bash
grep -q '^DESKSIDE_EXIGIR_SEGREDO_DO_AGENTE=' .env \
  && sed -i 's/^DESKSIDE_EXIGIR_SEGREDO_DO_AGENTE=.*/DESKSIDE_EXIGIR_SEGREDO_DO_AGENTE=true/' .env \
  || echo 'DESKSIDE_EXIGIR_SEGREDO_DO_AGENTE=true' >> .env
sudo docker compose -f docker-compose.lite.yml up -d api
```

**d) Trocar o que pode ter vazado**, conforme o caso:

| Vazou | O que fazer |
| --- | --- |
| `DESKSIDE_TURN_SECRET` | novo valor (`openssl rand -base64 48`) no `.env` e `sudo docker compose -f docker-compose.lite.yml up -d api coturn` |
| `DESKSIDE_JWT_SECRET` | ver o aviso acima; novo valor no `.env` e `up -d api` |
| Chave SSH do servidor | Oracle → instância → nova chave; tirar a antiga de `~/.ssh/authorized_keys` |
| Chave da App Store (`.p8`) | App Store Connect → Usuários e acesso → Integrações → revogar e criar outra |
| Conta de serviço do Google | Google Cloud → IAM → contas de serviço → excluir a chave e criar outra |
| Senha do provedor de e-mail | trocar no provedor e em `DESKSIDE_SMTP_PASSWORD` |
| Conta da Oracle | trocar a senha, conferir o MFA e os usuários com acesso |

---

## 2. Investigar (o que foi afetado)

**Registros de acesso** (IP, porta, hora e endereço pedido, guardados por 6
meses):

```bash
sudo docker compose -f docker-compose.lite.yml exec -T caddy sh -c 'ls -la /data/acessos/'
sudo docker compose -f docker-compose.lite.yml exec -T caddy sh -c 'cat /data/acessos/acesso.log' > ~/acessos-incidente.json
```

**Diário da API** (logins, agentes conectados, erros):

```bash
sudo docker compose -f docker-compose.lite.yml logs --since 72h api > ~/api-incidente.log
```

**Uma cópia do banco como estava**, antes de mexer em mais nada:

```bash
sudo docker compose -f docker-compose.lite.yml exec -T api python -m app.backup /backups
```

Anotar, com data e hora: quando começou, como foi descoberto, quais dados
(contas, e-mails, computadores), quantas pessoas, e o que já foi feito. É o que a
ANPD vai perguntar.

---

## 3. Restaurar

- Código: `git log` no VPS para conferir que o que está no ar é o do
  repositório; na dúvida, `git reset --hard origin/<branch>` e
  `sudo docker compose -f docker-compose.lite.yml up -d --build`.
- Banco: ver "Como restaurar" em `docs/deploy-vps-oracle.md`.
- Se a VM inteira estiver comprometida: VM nova pelo `docs/migrar-para-a1.md`,
  com o `.env` guardado fora e o último backup.

---

## 4. Comunicar (LGPD)

Se o incidente **pode causar risco ou dano relevante** às pessoas — dados
pessoais expostos, acesso indevido a contas ou a computadores —, a LGPD
(art. 48) e a Resolução CD/ANPD nº 15/2024 pedem:

1. **Comunicar a ANPD em até 3 dias úteis** a partir de quando se soube, pelo
   formulário de comunicação de incidente no site da ANPD. Informações
   pedidas: o que aconteceu, quais dados, quantas pessoas, as medidas tomadas e
   as que ainda serão, e o contato do responsável. Informação que ainda não se
   tem pode ser complementada depois.
2. **Avisar as pessoas afetadas no mesmo prazo**, por e-mail, em linguagem
   simples. Modelo:

   > **Assunto: Aviso de segurança sobre a sua conta Deskside**
   >
   > Olá, {nome}.
   >
   > No dia {data}, descobrimos {o que aconteceu, em uma frase}. Os dados
   > envolvidos foram: {lista}. {Não foram / Foram} afetados: senhas (que
   > guardamos só como hash), a imagem da sua tela e o que você digita.
   >
   > O que já fizemos: {encerramos todas as sessões / trocamos chaves / ...}.
   >
   > O que recomendamos: entre de novo no aplicativo, troque a senha e, se
   > ainda não usa, ligue a verificação em duas etapas. Se você usa a mesma
   > senha em outro lugar, troque lá também.
   >
   > Dúvidas: contato@deskside.com.br.

3. **Guardar o registro do incidente** — mesmo dos que não precisaram ser
   comunicados — com o que foi anotado no passo 2 e a decisão tomada. A
   resolução pede que esse registro fique guardado por pelo menos 5 anos.

Na dúvida sobre "pode causar risco relevante", comunique: o custo de comunicar
sem precisar é bem menor que o de não comunicar quando precisava. O advogado
que revisar os termos deve revisar este passo também.

---

## 5. Depois

Escrever, em `docs/`, o que aconteceu, por quê, e o que muda para não se
repetir. Sem culpados: o objetivo é o sistema, não a pessoa.
