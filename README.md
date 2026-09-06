# vllm-homelab

A self-hosted LLM on a home server: vLLM serving an OpenAI-compatible API,
deployed to k3s via Helm, GPU-accelerated on consumer hardware.

Built as a learning project — the goal was understanding Kubernetes, Helm, and
GPU scheduling properly, not just getting a model running. The commit history
and `docs/TROUBLESHOOTING.md` are part of the point.

## What it does

- Serves any vLLM-supported model over an OpenAI-compatible HTTP API
- Runs on a single-node k3s cluster with NVIDIA GPU passthrough
- Caches model weights on a PVC, so switching models doesn't re-download
- Exposed as **ClusterIP only** — reachable by other pods in the cluster, not
  by the LAN (see [Security](#security))

## Requirements

- Ubuntu server with an NVIDIA GPU (compute capability ≥ 7.5)
- NVIDIA driver already installed (`nvidia-smi` works)
- `just` for the task recipes

See `docs/HARDWARE.md` for what this actually runs on and what the GPU's
compute capability costs you.

## Setup

```bash
git clone <repo-url> && cd vllm-homelab
./scripts/setup-server.sh    # container toolkit, k3s, device plugin
just deploy                  # install the Helm release
```

`setup-server.sh` is idempotent — safe to re-run. It verifies each step rather
than assuming, and fails with actionable errors. Its header comment documents
what it does and, importantly, what it deliberately does *not* do.

## Usage

```bash
just forward                          # tunnel to localhost:8000
just test-api Qwen/Qwen3-4B-AWQ       # send a test completion
just logs                             # follow vLLM logs
just status                           # release status and history
```

From another pod in the cluster, the API is at:

```
http://vllm.vllm.svc.cluster.local:8000/v1/chat/completions
```

## Switching models

Everything model-specific lives in `helm/vllm/values.yaml`:

```bash
just switch-model Qwen/Qwen3-1.7B          # unquantized
just switch-model Qwen/Qwen3-4B-AWQ awq    # with quantization
just rollback                              # if it goes badly
```

Leaving `model.quantization` empty lets vLLM auto-detect the format from the
model's `config.json` — more reliable than trusting a repo's name to describe
its actual quantization format.

Models that work (and ones that don't, with reasons) are recorded in
`docs/HARDWARE.md`.

## Layout

```
helm/vllm/          Helm chart — the deployment path
k8s/                Raw manifests — reference only, except nvidia-plugin.yaml
scripts/            One-time server bootstrap
docs/               Hardware findings and troubleshooting
justfile            Task recipes
```

`k8s/` was written and verified first, then refactored into the chart. It's kept
because the hand-written version is easier to read than the templated one — see
`k8s/README.md` for what's still applied from there.

## Security

vLLM has no authentication. The Service is deliberately `ClusterIP`, not
`NodePort`: anything that can reach port 8000 can use the GPU without
restriction, so it's kept inside the cluster rather than exposed to the LAN.

When an app is built on top of this, that app gets the externally-reachable
Service and vLLM stays private behind it.

The Hugging Face token secret (`k8s/secret.yaml`) is gitignored; only
`k8s/secret.yaml.example` is tracked. Note that Kubernetes Secrets are
base64-encoded, not encrypted — the real access control is RBAC.

## Notes

Two things that cost real debugging time and aren't obvious:

- **`runtimeClassName: nvidia`** is required on every GPU pod spec. Registering
  the runtime with containerd doesn't make anything use it.
- **`enableServiceLinks: false`** is required because Kubernetes auto-injects a
  `VLLM_PORT` env var (from the Service named `vllm`) that collides with vLLM's
  own config.

Both, plus the k3s/containerd setup failure modes, are written up in
`docs/TROUBLESHOOTING.md`.
