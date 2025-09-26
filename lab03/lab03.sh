#!/usr/bin/env bash
# phone_ollama_all.sh — Sobe Android (VNC) + cliente LLM web (Flask) + ADB reverse
# Acesse o "telefone" em http://localhost:6080 e, dentro dele, abra http://127.0.0.1:7860 (cliente LLM)
# Vars opcionais:
#   OLLAMA_URL (padrão: http://127.0.0.1:11434)  | HOST_PORT (7860) | VNC_PORT (6080)
#   ANDROID_TAG (budtmo/docker-android:emulator_11.0) | EMU_DEVICE ("Samsung Galaxy S10")

set -Eeuo pipefail
IFS=$'\n\t'
trap 'rc=$?; echo -e "\n[ERRO] \"$BASH_COMMAND\" (linha $LINENO) → exit $rc"; exit $rc' ERR

# --------- Config ---------
APP_FILE="ollama_client.py"
VENV_DIR=".venv_phone_llm"
ANDROID_NAME="android-phone"
ANDROID_TAG="${ANDROID_TAG:-budtmo/docker-android:emulator_11.0}"
EMU_DEVICE="${EMU_DEVICE:-Samsung Galaxy S10}"
VNC_PORT="${VNC_PORT:-6080}"      # noVNC via HTTP
ADB_PORT="${ADB_PORT:-5555}"
HOST_PORT="${HOST_PORT:-7860}"    # Flask (cliente LLM)
OLLAMA_URL="${OLLAMA_URL:-http://127.0.0.1:11434}"  # aponte para onde seu Ollama server está

# --------- Helpers ---------
log(){ printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn(){ printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
die(){ printf "\033[1;31m[ERROR]\033[0m %s\n" "$*"; exit 1; }

need_cmd(){ command -v "$1" >/dev/null 2>&1 || die "Comando requerido não encontrado: $1"; }

# --------- Checks básicos ---------
need_cmd docker
if ! docker info >/dev/null 2>&1; then
  die "Docker não está rodando (daemon). Inicie o serviço e tente de novo."
fi

# ADB (host): usaremos o do container budtmo? Preferimos host adb se existir
if ! command -v adb >/dev/null 2>&1; then
  warn "adb não encontrado no host. Vou tentar usar o 'adb' do container para conectar."
fi

# --------- Cliente LLM (Flask) no host ---------
log "Preparando cliente LLM (Flask) no host, porta ${HOST_PORT}…"
if [ ! -d "$VENV_DIR" ]; then python3 -m venv "$VENV_DIR"; fi
# shellcheck disable=SC1090
source "$VENV_DIR/bin/activate"
python -m pip install --upgrade pip >/dev/null
pip install --quiet "flask>=3.0" "requests>=2.31"

cat > "$APP_FILE" <<PYEOF
import os, json
from flask import Flask, request, jsonify, make_response
import requests

app = Flask(__name__)
OLLAMA_URL = os.environ.get("OLLAMA_URL","$OLLAMA_URL").rstrip("/")
MODEL = os.environ.get("OLLAMA_MODEL","llama3.2:1b")
TEMP  = float(os.environ.get("OLLAMA_TEMP","0.2"))
MAX_TOK = int(os.environ.get("OLLAMA_MAXTOKENS","180"))
HEADERS = {}
try:
    if os.environ.get("OLLAMA_HEADERS","").strip():
        HEADERS = json.loads(os.environ["OLLAMA_HEADERS"])
except Exception: pass

HTML = f"""<!doctype html><meta charset='utf-8'>
<title>LLM Client</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
body{{font-family:system-ui,Segoe UI,Roboto,sans-serif;margin:16px;max-width:720px}}
.msg{{padding:10px 12px;border-radius:12px;margin:6px 0}}
.user{{background:#e8f0fe}} .assistant{{background:#f1f3f4}}
.small{{color:#6b7280;font-size:12px}} textarea,input,button{{font-size:16px}}
textarea{{width:100%;height:110px;padding:10px}} input,button{{padding:10px}}
.row{{display:flex;gap:8px;flex-wrap:wrap}} input[type=text],input[type=number]{{flex:1}}
</style>
<h1>🤖 LLM Client</h1>
<div class=small>Cliente simples para Ollama. Ajuste a URL se o servidor não estiver no host.</div>
<details open><summary>Config</summary>
<div class=row style="margin-top:8px">
  <input id=url type=text value="{OLLAMA_URL}" placeholder="Ollama URL (ex.: http://IP:11434)">
  <input id=model type=text value="{MODEL}" placeholder="Modelo">
</div>
<div class=row style="margin-top:8px">
  <input id=temp type=number step=0.05 min=0 max=1.5 value="{TEMP}">
  <input id=max  type=number min=16 max=4096 value="{MAX_TOK}">
</div>
<div class=row style="margin-top:8px">
  <input id=hdrs type=text placeholder='Headers JSON opcional (ex: {"Authorization":"Bearer ..."})'>
</div>
<div class=small>Modo:
  <label><input type=radio name=mode value=generate checked> /api/generate</label>
  <label><input type=radio name=mode value=chat> /api/chat</label>
</div>
</details>
<div id=chat></div>
<textarea id=inp placeholder="Escreva seu pedido..."></textarea>
<div class=row><button id=send>Enviar</button><button id=clr>Limpar</button></div>
<script>
const C = document.getElementById('chat'), I = document.getElementById('inp');
const U = document.getElementById('url'), M = document.getElementById('model'), T = document.getElementById('temp'), X = document.getElementById('max'), H = document.getElementById('hdrs');
const E = (n)=>document.querySelector('input[name="mode"]:checked').value;
function add(role, text){ const d=document.createElement('div'); d.className='msg '+role; d.textContent=text; C.appendChild(d); d.scrollIntoView({behavior:'smooth',block:'end'}); }
document.getElementById('clr').onclick=()=>{C.innerHTML=''; I.value='';};
document.getElementById('send').onclick=async ()=>{
  const text = I.value.trim(); if(!text) return; add('user',text); I.value='';
  let hdrs={}; try{ if(H.value.trim()) hdrs=JSON.parse(H.value);}catch(_){}
  const r = await fetch('/api/bridge',{method:'POST',headers:{'Content-Type':'application/json'},
    body: JSON.stringify({url:U.value, model:M.value, temp:parseFloat(T.value), max_tokens:parseInt(X.value), text, headers:hdrs, mode:E()})});
  const j = await r.json(); add('assistant', j.ok ? (j.text||'(vazio)') : ('[ERRO] '+(j.error||'falha')));
};
</script>
"""

SYS = ("Você é conciso. Dado o pedido do usuário, indique a MELHOR OPÇÃO NO GITHUB "
       "(Issues, Discussions, Projects, Actions, Wiki, Security/Dependabot, Codespaces, Pages, Releases) "
       "e forneça 3–5 passos práticos. Responda em português. Estruture em:\\n- Opção recomendada:\\n- Por quê:\\n- Passos:\\n")

@app.get("/")
def index():
    r = make_response(HTML); r.headers["Cache-Control"] = "no-store"; return r

@app.post("/api/bridge")
def bridge():
    d = request.get_json(force=True,silent=True) or {}
    url = (d.get("url") or OLLAMA_URL).rstrip("/")
    model = d.get("model") or MODEL
    temp = float(d.get("temp") or TEMP)
    max_t = int(d.get("max_tokens") or MAX_TOK)
    user = (d.get("text") or "").strip()
    mode = (d.get("mode") or "generate").strip()
    hdrs = dict(HEADERS); 
    if isinstance(d.get("headers"), dict): hdrs.update(d["headers"])
    try:
        if mode=="chat":
            body={"model":model,"messages":[{"role":"system","content":SYS},{"role":"user","content":user}],
                  "stream":False,"options":{"temperature":temp,"num_predict":max_t}}
            r = requests.post(url+"/api/chat", json=body, headers=hdrs, timeout=120)
            if not r.ok: return jsonify({"ok":False,"error":f"Ollama HTTP {r.status_code}","details":r.text[:500]})
            txt=(r.json().get("message",{}).get("content") or "").strip()
            return jsonify({"ok":True,"text":txt})
        else:
            body={"model":model,"prompt":SYS+f"Pedido do usuário: {user}","stream":False,
                  "options":{"temperature":temp,"num_predict":max_t}}
            r = requests.post(url+"/api/generate", json=body, headers=hdrs, timeout=120)
            if not r.ok: return jsonify({"ok":False,"error":f"Ollama HTTP {r.status_code}","details":r.text[:500]})
            txt=(r.json().get("response") or "").strip()
            return jsonify({"ok":True,"text":txt})
    except Exception as e:
        return jsonify({"ok":False,"error":str(e)}), 200

if __name__=="__main__":
    import os
    app.run(host=os.environ.get("HOST","0.0.0.0"), port=int(os.environ.get("PORT","$HOST_PORT")), debug=False)
PYEOF

export HOST=0.0.0.0 PORT="$HOST_PORT" OLLAMA_URL

# Levanta o cliente em background
python "$APP_FILE" & FLASK_PID=$!
trap 'kill $FLASK_PID >/dev/null 2>&1 || true' EXIT INT TERM
sleep 1
log "Cliente LLM ativo: http://localhost:${HOST_PORT}"

# --------- Sobe Android (docker-android com noVNC) ---------
if docker ps --format '{{.Names}}' | grep -q "^${ANDROID_NAME}$"; then
  log "Container ${ANDROID_NAME} já existe. Reutilizando."
else
  log "Baixando/rodando ${ANDROID_TAG} (Android + noVNC em ${VNC_PORT})…"
  # --device /dev/kvm melhora desempenho em hosts com KVM
  docker run -d --name "$ANDROID_NAME" \
    --privileged \
    --device /dev/kvm \
    -e EMULATOR_DEVICE="$EMU_DEVICE" \
    -e WEB_VNC=true \
    -p "${VNC_PORT}:6080" \
    -p "${ADB_PORT}:5555" \
    "$ANDROID_TAG"
fi

log "Acesse o 'telefone' via noVNC: http://localhost:${VNC_PORT}"

# --------- Espera boot do emulador ---------
log "Aguardando Android inicializar…"
for i in {1..60}; do
  if docker exec -it "$ANDROID_NAME" sh -c 'cat device_status 2>/dev/null' | grep -q "1"; then
    log "Android pronto."
    break
  fi
  sleep 3
  if [ "$i" -eq 60 ]; then warn "Tempo de espera esgotado, seguindo mesmo assim."; fi
done

# --------- Conecta ADB e cria reverse para o cliente ---------
if command -v adb >/dev/null 2>&1; then
  adb connect "localhost:${ADB_PORT}" || true
  # mapeia porta do dispositivo -> host (assim, dentro do Android: http://127.0.0.1:7860)
  adb -s "localhost:${ADB_PORT}" reverse "tcp:${HOST_PORT}" "tcp:${HOST_PORT}" || warn "Falha no adb reverse (abra http://<HOST_IP>:${HOST_PORT} do Android)."
else
  warn "adb não disponível no host. Se precisar do reverse, instale adb (platform-tools)."
fi

log "Tudo pronto ✅"
log "1) Abra o telefone:   http://localhost:${VNC_PORT}"
log "2) Dentro do Android, no navegador, abra:  http://127.0.0.1:${HOST_PORT}"
log "   (ou http://<IP_DO_HOST>:${HOST_PORT} se o reverse não funcionar)"
wait "$FLASK_PID"
