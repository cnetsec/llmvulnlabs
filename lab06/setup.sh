#!/bin/bash
set -e

echo "[*] Atualizando pacotes..."
if command -v apt >/dev/null 2>&1; then
  sudo apt update -y
  sudo apt install -y python3 python3-venv python3-pip curl git jq
elif command -v dnf >/dev/null 2>&1; then
  sudo dnf install -y python3 python3-venv python3-pip curl git jq
elif command -v brew >/dev/null 2>&1; then
  brew update
  brew install python git jq
else
  echo ">> Instale manualmente: Python 3.10+, pip, git, jq e curl"; exit 1
fi

echo "[*] Instalando Ollama (se necessário)..."
if ! command -v ollama >/dev/null 2>&1; then
  curl -fsSL https://ollama.com/install.sh | sh
fi

echo "[*] Iniciando o servidor do Ollama (se não estiver ativo)..."
if ! pgrep -x "ollama" >/dev/null 2>&1; then
  nohup ollama serve >/dev/null 2>&1 &
  sleep 3
fi

echo "[*] Criando venv..."
python3 -m venv mcp-multiia-env
source mcp-multiia-env/bin/activate

echo "[*] Instalando dependências Python..."
pip install --upgrade pip
pip install streamlit requests

echo "[*] Baixando modelos leves no Ollama..."
# Você pode ajustar a lista conforme sua máquina
MODELS=("llama3" "phi3" "gemma:2b")
for M in "${MODELS[@]}"; do
  echo " - puxando $M ..."
  ollama pull "$M" || true
done

echo "[*] Criando app.py..."
cat > app.py << 'PY'
import os
import time
import requests
import concurrent.futures
import streamlit as st

# -----------------------------
# CONFIG
# -----------------------------
DEFAULT_OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://localhost:11434")
MODELS = [
    {"key": "llama3",   "label": "IA1 — Llama3 (Ollama)"},
    {"key": "phi3",     "label": "IA2 — Phi3 (Ollama)"},
    {"key": "gemma:2b", "label": "IA3 — Gemma 2B (Ollama)"},
]
TIMEOUT = 120  # seg

# -----------------------------
# FUNÇÕES DE BACKEND
# -----------------------------
def check_ollama(ollama_url: str) -> tuple[bool, str]:
    try:
        r = requests.get(f"{ollama_url}/api/tags", timeout=5)
        if r.ok:
            return True, "OK"
        return False, f"Status {r.status_code}"
    except Exception as e:
        return False, str(e)

def ensure_model_exists(ollama_url: str, model: str) -> bool:
    try:
        tags = requests.get(f"{ollama_url}/api/tags", timeout=10).json()
        names = {m.get("name") for m in tags.get("models", [])}
        return model in names
    except Exception:
        return False

def ask_ollama(ollama_url: str, model: str, prompt: str, temperature: float, num_predict: int) -> dict:
    payload = {
        "model": model,
        "prompt": prompt,
        "stream": False,
        "options": {
            "temperature": float(temperature),
            "num_predict": int(num_predict)
        }
    }
    try:
        r = requests.post(f"{ollama_url}/api/generate", json=payload, timeout=TIMEOUT)
        js = r.json()
        return {
            "model": model,
            "ok": r.ok,
            "status": r.status_code,
            "answer": (js.get("response") if r.ok else js),
        }
    except Exception as e:
        return {"model": model, "ok": False, "status": None, "answer": f"Erro: {e}"}

def batch_ask(ollama_url: str, models: list[str], prompt: str, temperature: float, num_predict: int) -> list[dict]:
    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=min(4, len(models))) as ex:
        futs = [ex.submit(ask_ollama, ollama_url, m, prompt, temperature, num_predict) for m in models]
        for f in concurrent.futures.as_completed(futs):
            results.append(f.result())
    # manter na ordem solicitada
    order = {m: i for i, m in enumerate(models)}
    results.sort(key=lambda x: order.get(x["model"], 999))
    return results

# -----------------------------
# UI (Streamlit)
# -----------------------------
st.set_page_config(page_title="MCP Multi-IA (Ollama)", page_icon="🤖", layout="wide")

st.markdown("""
<style>
.small { color:#6b7280; font-size:12px; }
.ok { color:#059669; font-weight:600; }
.warn { color:#b45309; font-weight:600; }
.err { color:#dc2626; font-weight:600; }
.card {
  border: 1px solid #e5e7eb;
  border-radius: 14px;
  padding: 16px;
  margin-bottom: 12px;
  background: #fff;
  box-shadow: 0 1px 2px rgba(0,0,0,.04);
}
.hl { background:#f9fafb; padding:10px 12px; border-radius:10px; }
</style>
""", unsafe_allow_html=True)

st.title("🤖 MCP Multi-IA • Playground (Ollama)")

with st.sidebar:
    st.subheader("Configuração")
    ollama_url = st.text_input("Ollama URL", value=DEFAULT_OLLAMA_URL, help="Ex.: http://localhost:11434")
    temperature = st.slider("Temperatura", 0.0, 1.5, 0.2, 0.1)
    num_predict = st.slider("Máx. tokens de saída (num_predict)", 32, 2048, 256, 32)
    st.markdown("<span class='small'>Dica: 0.2 é mais objetivo; >0.8 mais criativo.</span>", unsafe_allow_html=True)

    st.divider()
    st.subheader("Modelos")
    available = [m["label"] for m in MODELS]
    pick = st.multiselect("Escolha 1+ modelos", options=available, default=available[:2])
    picked_keys = [next(m["key"] for m in MODELS if m["label"] == p) for p in pick] if pick else []

ok, detail = check_ollama(ollama_url)
if not ok:
    st.error(f"Não consegui falar com o Ollama em **{ollama_url}**. Detalhe: `{detail}`")
    st.stop()
else:
    st.markdown(f"<div class='hl'>Conexão com Ollama: <span class='ok'>OK</span> — {ollama_url}</div>", unsafe_allow_html=True)

# Verificação de modelos
missing = [m for m in picked_keys if not ensure_model_exists(ollama_url, m)]
if missing:
    st.warning(f"Modelos ausentes no Ollama: {', '.join(missing)}. Rode `ollama pull <modelo>` ou clique em 'Verificar novamente' abaixo.")
    if st.button("Verificar novamente"):
        st.rerun()

st.markdown("### Faça sua pergunta")
prompt = st.text_area("Prompt", placeholder="Digite aqui sua pergunta para as IAs...")

col_a, col_b = st.columns([1,1])
with col_a:
    run_one = st.button("Perguntar (modelos selecionados)")
with col_b:
    run_all = st.button("Perguntar (todos os modelos da lista)")

models_to_use = picked_keys if run_one else ([m["key"] for m in MODELS] if run_all else [])

if (run_one or run_all):
    if not prompt.strip():
        st.error("Escreva uma pergunta no campo de prompt.")
        st.stop()
    if not models_to_use:
        st.error("Selecione pelo menos um modelo na barra lateral, ou clique em 'Perguntar (todos)'.")
        st.stop()

    with st.spinner("Consultando modelos..."):
        t0 = time.time()
        results = batch_ask(ollama_url, models_to_use, prompt, temperature, num_predict)
        dt = time.time() - t0

    st.markdown(f"#### Respostas ({len(results)} modelos) • {dt:.1f}s")
    cols = st.columns(len(results)) if len(results) in (2,3,4) else [st.container()]

    def render_card(container, item):
        ok = item["ok"]
        status = item["status"]
        model = item["model"]
        answer = item["answer"]
        container.markdown(f"**{model}**  \nStatus: {'✅' if ok else '❌'} {status}")
        container.markdown("<div class='card'>"+str(answer).replace("\n","<br>")+"</div>", unsafe_allow_html=True)

    if len(cols) == 1:
        for item in results:
            render_card(cols[0], item)
    else:
        for c, item in zip(cols, results):
            render_card(c, item)

st.markdown("---")
st.caption("MCP Multi-IA local usando Ollama • Sem mock • Compare modelos lado a lado • Ajuste temperatura e limite de saída")
PY

echo
echo "[✔] Instalação concluída!"
echo ">> Para iniciar a UI agora:"
echo "source mcp-multiia-env/bin/activate && streamlit run app.py"
echo
echo "Acesse: http://localhost:8501"
