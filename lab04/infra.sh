#!/bin/bash
set -e

MODEL="llama3.2:1b"

# ===============================
# 0. Instalar Ollama (se não tiver)
# ===============================
if ! command -v ollama &> /dev/null
then
    echo "[*] Instalando Ollama..."
    curl -fsSL https://ollama.com/install.sh | sh
else
    echo "[*] Ollama já instalado."
fi

# ===============================
# 1. Subir Ollama
# ===============================
echo "[*] Iniciando Ollama em background..."
ollama serve > ollama.log 2>&1 &
OLLAMA_PID=$!
echo $OLLAMA_PID > ollama.pid

# Esperar Ollama responder
echo "[*] Aguardando Ollama iniciar..."
until curl -s http://127.0.0.1:11434/api/tags > /dev/null 2>&1; do
    echo "   ... esperando Ollama (pid=$OLLAMA_PID)"
    sleep 2
done
echo "[*] Ollama está pronto!"

# ===============================
# 2. Garantir modelo
# ===============================
echo "[*] Baixando/verificando modelo $MODEL..."
ollama pull $MODEL

# ===============================
# 3. Gerar config REST pro Garak
# ===============================
cat > rest_ollama.yaml <<EOF
generator:
  class: rest.RestGenerator
  config:
    method: POST
    url: http://127.0.0.1:11434/api/generate
    headers:
      Content-Type: application/json
    request_json:
      model: "$MODEL"
      prompt: "{{PROMPT}}"
      stream: false
    response_jsonpath: "$.response"
EOF

echo "[*] Config rest_ollama.yaml criada com sucesso."
echo "[*] Infra pronta! Ollama rodando em PID=$OLLAMA_PID"
