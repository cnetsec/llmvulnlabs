#!/usr/bin/env bash
# lab03.sh — Streamlit + cliente Ollama + upload/instalação de APK
# Foco: Android/Termux (cliente) conectando num Ollama Server via API HTTP.
# Também funciona em Linux desktop/servidor.
# -----------------------------------------------------------------------------

set -Eeuo pipefail
IFS=$'\n\t'

APP_FILE="lab_ollama_client.py"
VENV_DIR=".venv_lab03"
PORT="${PORT:-7860}"
ADDRESS="${ADDRESS:-0.0.0.0}"

log()  { printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
die()  { printf "\033[1;31m[ERROR]\033[0m %s\n" "$*"; exit 1; }

# -------------------- 1) Detecta ambiente --------------------
is_termux=false
if command -v termux-info >/dev/null 2>&1 || [[ -d "/data/data/com.termux/files/usr" ]]; then
  is_termux=true
fi

# -------------------- 2) Dependências de sistema --------------------
if $is_termux; then
  log "Detectado Android/Termux."
  pkg update -y
  pkg install -y python python-cryptography libffi openssl git
else
  log "Ambiente Linux desktop/servidor."
  command -v python3 >/dev/null 2>&1 || {
    if command -v apt-get >/dev/null 2>&1; then
      sudo apt-get update -y
      sudo apt-get install -y python3 python3-venv python3-pip
    else
      die "python3 não encontrado. Instale python3/venv/pip."
    fi
  }
  # adb é opcional fora do Android; não falhe se não existir
  if ! command -v adb >/dev/null 2>&1; then
    warn "adb não encontrado (necessário apenas para instalar APK via desktop)."
  fi
fi

# -------------------- 3) Ambiente Python --------------------
if [ ! -d "$VENV_DIR" ]; then
  log "Criando venv em $VENV_DIR"
  python3 -m venv "$VENV_DIR"
fi
# shellcheck disable=SC1090
source "$VENV_DIR/bin/activate"

log "Atualizando pip e instalando libs (leves, sem torch/transformers)..."
python -m pip install --upgrade pip >/dev/null
pip install --quiet "streamlit>=1.30" "requests>=2.31"

# -------------------- 4) App Streamlit --------------------
log "Gerando $APP_FILE"
cat > "$APP_FILE" << 'PYEOF'
import os, time, shlex, subprocess, requests, streamlit as st

# ---------------- Config ----------------
TMP_DIR = "/data/data/com.termux/files/usr/tmp/lab03_apks" if os.path.isdir("/data/data/com.termux/files/usr/tmp") else "/tmp/lab03_apks"
os.makedirs(TMP_DIR, exist_ok=True)

DEFAULT_OLLAMA_URL   = os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434")
DEFAULT_OLLAMA_MODEL = os.environ.get("OLLAMA_MODEL", "llama3.2:1b")
DEFAULT_TEMP         = float(os.environ.get("OLLAMA_TEMP", "0.2"))
DEFAULT_MAXTOK       = int(os.environ.get("OLLAMA_MAXTOK", "180"))

st.set_page_config(page_title="Hacktiba — Ollama Client (Android)", page_icon="🤖", layout="centered")
st.markdown("""<style>
.block-container {padding-top: 1rem; max-width: 720px;}
.user {background:#e8f0fe;border-radius:14px;padding:10px 12px;margin:6px 0;}
.assistant {background:#f1f3f4;border-radius:14px;padding:10px 12px;margin:6px 0;}
.small {font-size:12px;color:#6b7280;}
.header {display:flex;gap:8px;align-items:center;}
.header .title {font-weight:700;font-size:18px;}
.kv {font-family: ui-monospace, monospace;}
</style>""", unsafe_allow_html=True)

st.markdown('<div class="header">🤖 <div class="title">Hacktiba — Ollama Client (Android)</div></div>', unsafe_allow_html=True)
st.caption("Android com Ollama App (cliente) conectando no Ollama Server por API. Upload e instalação de APKs inclusos.")

def is_termux() -> bool:
    return os.path.isdir("/data/data/com.termux/files/usr") or "ANDROID_ROOT" in os.environ

# ---------------- Sidebar: Ollama ----------------
with st.sidebar:
    st.subheader("Ollama Server")
    if "cfg" not in st.session_state:
        st.session_state.cfg = {
            "url": DEFAULT_OLLAMA_URL,
            "model": DEFAULT_OLLAMA_MODEL,
            "temp": DEFAULT_TEMP,
            "max_tokens": DEFAULT_MAXTOK,
        }
    st.session_state.cfg["url"]   = st.text_input("Ollama URL", st.session_state.cfg["url"], help="Ex.: http://SEU-SERVIDOR:11434")
    st.session_state.cfg["model"] = st.text_input("Modelo", st.session_state.cfg["model"], help="Ex.: llama3.2:1b")
    st.session_state.cfg["temp"]  = st.slider("Temperatura", 0.0, 1.5, float(st.session_state.cfg["temp"]), 0.05)
    st.session_state.cfg["max_tokens"] = st.slider("Máx. tokens", 16, 4096, int(st.session_state.cfg["max_tokens"]), 16)

    st.markdown("---")
    st.subheader("Status")
    try:
        r = requests.get(st.session_state.cfg["url"].rstrip("/") + "/api/tags", timeout=3)
        if r.ok:
            models = ", ".join(m.get("name","?") for m in r.json().get("models", [])[:6]) or "—"
            st.success(f"Ollama OK • modelos: {models}")
        else:
            st.warning(f"Ollama HTTP {r.status_code}")
    except Exception as e:
        st.warning(f"Ollama indisponível: {e}")

    if st.button("Atualizar"):
        st.experimental_rerun()

# ---------------- Chat state ----------------
if "messages" not in st.session_state:
    st.session_state.messages = [
        {"role":"assistant","content":"Diga o que quer fazer no GitHub e eu recomendo a feature ideal (Issues, Discussions, Projects, Actions, Wiki, Security/Dependabot, Codespaces, Pages, Releases) com 3–5 passos práticos."}
    ]

for m in st.session_state.messages:
    cls = "assistant" if m["role"]=="assistant" else "user"
    st.markdown(f'<div class="{cls}">{m["content"]}</div>', unsafe_allow_html=True)

# ---------------- Cliente Ollama (API) ----------------
def ask_ollama(user_text: str) -> str:
    prompt = (
        "Você é conciso. Dado o pedido do usuário, indique a MELHOR OPÇÃO NO GITHUB "
        "(Issues, Discussions, Projects, Actions, Wiki, Security/Dependabot, Codespaces, Pages, Releases) "
        "e forneça 3–5 passos práticos. Responda em português. Estruture em:\n"
        "- Opção recomendada:\n- Por quê:\n- Passos:\n"
        f"Pedido do usuário: {user_text}"
    )
    body = {
        "model": st.session_state.cfg["model"],
        "prompt": prompt,
        "stream": False,
        "options": {"temperature": float(st.session_state.cfg["temp"]),
                    "num_predict": int(st.session_state.cfg["max_tokens"])}
    }
    try:
        resp = requests.post(st.session_state.cfg["url"].rstrip("/") + "/api/generate", json=body, timeout=120)
        if not resp.ok:
            return f"[Ollama HTTP {resp.status_code}] {resp.text[:300]}"
        return (resp.json().get("response") or "").strip() or "Sem resposta do modelo."
    except Exception as e:
        return f"Erro (Ollama): {e}"

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
    f'Temp: {st.session_state.cfg["temp"]} • Máx. tokens: {st.session_state.cfg["max_tokens"]}</div>',
    unsafe_allow_html=True
)
st.markdown("---")

# ---------------- APK: upload e instalação ----------------
st.header("Instalar APK no dispositivo atual")

st.write("No Android/Termux, a forma **sem root** mais estável é abrir o instalador do sistema (UI).")
st.write("Se você tiver ambiente/permite 'pm install', há um botão separado para tentar via pm.")

uploaded = st.file_uploader("Selecione um .apk", type=["apk"])
if uploaded:
    ts = int(time.time())
    safe_name = f"{ts}_{uploaded.name.replace(' ', '_')}"
    dest_path = os.path.join(TMP_DIR, safe_name)
    with open(dest_path, "wb") as f:
        f.write(uploaded.getbuffer())
    st.success(f"APK salvo: {dest_path}")

    # Botão 1: instalar via Package Installer (interativo) — funciona sem root
    if is_termux() and shutil.which("termux-open"):
        import shutil
        if st.button("Instalar (Package Installer • termux-open)"):
            try:
                # Usa content-type de APK para abrir o instalador
                cmd = ["termux-open", "--content-type", "application/vnd.android.package-archive", dest_path]
                st.info("Executando: " + " ".join(shlex.quote(c) for c in cmd))
                subprocess.check_call(cmd)
                st.success("Pedido de instalação enviado ao instalador do sistema.")
            except Exception as e:
                st.error(f"Falha ao chamar instalador do sistema: {e}")
    else:
        st.info("termux-open não disponível. Pule para 'Instalar via pm' (se permitido) ou use 'adb install' de um desktop.")

    # Botão 2: tentar instalar via pm (pode exigir permissões/root)
    if st.button("Instalar (pm install -r)"):
        cmd = ["pm", "install", "-r", dest_path]
        st.info("Executando: " + " ".join(shlex.quote(c) for c in cmd))
        try:
            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
            if proc.returncode == 0:
                st.success("APK instalado via pm.")
                st.code(proc.stdout or "(sem stdout)")
            else:
                st.error(f"Falha (exit {proc.returncode}).")
                st.code((proc.stdout or "") + "\n" + (proc.stderr or ""))
        except subprocess.TimeoutExpired:
            st.error("Timeout: instalação demorou demais.")
        except Exception as e:
            st.error(f"Erro ao executar pm: {e}")

# Para desktop: instrução rápida
if not is_termux():
    st.markdown("---")
    st.subheader("Instalar via ADB (desktop)")
    st.write("Use `adb install -r <arquivo.apk>` de sua máquina, apontando para este APK.")
PYEOF

# -------------------- 5) Sobe o app --------------------
log "Subindo Streamlit em http://${ADDRESS}:${PORT}"
exec streamlit run "$APP_FILE" --server.port "$PORT" --server.address "$ADDRESS"
