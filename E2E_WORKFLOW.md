# End-to-End Workflow Analysis: Distributed LLM Inference

This document details the processing steps, hardware utilization, and latency analysis for the Distributed LLM Inference Benchmark system (`vLLM` + `Redis` + `FastAPI`).

## Test Configuration
*   **Model:** `deepseek-ai/DeepSeek-R1-Distill-Qwen-32B`
*   **Input Payload:** 1000 tokens (500 fixed prefix + 500 variable).
*   **Output Generation:** Forced 500 tokens (`min_tokens=500`).
*   **Throughput Observed:** ~22.4 tokens/sec (22.31s inference time).
*   **Prefix Caching:** Enabled (optimized for repeated system prompts).

---

## Workflow & Timing Breakdown

### Step 1: Client Submission (Start of Overall Timer)
*   **Action:** The Client (`test_client.py`) generates the 1000-token prompt and sends a POST request.
*   **Hardware:** Client CPU.
*   **Metric:** **`Overall Request Time` Timer STARTS here.**

### Step 2: Ingestion & Queuing
*   **Action:** `Ingestion Server` (FastAPI) receives the request, generates a UUID, pushes the job to Redis (`LPUSH job_queue`), and returns the Job ID to the client.
*   **Hardware:** CPU (Lightweight I/O).
*   **Data:** Payload (1000 tokens) is serialized and stored in RAM (Redis).

### Step 3: Worker Dequeuing
*   **Action:** `Proxy Worker` (Background Python Process) instantly detects the job (`BLPOP`), parses it, and forwards it to the Internal Worker API.
*   **Mechanism:** Uses **Blocking Pop** to eliminate polling latency.
*   **Hardware:** CPU.

### Step 4: Inference Preparation (Start of Inference Timer)
*   **Action:** `Internal Worker` (`fastapi_server.py`) receives the job.
*   **Metric:** **`LLM Inference Time` Timer STARTS here.**
*   **Action:** Worker sends HTTP POST to vLLM Container (`localhost:8000`).

### Step 5: LLM Generation (The Heavy Lifting)
*   **Action:** vLLM receives the 1000-token prompt.
    1.  **Prefill (GPU):** Processes input tokens.
        *   *Prefix Cache Hit:* The first 500 tokens (System Context) are retrieved from GPU memory (fast).
        *   *New Computation:* The remaining 500 tokens (User Query) are processed.
    2.  **Decoding (GPU):** Autoregressively generates 500 output tokens (one by one).
*   **Hardware:** **NVIDIA GPU** (High Utilization).
*   **Data:** Input: 1000 tokens $\rightarrow$ Output: 500 tokens.

### Step 6: Result Handling (End of Inference Timer)
*   **Action:** vLLM returns the generated text to the `Internal Worker`.
*   **Metric:** **`LLM Inference Time` Timer STOPS here.** (Result: ~22.31s)
*   **Action:** Worker saves the result to Redis (`SET <job_id> <result>`).
*   **Hardware:** CPU.

### Step 7: Client Retrieval (End of Overall Timer)
*   **Action:** Client (`test_client.py`) polls `Ingestion Server` (every 0.1s), retrieves the result from Redis, and prints the report.
*   **Metric:** **`Overall Request Time` Timer STOPS here.** (Result: ~22.35s)

---

## Performance Summary

| Metric | Measured Time | Token Flow | Description |
| :--- | :--- | :--- | :--- |
| **Overall Request Time** | **22.35s** | **In:** 1000 <br> **Out:** 500 | Total time perceived by the user. |
| **LLM Inference Time** | **22.31s** | **In:** 1000 <br> **Out:** 500 | Pure processing time (GPU). |
| **System Overhead** | **0.04s** | N/A | Time spent in Redis, Python logic, and HTTP transport. |

### Why is the overhead so low?
1.  **In-Memory Broker:** Redis operations happen in microseconds.
2.  **Blocking Pop:** The worker reacts instantly to new jobs (0ms wait state).
3.  **Aggressive Polling:** The client checks for results every 100ms, minimizing the gap between "Job Done" and "Job Retrieved".
