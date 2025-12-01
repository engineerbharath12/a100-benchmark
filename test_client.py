import time
import requests
import os
import io
import random
import string
from reportlab.pdfgen import canvas
from reportlab.lib.pagesizes import letter

INGESTION_URL = "http://localhost:80"

# Configuration
INPUT_TOKENS = int(os.getenv("INPUT_TOKENS", 2000)) # Default 2000 for ~4 pages
OUTPUT_TOKENS = int(os.getenv("OUTPUT_TOKENS", 500))

def generate_heavy_pdf_bytes(target_tokens=6000):
    """
    Generates a PDF file in memory with enough text to match target_tokens.
    """
    print(f"Generating PDF with approx {target_tokens} tokens...")
    buffer = io.BytesIO()
    c = canvas.Canvas(buffer, pagesize=letter)
    width, height = letter
    
    # Approx 500 words (tokens) per page to keep it dense
    words_per_page = 500
    total_pages = max(1, target_tokens // words_per_page)
    
    print(f"  - Pages: {total_pages}")
    
    # Use real words to ensure predictable tokenization (~0.75 tokens/word)
    base_sentence = "The quick brown fox jumps over the lazy dog and runs away to the distributed system benchmark. "
    
    for page_num in range(total_pages):
        text_object = c.beginText(40, height - 40)
        text_object.setFont("Helvetica", 10)
        
        # Generate text block using repetitions
        # 1 sentence is ~15 words. We need 500 words -> ~33 repetitions
        page_content = f"PAGE {page_num} " + (base_sentence * 35)
        
        # Split into lines (dumb wrapping)
        lines = [page_content[i:i+100] for i in range(0, len(page_content), 100)]
        
        for line in lines:
            text_object.textLine(line)
            
        c.drawText(text_object)
        c.showPage()
        
    c.save()
    buffer.seek(0)
    print(f"  - PDF Size: {len(buffer.getbuffer()) / 1024:.2f} KB")
    return buffer

def run_test():
    # 1. Generate PDF
    pdf_buffer = generate_heavy_pdf_bytes(INPUT_TOKENS)
    
    # 2. Start Overall Timer
    start_time = time.time()
    
    # 3. Submit Job (File Upload)
    print("Uploading PDF...")
    files = {'file': ('test_doc.pdf', pdf_buffer, 'application/pdf')}
    
    try:
        resp = requests.post(f"{INGESTION_URL}/submit_job", files=files)
        resp.raise_for_status()
        data = resp.json()
        job_id = data["job_id"]
        proc_time = data.get("processing_time", 0)
        print(f"Job submitted. ID: {job_id}")
        print(f"Server-Side PDF Processing Time: {proc_time:.4f}s")
    except Exception as e:
        print(f"Failed to submit job: {e}")
        if 'resp' in locals():
            print(resp.text)
        return

    # 4. Poll for Result
    print(f"Polling for results...")
    while True:
        try:
            resp = requests.get(f"{INGESTION_URL}/get_result/{job_id}")
            data = resp.json()
            
            if data["status"] == "completed":
                end_time = time.time()
                overall_time = end_time - start_time
                
                result_text = data["result"]
                print("\n" + "="*40)
                print("BENCHMARK REPORT (PDF TEST)")
                print("="*40)
                print(f"Server PDF Parsing Overhead: {proc_time:.4f}s")
                print("-" * 20)
                # Parse inference time from result string
                # Format: "Inference Time: 26.1234s | Output..."
                try:
                    inf_time_str = result_text.split("|")[0].split(":")[1].strip().replace("s", "")
                    inf_time = float(inf_time_str)
                    print(f"LLM Inference Time:        {inf_time:.4f}s")
                    
                    # Calculate true overhead
                    # Overall = (Upload + Parsing + Queue + Inference + Network)
                    # System Overhead = Overall - Inference
                    overhead = overall_time - inf_time
                    print(f"Total System Overhead:     {overhead:.4f}s")
                    print(f"  (Parsing accounted for:  {proc_time:.4f}s)")
                except:
                    print(f"Raw Result: {result_text}")
                
                print(f"Overall Request Time:      {overall_time:.4f}s")
                print("="*40)
                break
        except Exception as e:
            print(f"Error polling: {e}")
        
        time.sleep(0.1)

if __name__ == "__main__":
    run_test()