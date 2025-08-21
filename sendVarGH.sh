#!/usr/bin/env bash
set -euo pipefail

# defaults
ENV_NAME="production"
ENV_FILE=".env"
DRY_RUN=0
SCOPE_ARGS=()        # ex: --org minha-org (opcional; por padrão usa o repo atual)

usage() {
  cat <<EOF
Uso: $0 [opções]
  -e, --env <nome>         Nome do Environment (default: production)
  -f, --file <caminho>     Arquivo .env para ler (default: .env)
  -n, --dry-run            Não envia nada; só mostra o que faria
  -o, --org <org>          Define variables no nível da organização (usa repo atual se omitido)
  -h, --help               Ajuda

Exemplos:
  $0 --env production --file .env
  $0 -e staging -f .env.local
  $0 --env prod --org minha-org
EOF
}

# parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    -e|--env) ENV_NAME="$2"; shift 2 ;;
    -f|--file) ENV_FILE="$2"; shift 2 ;;
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
echo "Scope extra: ${SCOPE_ARGS[*]:-<repo atual>}"
echo "Dry-run: $DRY_RUN"
echo "-----------------------------------------"

# Processa linha a linha
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

  # Verifica se a chave contém token, pass ou secret
  if [[ "$key" =~ [tT][oO][kK][eE][nN] ]] || [[ "$key" =~ [pP][aA][sS][sS] ]] || [[ "$key" =~ [sS][eE][cC][rR][eE][tT] ]]; then
    # Define como secret
    if [[ $DRY_RUN -eq 1 ]]; then
      if [[ ${#SCOPE_ARGS[@]:-0} -gt 0 ]]; then
          echo "[dry-run] gh secret set $key --env $ENV_NAME ${SCOPE_ARGS[*]} --body '***${#val} chars***'"
      else
          echo "Scope extra: <repo atual>"
      fi
    else
      gh secret set "$key" --env "$ENV_NAME" "${SCOPE_ARGS[@]}" --body "$val"
      echo "SECRET $key"
    fi
  else
    # Define como variável normal
    if [[ $DRY_RUN -eq 1 ]]; then
      if [[ ${#SCOPE_ARGS[@]:-0} -gt 0 ]]; then
          echo "[dry-run] gh variable set $key --env $ENV_NAME ${SCOPE_ARGS[*]} --body '***${#val} chars***'"
      else
          echo "Scope extra: <repo atual>"
      fi
    else
      gh variable set "$key" --env "$ENV_NAME" "${SCOPE_ARGS[@]}" --body "$val"
      echo "OK   $key"
    fi
  fi
done < "$ENV_FILE"

echo "-----------------------------------------"
echo "Concluído."
