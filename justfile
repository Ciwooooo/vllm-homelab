# justfile — vLLM homelab operations
# Run from the repo root on the server, with kubectl configured.

set shell := ["bash", "-euo", "pipefail", "-c"]

namespace := "vllm"
release := "vllm"
chart := "./helm/vllm"

# Show available recipes
default:
    @just --list

# ---------------------------------------------------------------------------
# Deployment
# ---------------------------------------------------------------------------

# Install or upgrade the vLLM release from values.yaml
deploy:
    helm upgrade --install {{release}} {{chart}} -n {{namespace}} --create-namespace --wait --timeout 20m

# Switch models without editing values.yaml.
# Usage: just switch-model Qwen/Qwen3-4B-AWQ awq
#        just switch-model Qwen/Qwen3-1.7B
# Empty quantization lets vLLM auto-detect from the model's config.json.
switch-model model quantization="":
    helm upgrade {{release}} {{chart}} -n {{namespace}} --set model.name={{model}} --set model.quantization={{quantization}} --wait --timeout 20m

# Roll back to the previous release revision
rollback:
    helm rollback {{release}} -n {{namespace}}
    kubectl rollout status deployment/{{release}} -n {{namespace}} --timeout=20m

# Release status and revision history
status:
    @helm status {{release}} -n {{namespace}}
    @helm history {{release}} -n {{namespace}}
    @kubectl get pods -n {{namespace}}

# ---------------------------------------------------------------------------
# Operations
# ---------------------------------------------------------------------------

# Follow vLLM logs
logs:
    kubectl logs -n {{namespace}} -l app.kubernetes.io/name=vllm -f

# Tunnel the API to localhost:8000 (blocks — run in its own terminal)
forward:
    kubectl port-forward -n {{namespace}} svc/{{release}} 8000:8000

# Send a test completion. Requires `just forward` running.
# Usage: just test-api Qwen/Qwen3-4B-AWQ
test-api model:
    curl -s http://localhost:8000/v1/chat/completions -H "Content-Type: application/json" -d '{"model":"{{model}}","messages":[{"role":"user","content":"Say hello in one sentence."}],"max_tokens":50}' | python3 -m json.tool

# GPU memory currently held by the vLLM process
gpu:
    #!/usr/bin/env bash
    set -euo pipefail
    pod=$(kubectl get pods -n {{namespace}} -l app.kubernetes.io/name=vllm -o jsonpath='{.items[0].metadata.name}')
    kubectl exec -n {{namespace}} "$pod" -- nvidia-smi --query-compute-apps=pid,used_memory --format=csv

# ---------------------------------------------------------------------------
# Model cache (PVC)
# ---------------------------------------------------------------------------

# List models cached on the PVC, with sizes
list-models:
    #!/usr/bin/env bash
    set -euo pipefail
    pod=$(kubectl get pods -n {{namespace}} -l app.kubernetes.io/name=vllm -o jsonpath='{.items[0].metadata.name}')
    kubectl exec -n {{namespace}} "$pod" -- sh -c 'du -sh /root/.cache/huggingface/hub/*/ 2>/dev/null || echo "no models cached"'

# Total space used by the model cache
cache-usage:
    #!/usr/bin/env bash
    set -euo pipefail
    pod=$(kubectl get pods -n {{namespace}} -l app.kubernetes.io/name=vllm -o jsonpath='{.items[0].metadata.name}')
    kubectl exec -n {{namespace}} "$pod" -- du -sh /root/.cache/huggingface

# Delete a cached model from the PVC.
# Usage: just delete-model Qwen/Qwen3-1.7B
delete-model model:
    #!/usr/bin/env bash
    set -euo pipefail
    pod=$(kubectl get pods -n {{namespace}} -l app.kubernetes.io/name=vllm -o jsonpath='{.items[0].metadata.name}')
    dir="models--$(echo "{{model}}" | sed 's#/#--#')"
    echo "This will permanently delete: ${dir}"
    read -p "Continue? [y/N] " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "Aborted."
        exit 1
    fi
    kubectl exec -n {{namespace}} "$pod" -- rm -rf "/root/.cache/huggingface/hub/${dir}"
    echo "Deleted ${dir}"
