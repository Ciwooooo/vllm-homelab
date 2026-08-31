## GPU device plugin fails after a fresh k3s + NVIDIA setup

This one has several layered failure modes if you're setting up GPU support
on k3s from scratch. Learned the hard way — worth reading in order even if
you're only hitting one symptom, since they're easy to reintroduce one at a
time while chasing the others.

### Don't hand-write containerd's config template

k3s's own docs warn about this, but it's easy to miss: `config.toml.tmpl`
(or `config-v3.toml.tmpl` on newer containerd) **replaces** k3s's default
containerd config entirely — it isn't merged in. Writing a full config from
scratch based on a generic containerd tutorial will silently drop
k3s-specific sections (notably CNI setup), which shows up as the node going
`NotReady` with: container runtime network not ready: NetworkReady=false
reason:NetworkPluginNotReady message:Network plugin returns error:
cni plugin not initialized

**Fix:** if you need to add anything to containerd's config, start the
template with `{{ template "base" . }}` and only add what's genuinely new
below it. This pulls in all of k3s's real defaults instead of replacing them.

### Match the containerd config version to what's actually running

Check your containerd version first:
```bash
kubectl get nodes -o wide   # look at the CONTAINER-RUNTIME column
```
- containerd 1.7.x → `config.toml.tmpl`, plugin paths like
  `plugins."io.containerd.grpc.v1.cri"`
- containerd 2.0+ → `config-v3.toml.tmpl`, plugin paths like
  `plugins.'io.containerd.cri.v1.runtime'` (note the quoting style also
  changes — single quotes around the plugin/runtime name)

Using the wrong version's file/syntax mostly "works" via a legacy-compat
fallback, but isn't correct and isn't what k3s's own docs recommend.

### k3s auto-detects the NVIDIA runtime — don't add it yourself

Once `nvidia-container-toolkit` is installed (so `nvidia-container-runtime`
is on `PATH`), k3s's base template **automatically** adds an `nvidia`
containerd runtime entry on its own, with no manual config needed at all.

Manually adding your own `[plugins...runtimes.nvidia]` block on top of the
base template causes:

containerd: failed to unmarshal TOML: toml: table nvidia already exists

because TOML doesn't allow declaring the same table twice — and this
crashes containerd entirely, which cascades into the same `NotReady` /
`cni plugin not initialized` symptom as the section above, for a completely
different reason. If you see that TOML error in
`/var/lib/rancher/k3s/agent/containerd/containerd.log`, the fix is to
**delete your custom template**, not edit it further — verify with:
```bash
sudo grep -A2 "runtimes.'nvidia'" /var/lib/rancher/k3s/agent/etc/containerd/config.toml
```

### Registering the runtime doesn't make anything use it

Even with the `nvidia` runtime correctly registered in containerd, pods
still run under plain `runc` by default. Symptom — the device plugin pod
starts but crashes immediately with: Failed to initialize NVML: ERROR_LIBRARY_NOT_FOUND.
If this is a GPU node, did you set the docker default runtime to nvidia?

**Fix:** the pod spec needs to explicitly opt in:
```yaml
spec:
  runtimeClassName: nvidia
  containers:
  - ...
```
k3s auto-creates the corresponding `RuntimeClass` object for supported
runtimes (`kubectl get runtimeclass` should show `nvidia` already there) —
you just have to reference it from the pod spec yourself. **This applies to
any GPU workload, not just the device plugin** — the vLLM deployment needs
this field too.

### Sanity checklist, top to bottom
```bash
nvidia-smi                                  # driver works on the host
nvidia-ctk --version                        # toolkit installed
which nvidia-container-runtime              # binary on PATH
kubectl get nodes                           # node is Ready
sudo grep -A2 "runtimes.'nvidia'" \
  /var/lib/rancher/k3s/agent/etc/containerd/config.toml   # runtime registered
kubectl get runtimeclass                    # nvidia RuntimeClass exists
kubectl get pods -n nvidia-device-plugin    # plugin pod Running, not restarting
kubectl describe node | grep -A8 Allocatable # nvidia.com/gpu: 1 present
```


## Pod crashes with "VLLM_PORT ... appears to be a URI"

Full error, buried in the EngineCore traceback:

ValueError: VLLM_PORT 'tcp://10.43.250.121:8000' appears to be a URI.
This may be caused by a Kubernetes service discovery issue


**Cause:** Kubernetes automatically injects environment variables into every
pod for every Service that exists in the same namespace, using a legacy
Docker-links-style naming convention: `<SERVICE_NAME>_SERVICE_HOST`,
`<SERVICE_NAME>_PORT`, etc. (all uppercased). Our vLLM Service is named
`vllm`, exposing port `8000` — so Kubernetes auto-injects a variable
literally named `VLLM_PORT` set to `tcp://<clusterIP>:8000`.

vLLM *also* reads an environment variable called `VLLM_PORT` for its own
configuration, expecting a plain integer. The name collision means
Kubernetes' auto-injected value silently overwrites what vLLM expects, and
vLLM crashes trying to parse a URI as a port number.

This is specific to naming the Service the same as (or matching a prefix
recognized by) the application inside it — a Service named something else
(e.g. `mistral-api`) wouldn't collide with `VLLM_PORT` at all. Worth knowing
this class of bug exists any time an app reads its own config from env
vars with a common/short name (`PORT`, `HOST`, etc.) — the more generic the
name, the more likely a same-namespace Service collides with it.

**Fix:** disable this legacy env var injection for the pod, since we use
DNS-based service discovery (`vllm.vllm.svc.cluster.local`) instead, which
doesn't have this collision problem:
```yaml
spec:
  template:
    spec:
      enableServiceLinks: false   # pod-spec level, sibling of containers:
      containers:
      - name: vllm
        ...
```

**Sanity check if this happens again:** exec into a running pod (or check
`kubectl describe pod` env section) and look for auto-injected
`<NAME>_SERVICE_HOST` / `<NAME>_PORT` variables matching any Service in the
namespace — that's the signature of this exact issue, not a vLLM bug.
