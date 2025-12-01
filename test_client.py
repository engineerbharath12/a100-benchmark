import time
import requests
import sys
import os
import random
import string

INGESTION_URL = "http://localhost:80"

# Configuration from Environment
INPUT_TOKENS = int(os.getenv("INPUT_TOKENS", 1000))
OUTPUT_TOKENS = int(os.getenv("OUTPUT_TOKENS", 500))

def generate_prefixed_prompt(total_tokens=1000):
    """
    Generates a prompt where:
    - First 50% is a FIXED prefix (System Prompt / Context).
    - Last 50% is RANDOM (User Query).
    - Ensures Prefix Caching logic is exercised.
    """
    prefix_tokens = total_tokens // 2
    variable_tokens = total_tokens - prefix_tokens
    
    print(f"Generating Prompt: Total={total_tokens}, Prefix={prefix_tokens}, Variable={variable_tokens}")
    
    # 1. Fixed Prefix (Simulating a long system prompt or RAG context)
    # Using a repeating recognizable pattern
    fixed_part = "SYSTEM_CONTEXT_PREFIX_BLOCK_CACHED_ " * (prefix_tokens // 5)
    
    # 2. Variable Part (Simulating unique user query)
    # Using random words to avoid cache hits on this part
    random_part = ''.join(random.choices(string.ascii_letters + " ", k=variable_tokens * 4))
    
    return fixed_part + "\n" + random_part

def run_test():
    print(f"--- Benchmark Configuration ---")
    print(f"Target Input Tokens:  {INPUT_TOKENS}")
    print(f"Target Output Tokens: {OUTPUT_TOKENS}")
    print(f"-------------------------------")

    prompt = generate_prefixed_prompt(INPUT_TOKENS)
    print(f"Payload Size: {len(prompt)} chars")
    
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
    print(f"Polling for results (generating {OUTPUT_TOKENS} tokens)...")
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
        
        time.sleep(0.1)

if __name__ == "__main__":
    run_test()
