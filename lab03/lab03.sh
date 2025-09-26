#!/usr/bin/env bash
set -euo pipefail

OUT_TXT="GARAK_LLMVULNLABS.txt"
OUT_JSONL="GARAK_LLMVULNLABS.jsonl"
LOG_DIR="${HOME}/.local/share/garak"
GARAK_LOG="${LOG_DIR}/garak.log"
REST_YAML="$(pwd)/rest_ollama.yaml"
OLLAMA_URL="http://127.0.0.1:11434"
MODEL_NAME="llama3.2:1b"
PROBES="encoding,promptinject,dan.Dan_11_0,lmrc.Profanity,malwaregen.TopLevel,xss.MarkdownImageExfil,realtoxicityprompts.RTPInsult"

echo "=== GARAK + OLLAMA runner ==="
echo "Outputs: $(pwd)/${OUT_TXT}, $(pwd)/${OUT_JSONL}"
echo

# 0) ensure jq exists (for nicer summaries)
if ! command -v jq >/dev/null 2>&1; then
  echo "[!] jq not found. Please install (apt: sudo apt install -y jq) for JSON summary. Continuing without jq..."
fi

# 1) Ensure garak installed
if ! python3 -m pip show garak >/dev/null 2>&1; then
  echo "[*] Installing garak (pip)..."
  python3 -m pip install -U garak
else
  echo "[*] garak already installed."
fi

# 2) Wait for Ollama to respond
echo "[*] Checking Ollama at ${OLLAMA_URL} ..."
TRIES=0
until curl -sS "${OLLAMA_URL}/v1/models" >/dev/null 2>&1 || curl -sS "${OLLAMA_URL}/api/tags" >/dev/null 2>&1 || [ $TRIES -ge 10 ]; do
  echo "   ... aguardando Ollama (attempt=$((TRIES+1)))"
  sleep 2
  TRIES=$((TRIES+1))
done

if [ $TRIES -ge 10 ]; then
  echo "[!] Ollama não respondeu em ${OLLAMA_URL}. Continuarei mas pode falhar. Se estiver em container, expõe a porta."
fi

# 3) Create REST YAML fallback (always safe to have)
cat > "${REST_YAML}" <<'YAML'
generator:
  class: rest.RestGenerator
  config:
    method: POST
    url: http://127.0.0.1:11434/api/generate
    headers:
      Content-Type: application/json
    request_json:
      model: "llama3.2:1b"
      prompt: "{{PROMPT}}"
      stream: false
      options:
        temperature: 0.7
        num_predict: 768
    response_jsonpath: "$.response"
YAML
echo "[*] Created REST config at ${REST_YAML}"

# 4) Prepare outputs (clean previous)
rm -f "${OUT_TXT}" "${OUT_JSONL}"
mkdir -p "$(pwd)"
touch "${OUT_TXT}" "${OUT_JSONL}"

# 5) Try using the dedicated 'ollama' generator first (preferred)
echo
echo "======================"
echo "Attempt 1: using --model_type ollama"
echo "======================"
set +e
python3 -m garak \
  --model_type ollama \
  --model_name "${MODEL_NAME}" \
  --probes "${PROBES}" \
  --generations 2 \
  --skip_unknown --verbose \
  --report "./${OUT_JSONL}" \
  2>&1 | tee "./${OUT_TXT}"
RC=$?
set -e

if [ $RC -eq 0 ]; then
  echo "[*] garak finished (ollama generator)."
else
  echo "[!] garak failed with ollama generator (RC=${RC}). Will retry with REST generator."
  echo >> "${OUT_TXT}"
  echo "=== ollama-run-failed: fallback to REST generator ===" >> "${OUT_TXT}"

  # 6) Run via REST generator (fallback)
  python3 -m garak \
    --model_type rest \
    --model_name "${REST_YAML}" \
    --probes "${PROBES}" \
    --generations 2 \
    --skip_unknown --verbose \
    --report "./${OUT_JSONL}" \
    2>&1 | tee -a "./${OUT_TXT}"
fi

# 7) Post-process: create a concise PASS/FAIL summary in the TXT (append)
echo >> "${OUT_TXT}"
echo "===== SUMMARY (generated at $(date -u +'%Y-%m-%dT%H:%M:%SZ')) =====" >> "${OUT_TXT}"

# Try to extract PASS/FAIL lines from garak textual output (best-effort)
if grep -E "PASS|FAIL" "./${OUT_TXT}" >/dev/null 2>&1; then
  echo "[*] Extracting PASS/FAIL lines into the top of the report..."
  {
    echo "---- PASS/FAIL lines from run output ----"
    grep -En "PASS|FAIL" "./${OUT_TXT}" | sed -n '1,200p'
    echo
  } >> "${OUT_TXT}"
else
  echo "No PASS/FAIL strings found in textual run output." >> "${OUT_TXT}"
fi

# 8) If JSONL report exists, produce structured summary (requires jq)
if [ -s "./${OUT_JSONL}" ] && command -v jq >/dev/null 2>&1; then
  echo "[*] Generating structured summary from JSONL (jq)."
  {
    echo "---- Structured summary from ${OUT_JSONL} ----"
    echo "Total attempts: $(wc -l < "${OUT_JSONL}")"
    echo
    echo "Probe hit counts (probe_name / count):"
    jq -r '(.probe_name // .probe // "unknown")' "${OUT_JSONL}" | sort | uniq -c | sort -rn
    echo
    echo "Failing evaluations (first 20):"
    jq -c 'select((.evaluation.status // "") == "fail" or (.evaluation.result // "" | test("FAIL"; "i")) )' "${OUT_JSONL}" | sed -n '1,20p'
    echo
    echo "Top-level evaluation summary (status counts):"
    jq -r '.evaluation.status // "none"' "${OUT_JSONL}" | sort | uniq -c | sort -rn
  } >> "${OUT_TXT}"
else
  if [ -s "./${OUT_JSONL}" ]; then
    echo "[!] jq not available - JSONL is present but cannot create structured summary. Install jq to get it." >> "${OUT_TXT}"
  else
    echo "[!] No JSONL report was produced (check garak output and ${GARAK_LOG})." >> "${OUT_TXT}"
  fi
fi

# 9) Append tail of garak.log for diagnostics (if available)
if [ -f "${GARAK_LOG}" ]; then
  echo >> "${OUT_TXT}"
  echo "---- Last 100 lines of ${GARAK_LOG} ----" >> "${OUT_TXT}"
  tail -n 100 "${GARAK_LOG}" >> "${OUT_TXT}"
else
  echo "No garak.log found at ${GARAK_LOG}." >> "${OUT_TXT}"
fi

echo
echo "DONE. Results:"
echo " - Text report: $(pwd)/${OUT_TXT}"
echo " - JSONL report: $(pwd)/${OUT_JSONL} (may be empty if run failed)"
echo "Check ${GARAK_LOG} for internal logs."
