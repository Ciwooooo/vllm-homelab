#!/usr/bin/env bash
#
# One-time server bootstrap for the vLLM homelab cluster
# Prerequisited (NOT adressed here)
# Ubuntu server with NVIDIA GPU
# NVIDIA drivers already installed and working (nvidia-smi)
#
# What this script does:
# 1. Installs NVIDIA Container toolkit
# 2. Installs k3s (traefik/servicelb disabled Cluser IP + port-forward)
# 3. Sets up kubeconfig for the invoking user
# 4. Verified k3s auto-detected the nvidia container runtime
# 5. Created the model cache dir
# 6. Applied the NVIDIA device plugin
#
# Deliberately NOT done: hand-writing a containerd config template. k3s
# auto-detects nvidia-container-runtime from PATH and adds the runtime block
# itself. Writing our own template either replaces k3s's defaults (breaking
# CNI) or collides with the auto-added block (TOML "table already exists").
# See docs/TROUBLESHOOTING.md.

set -euo pipefail # exit if anything fails, error on undefined vars, fail if any stage fails

CACHE_DIR="/mnt/vllm-cache"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" # resolve the dir no matter where the script is called from
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# helper funcs
log() { echo -e "\n=== $* ===\n"; }
fail() { echo "ERROR: $*" >&2; exit 1; }


# ------------------------------------------------------------
log "Checking prerequisites"

command -v nvidia-smi &>/dev/null \
    || fail "nvidia-smi not found. Install the NVIDIA driver before running this."
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv

[[ $EUID -ne 0 ]] || fail "Run as a normal user (with sudo access), not as root."


# ------------------------------------------------------------
log "Installing NVIDIA Container Toolkit"

# if else makes it indepotent, safe to run agian, nothing will happen
if command -v nvidia-ctk &>/dev/null; then
  echo "Already installed: $(nvidia-ctk --version | head -1)"
else
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

  curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null

  sudo apt-get update
  sudo apt-get install -y nvidia-container-toolkit
fi

command -v nvidia-container-runtime &>/dev/null \
  || fail "nvidia-container-runtime not on PATH after toolkit install."


# ------------------------------------------------------------
log "Installing k3s"

if systemctl is-active --quiet k3s; then
  echo "k3s already running, skipping install."
else
  # traefik: we don't need an ingress controller (ClusterIP + port-forward)
  # servicelb: no LoadBalancer services on bare metal
  curl -sfL https://get.k3s.io | sh -s - server \
    --disable traefik \
    --disable servicelb

  sleep 10
fi

systemctl is-active --quiet k3s || fail "k3s failed to start. Check: journalctl -u k3s"


# ------------------------------------------------------------
log "Configuring kubeconfig for $USER"

mkdir -p "$HOME/.kube"
sudo cp /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
chmod 600 "$HOME/.kube/config" # give rw to only the owner

# guard from appending a new line each time the script runs
if ! grep -q "KUBECONFIG" "$HOME/.bashrc"; then
  echo "export KUBECONFIG=$HOME/.kube/config" >> "$HOME/.bashrc"
fi
export KUBECONFIG="$HOME/.kube/config"

kubectl get nodes || fail "kubectl cannot reach the cluster."


# ------------------------------------------------------------
log "Verifying k3s auto-detected the nvidia runtime"

CONTAINERD_CONFIG="/var/lib/rancher/k3s/agent/etc/containerd/config.toml"

sudo grep -q "runtimes.'nvidia'" "$CONTAINERD_CONFIG" \
  || fail "k3s did not add the nvidia runtime to $CONTAINERD_CONFIG.
  nvidia-container-runtime is at: $(command -v nvidia-container-runtime)
  Try: sudo systemctl restart k3s
  Do NOT hand-write a containerd template — see docs/TROUBLESHOOTING.md"

echo "nvidia runtime registered."
kubectl get runtimeclass nvidia &>/dev/null \
  || echo "WARNING: no 'nvidia' RuntimeClass found — GPU pods will need one."


# ------------------------------------------------------------
log "Creating model cache directory"

sudo mkdir -p "$CACHE_DIR"
sudo chown "$(id -u):$(id -g)" "$CACHE_DIR"

# ------------------------------------------------------------
log "Applying NVIDIA device plugin"

kubectl apply -f "$REPO_ROOT/k8s/nvidia-plugin.yaml"

echo "Waiting for device plugin to become ready..."
kubectl wait --for=condition=ready pod \
  -n nvidia-device-plugin \
  -l name=nvidia-device-plugin-ds \
  --timeout=300s || fail "Device plugin did not become ready. Check:
  kubectl logs -n nvidia-device-plugin -l name=nvidia-device-plugin-ds"

# ------------------------------------------------------------
log "Verifying GPU is schedulable"

if kubectl get nodes -o jsonpath='{.items[0].status.allocatable}' | grep -q "nvidia.com/gpu"; then
  echo "GPU is allocatable:"
  kubectl get nodes -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}'
  echo " GPU(s)"
else
  fail "nvidia.com/gpu not allocatable. See docs/TROUBLESHOOTING.md"
fi

# ------------------------------------------------------------
log "Setup complete"
cat <<EOF
Next steps:
  just deploy                    # install the vLLM Helm release
  just forward                   # open a tunnel to the API
  just test-api Qwen/Qwen3-4B-AWQ

Note: 'export KUBECONFIG=$HOME/.kube/config' was added to ~/.bashrc.
Either open a new shell or run it manually in this one.
EOF
