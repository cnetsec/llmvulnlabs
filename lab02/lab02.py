import os
import gradio as gr

# -------- Config --------
OLLAMA_HOST = os.environ.get("OLLAMA_HOST", "http://127.0.0.1:11434")
OLLAMA_MODEL = os.environ.get("LAB02_MODEL", "llama2")
HF_MODEL = os.environ.get("LAB02_FALLBACK", "google/flan-t5-small")  # fallback
PORT = int(os.environ.get("LAB02_PORT", "7860"))

# -------- Checagem de Ollama --------
def _ollama_available() -> bool:
    import urllib.request, json
    try:
        with urllib.request.urlopen(OLLAMA_HOST + "/api/tags", timeout=1.5) as r:
            json.load(r)
        return True
    except Exception:
        return False

OLLAMA_OK = _ollama_available()
if OLLAMA_OK:
    try:
        import ollama  # type: ignore
    except Exception:
        OLLAMA_OK = False

# -------- Fallback Transformers --------
hf_pipe = None
def _ensure_hf():
    global hf_pipe
    if hf_pipe is None:
        from transformers import pipeline
        # modelo leve, bom em instruções e roda em CPU
        hf_pipe = pipeline("text2text-generation", model=HF_MODEL)

def _ask_hf(pergunta: str) -> str:
    _ensure_hf()
    out = hf_pipe(
        pergunta,
        max_new_tokens=180,
        do_sample=False,
        num_beams=4
    )[0]["generated_text"]
    return out.strip()

# -------- Lógica de resposta --------
PROMPT_GUIDE = (
    "Você é conciso. Indique a MELHOR OPÇÃO NO GITHUB "
    "(Issues, Discussions, Projects, Actions, Wiki, Security/Dependabot, Codespaces, Pages, Releases) "
    "e forneça 3–5 passos práticos. Responda em português. Estruture em:\n"
    "- Opção recomendada:\n- Por quê:\n- Passos:\n"
    "Pedido do usuário: "
)

def responder(pergunta: str) -> str:
    pergunta = (pergunta or "").strip()
    if not pergunta:
        return "Digite uma pergunta."
    msg = PROMPT_GUIDE + pergunta

    if OLLAMA_OK:
        try:
            r = ollama.chat(
                model=OLLAMA_MODEL,
                messages=[{"role": "user", "content": msg}],
                options={"temperature": 0.2}
            )
            return r["message"]["content"]
        except Exception as e:
            return f"⚠️ Falha ao consultar Ollama ({e})."

    # Fallback Transformers (Codespaces-friendly)
    return _ask_hf(msg)

# -------- UI (Gradio) --------
with gr.Blocks() as demo:
    gr.Markdown(
        f"# Hacktiba 2025 — Lab02 (GitHub advisor)\n"
        f"- Backend: **{'Ollama' if OLLAMA_OK else 'Transformers (fallback)'}**\n"
        f"- Modelo Ollama: `{OLLAMA_MODEL}` • Host: `{OLLAMA_HOST}`\n"
        f"- Fallback HF: `{HF_MODEL}`"
    )
    entrada = gr.Textbox(label="Pergunta", placeholder="Ex.: Quero automatizar build e testes…")
    saida = gr.Textbox(label="Resposta")
    gr.Button("Enviar").click(responder, inputs=entrada, outputs=saida)

demo.launch(server_name="0.0.0.0", server_port=PORT)
