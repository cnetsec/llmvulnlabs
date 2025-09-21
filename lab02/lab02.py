import os
import gradio as gr

try:
    import ollama
except ImportError:
    raise SystemExit("⚠️ Biblioteca 'ollama' não instalada. Rode: pip install ollama")

# Modelo Ollama (default: llama2)
MODEL = os.environ.get("LAB02_MODEL", "llama2")

def responder(pergunta: str) -> str:
    """Envia a pergunta ao Ollama e retorna a resposta."""
    try:
        resp = ollama.chat(
            model=MODEL,
            messages=[{"role": "user", "content": pergunta}]
        )
        return resp["message"]["content"]
    except Exception as e:
        return f"⚠️ Erro ao consultar modelo Ollama: {e}"

with gr.Blocks() as demo:
    gr.Markdown(f"# Hacktiba 2025 — Lab02 (Ollama)\nUsando modelo: **{MODEL}**")

    entrada = gr.Textbox(label="Pergunta", placeholder="Digite sua pergunta aqui...")
    saida = gr.Textbox(label="Resposta do modelo")

    btn = gr.Button("Enviar")
    btn.click(responder, inputs=entrada, outputs=saida)

demo.launch(server_name="0.0.0.0", server_port=7860)
