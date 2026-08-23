#!/usr/bin/env sh
# Confere as dependências do backend contra os avisos de vulnerabilidade
# publicados, e avisa se o arquivo travado saiu de sincronia com o pyproject.
#
# ## Por que um script, e não "rodar de vez em quando"
#
# "De vez em quando" não é uma frequência. Uma dependência com falha conhecida
# não avisa nada: o servidor sobe igual, os testes passam igual, e a diferença
# entre estar exposto e não estar é alguém ter lembrado de olhar. Um comando com
# nome é o que transforma isso em hábito — e é o que se põe numa CI no dia em
# que houver uma.
#
# ## Uso
#
#     cd backend && ./scripts/auditar.sh
#
# Sai com código diferente de zero quando acha algo, para poder entrar numa
# corrente de comandos.
set -e

cd "$(dirname "$0")/.."

if ! python -c "import pip_audit" 2>/dev/null; then
    echo "instalando as ferramentas de auditoria..."
    pip install -q -e ".[dev]"
fi

echo "--- 1. o arquivo travado ainda corresponde ao pyproject? ---"
# Regera num arquivo temporário e compara. Se alguém acrescentou uma
# dependência ao pyproject e esqueceu de regerar o lock, o Docker continuaria
# instalando o conjunto antigo - e o defeito apareceria como "o import falhou
# em produção e aqui não".
temporario=$(mktemp)
python -m piptools compile --quiet --strip-extras --generate-hashes \
    --output-file="$temporario" pyproject.toml

# Arquivos de verdade, e não `<(...)`: substituição de processo é do bash, e
# este script roda com `sh`. O cabeçalho gerado pelo pip-compile traz o comando
# que o produziu, então as duas primeiras linhas sempre diferem — daí o `grep`
# que tira os comentários antes de comparar.
atual=$(mktemp); novo=$(mktemp)
grep -v '^#' requirements.txt > "$atual"
grep -v '^#' "$temporario" > "$novo"
if ! diff -q "$atual" "$novo" >/dev/null; then
    echo "FALHOU: requirements.txt está fora de sincronia com pyproject.toml."
    echo "  Regere com:"
    echo "  python -m piptools compile --strip-extras --generate-hashes -o requirements.txt pyproject.toml"
    rm -f "$temporario" "$atual" "$novo"
    exit 1
fi
rm -f "$temporario" "$atual" "$novo"
echo "ok: o lock corresponde ao pyproject."

echo
echo "--- 2. alguma dependência tem falha conhecida? ---"
python -m pip_audit -r requirements.txt --disable-pip
