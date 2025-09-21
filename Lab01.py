#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os, json
from typing import List
from transformers import pipeline

def parse_perguntas(raw: str) -> List[str]:
    raw = (raw or "").strip()
    try:
        data = json.loads(raw)
        if isinstance(data, list):
            return [str(x) for x in data]
        return [str(data)]
    except Exception:
        return [p.strip() for p in raw.split("||") if p.strip()]

def main():
    raw = os.environ.get("LAB01_PERGUNTAS", "")
    if not raw:
        raise SystemExit("❌ LAB01_PERGUNTAS vazio")

    perguntas = parse_perguntas(raw)
    model_name = os.environ.get("LAB01_MODEL", "sshleifer/tiny-gpt2")
    max_tokens = int(os.environ.get("LAB01_TAMANHO", "40"))

    print(f"[info] Usando modelo: {model_name} | tamanho: {max_tokens}")

    gen = pipeline("text-generation", model=model_name)

    for q in perguntas:
        out = gen(q, max_new_tokens=max_tokens, num_return_sequences=1)[0]["generated_text"]
        resp = out.replace("\n", " ").strip()
        print(f"**Pergunta:** {q}")
        print(f"**Resposta:** {resp}\n")

if __name__ == "__main__":
    main()
