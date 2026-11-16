# Revisão de código

Quase todo o código do Deskside é escrito pelo Claude e ia direto para a branch
de onde saem o servidor e os instaladores. Nenhuma outra pessoa o lia antes de
entrar em produção. Este documento é o processo que fecha isso.

## O que já existe

- **CI nesta branch.** Os workflows do servidor (`backend.yml`), do app
  (`client.yml`) e do agente no Windows (`agent.yml`) passaram a rodar em todo
  push, e não só na `main`. Eles rodam os testes, o lint e a auditoria das
  dependências (`pip-audit` e `cargo audit`). Linux e Mac do agente já rodavam
  (`agente-linux.yml`, `agente-mac.yml`).
- **Testes de segurança** que quebram o CI se uma proteção sumir: rotas de
  outra conta (`test_outra_conta.py`), limites de tentativa, segredo do agente,
  sessões, conformidade.
- **Dependabot** (`.github/dependabot.yml`), com um PR por semana para cada
  parte.

## O processo

1. **O trabalho vai num pull request para a `main`**, e não direto para
   produção. O PR descreve o que mudou e como foi testado.
2. **O CI precisa passar.** No GitHub: Settings → Branches → Add branch
   protection rule → `main` → "Require status checks to pass before merging",
   marcando os jobs dos workflows acima.
3. **Uma revisão automática no PR**: `/code-review` no Claude Code, com o
   número do PR. É um segundo olhar — não substitui o seu.
4. **A sua revisão**, com foco em três perguntas, que não exigem ler cada
   linha:
   - O PR mexe em autenticação, permissões, pagamento, dados pessoais ou no
     que o agente aceita do servidor? Se sim, leia essa parte com calma.
   - Os testes novos testam o que o PR diz que faz?
   - Algo foi apagado ou desligado sem explicação?
5. **Só então o merge**, e o deploy sai da `main`.

## Antes de cobrar de estranhos

Uma revisão de segurança por uma pessoa de fora, que não escreveu o código. A
revisão de agosto de 2026 já recomendava isso (`docs/revisao-de-seguranca.md`),
e ela continua sendo o item que nenhum teste substitui.

## Pendência para pôr isto em prática

Hoje a `main` só tem o commit inicial, e o servidor é atualizado a partir desta
branch. Para o processo valer:

1. Abrir um PR desta branch para a `main` e fazer o merge (é o estado atual do
   projeto, já testado).
2. Ligar a proteção da `main` (passo 2 acima).
3. Mudar o servidor e os scripts (`atualizar.ps1`) para a `main`.
4. O Dependabot só lê a configuração da branch **padrão** do repositório: depois
   do merge, trocar `target-branch` em `.github/dependabot.yml` para `main`.
