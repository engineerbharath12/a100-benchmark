# Distributed LLM Inference Benchmark System

A scalable, high-performance distributed architecture for serving Large Language Models (LLMs) using **Redis**, **FastAPI**, and **vLLM**.

## 🏗 System Architecture

This project implements a decoupled **Producer-Consumer** pattern to handle heavy LLM inference workloads efficiently:

1.  **Ingestion Server (FastAPI, Port 80):** Accepts jobs, returns a Job ID instantly, and offloads work to Redis.
2.  **Job Queue (Redis, Port 6379):** Acts as the high-speed, in-memory message broker.
3.  **Proxy Worker (Python):** Uses **Blocking Pop** to instantly consume jobs from Redis without polling latency.
4.  **Inference Worker (FastAPI, Port 8001):** Manages the communication with the inference engine and measures GPU execution time.
5.  **Inference Engine (vLLM, Port 8000):** Hosting `deepseek-ai/DeepSeek-R1-Distill-Qwen-32B` with **Prefix Caching** enabled for maximum throughput.

---

## ✅ Prerequisites

Before running this system, ensure your environment meets these requirements:

*   **Operating System:** Linux (Debian/Ubuntu recommended).
*   **Hardware:** NVIDIA GPU with at least **24GB VRAM** (Required for the 32B model).
*   **Software:**
    *   Docker & NVIDIA Container Toolkit (installed and active).
    *   Python 3.10 or higher.
    *   `sudo` privileges (for installing dependencies).

---

## 🚀 Usage Guide

The system is automated via two main scripts: `deploy.sh` (Infrastructure) and `test.sh` (Benchmark).

### 1. Deploy the System
This script installs dependencies, sets up Redis/vLLM, and launches the Python microservices.

```bash
cd llm_dist_benchmark
chmod +x deploy.sh
./deploy.sh
```

> **Note:** The first run will download the 32B model (~60GB), which may take several minutes. The script waits automatically until vLLM is ready.

### 2. Run the Benchmark
Once deployment is complete, run the end-to-end test.

```bash
chmod +x test.sh
./test.sh
```

### 3. Customizing the Benchmark
You can configure the workload size using environment variables without changing code.

**Example: Run a lighter test (500 input, 100 output)**
```bash
export INPUT_TOKENS=500
export OUTPUT_TOKENS=100
./deploy.sh   # Restart services with new config
./test.sh     # Run test
```

| Variable | Default | Description |
| :--- | :--- | :--- |
| `INPUT_TOKENS` | `1000` | Total prompt length. (Split 50/50 between Fixed Prefix and Random Suffix). |
| `OUTPUT_TOKENS` | `500` | Number of tokens the model is forced to generate. |

---

## 📊 Performance & Workflow

For a deep dive into the latency breakdown and hardware utilization, please read the [E2E_WORKFLOW.md](./E2E_WORKFLOW.md) file included in this repository.

**Typical Results (DeepSeek 32B on A100/H100):**
*   **System Overhead:** < 50ms (0.05s)
*   **Throughput:** ~22-25 tokens/sec
*   **Efficiency:** >99.8% of total request time is spent on productive GPU inference.

---

## 🛠 Troubleshooting

*   **Ports in use?**
    The script attempts to use ports `80`, `8000`, `8001`, and `6379`. Ensure these are free.
*   **"Port 80 is NOT open"?**
    Port 80 requires root privileges. Ensure `deploy.sh` ran `sudo uvicorn ...` successfully. Check `ingestion.log`.
*   **Model failing to load?**
    Check Docker logs: `docker logs vllm_server`. Ensure you have enough GPU VRAM.
