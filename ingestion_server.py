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
    result_data = r.get(job_id)
    if result_data:
        return {"status": "completed", "result": result_data}
    return {"status": "pending"}