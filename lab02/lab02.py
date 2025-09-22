import os
import gradio as gr
import ollama  # garante que você já tem o ollama instalado/rodando

# -------- Config --------
OLLAMA_HOST = os.environ.get("OLLAMA_HOST", "http://127.0.0.1:11434")
OLLAMA_MODEL = os.environ.get("LAB02_MODEL", "llama3.1:8b")
PORT = int(os.environ.get("LAB02_PORT", "7860"))

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
Você é o **assistente oficial do Hacktiba 2025**.
Use o contexto abaixo sempre que responder.
Responda em português, de forma clara, completa e organizada.

{HACKTIBA_CONTEXT}

Agora responda à pergunta do usuário:
"""

# -------- Função principal --------
def responder(pergunta: str) -> str:
    if not pergunta.strip():
        return "Digite uma pergunta sobre o Hacktiba."
    try:
        r = ollama.chat(
            model=OLLAMA_MODEL,
            messages=[
                {"role": "system", "content": PROMPT_GUIDE},
                {"role": "user", "content": pergunta}
            ],
            options={"temperature": 0.2}
        )
        return r["message"]["content"]
    except Exception as e:
        return f"⚠️ Erro ao consultar Ollama: {e}"

# -------- UI (Gradio) --------
with gr.Blocks() as demo:
    gr.Markdown(
        f"# Hacktiba 2025 — Assistente Oficial\n"
        f"- Backend: **Ollama**\n"
        f"- Modelo: `{OLLAMA_MODEL}` • Host: `{OLLAMA_HOST}`"
    )
    entrada = gr.Textbox(label="Pergunta sobre o Hacktiba", placeholder="Ex.: Qual a missão do evento?")
    saida = gr.Textbox(label="Resposta", lines=10)
    gr.Button("Enviar").click(responder, inputs=entrada, outputs=saida)

demo.launch(server_name="0.0.0.0", server_port=PORT)
