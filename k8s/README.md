# Raw Kubernetes manifests

These are **not** the deployment path. `helm/vllm/` is authoritative for the
vLLM workload — see the root README for deploy instructions.

## What's actually applied from here

- **`nvidia-plugin.yaml`** — applied directly, still live. The NVIDIA device
  plugin is cluster infrastructure rather than part of the vLLM application,
  so it sits outside the chart deliberately: it's a prerequisite that has to
  exist before any GPU workload (this one or a future one) can schedule.
  Reapply with `kubectl apply -f k8s/nvidia-plugin.yaml`.

## What's kept for reference only

- `namespace.yaml`
- `pv.yaml` / `pvc.yaml`
- `secret.yaml.example`
- `vllm/deployment.yaml`
- `vllm/service.yaml`

These were hand-written first, deployed, and verified working before being
refactored into the Helm chart in `helm/vllm/`. They're kept because the
hand-written version is easier to read than the templated one — when the
chart does something confusing, diffing `helm template vllm ./helm/vllm`
against these files is usually the fastest way to see what changed.

**They are not applied and will drift.** If you change something in the
chart, don't assume these reflect it. Treat them as a snapshot of the
working configuration at the time of the Helm refactor, not as live config.
