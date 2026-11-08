# GLM-5.3-Flash NVFP4 on three DGX Sparks — maintained fork

Fork of [strusty/GLM-5.3-Flash-NVFP4-3x-DGX-Sparks-kindling-DGXOS](https://github.com/strusty/GLM-5.3-Flash-NVFP4-3x-DGX-Sparks-kindling-DGXOS)
(upstream README kept as [README-upstream.md](README-upstream.md)).
It serves GLM-5.3-Flash at TP=3 (kindling/vLLM, NVFP4, DFlash2) on **any three
GB10 boxes** (DGX Spark / Ascent GX10) cabled as a switchless CX7 triangle,
managed from [sparkDash](https://github.com/MiaAI-Lab/sparkDash) launchers.

**Status: working** (brought up and measured on a three-unit GB10 ring, DGX OS 7.x,
4K kernel, GPUs clock-capped at 2200 MHz).

## First measurements (Nov 8; capped 2200 MHz, 4K kernel, ARX off)

| Measurement | Result | Upstream reference (64K kernel, uncapped) |
|---|---|---|
| Cold prefill 64k | 21.9 s ≈ **3,170 tok/s** | 20.0 s / ~3,540 |
| Same prompt repeated | **0.4 s** | 0.41 s |
| Solo decode | **95.9 tok/s** | ~66 (prose) |

These numbers were taken with the GPUs clock-capped at 2200 MHz on a 4K-page
kernel and with ARX off; the upstream reference column shows the uncapped
64K-kernel figures. State your own conditions when comparing — the cap and the
kernel page size measurably move the prefill rate.

## Why this fork exists

The upstream recipe pins its engine base to a vLLM nightly that Docker Hub has
since purged (nightlies live ~6 weeks). This fork moves the stack to the
nearest LIVE base and carries the small adaptations that need — nothing else.

## What this fork changes vs upstream

1. **`patches/kindling-a3c3a1d-live-base.patch`** — kindling-tree adaptations
   for base `vllm/vllm-openai:nightly-dev-arm64-cu130-52cb02dee06e` (the
   nearest live equivalent of the purged pin, one day younger; verified with an
   anchor battery — see Lessons):
   - `draft_trunc.py`: version guard → `52cb02dee`
   - `model_runner.py`: drop the `attn_cg_support` kwarg (upstream renamed it
     to `additional_attn_cg_support` one day after the original pin)
   - `fixes/kv_cache_utils.py`: `to_event_extra_keys` backport
   - `image/Dockerfile`: skip vllm-58720 (ad6817b already in this base),
     **pyc-clean after patching** (stale `__pycache__` in deeper layers causes
     silent import crashes), hisparse-addendum step (no-op on this base)
2. **`compose/triangle-dgxos.yaml`**: `VLLM_ARX_RING=0` — the ARX ring hit QP
   setup timeouts on our switchless triangle while NCCL over the same links
   worked; collectives fall back to NCCL and the engine runs fine. Re-enable
   ARX if your ring probes clean (it is a small-batch decode optimization).
   Also appends `--api-key ${VLLM_API_KEY}` to EXTRA_ARGS (see auth below).
3. **`scripts/install-overlay.sh`** — one-shot overlay run after upstream
   `scripts/install.sh`: applies the patch, writes `IMAGE`/`HEAD_HOST`
   (auto-detected head LAN address) into `compose/.env` on all three boxes,
   sets `MENTAT_ISLAND_PLACEMENT=off` + restarts mentatd (without it placement
   can hang — see Lessons), builds the image, distributes it to the workers.
4. **`scripts/local.sh.example`** — template for your workers/folders.
5. **`sparkdash-start.sh` / `sparkdash-stop.sh`** — sparkDash launcher wrappers.
6. **`scripts/start.sh`**: the smoke test sends the API key when
   `VLLM_API_KEY` is set (auth below).

## Configure for your cluster

Two files carry every cluster-specific value; nothing is hardcoded.

| What | File | How to find / set |
|---|---|---|
| Worker fabric addresses (`WORKER1/2`) | `scripts/local.sh` (copy from `local.sh.example`) | `ip -br addr | grep np` on each box; pick a DIRECT-link subnet shared with the head |
| Head LAN address (`HEAD_LAN_IP`) | same, optional | auto-detected (default-route source); set only if you run VPNs/multi-route |
| Weights paths, API port | same, optional | defaults fit the walk-through below |
| API key (`VLLM_API_KEY`) | kindling tree: `compose/.env` | any secret; see "API auth" |

**mentat `.env` on every box** (checkout of [mentat](https://github.com/mmastrac/mentat) at `v0.17.1`, published images — no build):

```bash
cd ~/mentat
cat > .env <<'EOF'
IMAGE=mmastrac/mentatd:0.17.1
MENTAT_PEERS=<LAN address of ANY other box>:6379
MENTAT_NODE_IP=<THIS box's LAN address>
# tag every CX7 interface rdma and the default-route interface lan:
MENTAT_ANNOUNCE_IFACES=en*f*np*=connectx+rdma,<your-lan-iface>=lan  # find the name: ip -o -4 route show default
EOF
docker compose -f mentatd.yaml up -d
```

**Weights over NFS (recommended)** — on the head, export the weights dir to the
workers' FABRIC addresses; on each worker, mount it at the same path. Use the
fabric IPs, never a hostname — it does not resolve from the workers:

```bash
# head: /etc/exports (adjust the two worker addresses)
/home/<you>/models 10.0.0.2(ro,sync,no_subtree_check,no_root_squash) 10.0.0.3(ro,sync,no_subtree_check,no_root_squash)
sudo exportfs -ra
# worker: /etc/fstab (adjust the head's fabric address) — then `sudo mount`
<head-fabric-ip>:/home/<you>/models /home/<you>/models nfs ro,soft,timeo=50,retrans=2,noatime,_netdev 0 0
```

## Install from scratch (short version)

Run everything from the HEAD (rank 0). Steps in order — each later step uses
what the earlier ones produced.

```
# 0. tools on the head (two small venvs; system python/hf are NOT enough):
python3 -m venv ~/tools/hf-venv && ~/tools/hf-venv/bin/pip install "huggingface_hub[hf_xet]"
python3 -m venv ~/tools/torch-venv && ~/tools/torch-venv/bin/pip install torch --index-url https://download.pytorch.org/whl/cpu safetensors numpy

# 1. mentat on all three boxes — see "Configure for your cluster" for the .env

# 2. this recipe's files + your local.sh (WORKERS etc.) BEFORE install.sh needs them:
cp scripts/local.sh.example scripts/local.sh   # then edit: workers, optional VLLM_API_KEY
./scripts/install.sh        # clones kindling (~/glm53-kindling, pinned) on all 3 boxes, writes compose/.env

# 3. weights (kindling tree from step 2 provides make_padded; torch-venv from step 0):
~/tools/hf-venv/bin/hf download nvidia/GLM-5.3-Flash-NVFP4 --local-dir ~/models/glm-5.3-flash-nvfp4-src
~/tools/hf-venv/bin/hf download incoai/GLM-5.3-Flash-DFlash2 --local-dir ~/models/glm-5.3-flash-dflash2-src
~/tools/torch-venv/bin/python ~/glm53-kindling/experimental/tp3/make_padded.py \
  ~/models/glm-5.3-flash-nvfp4-src ~/models/glm53-nvfp4-tp3 \
  ~/models/glm-5.3-flash-dflash2-src ~/models/glm53-dflash2-tp3

# 4. make the padded dirs reachable at the SAME path on every box — NFS
#    export + mounts: copy-paste blocks in "Configure for your cluster"

# 5. ./scripts/install-overlay.sh   # patch + .env x3 (incl. VLLM_API_KEY from
#                                    # local.sh) + mentat island fix + build + distribute

# 6. start: ./sparkdash-start.sh    # boot 3–10 min; first start writes ~67G
#    weight snapshots per rank. NOTE: the FIRST requests after a fresh install
#    compile kernels per batch shape — minutes, once per shape; not a hang.
```

## API auth

The engine enforces a Bearer key. Put `VLLM_API_KEY=sk-...` in
`scripts/local.sh` (uncommitted, like the MiaAI-Lab recipes treat tokens);
`install-overlay.sh` propagates it into the kindling tree's `compose/.env` on
all three boxes. Without it the engine still runs — with NO auth.

## Serving convention: one shared port

Whichever GLM engine you run (TP2/TP3/…), serve it on the same port and URL so
clients never change — e.g. this stack on port 8891 behind whatever reverse
proxy exposes your head. Only one engine at a time (same port). Mind proxy
request timeouts (~100 s on some CDNs) and that this engine serves a 262k
window per request.

## sparkDash

Add a launcher on the head's spark page: dir = this repo, start script
`sparkdash-start.sh`, stop script `sparkdash-stop.sh`, port = your API_PORT.
Quirk: the LLM probe reads only the FIRST port of a spark's `llmPorts` — keep
the active engine's port first.

## Lessons (kept so they are not lost)

- **Pinned nightly bases get purged from Docker Hub (~6 weeks).** Map the pin
  to the nearest LIVE tag and verify with an "anchor battery" (grep the exact
  fragments every patch hooks into) before building anything.
- **Runtime overlays ≠ build.** kindling bind-mounts `experimental/*` OVER the
  image at runtime — a green build says nothing about runtime; simulate with
  the full set of mounts.
- **Patching .py files does not invalidate `__pycache__`** baked in deeper
  layers → silent crashes. Clean `__pycache__` after the last patch step.
- **Env asymmetry between ranks = a deadlock with no traceback** (idle at
  1–3% CPU). Always `docker exec <rank> printenv | grep -E "ARX|API"` on all
  three ranks when a boot hangs.
- **mentat islands:** if `/status` on port 6380 shows more islands than nodes,
  set `MENTAT_ISLAND_PLACEMENT=off` or placement waits forever.
- `tar | head` = SIGPIPE truncates the extraction. Never pipe tar into a filter.

## Open (non-blocking)

- ARX ring QP-timeout diagnosis (would re-enable a small-batch decode win)
- dispram (+2 GiB KV per rank) — not deployed

## Acknowledgements

This fork stands on the shoulders of the people who did the real work:

- **[strusty](https://github.com/strusty/GLM-5.3-Flash-NVFP4-3x-DGX-Sparks-kindling-DGXOS)** —
  the upstream recipe this repo forks: the TP=3 orchestration, the ARX/rank
  tooling, the measurements, and the weekend of agent traffic behind them.
- **[kindling](https://github.com/kindlingai/glm-5.3-flash-gx10)** — the engine
  this serves on: a vLLM fork tuned for GB10 (mentat in place of Ray, ARX
  ring transport, DFlash2 speculative decoding, the experimental overlays).
- **[mmastrac](https://github.com/mmastrac/mentat)** — mentat, the cluster
  manager that replaces Ray across the three boxes.
- **[MiaAI Lab](https://github.com/MiaAI-Lab)** — the GB10 sparse-MLA patches
  vendored inside the engine image (SM121/FA2 gating; MIT-licensed, kept
  verbatim beside their licence file).
- **[vLLM](https://github.com/vllm-project/vllm)** — the engine underneath it all.
- **Zhipu AI (z.ai)** for open-sourcing GLM-5.3-Flash, **NVIDIA** for the
  NVFP4 checkpoint and the GB10 platform, and **[incoai](https://huggingface.co/incoai)**
  for the DFlash2 drafter weights.
