#!/bin/bash
set -e

# ==============================================================================
# CONFIGURATION
# ==============================================================================
# Using the 32B model as requested.
# Note: This requires significant VRAM (approx 64GB in FP16 or 40GB in 8-bit).
MODEL_ID="deepseek-ai/DeepSeek-R1-Distill-Qwen-32B"
VLLM_PORT=8000
INGESTION_PORT=80
INTERNAL_WORKER_PORT=8001
REDIS_HOST="localhost"
REDIS_PORT=6379

echo "=============================================================================="
echo "PHASE 1: INSTALLATION & INFRASTRUCTURE"
echo "=============================================================================="

# 1. Install Dependencies
echo "[+] Updating apt and installing dependencies..."
sudo apt-get update -qq
sudo apt-get install -y -qq redis-server python3-pip curl

echo "[+] Installing Python libraries..."
# Try installing with --break-system-packages (for newer Debian/Ubuntu), fallback to normal if that fails or flag is unknown
sudo python3 -m pip install --upgrade pip --break-system-packages || sudo python3 -m pip install --upgrade pip
sudo python3 -m pip install fastapi uvicorn redis requests --break-system-packages || sudo python3 -m pip install fastapi uvicorn redis requests

# 2. Start Redis Server
echo "[+] Starting Redis Server..."
sudo service redis-server start

# 3. Manage vLLM Docker Container
CONTAINER_NAME="vllm_server"

if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
    echo "[+] Removing existing vLLM container..."
    docker stop $CONTAINER_NAME >/dev/null 2>&1 || true
    docker rm $CONTAINER_NAME >/dev/null 2>&1 || true
fi

echo "[+] Starting vLLM Docker container..."
echo "    Model: $MODEL_ID"
echo "    Context: 16384 tokens (to support 8k in + 6k out)"
# We set --max-model-len to 16384 to ensure we can handle the large input+output.
docker run -d \
    --name $CONTAINER_NAME \
    --gpus all \
    --shm-size 16g \
    -p $VLLM_PORT:8000 \
    --ipc=host \
    vllm/vllm-openai:latest \
    --model $MODEL_ID \
    --tensor-parallel-size 1 \
    --trust-remote-code \
    --max-model-len 16384 \
    --gpu-memory-utilization 0.95

# 4. Wait for vLLM to be ready
echo "[+] Waiting for vLLM to initialize (this may take minutes for a 32B model)..."
while ! curl -s "http://localhost:$VLLM_PORT/v1/models" > /dev/null; do
    echo -n "."
    sleep 5
done
echo ""
echo "[+] vLLM is ready!"

echo "=============================================================================="
echo "PHASE 2: PYTHON IMPLEMENTATION (GENERATING FILES)"
echo "=============================================================================="

# A. Ingestion Server (Port 80)
cat << 'EOF' > ingestion_server.py
import uuid
import redis
from fastapi import FastAPI
from pydantic import BaseModel

app = FastAPI()
r = redis.Redis(host='localhost', port=6379, db=0, decode_responses=True)

class JobRequest(BaseModel):
    prompt: str

@app.post("/submit_job")
async def submit_job(job: JobRequest):
    job_id = str(uuid.uuid4())
    # Push job to Redis Queue (List)
    r.lpush("job_queue", f"{job_id}|{job.prompt}")
    return {"job_id": job_id}

@app.get("/get_result/{job_id}")
async def get_result(job_id: str):
    # Check if result exists
    result_data = r.get(job_id)
    if result_data:
        return {"status": "completed", "result": result_data}
    return {"status": "pending"}
EOF
echo "[+] Created ingestion_server.py"

# B. Proxy Worker
cat << 'EOF' > proxy.py
import redis
import requests
import time
import sys

r = redis.Redis(host='localhost', port=6379, db=0, decode_responses=True)
WORKER_URL = "http://localhost:8001/invoke"

print("Proxy started. Waiting for jobs in 'job_queue'...")
sys.stdout.flush()

while True:
    # Blocking pop from Redis
    job = r.blpop("job_queue", timeout=0)
    if job:
        _, job_data = job
        try:
            job_id, prompt = job_data.split("|", 1)
            print(f"Processing Job: {job_id} (Prompt Length: {len(prompt)})")
            
            # Forward to Internal FastAPI Worker
            payload = {"job_id": job_id, "prompt": prompt}
            try:
                requests.post(WORKER_URL, json=payload)
            except Exception as e:
                print(f"Error calling worker: {e}")
            sys.stdout.flush()
                
        except ValueError:
            print("Invalid job format received.")
            sys.stdout.flush()
EOF
echo "[+] Created proxy.py"

# C. Internal FastAPI Server (Port 8001)
cat << 'EOF' > fastapi_server.py
import time
import redis
import requests
from fastapi import FastAPI
from pydantic import BaseModel

app = FastAPI()
r = redis.Redis(host='localhost', port=6379, db=0, decode_responses=True)
VLLM_URL = "http://localhost:8000/v1/completions"

class WorkerPayload(BaseModel):
    job_id: str
    prompt: str

@app.post("/invoke")
async def invoke(payload: WorkerPayload):
    print(f"Worker received job {payload.job_id}")
    # 1. Start Inference Timer
    start_time = time.time()
    
    # 2. Call vLLM
    # Requesting 6000 tokens of output.
    vllm_payload = {
        "model": "deepseek-ai/DeepSeek-R1-Distill-Qwen-32B",
        "prompt": payload.prompt,
        "max_tokens": 6000,
        "temperature": 0.7
    }
    
    generated_text = ""
    try:
        response = requests.post(VLLM_URL, json=vllm_payload)
        response.raise_for_status()
        response_json = response.json()
        generated_text = response_json['choices'][0]['text']
    except Exception as e:
        print(f"vLLM Error: {e}")
        if 'response' in locals():
            print(f"Response: {response.text}")
        generated_text = f"Error: {str(e)}"

    # 3. Stop Inference Timer
    end_time = time.time()
    inference_time = end_time - start_time
    
    # 4. Store Result in Redis
    # Storing length of output to verify the 6k requirement
    output_len = len(generated_text)
    final_result = f"Inference Time: {inference_time:.4f}s | Output Length: {output_len} chars"
    r.set(payload.job_id, final_result)
    
    return {"status": "processed", "inference_time": inference_time}
EOF
echo "[+] Created fastapi_server.py"

# D. Test Client
cat << 'EOF' > test_client.py
import time
import requests
import sys

INGESTION_URL = "http://localhost:80"

def generate_large_prompt(target_tokens=8000):
    # Approximation: 1 token ~= 4 characters in English
    # We repeat a phrase to hit the target size.
    base_word = "repetition " 
    # 11 chars per word (including space) ~= 2.75 tokens?
    # Let's use a simpler metric: "the " is 1 token.
    # To get 8000 tokens, we need roughly 8000 words if they are simple.
    # Let's be safe and generate 32000 characters of text.
    print(f"Generating input payload for ~{target_tokens} tokens...")
    return "word " * target_tokens

def run_test():
    prompt = generate_large_prompt(8000)
    print(f"Sending payload size: {len(prompt)} characters")
    
    # 1. Start Overall Timer
    start_time = time.time()
    
    # 2. Submit Job
    try:
        resp = requests.post(f"{INGESTION_URL}/submit_job", json={"prompt": prompt})
        resp.raise_for_status()
        job_id = resp.json()["job_id"]
        print(f"Job submitted. ID: {job_id}")
    except Exception as e:
        print(f"Failed to submit job: {e}")
        return

    # 3. Poll for Result
    print("Polling for results (this will take time due to 6k token generation)...")
    while True:
        try:
            resp = requests.get(f"{INGESTION_URL}/get_result/{job_id}")
            data = resp.json()
            
            if data["status"] == "completed":
                # 4. Stop Overall Timer
                end_time = time.time()
                overall_time = end_time - start_time
                
                result_text = data["result"]
                print("\n" + "="*40)
                print("BENCHMARK REPORT")
                print("="*40)
                print(f"Result: {result_text}")
                print("-" * 20)
                print(f"Overall Request Time: {overall_time:.4f}s")
                print("="*40)
                break
        except Exception as e:
            print(f"Error polling: {e}")
        
        time.sleep(2)

if __name__ == "__main__":
    run_test()
EOF
echo "[+] Created test_client.py"


echo "=============================================================================="
echo "PHASE 3: EXECUTION & TESTING"
echo "=============================================================================="

# 1. Start Ingestion Server (Port 80)
echo "[+] Starting Ingestion Server (Port 80)..."
sudo uvicorn ingestion_server:app --host 0.0.0.0 --port 80 > ingestion.log 2>&1 &
echo "[+] Ingestion Server running in background."

# 2. Start Internal Worker (Port 8001)
echo "[+] Starting Internal Worker API (Port 8001)..."
uvicorn fastapi_server:app --host 0.0.0.0 --port 8001 > worker.log 2>&1 &
echo "[+] Internal Worker running in background."

# 3. Start Proxy
echo "[+] Starting Proxy Service..."
python3 proxy.py > proxy.log 2>&1 &
echo "[+] Proxy running in background."

# Wait for servers to spin up
echo "[+] Waiting 5s for services to stabilize..."
sleep 5

# 4. Run Benchmark
echo "[+] Running Benchmark Client..."
python3 test_client.py

echo ""
echo "=============================================================================="
echo "TEST COMPLETE"
echo "=============================================================================="
echo "Processes are still running as requested."
echo "Logs available in: ingestion.log, worker.log, proxy.log"
