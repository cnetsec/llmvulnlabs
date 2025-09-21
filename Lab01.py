#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os, json
from transformers import pipeline

def main():
    raw = os.environ.get("LAB01_PERGUNTAS", "").strip()
    if not raw:
        raise SystemExit("❌ Nenhuma pergunta recebida.")

    try:
        perguntas = json.loads(raw)
        if not isinstance(perguntas, list):
            perguntas = [str(perguntas)]
    except Exception:
        perguntas = [p.strip() for p in raw.split("||") if p.strip()]

    # Carregar modelo local (distilgpt2 é leve e roda no Actions)
    generator = pipeline("text-generation", model="distilgpt2")

    for q in perguntas:
        resp = generator(q, max_length=50, num_return_sequences=1)
        resposta = resp[0]["generated_text"].replace("\n", " ").strip()
        print(f"**Pergunta:** {q}")
        print(f"**Resposta:** {resposta}\n")

if __name__ == "__main__":
    main()
