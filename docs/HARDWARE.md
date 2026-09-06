# Hardware

## The box

- **GPU:** NVIDIA GTX 1660 Ti mobile — 6GB VRAM, Turing (TU116), **compute capability 7.5**
- **RAM:** ~15GB total, but only ~4.4GB free at model-load time
- **OS:** Ubuntu 26.04, k3s, vLLM 0.28.0

Compute capability 7.5 matters more than the 6GB. It is the constraint that
decides which models are possible at all.

## What compute capability 7.5 costs

Every line below appeared in our own vLLM logs. All are fallbacks, not errors —
the model still runs, just on slower paths.

| Missing | Log evidence | Consequence |
|---|---|---|
| bfloat16 hardware | `Casting torch.bfloat16 to torch.float16` | bf16 models silently downcast |
| FlashAttention 2 | `FA2 is only supported on devices with compute capability >= 8` | falls back to `TRITON_ATTN` |
| FlashInfer sampler | `unsupported compute capability 7.5; falling back` | slower top-p/top-k sampling |
| Fused GDN kernel | `requires ... a GPU with compute capability 8.0+` | Triton fallback for linear attention |

One limit is **not** a fallback — it's a hard block: Turing has a **64KB
shared-memory ceiling per SM**. Architectures needing more simply cannot run.

## Measured VRAM

| Model | Quantization | Process VRAM | Weights |
|---|---|---|---|
| Qwen3-1.7B | none (fp16) | 5530 MiB | ~3.2 GiB |
| Qwen3-4B-AWQ | AWQ | 5478 MiB | ~3.3 GiB |

**These are nearly identical despite a 2.4× parameter difference.** That's not a
measurement error: `--gpu-memory-utilization=0.92` makes vLLM pre-allocate KV
cache to fill the target regardless of weight size. Total VRAM is therefore a
useless number for comparing models. The number that matters is **how much KV
cache is left after weights load** — vLLM prints it as `Available KV cache
memory`.

## Why `--enforce-eager` is mandatory here

First attempt, at `gpu-memory-utilization=0.85` with CUDA graph capture on:

```
Available KV cache memory: 0.13 GiB
ValueError: To serve at least one request with the model's max seq len (2048),
0.22 GiB KV cache is needed, which is larger than the available KV cache memory
```

`torch.compile` graph artifacts were consuming the headroom. `--enforce-eager`
disables graph capture and returns that memory to KV cache, at some throughput
cost. On this card it isn't optional.

Tuning order when KV cache is short: `--enforce-eager` first, then raise
`--gpu-memory-utilization`, then lower `--max-model-len`.

## Models tested

| Model | Result |
|---|---|
| Qwen3-1.7B | Works, unquantized |
| Qwen3-4B-AWQ | **Works — current default** |
| Qwen3.5-4B (AWQ, community) | Fails, OOM |
| Gemma 4 (any size) | Architecturally blocked |

### Qwen3.5-4B — why it failed

OOM with **9 MB free of 6 GB**, after weights took only 3.28 GiB. Three causes
stacked:

1. **Hybrid architecture.** Qwen3.5 uses Gated DeltaNet linear attention. Mamba-
   style state caches are allocated **upfront per sequence**, not paged like KV
   cache — so `--gpu-memory-utilization` can't tune them down.
2. **`--language-model-only` is weaker than it sounds.** It sets multimodal
   input limits to zero (confirmed: `running in text-only mode`), but the vision
   tower weights are still in the checkpoint and still allocated. The log still
   shows `MMEncoderAttention` initializing.
3. **Every fast path unavailable** on sm_75, per the table above.

Also worth noting: the repo was named `-AWQ-4bit` but actually shipped
`compressed-tensors` format, so `--quantization=awq` failed validation. Leaving
`model.quantization` empty and letting vLLM auto-detect from `config.json` is
more robust than trusting a repo name.

### Gemma 4 — architecturally blocked

Not a tuning problem. Gemma4 specifies `head_dim: 256` (sliding attention) and
`global_head_dim: 512` (full attention). The large head dimension makes Triton
attention kernels request **96KB shared memory against Turing's 64KB hardware
limit**. FlashInfer isn't an escape either — it supports head sizes 64, 128, and
256 only. There is no working backend on this GPU.

## Upgrade guidance

**Prioritize compute capability ≥ 8.0 over raw VRAM.**

The 2026 model generation leans on large head dimensions, Mamba/linear-attention
state caches, and BF16-native math. Turing lacks the shared memory, the fused
kernels, and the BF16 units for all three. A different Turing card with more VRAM
would hit every wall in this document.

An Ampere card (SM 8.6) — e.g. RTX 3060 12GB — is a generational change, not a
memory upgrade. That distinction is the practical conclusion of everything here.
