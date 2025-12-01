import redis
import requests
import sys

r = redis.Redis(host='localhost', port=6379, db=0, decode_responses=True)
WORKER_URL = "http://localhost:8001/invoke"

print("Proxy started. Waiting for jobs in 'job_queue'...")
sys.stdout.flush()

while True:
    # Blocking pop from Redis (waits indefinitely)
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