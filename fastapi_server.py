import time
import redis
import requests
import os
from fastapi import FastAPI
from pydantic import BaseModel

app = FastAPI()
r = redis.Redis(host='localhost', port=6379, db=0, decode_responses=True)
# Switch to Chat Completions Endpoint
VLLM_URL = "http://localhost:8000/v1/chat/completions"

# Configuration from Environment
OUTPUT_TOKENS = int(os.getenv("OUTPUT_TOKENS", 500))

class WorkerPayload(BaseModel):
    job_id: str
    prompt: str

@app.post("/invoke")
async def invoke(payload: WorkerPayload):
    print(f"Worker received job {payload.job_id}. Target Output: {OUTPUT_TOKENS} tokens.")
    start_time = time.time()
    
    # Construct Chat Messages
    messages = [
        {
            "role": "system",
            "content": "You are a helpful assistant designed to extract structured data from documents."
        },
        {
            "role": "user",
            "content": f"Please extract the invoice number and invoice date from the following document text: {payload.prompt}"
        }
    ]

    vllm_payload = {
        "model": "deepseek-ai/DeepSeek-R1-Distill-Qwen-32B",
        "messages": messages,
        "max_tokens": OUTPUT_TOKENS,
        # "min_tokens": OUTPUT_TOKENS, # min_tokens not always supported in chat API on all vllm versions, checking support
        "temperature": 0.7,
        "ignore_eos": True
    }
    
    generated_text = ""
    try:
        response = requests.post(VLLM_URL, json=vllm_payload)
        response.raise_for_status()
        response_json = response.json()
        
        if 'usage' in response_json:
             print(f"Token Usage: {response_json['usage']}")
        
        generated_text = response_json['choices'][0]['message']['content']
    except Exception as e:
        print(f"vLLM Error: {e}")
        if 'response' in locals():
            print(f"Response Body: {response.text}")
        generated_text = f"Error: {str(e)}"

    end_time = time.time()
    inference_time = end_time - start_time
    
    output_len = len(generated_text)
    final_result = f"Inference Time: {inference_time:.4f}s | Output Length: {output_len} chars"
    r.set(payload.job_id, final_result)
    
    return {"status": "processed", "inference_time": inference_time}