import os, json, time, urllib.request, urllib.error
import gradio as gr
import ollama

# -------- Config --------
OLLAMA_HOST = os.environ.get("OLLAMA_HOST", "http://127.0.0.1:11434")
OLLAMA_MODEL = os.environ.get("LAB02_MODEL", "llama3.2:3b-instruct")  # leve p/ CPU
LAB02_AUTO_PULL = os.environ.get("LAB02_AUTO_PULL", "true").lower() in {"1","true","yes"}
PORT = int(os.environ.get("LAB02_PORT", "7860"))

client = ollama.Client(host=OLLAMA_HOST)

# -------- Utils HTTP --------
def _http_json(method: str, path: str, payload: dict | None = None, timeout: float = 15.0):
    url = OLLAMA_HOST.rstrip("/") + path
    data = None
    headers = {"Content-Type": "application/json"}
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))

def ollama_alive():
    try:
        _http_json("GET", "/api/tags", timeout=3.0)
        return True, "OK"
    except Exception as e:
        return False, f"{e}"

def model_installed(model: str) -> bool:
    try:
        tags = _http_json("GET", "/api/tags")
        for m in tags.get("models", []):
            if m.get("name") == model:
                return True
        return False
    except Exception:
        return False

def pull_model_blocking(model: str, max_wait_sec: int = 900, poll_every: float = 3.0) -> str:
    """
    Puxa o modelo sem streaming e aguarda até aparecer em /api/tags.
    """
    try:
        _http_json("POST", "/api/pull", {"model": model, "stream": False}, timeout=120.0)
    except urllib.error.HTTPError as he:
        return f"❌ HTTPError no pull: {he.code} {he.reason}"
    except Exception as e:
        return f"❌ Erro ao iniciar pull: {e}"

    start = time.time()
    while time.time() - start < max_wait_sec:
        if model_installed(model):
            return "✅ Modelo instalado."
        time.sleep(poll_every)
    return f"⏳ Timeout: modelo '{model}' não apareceu após {max_wait_sec}s."

# -------- Contexto Hacktiba --------
HACKTIBA_CONTEXT = """
# Hacktiba 2025 — Evento de Segurança da Informação

## Propósito
Missão: Fortalecer o ecossistema de cibersegurança por meio da pesquisa, aprendizado contínuo e compartilhamento.
Valores:
- Research: curiosidade, investigação e descoberta.
- Learn: aprendizado técnico com propósito.
- Share: compartilhamento de conhecimento com impacto real.

## Detalhes
- Nome: Hacktiba 2025
- Data: 11 de outubro de 2025
- Horário: 09:00 – 12:00
- Local: R. Dr. Alcides Vieira Arcoverde, 1225 – Curitiba/PR
- Formato: palestras curtas, painéis, demonstrações, labs leves, networking
- Público-alvo: desenvolvedores, analistas, estudantes e pesquisadores
- Slogan: “Do CVE à Correção”

## Agenda
08:30 — Boas-vindas e credenciamento
09:00 – 09:20 — Danilo Costa: “Do CVE à Correção: A Jornada de uma Vulnerabilidade em um Software de IA”
09:20 – 10:00 — Wagner Elias: Painel AppSec — Perguntas e Respostas
10:05 – 10:35 — Julio: Gestão de Riscos de Terceiros (ISO 27001, NIST, LGPD)
10:40 – 11:10 — Izael GrPereira: DevSecOps — O básico bem-feito é melhor que perfeito (OWASP Top 10, pipelines open source)
11:15 – 11:45 — Luigi Polidorio: Q-Day — O dia em que a segurança digital vai quebrar (computação quântica)

## Avisos
O evento poderá ser adiado ou cancelado em razão de força maior.
Não há responsabilidade da organização por despesas adicionais de transporte, hospedagem ou alimentação.

## Chamado
Traga sua pesquisa, mostre sua demo e aprenda com a comunidade Hacktiba.
"""

PROMPT_GUIDE = f"""
Você é o assistente oficial do Hacktiba 2025.
Use SEMPRE o contexto abaixo para responder. Seja claro, completo e organizado, em português.
Se a pergunta não for sobre o evento, responda brevemente e retorne ao contexto do Hacktiba.

{HACKTIBA_CONTEXT}

Agora responda à pergunta do usuário:
"""

# -------- Ações UI --------
def do_health():
    alive, why = ollama_alive()
    if not alive:
        return (f"**Host:** `{OLLAMA_HOST}` • ❌ Ollama indisponível ({why})",)
    msg = f"**Host:** `{OLLAMA_HOST}` • ✅ Ollama OK  "
    msg += f"• **Modelo:** `{OLLAMA_MODEL}` "
    msg += "(instalado ✅)" if model_installed(OLLAMA_MODEL) else "(não instalado ❌)"
    return (msg,)

def do_pull():
    alive, why = ollama_alive()
    if not alive:
        return f"❌ Ollama indisponível ({why}). Inicie com `ollama serve`."
    status = pull_model_blocking(OLLAMA_MODEL)
    # retorna status + estado final
    final = "✅" if model_installed(OLLAMA_MODEL) else "❌"
    return f"{status}\nEstado final: {final} • Modelo: {OLLAMA_MODEL}"

# -------- Chat --------
def responder(pergunta: str) -> str:
    pergunta = (pergunta or "").strip()
    if not pergunta:
        return "Digite uma pergunta sobre o Hacktiba."

    alive, why = ollama_alive()
    if not alive:
        return f"❌ Ollama indisponível em {OLLAMA_HOST}. Detalhe: {why}"

    if not model_installed(OLLAMA_MODEL):
        if LAB02_AUTO_PULL:
            pull_status = pull_model_blocking(OLLAMA_MODEL)
            if not model_installed(OLLAMA_MODEL):
                return (f"{pull_status}\n\nAinda não encontrei o modelo '{OLLAMA_MODEL}'. "
                        f"Tente manualmente: `ollama pull {OLLAMA_MODEL}`.")
        else:
            return (f"⚠️ Modelo '{OLLAMA_MODEL}' não encontrado.\n"
                    f"Instale com: `ollama pull {OLLAMA_MODEL}` ou ajuste LAB02_MODEL.")

    try:
        r = client.chat(
            model=OLLAMA_MODEL,
            messages=[
                {"role": "system", "content": PROMPT_GUIDE},
                {"role": "user", "content": pergunta}
            ],
            options={"temperature": 0.2}
        )
        return r["message"]["content"]
    except Exception as e:
        if "not found" in str(e).lower():
            return (f"⚠️ Modelo '{OLLAMA_MODEL}' não encontrado pelo servidor.\n"
                    f"Execute: `ollama pull {OLLAMA_MODEL}` e tente novamente.")
        return f"⚠️ Erro ao consultar Ollama: {e}"

# -------- UI --------
with gr.Blocks() as demo:
    gr.Markdown("# Hacktiba 2025 — Assistente Oficial (Ollama)")
    status_md = gr.Markdown(value="Carregando status…")
    with gr.Row():
        btn_health = gr.Button("🔎 Health-check")
        btn_pull = gr.Button("⬇️ Baixar modelo agora")

    entrada = gr.Textbox(label="Pergunta sobre o Hacktiba", placeholder="Ex.: Qual a missão do evento?")
    saida = gr.Textbox(label="Resposta", lines=12)
    btn_enviar = gr.Button("Enviar")

    # ações
    btn_enviar.click(responder, inputs=entrada, outputs=saida)
    btn_health.click(do_health, inputs=None, outputs=status_md)
    btn_pull.click(do_pull, inputs=None, outputs=saida)

    # faz um health inicial
    init = do_health()[0]
    status_md.value = init

demo.launch(server_name="0.0.0.0", server_port=PORT)
