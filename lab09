#!/usr/bin/env bash
# start.sh - instala e configura ambiente Promptfoo + Ollama localmente
# Uso: chmod +x start.sh && ./start.sh
# Variáveis exportáveis:
#   MODEL         -> modelo a puxar (padrão: "smollm2:135m" - ajuste conforme disponível)
#   PULL_MODEL    -> "true" ou "false" (padrão: "true")
#   OLLAMA_PORT   -> porta do ollama (padrão: 11434)
#   USE_DOCKER    -> "true" para usar docker (não instalar diretamente ollama), padrão "false"

set -euo pipefail
IFS=$'\n\t'

# --- Configuração padrão (sobreponha via environment)
MODEL="${MODEL:-smollm2:135m}"
PULL_MODEL="${PULL_MODEL:-true}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
USE_DOCKER="${USE_DOCKER:-false}"
WORKDIR="${WORKDIR:-${PWD}/promptfoo-ollama}"
OLLAMA_INSTALL_SCRIPT="${OLLAMA_INSTALL_SCRIPT:-https://ollama.com/install.sh}"
NODE_VERSION="${NODE_VERSION:-20}"
LOGFILE="${WORKDIR}/ollama-serve.log"

echo "=== Promptfoo + Ollama starter ==="
echo "Workdir: $WORKDIR"
echo "MODEL: $MODEL   PULL_MODEL: $PULL_MODEL   OLLAMA_PORT: $OLLAMA_PORT   USE_DOCKER: $USE_DOCKER"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

# --- helper functions
cmd_exists() { command -v "$1" >/dev/null 2>&1; }

safe_sudo() {
  if cmd_exists sudo; then
    sudo "$@"
  else
    "$@"
  fi
}

# --- 0) Basic packages (only try, do not fail if not available)
echo "[1/8] Verificando dependências básicas (curl, git, lsof)..."
if ! cmd_exists curl; then
  echo " - curl não encontrado. Tentando instalar..."
  if cmd_exists apt-get; then safe_sudo apt-get update && safe_sudo apt-get install -y curl git lsof || true; fi
  if cmd_exists yum; then safe_sudo yum install -y curl git lsof || true; fi
fi

# --- 1) Ollama (instalação ou opção Docker)
if [ "$USE_DOCKER" = "true" ]; then
  echo "[2/8] Modo DOCKER selecionado: verificando docker..."
  if ! cmd_exists docker; then
    echo " - Docker não instalado. Instale Docker manualmente ou defina USE_DOCKER=false e reexecute."
    exit 1
  fi
  # start ollama docker container (idempotente)
  if ! docker ps --format '{{.Ports}}{{.Names}}' | grep -q "11434"; then
    echo " - Subindo container Ollama (porta $OLLAMA_PORT -> 11434)..."
    docker run -d --name ollama-local -p "${OLLAMA_PORT}:11434" \
      -v ollama-data:/root/.ollama \
      ollama/ollama:latest >/dev/null
    sleep 3
  else
    echo " - Container Ollama parece já estar em execução."
  fi
else
  echo "[2/8] Modo LOCAL Ollama: verificando comando 'ollama'..."
  if ! cmd_exists ollama; then
    echo " - 'ollama' não encontrado. Instalando via script oficial..."
    # tentativa de instalar; instalação pode exigir interação/sudo dependendo do sistema
    /bin/sh -c "$(curl -fsSL ${OLLAMA_INSTALL_SCRIPT})"
    if ! cmd_exists ollama; then
      echo " - Atenção: 'ollama' continua não disponível no PATH. Verifique a instalação e reexecute."
      echo " - Se você instalou e precisar recarregar shell, abra uma nova sessão e reexecute este script."
      exit 1
    fi
  else
    echo " - 'ollama' já instalado."
  fi

  # start serve if not listening
  if ! lsof -iTCP:"${OLLAMA_PORT}" -sTCP:LISTEN -t >/dev/null 2>&1; then
    echo " - Iniciando 'ollama serve' em background (logs -> $LOGFILE)..."
    # nohup para deixar em background; redireciona saída
    nohup ollama serve > "$LOGFILE" 2>&1 &
    # aguarda brevemente e verifica
    sleep 2
    if ! lsof -iTCP:"${OLLAMA_PORT}" -sTCP:LISTEN -t >/dev/null 2>&1; then
      echo " - Falha ao iniciar ollama serve. Verifique $LOGFILE"
      tail -n 50 "$LOGFILE" || true
      exit 1
    fi
  else
    echo " - Porta $OLLAMA_PORT já em uso (ollama possivelmente em execução)."
  fi
fi

# --- 2) Pull model (opcional)
if [ "${PULL_MODEL}" = "true" ]; then
  echo "[3/8] Fazendo pull do modelo: $MODEL (pode levar tempo)..."
  set +e
  if [ "$USE_DOCKER" = "true" ]; then
    docker exec -i ollama-local ollama pull "${MODEL}" >/dev/null 2>&1 || true
  else
    ollama pull "${MODEL}" >/dev/null 2>&1 || true
  fi
  set -e
  echo " - Pull finalizado (ou já presente)."
else
  echo "[3/8] PULAR pull do modelo conforme PULL_MODEL=false."
fi

# --- 3) Node / nvm / npm
echo "[4/8] Verificando Node / npm..."
if ! cmd_exists node || ! cmd_exists npm; then
  echo " - Node/npm não encontrados. Instalando nvm + Node ${NODE_VERSION}..."
  if [ ! -d "${HOME}/.nvm" ]; then
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.4/install.sh | bash
  fi
  export NVM_DIR="${HOME}/.nvm"
  # shellcheck disable=SC1090
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
  nvm install "${NODE_VERSION}"
  nvm use "${NODE_VERSION}"
else
  echo " - Node/NPM já presentes."
fi

# --- 4) promptfoo (npm)
echo "[5/8] Instalando promptfoo globalmente (npm) se necessário..."
if ! cmd_exists promptfoo; then
  npm install -g promptfoo@latest
else
  echo " - promptfoo já instalado."
fi

# --- 5) Criar arquivos de configuração promptfoo (idempotente)
echo "[6/8] Gerando arquivos de configuração (promptfooconfig.yaml, .promptfoo-vars.yaml, run_redteam.sh)..."

# promptfooconfig.yaml: provider HTTP apontando para Ollama
cat > promptfooconfig.yaml <<'YAML'
# promptfooconfig.yaml - example wired to local Ollama HTTP provider
providers:
  - id: ollama_local_http
    config:
      url: 'http://127.0.0.1:11434/v1/chat/completions'
      request: |
        POST /v1/chat/completions HTTP/1.1
        Host: 127.0.0.1:11434
        Content-Type: application/json

        {
          "model": "{{model}}",
          "messages": [
            {"role": "system", "content": "You are a helpful assistant."},
            {"role": "user", "content": "{{prompt}}"}
          ],
          "stream": false
        }
      transformResponse: 'json.choices[0].message.content'
tests:
  - id: sample-test
    name: "Sample prompt test"
    prompt: |
      Translate the following sentence to Portuguese:
      "Security is a process, not a product."
    vars:
      model: "{{default_model}}"
    assertions:
      - contains: "Segurança"
redteam:
  provider: ollama_local_http
  targets:
    - id: ollama_local_http
      label: "local-ollama"
  plugins:
    - jailbreak
    - prompt-injection
  injectVar: "{{prompt}}"
  numTests: 3
YAML

cat > .promptfoo-vars.yaml <<EOF
default_model: "${MODEL}"
EOF

cat > run_redteam.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo "Executando promptfoo redteam (config: promptfooconfig.yaml)..."
promptfoo redteam run --config promptfooconfig.yaml
SH
chmod +x run_redteam.sh

# --- 6) Mensagens finais
echo "[7/8] Pronto! Artefatos gerados em: $(pwd)"
ls -1 promptfooconfig.yaml .promptfoo-vars.yaml run_redteam.sh || true

echo ""
echo "=== Como usar ==="
echo "1) Se estiver no modo local (USE_DOCKER=false):"
echo "   - Verifique logs do Ollama: tail -F \"$LOGFILE\""
echo "   - Rode: ./run_redteam.sh"
echo ""
echo "2) Se tiver problemas com 'ollama' no PATH depois da instalação, abra uma nova shell (ou reinicie o terminal) e reexecute o script."
echo ""
echo "=== Notas de segurança e operação ==="
echo "- NÃO exponha a porta $OLLAMA_PORT publicamente sem autenticação/firewall."
echo "- Em CI ou servidores públicos prefira rodar o Ollama dentro de container protegido ou em rede privada."
echo "- Modelos grandes exigem muita RAM/CPU/GPU: ajuste MODEL conforme sua infra."
echo ""
echo "Se quiser, gero também:"
echo " - Dockerfile + docker-compose para subir Ollama + promptfoo em containers (útil para CI)."
echo " - Um conjunto de tests/examples em tests/*.md para rodar com promptfoo."
echo ""
echo "[8/8] FIM - Script executado com sucesso."
