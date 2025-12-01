import time
import redis
import requests
import os
from fastapi import FastAPI
from pydantic import BaseModel

app = FastAPI()
r = redis.Redis(host='localhost', port=6379, db=0, decode_responses=True)
VLLM_URL = "http://localhost:8000/v1/completions"

# Configuration from Environment
OUTPUT_TOKENS = int(os.getenv("OUTPUT_TOKENS", 500))

class WorkerPayload(BaseModel):
    job_id: str
    prompt: str

@app.post("/invoke")
async def invoke(payload: WorkerPayload):
    print(f"Worker received job {payload.job_id}. Target Output: {OUTPUT_TOKENS} tokens.")
    # 1. Start Inference Timer
    start_time = time.time()
    
    # 2. Call vLLM
    vllm_payload = {
        "model": "deepseek-ai/DeepSeek-R1-Distill-Qwen-32B",
        "prompt": payload.prompt,
        "max_tokens": OUTPUT_TOKENS,
        "min_tokens": OUTPUT_TOKENS,
        "ignore_eos": True,
        "temperature": 0.7
    }
    
    generated_text = ""
    try:
        response = requests.post(VLLM_URL, json=vllm_payload)
        response.raise_for_status()
        response_json = response.json()
        
        # Log token usage if available
        if 'usage' in response_json:
             print(f"Token Usage: {response_json['usage']}")
        
        generated_text = response_json['choices'][0]['text']
    except Exception as e:
        print(f"vLLM Error: {e}")
        generated_text = f"Error: {str(e)}"

    # 3. Stop Inference Timer
    end_time = time.time()
    inference_time = end_time - start_time
    
    # 4. Store Result in Redis
    output_len = len(generated_text)
    final_result = f"Inference Time: {inference_time:.4f}s | Output Length: {output_len} chars"
    r.set(payload.job_id, final_result)
    
    return {"status": "processed", "inference_time": inference_time}
