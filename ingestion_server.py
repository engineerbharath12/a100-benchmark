import uuid
import redis
import time
import io
from fastapi import FastAPI, UploadFile, File
from pydantic import BaseModel
from pypdf import PdfReader

app = FastAPI()
r = redis.Redis(host='localhost', port=6379, db=0, decode_responses=True)

@app.post("/submit_job")
async def submit_job(file: UploadFile = File(...)):
    print(f"Received file: {file.filename}")
    
    # 1. Start PDF Processing Timer
    start_proc = time.time()
    
    # 2. Read File into Memory (CPU Bound if large)
    content = await file.read()
    pdf_file = io.BytesIO(content)
    
    # 3. Extract Text using pypdf (CPU Intensive)
    print("Starting PDF Extraction...")
    reader = PdfReader(pdf_file)
    extracted_text = ""
    for page in reader.pages:
        extracted_text += page.extract_text() + "\n"
    
    proc_time = time.time() - start_proc
    print(f"PDF Extraction Complete. Pages: {len(reader.pages)}, Time: {proc_time:.4f}s")

    # 4. Construct Structured Prompt
    # We serialize this to JSON string to pass through Redis
    # Note: We are passing the RAW TEXT, the Worker will format it for vLLM Chat API
    
    job_id = str(uuid.uuid4())
    # Push job to Redis Queue
    # We store: "job_id|EXTRACTED_TEXT"
    # Ideally we'd use a better serializer, but this keeps the pipe simple.
    # We replace pipes in text to avoid breaking our simple splitter
    safe_text = extracted_text.replace("|", " ")
    r.lpush("job_queue", f"{job_id}|{safe_text}")
    
    return {"job_id": job_id, "processing_time": proc_time}

@app.get("/get_result/{job_id}")
async def get_result(job_id: str):
    result_data = r.get(job_id)
    if result_data:
        return {"status": "completed", "result": result_data}
    return {"status": "pending"}
