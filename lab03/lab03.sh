#!/data/data/com.termux/files/usr/bin/bash 2>/dev/null
#!/bin/bash
# lab_ollama_android.sh
# - Detecta Termux/Android vs Linux
# - Instala Python + deps mínimos
# - Gera app Streamlit com:
#   * Chat via Ollama HTTP (URL/model/temperatura/tokens configuráveis)
#   * Upload e instalação de APK (pm no Android; adb fora do Android)
# - Sobe Streamlit

set -euo pipefail
IFS=$'\n\t'

APP_FILE="lab_ollama_app.py"
VENV_DIR=".venv_lab03"
PORT="${PORT:-7860}"
ADDRESS="${ADDRESS:-0.0.0.0}"

info()  { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }

is_termux=false
if command -v termux-info >/dev/null 2>&1 || [[ -d "/data/data/com.termux/files/usr" ]]; then
  is_termux=true
fi

# ---------- 1) Dependências do SO ----------
if $is_termux; then
  info "Detectado Termux/Android."
  pkg update -y
  pkg install -y python clang libffi openssl git
else
  info "Ambiente Linux desktop/servidor."
  if ! command -v python3 >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      sudo apt-get update -y
      sudo apt-get install -y python3 python3-venv python3-pip
    else
      error "python3 não encontrado. Instale python3/venv/pip e rode novamente."
      exit 1
    fi
  fi
  # adb (opcional fora do Android)
  if ! command -v adb >/dev/null 2>&1; then
    warn "adb não encontrado. Tentando instalar (apt-get)..."
    if command -v apt-get >/devnull 2>&1; then
      sudo apt-get update -y && sudo apt-get install -y adb || warn "Falhou instalar adb automaticamente."
    fi
  fi
fi

# ---------- 2) Ambiente Python ----------
if [ ! -d "$VENV_DIR" ]; then
  info "Criando venv em $VENV_DIR"
  python3 -m venv "$VENV_DIR"
fi
# shellcheck source=/dev/null
source "$VENV_DIR/bin/activate"

info "Atualizando pip e instalando libs (leves para Android)..."
python -m pip install --upgrade pip >/dev/null
pip install --quiet streamlit requests

# ---------- 3) App Streamlit (Ollama + APK install) ----------
info "Gerando $APP_FILE"
cat > "$APP_FILE" << 'PYEOF'
import os, time, shlex, subprocess, requests, streamlit as st

# -------- Config --------
TMP_DIR = "/data/data/com.termux/files/usr/tmp/lab03_apks" if os.path.isdir("/data/data/com.termux/files/usr/tmp") else "/tmp/lab03_apks"
os.makedirs(TMP_DIR, exist_ok=True)

DEFAULT_OLLAMA_URL   = os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434")
DEFAULT_OLLAMA_MODEL = os.environ.get("OLLAMA_MODEL", "llama3.2:1b")
DEFAULT_TEMP         = float(os.environ.get("OLLAMA_TEMP", "0.2"))
DEFAULT_MAXTOK       = int(os.environ.get("OLLAMA_MAXTOK", "180"))

st.set_page_config(page_title="Hacktiba — Lab (Android + Ollama)", page_icon="🤖", layout="centered")
st.markdown("""<style>
.block-container {padding-top: 1rem; max-width: 720px;}
.user {background:#e8f0fe;border-radius:14px;padding:10px 12px;margin:6px 0;}
.assistant {background:#f1f3f4;border-radius:14px;padding:10px 12px;margin:6px 0;}
.small {font-size:12px;color:#6b7280;}
.header {display:flex;gap:8px;align-items:center;}
.header .title {font-weight:700;font-size:18px;}
.kv {font-family: ui-monospace, monospace;}
</style>""", unsafe_allow_html=True)

st.markdown('<div class="header">🤖 <div class="title">Hacktiba — Lab (Android + Ollama)</div></div>', unsafe_allow_html=True)
st.caption("Conecta no Ollama App local e instala APKs (pm no Android, adb fora do Android).")

# -------- Sidebar: Ollama --------
with st.sidebar:
    st.subheader("Ollama (local)")
    if "cfg" not in st.session_state:
        st.session_state.cfg = {
            "url": DEFAULT_OLLAMA_URL,
            "model": DEFAULT_OLLAMA_MODEL,
            "temp": DEFAULT_TEMP,
            "max_tokens": DEFAULT_MAXTOK,
        }
    st.session_state.cfg["url"]   = st.text_input("Ollama URL", st.session_state.cfg["url"], help="Ex.: http://127.0.0.1:11434 (padrão do Ollama App)")
    st.session_state.cfg["model"] = st.text_input("Modelo", st.session_state.cfg["model"], help="Ex.: llama3.2:1b")
    st.session_state.cfg["temp"]  = st.slider("Temperatura", 0.0, 1.5, float(st.session_state.cfg["temp"]), 0.05)
    st.session_state.cfg["max_tokens"] = st.slider("Máx. tokens", 16, 2048, int(st.session_state.cfg["max_tokens"]), 16)

    st.markdown("---")
    st.subheader("Status")
    # Teste rápido do Ollama
    try:
        r = requests.get(st.session_state.cfg["url"].rstrip("/") + "/api/tags", timeout=2)
        ok = r.ok
        models = ", ".join(m.get("name","?") for m in (r.json().get("models", []) if ok else [] )[:6]) if ok else ""
        if ok:
            st.success(f"Ollama OK — modelos: {models or '—'}")
        else:
            st.warning(f"Ollama HTTP {r.status_code}")
    except Exception as e:
        st.warning(f"Ollama indisponível: {e}")

    if st.button("Atualizar"):
        st.experimental_rerun()

# -------- Chat State --------
if "messages" not in st.session_state:
    st.session_state.messages = [
        {"role":"assistant","content":"Oi! Diga o que precisa fazer no GitHub e eu recomendo a feature ideal com 3–5 passos práticos."}
    ]

for m in st.session_state.messages:
    cls = "assistant" if m["role"]=="assistant" else "user"
    st.markdown(f'<div class="{cls}">{m["content"]}</div>', unsafe_allow_html=True)

# -------- LLM via Ollama --------
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
    f'<div class="small kv">Ollama: {st.session_state.cfg["url"]} • Modelo: {st.session_state.cfg["model"]} • '
    f'Temp: {st.session_state.cfg["temp"]} • Máx. tokens: {st.session_state.cfg["max_tokens"]}</div>',
    unsafe_allow_html=True
)
st.markdown("---")

# -------- APK Upload & Instalação --------
st.header("Instalar APK (Android)")

def is_android_termux() -> bool:
    try:
        return os.path.isdir("/data/data/com.termux/files/usr") or "ANDROID_ROOT" in os.environ
    except Exception:
        return False

def adb_or_pm_devices_output() -> str:
    if is_android_termux():
        # no Android, mostrar info básica
        return "Executando em Android/Termux. Use 'pm' para instalar.\nDica: ative 'Instalar via USB' se necessário."
    try:
        res = subprocess.run(["adb", "devices"], capture_output=True, text=True, timeout=10)
        return res.stdout
    except Exception as e:
        return f"Erro executando 'adb devices': {e}"

st.subheader("Ambiente")
st.code(adb_or_pm_devices_output())

st.subheader("Upload de APK")
uploaded = st.file_uploader("Escolha o arquivo .apk", type=["apk"])
if uploaded:
    ts = int(time.time())
    safe_name = f"{ts}_{uploaded.name.replace(' ', '_')}"
    dest_path = os.path.join(TMP_DIR, safe_name)
    with open(dest_path, "wb") as f:
        f.write(uploaded.getbuffer())
    st.success(f"APK salvo em: {dest_path}")

    if is_android_termux():
        # Android: usar pm install -r
        if st.button("Instalar APK (pm)"):
            cmd = ["pm", "install", "-r", dest_path]
            st.info("Executando: " + " ".join(shlex.quote(c) for c in cmd))
            try:
                proc = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
                if proc.returncode == 0:
                    st.success("APK instalado com sucesso (pm).")
                    st.code(proc.stdout or "(sem stdout)")
                else:
                    st.error(f"Falha ao instalar (exit {proc.returncode}).")
                    st.code((proc.stdout or "") + "\n" + (proc.stderr or ""))
            except subprocess.TimeoutExpired:
                st.error("Timeout: instalação demorou demais.")
            except Exception as e:
                st.error(f"Erro ao executar pm install: {e}")
    else:
        # Desktop: usar adb install -r (opcional deviceId)
        st.write("Defina deviceId (opcional) — use um da lista do 'adb devices' (ex.: emulator-5554).")
        device_id = st.text_input("deviceId (opcional)")
        if st.button("Instalar APK (adb)"):
            cmd = ["adb"]
            if device_id.strip():
                cmd += ["-s", device_id.strip()]
            cmd += ["install", "-r", dest_path]
            st.info("Executando: " + " ".join(shlex.quote(c) for c in cmd))
            try:
                proc = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
                if proc.returncode == 0:
                    st.success("APK instalado com sucesso (adb).")
                    st.code(proc.stdout or "(sem stdout)")
                else:
                    st.error(f"Falha ao instalar (exit {proc.returncode}).")
                    st.code((proc.stdout or "") + "\n" + (proc.stderr or ""))
            except subprocess.TimeoutExpired:
                st.error("Timeout: instalação demorou demais.")
            except Exception as e:
                st.error(f"Erro ao executar adb install: {e}")
PYEOF

# ---------- 4) Executar ----------
info "Subindo Streamlit em http://${ADDRESS}:${PORT} ..."
streamlit run "$APP_FILE" --server.port "$PORT" --server.address "$ADDRESS"        "e forneça 3–5 passos práticos. Responda em português. Estruture em:\n"
        "- Opção recomendada:\n- Por quê:\n- Passos:\n"
        f"Pedido do usuário: {user_text}"
    )
    out = gen(prompt, max_new_tokens=180, do_sample=False, num_beams=4)[0]["generated_text"]
    return out.strip()

with st.form("chat", clear_on_submit=True):
    user_text = st.text_input("Digite aqui…", placeholder="Ex.: Quero reportar um bug no app móvel…")
    sent = st.form_submit_button("Enviar")
    if sent and user_text.strip():
        st.session_state.messages.append({"role":"user","content":user_text.strip()})
        try:
            reply = ask_model(user_text.strip())
        except Exception as e:
            reply = f"Não consegui gerar resposta ({e})."
        st.session_state.messages.append({"role":"assistant","content":reply})
        st.rerun()

st.markdown('<div class="small">Modelo: ' + MODEL + " • Execução local (CPU)</div>", unsafe_allow_html=True)
