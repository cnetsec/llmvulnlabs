#!/usr/bin/env bash
# lab_android_all.sh  —  v2
# Android (Termux) ou Linux rodando Streamlit que conecta num Ollama Server via API
# + Uploader/instalador de APK (Package Installer / pm em Android; instruções adb em Linux)

set -Eeuo pipefail
IFS=$'\n\t'

APP_FILE="lab_ollama_client.py"
VENV_DIR=".venv_lab03"
PORT="${PORT:-7860}"
ADDRESS="${ADDRESS:-0.0.0.0}"

log()  { printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
die()  { printf "\033[1;31m[ERROR]\033[0m %s\n" "$*"; exit 1; }

is_termux=false
is_codespaces=false
if command -v termux-info >/dev/null 2>&1 || [[ -d "/data/data/com.termux/files/usr" ]]; then
  is_termux=true
fi
if [[ -n "${CODESPACES:-}" || -n "${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-}" ]]; then
  is_codespaces=true
fi

# ---------- 1) Sistema ----------
if $is_termux; then
  log "Detectado Android/Termux."
  pkg update -y
  pkg install -y python python-cryptography libffi openssl git
  if ! command -v termux-open >/dev/null 2>&1; then
    warn "Instalando 'termux-api' (requer app Termux:API no Android para abrir instalador de APK)."
    pkg install -y termux-api || warn "Não foi possível instalar 'termux-api'."
  fi
else
  log "Ambiente Linux."
  if ! command -v python3 >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      sudo apt-get update -y
      sudo apt-get install -y python3 python3-venv python3-pip
    else
      die "python3 não encontrado. Instale python3/venv/pip."
    fi
  fi
fi

# ---------- 2) Python/venv ----------
if [ ! -d "$VENV_DIR" ]; then
  log "Criando venv: $VENV_DIR"
  python3 -m venv "$VENV_DIR"
fi
# shellcheck disable=SC1090
source "$VENV_DIR/bin/activate"

log "Atualizando pip e instalando libs (leves)…"
python -m pip install --upgrade pip >/dev/null
pip install --quiet "streamlit>=1.32" "requests>=2.31"

# ---------- 3) App Streamlit ----------
log "Gerando $APP_FILE"
cat > "$APP_FILE" << 'PYEOF'
import os, time, shlex, subprocess, shutil, json, socket, requests, streamlit as st

# ---------------- Config ----------------
TMP_DIR_TERMUX = "/data/data/com.termux/files/usr/tmp"
TMP_DIR = (TMP_DIR_TERMUX + "/lab03_apks") if os.path.isdir(TMP_DIR_TERMUX) else "/tmp/lab03_apks"
os.makedirs(TMP_DIR, exist_ok=True)

DEFAULT_URL     = os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434")
DEFAULT_MODEL   = os.environ.get("OLLAMA_MODEL", "llama3.2:1b")
DEFAULT_TEMP    = float(os.environ.get("OLLAMA_TEMP", "0.2"))
DEFAULT_MAXTOK  = int(os.environ.get("OLLAMA_MAXTOK", "180"))
DEFAULT_HEADERS = os.environ.get("OLLAMA_HEADERS", "")  # formato JSON opcional: {"Authorization":"Bearer ..."}
DEFAULT_MODE    = os.environ.get("OLLAMA_MODE", "generate")  # generate|chat

def is_termux() -> bool:
    return os.path.isdir("/data/data/com.termux/files/usr") or "ANDROID_ROOT" in os.environ

st.set_page_config(page_title="Hacktiba — Ollama Client", page_icon="🤖", layout="centered")
st.markdown("""<style>
.block-container {padding-top: 1rem; max-width: 720px;}
.user {background:#e8f0fe;border-radius:14px;padding:10px 12px;margin:6px 0;}
.assistant {background:#f1f3f4;border-radius:14px;padding:10px 12px;margin:6px 0;}
.small {font-size:12px;color:#6b7280;}
.header {display:flex;gap:8px;align-items:center;}
.header .title {font-weight:700;font-size:18px;}
.kv {font-family: ui-monospace, monospace;}
</style>""", unsafe_allow_html=True)

st.markdown('<div class="header">🤖 <div class="title">Hacktiba — Ollama Client</div></div>', unsafe_allow_html=True)
st.caption("Cliente para Ollama Server via API + upload/instalação de APK (Android/Termux).")

# ---------------- Sidebar ----------------
with st.sidebar:
    st.subheader("Ollama Server")
    if "cfg" not in st.session_state:
        st.session_state.cfg = {
            "url": DEFAULT_URL,
            "model": DEFAULT_MODEL,
            "temp": DEFAULT_TEMP,
            "max_tokens": DEFAULT_MAXTOK,
            "headers": DEFAULT_HEADERS,
            "mode": DEFAULT_MODE,   # generate | chat
        }

    st.session_state.cfg["url"]   = st.text_input("Ollama URL", st.session_state.cfg["url"], help="Ex.: http://127.0.0.1:11434")
    st.session_state.cfg["model"] = st.text_input("Modelo", st.session_state.cfg["model"], help="Ex.: llama3.2:1b")
    st.session_state.cfg["mode"]  = st.radio("Endpoint", ["generate","chat"], index=0 if st.session_state.cfg["mode"]=="generate" else 1,
                                             help="`generate` usa prompt único; `chat` mantém histórico.")
    st.session_state.cfg["temp"]  = st.slider("Temperatura", 0.0, 1.5, float(st.session_state.cfg["temp"]), 0.05)
    st.session_state.cfg["max_tokens"] = st.slider("Máx. tokens", 16, 4096, int(st.session_state.cfg["max_tokens"]), 16)

    st.markdown("Cabeçalhos HTTP (JSON opcional)")
    st.session_state.cfg["headers"] = st.text_area("Ex.: {\"Authorization\":\"Bearer ...\"}", st.session_state.cfg["headers"], height=60)

    # Status do Ollama
    st.markdown("---")
    st.subheader("Status")
    headers = {}
    try:
        if st.session_state.cfg["headers"].strip():
            headers = json.loads(st.session_state.cfg["headers"])
    except Exception as e:
        st.warning(f"Cabeçalhos inválidos (JSON): {e}")

    try:
        r = requests.get(st.session_state.cfg["url"].rstrip("/") + "/api/tags", timeout=3, headers=headers)
        if r.ok:
            models = ", ".join(m.get("name","?") for m in r.json().get("models", [])[:6]) or "—"
            st.success(f"Ollama OK • modelos: {models}")
        else:
            st.warning(f"Ollama HTTP {r.status_code}")
    except Exception as e:
        st.warning(f"Ollama indisponível: {e}")

    if st.button("Atualizar"):
        st.experimental_rerun()

# ---------------- Chat State ----------------
if "messages" not in st.session_state:
    st.session_state.messages = [
        {"role":"assistant","content":"Diga o que quer fazer no GitHub e eu recomendo a feature ideal (Issues, Discussions, Projects, Actions, Wiki, Security/Dependabot, Codespaces, Pages, Releases) com 3–5 passos práticos."}
    ]

for m in st.session_state.messages:
    cls = "assistant" if m["role"]=="assistant" else "user"
    st.markdown(f'<div class="{cls}">{m["content"]}</div>', unsafe_allow_html=True)

SYSTEM_PROMPT = ("Você é conciso. Dado o pedido do usuário, indique a MELHOR OPÇÃO NO GITHUB "
                 "(Issues, Discussions, Projects, Actions, Wiki, Security/Dependabot, Codespaces, Pages, Releases) "
                 "e forneça 3–5 passos práticos. Responda em português. Estruture em:\n"
                 "- Opção recomendada:\n- Por quê:\n- Passos:\n")

def call_ollama_generate(user_text: str, cfg: dict, headers: dict) -> str:
    body = {
        "model": cfg["model"],
        "prompt": SYSTEM_PROMPT + f"Pedido do usuário: {user_text}",
        "stream": False,
        "options": {"temperature": float(cfg["temp"]), "num_predict": int(cfg["max_tokens"])}
    }
    try:
        resp = requests.post(cfg["url"].rstrip("/") + "/api/generate", json=body, timeout=120, headers=headers)
        if not resp.ok:
            return f"[Ollama HTTP {resp.status_code}] {resp.text[:300]}"
        return (resp.json().get("response") or "").strip() or "Sem resposta do modelo."
    except Exception as e:
        return f"Erro (Ollama): {e}"

def call_ollama_chat(user_text: str, cfg: dict, headers: dict) -> str:
    if "chat_history" not in st.session_state:
        st.session_state.chat_history = [{"role":"system","content":SYSTEM_PROMPT}]
    st.session_state.chat_history.append({"role":"user","content":user_text})
    body = {
        "model": cfg["model"],
        "messages": st.session_state.chat_history,
        "stream": False,
        "options": {"temperature": float(cfg["temp"]), "num_predict": int(cfg["max_tokens"])}
    }
    try:
        resp = requests.post(cfg["url"].rstrip("/") + "/api/chat", json=body, timeout=120, headers=headers)
        if not resp.ok:
            return f"[Ollama HTTP {resp.status_code}] {resp.text[:300]}"
        txt = (resp.json().get("message", {}).get("content") or "").strip() or "Sem resposta do modelo."
        st.session_state.chat_history.append({"role":"assistant","content":txt})
        return txt
    except Exception as e:
        return f"Erro (Ollama/chat): {e}"

def ask_ollama(user_text: str) -> str:
    cfg = st.session_state.cfg
    headers = {}
    try:
        if cfg.get("headers","").strip():
            headers = json.loads(cfg["headers"])
    except Exception as e:
        return f"Erro (headers JSON inválido): {e}"
    if cfg.get("mode","generate") == "chat":
        return call_ollama_chat(user_text, cfg, headers)
    return call_ollama_generate(user_text, cfg, headers)

with st.form("chat", clear_on_submit=True):
    user_text = st.text_input("Digite aqui…", placeholder="Ex.: Quero reportar um bug no app móvel…")
    sent = st.form_submit_button("Enviar")
    if sent and user_text.strip():
        st.session_state.messages.append({"role":"user","content":user_text.strip()})
        reply = ask_ollama(user_text.strip())
        st.session_state.messages.append({"role":"assistant","content":reply})
        st.experimental_rerun()

st.markdown(
    f'<div class="small kv">URL: {st.session_state.cfg["url"]} • Modelo: {st.session_state.cfg["model"]} • '
    f'Modo: {st.session_state.cfg["mode"]} • Temp: {st.session_state.cfg["temp"]} • Máx. tokens: {st.session_state.cfg["max_tokens"]}</div>',
    unsafe_allow_html=True
)
st.markdown("---")

# ---------------- APK upload & instalação ----------------
st.header("Instalar APK neste dispositivo")

st.write("- **Android/Termux**: preferível usar o **Package Installer** via `termux-open` (sem root).")
st.write("- **pm install -r**: funciona em alguns ambientes (pode exigir permissões).")
st.write("- **Linux**: use `adb install -r <apk>` a partir do seu PC.")

uploaded = st.file_uploader("Selecione um .apk", type=["apk"])
if uploaded:
    ts = int(time.time())
    safe_name = f"{ts}_{uploaded.name.replace(' ', '_')}"
    dest_path = os.path.join(TMP_DIR, safe_name)
    with open(dest_path, "wb") as f:
        f.write(uploaded.getbuffer())
    st.success(f"APK salvo: {dest_path}")

    # Botão 1: Package Installer (termux-open)
    if is_termux() and shutil.which("termux-open"):
        if st.button("Instalar (Package Installer • termux-open)"):
            try:
                cmd = ["termux-open", "--content-type", "application/vnd.android.package-archive", dest_path]
                st.info("Executando: " + " ".join(shlex.quote(c) for c in cmd))
                subprocess.check_call(cmd)
                st.success("Solicitação enviada ao instalador do sistema.")
            except Exception as e:
                st.error(f"Falha ao abrir instalador do sistema: {e}")
    else:
        st.info("termux-open indisponível. Tente 'Instalar via pm' abaixo.")

    # Botão 2: pm install
    if st.button("Instalar (pm install -r)"):
        if is_termux():
            cmd = ["pm", "install", "-r", dest_path]
            st.info("Executando: " + " ".join(shlex.quote(c) for c in cmd))
            try:
                proc = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
                if proc.returncode == 0:
                    st.success("APK instalado via pm.")
                    st.code(proc.stdout or "(sem stdout)")
                else:
                    st.error(f"Falhou (exit {proc.returncode}).")
                    st.code((proc.stdout or "") + "\n" + (proc.stderr or ""))
            except subprocess.TimeoutExpired:
                st.error("Timeout: instalação demorou demais.")
            except Exception as e:
                st.error(f"Erro ao executar pm: {e}")
        else:
            st.info("Desktop/Linux: use `adb install -r <apk>` no seu PC.")

PYEOF

# ---------- 4) Porta livre & subir app ----------
if lsof -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  warn "Porta $PORT já está em uso. Ajuste PORT=xxxx ou feche o processo antigo."
fi

log "Subindo Streamlit em http://${ADDRESS}:${PORT}"
streamlit run "$APP_FILE" --server.port "$PORT" --server.address "$ADDRESS" &
APP_PID=$!

cleanup() {
  log "Encerrando app (PID $APP_PID)…"
  kill "$APP_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

# ---------- 5) Dica de acesso ----------
if $is_termux; then
  if command -v termux-open-url >/dev/null 2>&1; then
    sleep 2
    termux-open-url "http://127.0.0.1:${PORT}" || true
  fi
  log "Abra no navegador do Android: http://127.0.0.1:${PORT}"
elif $is_codespaces; then
  if command -v gp >/dev/null 2>&1; then
    PUBLIC_URL="$(gp url "$PORT" || true)"
    [ -n "$PUBLIC_URL" ] && log "Codespaces URL: $PUBLIC_URL"
  fi
  log "No Codespaces, exponha a porta $PORT e abra a URL pública."
else
  log "Abra no navegador: http://localhost:${PORT}"
fi

wait "$APP_PID"
