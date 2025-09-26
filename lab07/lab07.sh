#!/usr/bin/env bash
#
# publish_explanation_on_solve.sh  —  CTFd automation (token-based)
#
# Monitora um challenge no CTFd e, quando detectar o primeiro solve,
# publica a explicação como HINT (ou faz upload de um arquivo .md como FILE).
#
# Uso (HINT padrão):
#   ./publish_explanation_on_solve.sh --url https://ctfd.example.com \
#     --token $CTFD_API_TOKEN --challenge 12 \
#     --explanation explanations/01_LLM01_Prompt_Injection.md
#
# Uso (FILE upload, em vez de hint):
#   ./publish_explanation_on_solve.sh --url https://ctfd.example.com \
#     --token $CTFD_API_TOKEN --challenge 12 \
#     --explanation explanations/01_LLM01_Prompt_Injection.md \
#     --mode file
#
# Parâmetros:
#   --url <CTFD_URL>            URL base do CTFd
#   --token <API_TOKEN>         API token com permissão
#   --challenge <ID>            ID numérico do challenge
#   --explanation <PATH>        Caminho do arquivo .md com explicação
#   --mode <hint|file>          Publicar como hint (padrão) ou file
#   --interval <segundos>       Intervalo de polling (padrão: 10)
#   --timeout <segundos>        Timeout total (padrão: 86400 = 24h)
#
# Dependências: curl, jq (opcional), python3
# Segurança: prefira passar o token via variável de ambiente (CTFD_API_TOKEN) ou secret manager.
#
set -euo pipefail

# Defaults
CTFD_URL=""
API_TOKEN="${CTFD_API_TOKEN:-}"
CHALLENGE_ID=""
EXPLANATION_FILE=""
MODE="hint"       # hint | file
POLL_INTERVAL=10
MAX_WAIT=86400

# --------- Parse args ---------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --url) CTFD_URL="$2"; shift 2;;
    --token) API_TOKEN="$2"; shift 2;;
    --challenge) CHALLENGE_ID="$2"; shift 2;;
    --explanation) EXPLANATION_FILE="$2"; shift 2;;
    --mode) MODE="$2"; shift 2;;
    --interval) POLL_INTERVAL="$2"; shift 2;;
    --timeout) MAX_WAIT="$2"; shift 2;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *)
      echo "Parâmetro desconhecido: $1" >&2; exit 1;;
  esac
done

# --------- Validations ---------
if [[ -z "$CTFD_URL" ]]; then
  echo "Erro: --url é obrigatório" >&2; exit 2
fi
if [[ -z "$API_TOKEN" ]]; then
  echo "Erro: --token é obrigatório (ou defina CTFD_API_TOKEN no ambiente)" >&2; exit 2
fi
if [[ -z "$CHALLENGE_ID" ]]; then
  echo "Erro: --challenge é obrigatório" >&2; exit 2
fi
if [[ -z "$EXPLANATION_FILE" ]] || [[ ! -f "$EXPLANATION_FILE" ]]; then
  echo "Erro: --explanation arquivo não encontrado: $EXPLANATION_FILE" >&2; exit 2
fi
if [[ "$MODE" != "hint" && "$MODE" != "file" ]]; then
  echo "Erro: --mode deve ser 'hint' ou 'file'" >&2; exit 2
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "Erro: 'curl' não encontrado" >&2; exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "Aviso: 'jq' não encontrado — tentarei um fallback simples" >&2
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "Erro: python3 é necessário para serializar a explicação em JSON" >&2; exit 2
fi

# Normaliza URL (remove trailing /)
CTFD_URL="${CTFD_URL%/}"

# --------- Helpers ---------
serialize_explanation_json() {
  python3 - <<PY
import json,sys
p=sys.argv[1]
print(json.dumps(open(p,'r',encoding='utf-8').read()))
PY
  "$EXPLANATION_FILE"
}

get_solves_count() {
  local resp
  resp=$(curl -s -H "Authorization: Token ${API_TOKEN}" \
               -H "Content-Type: application/json" \
               "${CTFD_URL}/api/v1/challenges/${CHALLENGE_ID}/solves")

  if command -v jq >/dev/null 2>&1; then
    echo "$resp" | jq 'if type=="array" then length elif (.data? and (.data|type=="array")) then .data|length else 0 end' 2>/dev/null || echo 0
  else
    # fallback bruto
    echo "$resp" | grep -c '"id"' || echo 0
  fi
}

publish_hint() {
  local content payload status
  content=$(serialize_explanation_json)
  payload=$(cat <<JSON
{
  "challenge_id": ${CHALLENGE_ID},
  "content": ${content},
  "type": "standard",
  "cost": 0
}
JSON
)
  echo "[INFO] Publicando HINT..."
  status=$(curl -s -o /tmp/ctfd_resp_hint -w "%{http_code}" \
    -X POST \
    -H "Authorization: Token ${API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data-binary "$payload" \
    "${CTFD_URL}/api/v1/hints")

  if [[ "$status" =~ ^2 ]]; then
    echo "[OK] Hint publicado."
  else
    echo "[ERRO] Falha ao publicar hint (HTTP $status). Resposta:" >&2
    cat /tmp/ctfd_resp_hint >&2
    return 1
  fi
}

upload_file() {
  echo "[INFO] Enviando FILE ao challenge..."
  local status
  status=$(curl -s -o /tmp/ctfd_resp_file -w "%{http_code}" \
    -X POST \
    -H "Authorization: Token ${API_TOKEN}" \
    -F "file=@${EXPLANATION_FILE};type=text/markdown" \
    "${CTFD_URL}/api/v1/challenges/${CHALLENGE_ID}/files")
  if [[ "$status" =~ ^2 ]]; then
    echo "[OK] Arquivo anexado ao challenge."
  else
    echo "[ERRO] Falha ao anexar arquivo (HTTP $status). Resposta:" >&2
    cat /tmp/ctfd_resp_file >&2
    return 1
  fi
}

# --------- Main loop ---------
echo "[INFO] Monitorando solves do challenge #${CHALLENGE_ID} em ${CTFD_URL}."
echo "[INFO] Modo de publicação: ${MODE} | Intervalo: ${POLL_INTERVAL}s | Timeout: ${MAX_WAIT}s"
end_time=$(( $(date +%s) + MAX_WAIT ))

while [[ $(date +%s) -lt $end_time ]]; do
  solves=$(get_solves_count || echo 0)
  solves=${solves:-0}
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] Solves: ${solves}"

  if [[ "$solves" -gt 0 ]]; then
    echo "[INFO] Detecção de solve. Publicando explicação..."
    if [[ "$MODE" == "hint" ]]; then
      publish_hint && exit 0 || echo "[WARN] Tentarei novamente em ${POLL_INTERVAL}s"
    else
      upload_file && exit 0 || echo "[WARN] Tentarei novamente em ${POLL_INTERVAL}s"
    fi
  fi

  sleep "$POLL_INTERVAL"
done

echo "[TIMEOUT] Nenhum solve detectado dentro do limite de ${MAX_WAIT}s."
exit 4

# ----------------------------
# OPCIONAL: UPLOAD DO ARQUIVO COMO 'file' (em vez de hint)
# ----------------------------
# Se preferir anexar o .md como arquivo ao challenge, você poderia descomentar e usar a seção abaixo.
# Note que alguns CTFd deployments expõem o endpoint:
#   POST /api/v1/challenges/<challenge_id>/files
# com multipart/form-data (field name 'file').
#
# Exemplo (usar manualmente ou adaptar no fluxo acima):
#
# curl -X POST -H "Authorization: Token ${API_TOKEN}" \
#   -F "file=@${EXPLANATION_FILE};type=text/markdown" \
#   "${CTFD_URL%/}/api/v1/challenges/${CHALLENGE_ID}/files"
#
# Se sua instância usar outro endpoint para upload de arquivos, ajuste esse comando.
#
# Você pode então manter a visibilidade do arquivo controlada com um plugin, ou
# deletar/reinserir o arquivo via API quando resolver.
