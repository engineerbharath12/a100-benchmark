#!/bin/bash
set -e

# Defaults (can be overridden by environment)
export INPUT_TOKENS=${INPUT_TOKENS:-1000}
export OUTPUT_TOKENS=${OUTPUT_TOKENS:-500}

echo "=============================================================================="
echo "PRE-FLIGHT CHECK"
echo "=============================================================================="

# Check Ports
error_found=0
for port in 6379 8000 8001 80; do
    if ! nc -z localhost $port; then
        echo "[ERROR] Port $port is NOT open. Please run ./deploy.sh first."
        error_found=1
    else
        echo "[OK] Port $port is listening."
    fi
done

if [ $error_found -eq 1 ]; then
    echo "Aborting test due to missing services."
    exit 1
fi

echo "=============================================================================="
echo "RUNNING BENCHMARK"
echo "=============================================================================="
echo "Configuration: Input=${INPUT_TOKENS}, Output=${OUTPUT_TOKENS}"

if [ ! -f "test_client.py" ]; then
    echo "[ERROR] test_client.py not found in current directory."
    exit 1
fi

python3 test_client.py