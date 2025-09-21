#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os, json
from typing import List

class ZephyrApp:
    def __init__(self):
        self._history: List[str] = []
    def reset(self):
        self._history.clear()
    def chat(self, prompt: str) -> str:
        return f"[resposta] {prompt}"

def main():
    raw = os.environ.get("LAB01_PERGUNTAS", "").strip()
    if not raw:
        raise SystemExit(1)
    try:
        perguntas = json.loads(raw)
        if not isinstance(perguntas, list):
            perguntas = [str(perguntas)]
    except Exception:
        perguntas = [p.strip() for p in raw.split("||") if p.strip()]
    app = ZephyrApp()
    for q in perguntas:
        app.reset()
        resp = app.chat(q)
        print(f"**Pergunta:** {q}")
        print(f"**Resposta:** {resp}\n")

if __name__ == "__main__":
    main()
