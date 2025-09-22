import os
import json
import time
import urllib.request
import urllib.error
import gradio as gr
import ollama

# -------- Config --------
OLLAMA_HOST = os.environ.get("OLLAMA_HOST", "http://127.0.0.1:11434")
OLLAMA_MODEL = os.environ.get("LAB02_MODEL", "llama3.2:3b-instruct")  # leve p/ CPU/Codespaces
LAB02_AUTO_PULL = os.environ.get("LAB02_AUTO_PULL", "true").lower() in {"1", "true", "yes"}
PORT = int(os.environ.get("LAB02_PORT", "7860"))

# Cliente Ollama apontando pro host configurado
client = ollama.Client(host=OLLAMA_HOST)

# -------- Utilidades Ollama --------
def _http_json(method: str, path: str, payload: dict | None = None, timeout: float = 10.0):
    url = OLLAMA_HOST.rstrip("/") + path
    data = None
    headers = {"Content-Type": "application/json"}
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))

def ollama_alive() -> tuple[bool, str]:
    try:
        _http_json("GET", "/api/tags", None, timeout=3.0)
        return True, "OK"
    except Exception as e:
        return False, f"{e}"

def model_installed(model: str) -> bool:
    try:
        tags = _http_json("GET", "/api/tags")
        for it in tags.get("models", []):
            if it.get("name") == model:
                return True
        return False
    except Exception:
        return False

def pull_model(model: str, max_wait_sec: int = 900) -> str:
    """
    Tenta baixar o modelo via /api/pull (streaming). Espera até max_wait_sec.
    Retorna msg de status.
    """
    start = time.time()
    try:
        # inicia o pull (stream = true); vamos ler em blocos até terminar ou estourar timeout
        req = urllib.request.Request(
            OLLAMA_HOST.rstrip("/") + "/api/pull",
            data=json.dumps({"model": model, "stream": True}).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=30.0) as r:
            # stream de linhas json
            while True:
                if time.time() - start > max_wait_sec:
                    return f"⏳ Pull do modelo '{model}' demorou demais (> {max_wait_sec}s)."
                line = r.readline()
                if not line:
                    break
                try:
                    ev = json.loads(line.decode("utf-8"))
                    # mensagens de progresso opcionais; poderíamos acumular, mas basta continuar
                    if ev.get("status") == "success":
                        break
                except Exception:
                    # ignora linhas não-JSON
                    pass
        # checa se instalou
        return "✅ Modelo baixado." if model_installed(model) else "⚠️ Pull finalizado, mas modelo não aparece em /api/tags."
    except urllib.error.HTTPError as he:
        return f"❌ HTTPError no pull: {he.code} {he.reason}"
    except Exception as e:
        return f"❌ Erro ao puxar modelo: {e}"

# -------- Contexto do Hacktiba --------
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

# -------- Função principal --------
def responder(pergunta: str) -> str:
    pergunta = (pergunta or "").strip()
    if not pergunta:
        return "Digite uma pergunta sobre o Hacktiba."

    alive, why = ollama_alive()
    if not alive:
        return f"❌ Ollama indisponível em {OLLAMA_HOST}. Detalhe: {why}\n" \
               f"Verifique se o serviço está rodando (ex.: `ollama serve`)."

    # Garante que o modelo está disponível (tenta auto-pull se habilitado)
    if not model_installed(OLLAMA_MODEL):
        if not LAB02_AUTO_PULL:
            return (f"⚠️ Modelo '{OLLAMA_MODEL}' não encontrado em {OLLAMA_HOST}.\n"
                    f"Instale com: `ollama pull {OLLAMA_MODEL}` ou defina LAB02_MODEL para um já instalado.")
        status = pull_model(OLLAMA_MODEL, max_wait_sec=900)
        if not model_installed(OLLAMA_MODEL):
            return f"{status}\n\nAinda não encontrei o modelo '{OLLAMA_MODEL}'. " \
                   f"Tente manualmente: `ollama pull {OLLAMA_MODEL}`."

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
        # Alguns erros de modelo retornam 404 internamente; orienta o usuário
        if "not found" in str(e).lower():
            return (f"⚠️ Erro: modelo '{OLLAMA_MODEL}' não encontrado.\n"
                    f"Baixe com: `ollama pull {OLLAMA_MODEL}` e tente novamente.")
        return f"⚠️ Erro ao consultar Ollama: {e}"

# -------- UI (Gradio) --------
def status_banner():
    alive, why = ollama_alive()
    if alive:
        model_msg = "instalado ✅" if model_installed(OLLAMA_MODEL) else "não instalado ❌"
        return (f"**Host:** `{OLLAMA_HOST}` • **Modelo:** `{OLLAMA_MODEL}` ({model_msg})  \n"
                f"Auto-pull: {'ativado' if LAB02_AUTO_PULL else 'desativado'}")
    return f"**Host:** `{OLLAMA_HOST}` • ❌ Ollama indisponível ({why})"

with gr.Blocks() as demo:
    gr.Markdown("# Hacktiba 2025 — Assistente Oficial (Ollama)")
    gr.Markdown(status_banner())
    entrada = gr.Textbox(label="Pergunta sobre o Hacktiba", placeholder="Ex.: Qual a missão do evento?")
    saida = gr.Textbox(label="Resposta", lines=12)
    gr.Button("Enviar").click(responder, inputs=entrada, outputs=saida)

demo.launch(server_name="0.0.0.0", server_port=PORT)
