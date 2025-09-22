import os, json
import gradio as gr

# -------- Config --------
OLLAMA_HOST = os.environ.get("OLLAMA_HOST", "http://127.0.0.1:11434")
OLLAMA_MODEL = os.environ.get("LAB02_MODEL", "llama3.1:8b")
HF_MODEL = os.environ.get("LAB02_FALLBACK", "google/flan-t5-small")  # fallback
PORT = int(os.environ.get("LAB02_PORT", "7860"))

# -------- Fatos Hacktiba (embutidos) --------
HACKTIBA_FACTS = {
    "nome": "Hacktiba",
    "edicao": "2025",
    "slogan": "Do CVE à Correção",
    "data": "07 de fevereiro de 2026",
    "local": "Chácara Fressato, São José dos Pinhais - PR",
    "pilares": ["Comunidade", "Pesquisa Aplicada", "Labs/Demos"],
    "topicos": [
        "LLM Security",
        "DevSecOps prático",
        "AppSec em fintechs",
        "Do CVE à Correção"
    ],
    "formato": ["palestras curtas", "demonstrações", "labs leves", "networking"],
    "cta": "Traga sua pesquisa, mostre sua demo e aprenda com a comunidade.",
    "faq": [
        {"q": "Quem pode participar?", "a": "Devs, analistas, estudantes e pesquisadores."},
        {"q": "Terá hands-on?", "a": "Sim, com labs guiados e demonstrações práticas."}
    ]
}

FEW_SHOTS = [
    {
        "q": "Como participar do Hacktiba?",
        "a": (
            "- Opção recomendada: *Issues* do GitHub para inscrição e triagem.\n"
            "- Por quê: centraliza propostas de talks/demos e dúvidas.\n"
            "- Passos:\n"
            "  1. Abra uma issue com título ‘Proposta de Talk/Demo’.\n"
            "  2. Descreva tema, duração e requisitos.\n"
            "  3. Adicione links de repositório ou slides.\n"
            "  4. Organização revisa.\n"
            "  5. Confirme presença."
        )
    }
]

# -------- Checagem de Ollama --------
def _ollama_available() -> bool:
    import urllib.request, json as js
    try:
        with urllib.request.urlopen(OLLAMA_HOST + "/api/tags", timeout=2) as r:
            js.load(r)
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
        hf_pipe = pipeline("text2text-generation", model=HF_MODEL)

def _ask_hf(pergunta: str) -> str:
    _ensure_hf()
    out = hf_pipe(pergunta, max_new_tokens=180, do_sample=False, num_beams=4)[0]["generated_text"]
    return out.strip()

# -------- Prompting --------
PROMPT_GUIDE = (
    "Você é conciso. Indique a MELHOR OPÇÃO NO GITHUB "
    "(Issues, Discussions, Projects, Actions, Wiki, Security/Dependabot, Codespaces, Pages, Releases) "
    "e forneça 3–5 passos práticos.\n"
    "Responda em português e insira contexto do Hacktiba quando aplicável.\n"
    "Estruture em:\n"
    "- Opção recomendada:\n- Por quê:\n- Passos:\n\n"
)

PROMPT_EVENT = (
    f"Contexto do Evento: {HACKTIBA_FACTS['nome']} {HACKTIBA_FACTS['edicao']} — "
    f"{HACKTIBA_FACTS['slogan']}, em {HACKTIBA_FACTS['data']} no {HACKTIBA_FACTS['local']}.\n"
    f"Tópicos: {', '.join(HACKTIBA_FACTS['topicos'])}.\n"
    f"Formato: {', '.join(HACKTIBA_FACTS['formato'])}.\n"
    f"FAQ: {HACKTIBA_FACTS['faq']}.\n\n"
)

# -------- Lógica de resposta --------
def responder(pergunta: str) -> str:
    pergunta = (pergunta or "").strip()
    if not pergunta:
        return "Digite uma pergunta."

    # few-shots
    for shot in FEW_SHOTS:
        if shot["q"].lower() in pergunta.lower():
            return shot["a"]

    msg = PROMPT_GUIDE + PROMPT_EVENT + "Pedido do usuário: " + pergunta

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

    return _ask_hf(msg)

# -------- UI (Gradio) --------
with gr.Blocks() as demo:
    gr.Markdown(
        f"# Hacktiba 2025 — Lab02 (GitHub Advisor)\n"
        f"- Backend: **{'Ollama' if OLLAMA_OK else 'Transformers (fallback)'}**\n"
        f"- Modelo Ollama: `{OLLAMA_MODEL}` • Host: `{OLLAMA_HOST}`\n"
        f"- Fallback HF: `{HF_MODEL}`"
    )
    entrada = gr.Textbox(label="Pergunta", placeholder="Ex.: Quero automatizar build e testes…")
    saida = gr.Textbox(label="Resposta")
    gr.Button("Enviar").click(responder, inputs
