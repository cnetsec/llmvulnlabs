import os
import streamlit as st
from transformers import pipeline

MODEL = os.environ.get("LAB03_MODEL", "google/flan-t5-small")
gen = pipeline("text2text-generation", model=MODEL)

st.set_page_config(page_title="Hacktiba 2025 — Lab03 (Mobile Chat)", page_icon="📱", layout="centered")

st.markdown("""
<style>
.block-container {padding-top: 1rem; max-width: 420px;}
.user {background:#e8f0fe;border-radius:14px;padding:10px 12px;margin:6px 0;}
.assistant {background:#f1f3f4;border-radius:14px;padding:10px 12px;margin:6px 0;}
.small {font-size:12px;color:#6b7280;}
.header {display:flex;gap:8px;align-items:center;}
.header .title {font-weight:700;font-size:16px;}
</style>
""", unsafe_allow_html=True)

st.markdown('<div class="header">📱 <div class="title">Hacktiba 2025 — Lab03</div></div>', unsafe_allow_html=True)
st.caption("Chat mobile-like. Descreva o que quer fazer no GitHub (ex.: reportar bug, pedir ajuda, automatizar). Eu sugiro a melhor opção e passos rápidos.")

if "messages" not in st.session_state:
    st.session_state.messages = [
        {"role":"assistant","content":"Oi! Diga o que precisa fazer no GitHub e eu recomendo a feature ideal (Issues, Discussions, Projects, Actions, Wiki, Security/Dependabot, Codespaces, Pages, Releases) com 3–5 passos práticos."}
    ]

for m in st.session_state.messages:
    cls = "assistant" if m["role"]=="assistant" else "user"
    st.markdown(f'<div class="{cls}">{m["content"]}</div>', unsafe_allow_html=True)

def ask_model(user_text: str) -> str:
    prompt = (
        "Você é conciso. Dado o pedido do usuário, indique a MELHOR OPÇÃO NO GITHUB "
        "(Issues, Discussions, Projects, Actions, Wiki, Security/Dependabot, Codespaces, Pages, Releases) "
        "e forneça 3–5 passos práticos. Responda em português. Estruture em:\n"
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
