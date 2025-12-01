#!/bin/bash
set -e

# ==============================================================================
# CONFIGURATION
# ==============================================================================
MODEL_ID="deepseek-ai/DeepSeek-R1-Distill-Qwen-32B"
VLLM_PORT=8000
REDIS_PORT=6379

# Configurable Tokens (Defaults)
export INPUT_TOKENS=${INPUT_TOKENS:-1000}
export OUTPUT_TOKENS=${OUTPUT_TOKENS:-500}

echo "=============================================================================="
echo "PHASE 1: SYSTEM PREPARATION"
echo "=============================================================================="

# 1. Install Dependencies
echo "[+] Updating apt and installing dependencies..."
sudo apt-get update -qq
sudo apt-get install -y -qq redis-server python3-pip curl netcat-openbsd

echo "[+] Installing Python libraries..."
sudo python3 -m pip install --upgrade pip --break-system-packages || sudo python3 -m pip install --upgrade pip
sudo python3 -m pip install fastapi uvicorn redis requests --break-system-packages || sudo python3 -m pip install fastapi uvicorn redis requests

# 2. Start Redis Server
if ! sudo lsof -i:$REDIS_PORT -t >/dev/null; then
    echo "[+] Starting Redis Server..."
    sudo service redis-server start || sudo redis-server --daemonize yes
else
    echo "[+] Redis is already running (Port $REDIS_PORT active)."
fi

# 3. Manage vLLM Docker Container
CONTAINER_NAME="vllm_server"

if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
    echo "[+] Container '$CONTAINER_NAME' is already running. Skipping restart."
else
    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        echo "[+] Removing stopped vLLM container..."
        docker rm $CONTAINER_NAME >/dev/null 2>&1 || true
    fi

    echo "[+] Starting vLLM Docker container..."
    echo "    Model: $MODEL_ID"
    echo "    Features: Prefix Caching Enabled"
    docker run -d \
        --name $CONTAINER_NAME \
        --gpus all \
        --shm-size 16g \
        -v $HOME/.cache/huggingface:/root/.cache/huggingface \
        -p $VLLM_PORT:8000 \
        --ipc=host \
        vllm/vllm-openai:latest \
        --model $MODEL_ID \
        --tensor-parallel-size 1 \
        --trust-remote-code \
        --max-model-len 16384 \
        --gpu-memory-utilization 0.95 \
        --enable-prefix-caching
fi

# 4. Wait for vLLM Readiness
echo "[+] Waiting for vLLM to initialize (this may take minutes for a 32B model)..."
while ! curl -s "http://localhost:$VLLM_PORT/v1/models" > /dev/null; do
    echo -n "."
    sleep 5
done
echo ""
echo "[+] vLLM is ready!"

echo "=============================================================================="
echo "PHASE 2: STARTING SERVICES"
echo "=============================================================================="
echo "Configuration: Input=${INPUT_TOKENS}, Output=${OUTPUT_TOKENS}"

# 1. Start Ingestion Server (Port 80)
if pgrep -f "uvicorn ingestion_server:app" > /dev/null; then
    echo "[+] Ingestion Server is already running."
else
    echo "[+] Starting Ingestion Server (Port 80)..."
    sudo uvicorn ingestion_server:app --host 0.0.0.0 --port 80 --reload > ingestion.log 2>&1 &
fi

# 2. Start Internal Worker (Port 8001)
# Note: We export the vars so the background process inherits them
if pgrep -f "uvicorn fastapi_server:app" > /dev/null; then
    echo "[+] Internal Worker is already running. (Restarting to apply new config)..."
    pkill -f "uvicorn fastapi_server:app"
    sleep 2
fi

echo "[+] Starting Internal Worker API (Port 8001)..."
export OUTPUT_TOKENS
uvicorn fastapi_server:app --host 0.0.0.0 --port 8001 --reload > worker.log 2>&1 &

# 3. Start Proxy
if pgrep -f "python3 proxy.py" > /dev/null; then
    echo "[+] Proxy Service is already running."
else
    echo "[+] Starting Proxy Service..."
    python3 proxy.py > proxy.log 2>&1 &
fi

echo "[+] Waiting 5s for services to stabilize..."
sleep 5

echo "[SUCCESS] Deployment Complete."
echo "Run './test.sh' to benchmark."