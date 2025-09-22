# lab02.py — LLM Vuln Labs Assistant (leve, defensivo, com fallback e anti-oversafety)
import os, json, time, subprocess, urllib.request, urllib.error
from typing import Tuple, List
from fastapi import FastAPI, Form
from fastapi.responses import HTMLResponse, PlainTextResponse
import ollama

# ======================= CONFIG (otimizado p/ pouca RAM) =======================
OLLAMA_HOST  = os.environ.get("OLLAMA_HOST", "http://127.0.0.1:11434")
# Prioridade: 1) llama3.2:1b  ->  2) tinyllama:1.1b
OLLAMA_MODEL = os.environ.get("LAB02_MODEL", "llama3.2:1b")
AUTO_PULL    = os.environ.get("LAB02_AUTO_PULL", "true").lower() in {"1","true","yes"}
HOST         = os.environ.get("LAB02_HOST", "0.0.0.0")
PORT         = int(os.environ.get("LAB02_PORT", "7860"))
PULL_TIMEOUT = int(os.environ.get("LAB02_PULL_TIMEOUT", "900"))   # 15 min
NUM_CTX      = int(os.environ.get("LAB02_NUM_CTX", "128"))        # contexto baixo = menos RAM

# Fallbacks focados em leveza
ALT_TAGS = {
    "llama3.2:1b": ["tinyllama:1.1b"],
    "llama3.2:3b": ["llama3.2:1b", "tinyllama:1.1b"],
    "llama3.2:3b-instruct": ["llama3.2:1b", "tinyllama:1.1b"],
    "qwen2.5:1.5b-instruct": ["llama3.2:1b", "tinyllama:1.1b"],
}
SMALL_CANDIDATES = ["llama3.2:1b", "tinyllama:1.1b"]

client = ollama.Client(host=OLLAMA_HOST)

# ==================== OLLAMA HELPERS ===================
def _http_json(method: str, path: str, payload: dict | None = None, timeout: float = 12.0):
    url = OLLAMA_HOST.rstrip("/") + path
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"}, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))

def is_server_alive() -> Tuple[bool, str]:
    try:
        _http_json("GET", "/api/tags", timeout=4.0)
        return True, "OK"
    except Exception as e:
        return False, str(e)

def list_installed_models() -> List[str]:
    try:
        tags = _http_json("GET", "/api/tags")
        return [m.get("name") for m in tags.get("models", []) if m.get("name")]
    except Exception:
        return []

def is_model_installed(model: str) -> bool:
    return model in set(list_installed_models())

def resolve_model(model_name: str) -> str:
    if is_model_installed(model_name):
        return model_name
    for alt in ALT_TAGS.get(model_name, []):
        if is_model_installed(alt):
            return alt
    return model_name

def pull_model_blocking(model: str, timeout_sec: int = PULL_TIMEOUT) -> Tuple[bool, str]:
    try:
        proc = subprocess.run(
            ["ollama", "pull", model],
            capture_output=True, text=True, timeout=timeout_sec, check=False,
        )
        if proc.returncode == 0:
            for _ in range(10):
                if is_model_installed(model):
                    return True, f"✅ Modelo '{model}' instalado."
                time.sleep(1.0)
            return True, f"⚠️ Pull OK, mas ainda não vi '{model}' em /api/tags."
        return False, f"❌ Falha no pull ({proc.returncode}): {proc.stderr or proc.stdout}"
    except subprocess.TimeoutExpired:
        return False, f"⏳ Timeout ao puxar '{model}' (>{timeout_sec}s)."
    except FileNotFoundError:
        return False, "❌ 'ollama' CLI não encontrado no PATH. Instale e rode `ollama serve`."
    except Exception as e:
        return False, f"❌ Erro ao puxar modelo: {e}"

# =================== CONTEXTO: LLM VULN LABS (Educação/Defesa) ==================
LLM_VULN_LABS_CONTEXT = """
# LLM Vuln Labs — Repositório Didático de Vulnerabilidades em LLMs

## Objetivo
Ajudar equipes e estudantes a entender, demonstrar e MITIGAR classes comuns de vulnerabilidades em aplicações com Modelos de Linguagem (LLMs), sempre de forma ética e responsável.

## Escopo (alto nível, foco defensivo)
- Prompt Injection (direta e indireta / RAG) e Tool/Function Injection.
- Jailbreaks e bypass de políticas.
- Prompt/Secret Leaking e exfiltração de dados sensíveis.
- Training Data Extraction (consulta a memorizações indevidas).
- Insecure Output Handling (execução cega de comandos/URLs).
- Indução a fraude/engenharia social por LLMs.
- Avaliação de risco, testes e hardening de pipelines (RAG, agentes, ferramentas).

## O que o repositório cobre
- Cenários de laboratório seguros para estudo e validação.
- Exemplos de payloads *red-team style* em nível educacional (não operacional).
- Checklists de mitigação e padrões de arquitetura segura.
- Testes automatizados (harness) e métricas de robustez.

## Princípios
- Ensino responsável, sem instruções operacionais para dano real.
- Foco em prevenção, detecção e resposta.
- Privacidade: não usar dados reais/sensíveis nos testes.
- Conformidade: aderir a políticas de segurança e leis aplicáveis.

## Mitigações (resumo)
- Entrada: normalização, sanitação, filtragem contextual, anotação do user-intent.
- Política: prompts com políticas claras, role separations, *partial serialization* (evitar segredos no prompt).
- Pipeline: RAG com *content safety* no corpus, *link hygiene*, *guardrails* e *output moderation*.
- Execução: *least-privilege*, *sandboxing* e *allowlists* para ferramentas externas.
- Observabilidade: *audit logs*, *attack traces*, *canaries* e avaliações contínuas.
"""

# ======== PROMPT ANTI-OVER-SAFETY (defensivo, não recusar à toa) ========
PROMPT_GUIDE = f"""
Você é o **assistente oficial do LLM Vuln Labs** (educacional/defensivo).
Regras:
1) Trate SEMPRE 'LLM Vuln Labs' como um repositório didático de segurança em LLMs (ético).
2) NÃO recuse perguntas inofensivas sobre o laboratório. Recuse apenas pedidos claramente maliciosos ou que solicitem passo-a-passo operacional para causar dano.
3) Responda EM PORTUGUÊS, de forma clara e fiel AO CONTEXTO fornecido. Se algo não estiver no contexto, diga "não tenho essa informação no contexto".
4) Foque em conceitos, riscos, detecção e MITIGAÇÕES. Nada de instruções operacionais para invasão real.
5) Quando fizer sentido, estruture em: **Resumo • Riscos • Exemplos de teste (alto nível) • Mitigações • Próximos passos**.

Contexto oficial:
{LLM_VULN_LABS_CONTEXT}
"""

# Few-shots para orientar o tom
FEW_SHOTS = [
    {"role": "user", "content": "O que é o LLM Vuln Labs?"},
    {"role": "assistant", "content": "É um repositório didático para estudar vulnerabilidades em LLMs com foco defensivo: entender riscos (prompt injection, jailbreaks, leaking), testar em laboratório e aplicar MITIGAÇÕES seguras."},
    {"role": "user", "content": "Me dá um passo a passo para vazar segredos de produção via LLM."},
    {"role": "assistant", "content": "Não forneço instruções operacionais para causar dano. Posso explicar os riscos de prompt/secret leaking em ALTO NÍVEL e listar MITIGAÇÕES como remover segredos do prompt, filtrar saídas e usar sandboxes."},
    {"role": "user", "content": "Como mitigar prompt injection em um RAG?"},
    {"role": "assistant", "content": "Resumo: isole papéis, sanitize entradas, aplique content safety no corpus, use políticas no prompt e moderação de saída, limite permissões de ferramentas e adote observabilidade. Teste continuamente com um harness de ataques."},
]

# ======================= FASTAPI UI =====================
app = FastAPI()

HTML = """<!doctype html><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>LLM Vuln Labs — Assistente</title>
<script src="https://unpkg.com/htmx.org@2.0.3"></script>
<style>
body{font-family:system-ui,Segoe UI,Roboto,Arial,sans-serif;background:#0b1020;color:#fff;margin:0}
.wrap{max-width:900px;margin:40px auto;padding:0 16px}
.card{background:#111935;border:1px solid #1e2a55;border-radius:16px;box-shadow:0 8px 24px rgba(0,0,0,.25);padding:20px}
h1{margin:0 0 6px;font-size:24px}.muted{color:#a9b3d6}.row{display:flex;gap:8px;margin-top:12px}
input,button{font:inherit;border-radius:12px;border:1px solid #2b3b77;background:#0d142b;color:#fff}
input{width:100%;padding:12px}button{padding:12px 16px;cursor:pointer}
button.primary{background:#3c6df0;border-color:#3c6df0}
pre{white-space:pre-wrap;word-wrap:break-word}
.badge{display:inline-block;padding:4px 8px;border-radius:999px;background:#1b254d;color:#c8d3ff;font-size:12px;margin-left:8px}
.small{font-size:13px}
</style>
<div class="wrap">
  <div class="card">
    <h1>LLM Vuln Labs — Assistente <span id="status" class="badge">checando…</span></h1>
    <div id="hostinfo" class="muted small"></div>
    <div class="row">
      <button class="primary" hx-get="/health" hx-target="#status" hx-swap="innerHTML">🔎 Health-check</button>
      <button hx-post="/pull" hx-target="#answer" hx-swap="innerHTML">⬇️ Baixar modelo agora</button>
    </div>
  </div>
  <div class="card" style="margin-top:16px">
    <form hx-post="/chat" hx-target="#answer" hx-swap="innerHTML">
      <label>Pergunta sobre LLM Vuln Labs / LLM vulnerabilities</label>
      <input type="text" name="q" placeholder="Ex.: O que é prompt injection? Como mitigar?" required>
      <div class="row"><button class="primary" type="submit">Enviar</button></div>
    </form>
    <div id="answer" style="margin-top:16px"><pre class="muted">Digite sua pergunta acima…</pre></div>
  </div>
</div>
<script>
fetch('/health').then(r=>r.text()).then(t=>{document.getElementById('status').innerHTML=t});
fetch('/hostinfo').then(r=>r.text()).then(t=>{document.getElementById('hostinfo').innerHTML=t});
</script>"""

@app.get("/", response_class=HTMLResponse)
async def index(): 
    return HTML

@app.get("/hostinfo", response_class=PlainTextResponse)
async def hostinfo():
    eff = resolve_model(OLLAMA_MODEL)
    return f"Host: {OLLAMA_HOST} • Modelo configurado: {OLLAMA_MODEL} • Efetivo: {eff} • Auto-pull: {'ativado' if AUTO_PULL else 'desativado'} • num_ctx={NUM_CTX}"

@app.get("/health", response_class=PlainTextResponse)
async def health():
    alive, why = is_server_alive()
    if not alive:
        return f"❌ Ollama indisponível ({why})"
    eff = resolve_model(OLLAMA_MODEL)
    flag = "instalado ✅" if is_model_installed(eff) else "não instalado ❌"
    return f"✅ Ollama OK • {eff}: {flag} • num_ctx={NUM_CTX}"

def try_chat(model_name: str, prompt: str) -> Tuple[bool, str]:
    """Contexto + few-shots, foco defensivo/educacional (sem passo-a-passo ofensivo)."""
    user_prompt = (
        "O usuário pergunta sobre LLM vulnerabilities. "
        "Responda SOMENTE com informações do contexto dado, em alto nível e com MITIGAÇÕES; "
        "evite instruções operacionais para dano real.\n\nPergunta: "
        + prompt
    )
    msgs = [{"role":"system","content":PROMPT_GUIDE}] + FEW_SHOTS + [
        {"role":"user","content":user_prompt}
    ]
    try:
        r = client.chat(
            model=model_name,
            messages=msgs,
            options={"temperature": 0.2, "num_ctx": NUM_CTX}
        )
        return True, r["message"]["content"]
    except Exception as e:
        return False, str(e)

def handle_oom_and_fallback(err_msg: str, prompt: str) -> str:
    lowered = err_msg.lower()
    if ("more system memory" in lowered) or ("out of memory" in lowered) or ("not enough memory" in lowered):
        for cand in SMALL_CANDIDATES:
            if not is_model_installed(cand) and AUTO_PULL:
                pull_model_blocking(cand)
            if is_model_installed(cand):
                ok, out = try_chat(cand, prompt)
                if ok:
                    return f"(fallback: {cand}, num_ctx={NUM_CTX})\n\n{out}"
        return ("⚠️ Memória insuficiente e o fallback automático falhou.\n"
                "Use `ollama pull tinyllama:1.1b` e/ou `export LAB02_NUM_CTX=128`.")
    return f"⚠️ Erro ao consultar Ollama: {err_msg}"

@app.post("/pull", response_class=PlainTextResponse)
async def pull():
    alive, why = is_server_alive()
    if not alive:
        return f"❌ Ollama indisponível ({why}). Inicie com `ollama serve`."
    eff = resolve_model(OLLAMA_MODEL)
    if not is_model_installed(eff):
        ok, msg = pull_model_blocking(eff)
        final = "✅" if is_model_installed(eff) else "❌"
        return f"{msg}\nEstado final: {final} • Modelo: {eff}"
    return f"✅ Modelo já instalado: {eff}"

@app.post("/chat", response_class=HTMLResponse)
async def chat(q: str = Form(...)):
    q = (q or "").strip()
    if not q:
        return "<pre>Digite uma pergunta.</pre>"

    alive, why = is_server_alive()
    if not alive:
        return f"<pre>❌ Ollama indisponível em {OLLAMA_HOST}. Detalhe: {why}</pre>"

    eff = resolve_model(OLLAMA_MODEL)
    if not is_model_installed(eff):
        if AUTO_PULL:
            pull_model_blocking(eff)
            if not is_model_installed(eff):
                return f"<pre>Não encontrei '{eff}'. Rode `ollama pull {eff}`.</pre>"
        else:
            return f"<pre>⚠️ Modelo '{eff}' não encontrado. Rode `ollama pull {eff}`.</pre>"

    ok, out = try_chat(eff, q)
    if ok:
        return f"<pre>{out}</pre>"
    else:
        return f"<pre>{handle_oom_and_fallback(out, q)}</pre>"

# ===================== STARTUP HOOK =====================
def startup_prepare():
    alive, why = is_server_alive()
    if not alive:
        print(f"⚠️ Ollama offline ({why}). Inicie em outro terminal: `ollama serve`.")
        return
    eff = resolve_model(OLLAMA_MODEL)
    if not is_model_installed(eff) and AUTO_PULL:
        ok, msg = pull_model_blocking(eff)
        print(msg)

startup_prepare()

# ======================= MAIN ==========================
if __name__ == "__main__":
    import uvicorn
    uvicorn.run("lab02:app", host=HOST, port=PORT, reload=False)
