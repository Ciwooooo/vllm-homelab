# justfile — vLLM model cache management on the k3s server
# Requires: kubectl configured against the cluster (run from the server itself)

set shell := ["bash", "-euo", "pipefail", "-c"]

# Current vLLM pod name — re-evaluated on every invocation
pod := `kubectl get pods -n vllm -l app.kubernetes.io/name=vllm -o jsonpath='{.items[0].metadata.name}'`

# Default: show available recipes
default:
    @just --list

# List all models currently cached on the PVC, with sizes
list-models:
    kubectl exec -n vllm {{pod}} -- sh -c \
      'du -sh /root/.cache/huggingface/hub/*/ 2>/dev/null || echo "no models cached"'

# Show total space used by the model cache
cache-usage:
    kubectl exec -n vllm {{pod}} -- du -sh /root/.cache/huggingface

# Delete a cached model from the PVC. Usage: just delete-model Qwen/Qwen3-1.7B
delete-model model:
    #!/usr/bin/env bash
    set -euo pipefail
    dir="models--$(echo "{{model}}" | sed 's#/#--#')"
    echo "This will permanently delete: ${dir}"
    read -p "Continue? [y/N] " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "Aborted."
        exit 1
    fi
    kubectl exec -n vllm {{pod}} -- rm -rf "/root/.cache/huggingface/hub/${dir}"
    echo "Deleted ${dir}"
