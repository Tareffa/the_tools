#!/usr/bin/env bash
set -euo pipefail

# defaults
ENV_NAME="production"
ENV_FILE=".env"
INCLUDE_REGEX=".*"   # inclui tudo
EXCLUDE_REGEX="^$"   # exclui nada
DRY_RUN=0
SCOPE_ARGS=()        # ex: --org minha-org (opcional; por padrão usa o repo atual)

usage() {
  cat <<EOF
Uso: $0 [opções]
  -e, --env <nome>         Nome do Environment (default: production)
  -f, --file <caminho>     Arquivo .env para ler (default: .env)
  -i, --include <regex>    Regex de inclusão para NOME da variável (default: .*)
  -x, --exclude <regex>    Regex de exclusão para NOME da variável (default: ^$)
  -n, --dry-run            Não envia nada; só mostra o que faria
  -o, --org <org>          Define variables no nível da organização (usa repo atual se omitido)
  -h, --help               Ajuda

Exemplos:
  $0 --env production --file .env
  $0 -e staging -f .env.local -i '^(APP_|SPRING_)'
  $0 -e production -x '^(PASSWORD|SECRET|TOKEN)'
  $0 --env prod --org minha-org
EOF
}

# parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    -e|--env) ENV_NAME="$2"; shift 2 ;;
    -f|--file) ENV_FILE="$2"; shift 2 ;;
    -i|--include) INCLUDE_REGEX="$2"; shift 2 ;;
    -x|--exclude) EXCLUDE_REGEX="$2"; shift 2 ;;
    -n|--dry-run) DRY_RUN=1; shift ;;
    -o|--org) SCOPE_ARGS+=(--org "$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Opção desconhecida: $1"; usage; exit 1 ;;
  esac
done

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Erro: arquivo não encontrado: $ENV_FILE" >&2
  exit 1
fi

# Verificações básicas
if ! command -v gh >/dev/null 2>&1; then
  echo "Erro: 'gh' não encontrado no PATH. Instale o GitHub CLI." >&2
  exit 1
fi

# Garante que estamos autenticados
if ! gh auth status >/dev/null 2>&1; then
  echo "Erro: 'gh' não está autenticado. Rode: gh auth login" >&2
  exit 1
fi

echo "Environment: $ENV_NAME"
echo "Arquivo .env: $ENV_FILE"
echo "Include regex: $INCLUDE_REGEX"
echo "Exclude regex: $EXCLUDE_REGEX"
echo "Scope extra: ${SCOPE_ARGS[*]:-<repo atual>}"
echo "Dry-run: $DRY_RUN"
echo "-----------------------------------------"

# Processa linha a linha
# Regras:
# - remove espaços ao redor do '='
# - mantém tudo após o primeiro '=' como valor
# - remove prefixo 'export ' se existir
# - não expande variáveis, só texto literal
while IFS= read -r rawline || [[ -n "$rawline" ]]; do
  # remove BOM e CR (Windows)
  line="${rawline//$'\r'/}"
  line="${line/#$'\xEF\xBB\xBF'/}"

  # ignora vazio e comentário
  [[ -z "$line" ]] && continue
  [[ "$line" =~ ^[[:space:]]*# ]] && continue

  # remove "export " inicial
  line="${line#export }"
  line="${line#EXPORT }"

  # precisa ter '='
  if [[ "$line" != *"="* ]]; then
    echo "Aviso: ignorando linha sem '=': $line" >&2
    continue
  fi

  key="${line%%=*}"
  val="${line#*=}"

  # trim espaços ao redor da chave
  key="$(echo -n "$key" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"

  # trim espaço apenas à esquerda do valor (direita manter intacto)
  val="$(echo -n "$val" | sed -E 's/^[[:space:]]+//')"

  # remove aspas externas se valor estiver entre "..." ou '...'
  if [[ "$val" =~ ^\".*\"$ ]]; then
    val="${val:1:${#val}-2}"
  elif [[ "$val" =~ ^\'.*\'$ ]]; then
    val="${val:1:${#val}-2}"
  fi

  # filtra por include/exclude
  if ! [[ "$key" =~ $INCLUDE_REGEX ]]; then
    # echo "skip (não casa include): $key"
    continue
  fi
  if [[ "$key" =~ $EXCLUDE_REGEX ]]; then
    # echo "skip (casou exclude): $key"
    continue
  fi

  # Proteções básicas
  if [[ "$key" =~ [^A-Za-z0-9_]+ ]]; then
    echo "Aviso: nome inválido para variable (permitido A-Z a-z 0-9 _): $key — ignorando." >&2
    continue
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    if [[ ${#SCOPE_ARGS[@]:-0} -gt 0 ]]; then
        echo "[dry-run] gh variable set $key --env $ENV_NAME ${SCOPE_ARGS[*]} --body '***${#val} chars***'"
    else
        echo "Scope extra: <repo atual>"
    fi
  else
    # Define a variável; --body preserva conteúdo com espaços/=
    gh variable set "$key" --env "$ENV_NAME" "${SCOPE_ARGS[@]}" --body "$val"
    echo "OK   $key"
  fi
done < "$ENV_FILE"

echo "-----------------------------------------"
echo "Concluído."