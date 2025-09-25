#!/bin/bash
set -e

echo "[*] Atualizando sistema..."
sudo apt update && sudo apt install -y git python3 python3-venv python3-pip curl unzip jq nmap gobuster sqlmap chromium-browser

echo "[*] Clonando repositório HexStrike AI..."
if [ ! -d "hexstrike-ai" ]; then
  git clone https://github.com/0x4m4/hexstrike-ai.git
fi
cd hexstrike-ai

echo "[*] Criando ambiente virtual..."
python3 -m venv hexstrike-env
source hexstrike-env/bin/activate

echo "[*] Instalando dependências Python..."
pip install --upgrade pip
pip install -r requirements.txt

echo "[*] Instalando Nuclei..."
if ! command -v nuclei &>/dev/null; then
  curl -s https://api.github.com/repos/projectdiscovery/nuclei/releases/latest \
  | grep "browser_download_url.*linux_amd64.zip" \
  | cut -d '"' -f 4 | wget -i -
  unzip nuclei*.zip
  sudo mv nuclei /usr/local/bin/
  rm nuclei*.zip
fi

echo "[*] Iniciando servidor MCP (background)..."
nohup python3 hexstrike_server.py --port 8888 --debug > mcp_server.log 2>&1 &
sleep 5

echo "[*] Testando saúde do MCP..."
curl -s http://localhost:8888/health | jq .

echo "[*] === Ataque Simulado ==="
echo "[*] Rodando análise em exemplo.com via MCP..."
curl -s -X POST http://localhost:8888/api/intelligence/analyze-target \
  -H "Content-Type: application/json" \
  -d '{"target": "example.com", "analysis_type": "comprehensive"}' | jq .

echo "[*] === Defesa / Monitoramento ==="
echo "→ Logs em tempo real:"
tail -n 20 -f mcp_server.log
