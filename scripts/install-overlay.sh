#!/bin/bash
# install-overlay.sh — this fork's overlay on top of the upstream recipe
# (run AFTER scripts/install.sh, on the HEAD box).
#
# What it does:
#   1. applies patches/kindling-a3c3a1d-live-base.patch to the kindling tree
#      ($KINDLING_DIR) — adaptations for base image
#      vllm/vllm-openai:nightly-dev-arm64-cu130-52cb02dee06e (the upstream
#      recipe's pinned nightly was purged from Docker Hub; this is the nearest
#      live tree, anchor-verified): draft-trunc version guard,
#      additional_attn_cg_support kwarg, to_event_extra_keys backport,
#      Dockerfile updates (skip 58720, pyc-clean step, hisparse addendum step)
#   2. writes IMAGE / HEAD_HOST into compose/.env on all three boxes
#      (HEAD_HOST = this box's LAN address — auto-detected, or set HEAD_LAN_IP
#      in scripts/local.sh to override)
#   3. appends MENTAT_ISLAND_PLACEMENT=off to ~/mentat/.env on every box and
#      restarts mentatd (without it mentat may split the mesh into per-link
#      islands and TP=3 placement hangs forever)
#   4. builds the engine image with the live base (on the HEAD)
#   5. distributes the image to the workers (docker save | ssh docker load)
# NOTE: weights must already exist (make_padded + NFS mounts — see README.md).
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
# scripts/local.sh carries WORKER1/WORKER2; seed it from the example on first run
[ -f "$HERE/scripts/local.sh" ] || cp "$HERE/scripts/local.sh.example" "$HERE/scripts/local.sh"
. "$HERE/scripts/config.sh"
[ -n "${WORKER1:-}" ] && [ -n "${WORKER2:-}" ] || { echo "WORKER1/WORKER2 not set — copy scripts/local.sh.example to scripts/local.sh and fill in your boxes (see the comments there)"; exit 1; }
case "$WORKER1 $WORKER2" in
  *user@10.0.0.*) echo "WORKER1/WORKER2 still hold the example placeholders — edit scripts/local.sh with YOUR boxes' fabric addresses"; exit 1 ;;
esac
for h in "${HOSTS[@]}"; do
  run_on "$h" "[ -f ~/mentat/mentatd.yaml ]" || { echo "mentat checkout missing on $h (expected ~/mentat with mentatd.yaml) — see README step 3"; exit 1; }
done
BASE_TAG="vllm/vllm-openai:nightly-dev-arm64-cu130-52cb02dee06e"
IMG="spark-glm53:v11"
# the head's LAN address as the workers and mentat reach it: explicit override
# or the source address of this box's default route
HEAD_LAN_IP="${HEAD_LAN_IP:-$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<NF; i++) if ($i == "src") {print $(i+1); exit}}')}"
[ -n "$HEAD_LAN_IP" ] || { echo "cannot detect the head's LAN IP; set HEAD_LAN_IP in scripts/local.sh"; exit 1; }

echo "== 1/5 apply kindling patch (live-base) =="
PATCH="$HERE/patches/kindling-a3c3a1d-live-base.patch"
if run_on local "cd $KINDLING_DIR && git apply --check '$PATCH' 2>/dev/null"; then
  run_on local "cd $KINDLING_DIR && git apply '$PATCH'" && echo '  applied'
elif run_on local "cd $KINDLING_DIR && git apply --reverse --check '$PATCH' 2>/dev/null"; then
  echo '  already applied'
else
  echo "patch does not apply cleanly to $KINDLING_DIR (not applied, not reverse-appliable) — inspect manually"; exit 1
fi

echo "== 2/5 .env (IMAGE, HEAD_HOST${VLLM_API_KEY:+, VLLM_API_KEY}) on 3 boxes =="
for h in "${HOSTS[@]}"; do
  run_on "$h" "cd $KINDLING_DIR && { grep -q '^IMAGE=' compose/.env && sed -i 's|^IMAGE=.*|IMAGE=$IMG|' compose/.env || echo IMAGE=$IMG >> compose/.env; } && { grep -q '^HEAD_HOST=' compose/.env && sed -i 's|^HEAD_HOST=.*|HEAD_HOST=$HEAD_LAN_IP|' compose/.env || echo HEAD_HOST=$HEAD_LAN_IP >> compose/.env; }"
  [ -n "${VLLM_API_KEY:-}" ] && run_on "$h" "cd $KINDLING_DIR && { grep -q '^VLLM_API_KEY=' compose/.env && sed -i 's|^VLLM_API_KEY=.*|VLLM_API_KEY=$VLLM_API_KEY|' compose/.env || echo VLLM_API_KEY=$VLLM_API_KEY >> compose/.env; }"
done
echo "  .env x3 done (IMAGE=$IMG, HEAD_HOST=$HEAD_LAN_IP, auth=$([ -n "${VLLM_API_KEY:-}" ] && echo on || echo OFF))"

echo "== 3/5 mentat: MENTAT_ISLAND_PLACEMENT=off + restart (all boxes) =="
for h in "${HOSTS[@]}"; do
  run_on "$h" "cd ~/mentat && { grep -q '^MENTAT_ISLAND_PLACEMENT=' .env && sed -i 's|^MENTAT_ISLAND_PLACEMENT=.*|MENTAT_ISLAND_PLACEMENT=off|' .env || echo MENTAT_ISLAND_PLACEMENT=off >> .env; } && docker compose -f mentatd.yaml up -d --force-recreate >/dev/null && echo '  ok'"
done

echo "== 4/5 build the image (BASE=$BASE_TAG) =="
# install.sh clones kindling without --recursive; the build needs the spark-agent
# submodule (the vllm/ symlink points into it)
run_on local "git -C $KINDLING_DIR submodule update --init --recursive"
docker pull -q "$BASE_TAG"
(cd "$KINDLING_DIR" && docker build -t "$IMG" --build-arg BASE="$BASE_TAG" -f image/Dockerfile .)

echo "== 5/5 distribute to the workers =="
for h in "${WORKER1}" "${WORKER2}"; do
  echo "  -> $h"; docker save "$IMG" | ssh -o BatchMode=yes "$h" docker load
done
echo "DONE. Start with: ./sparkdash-start.sh  (or scripts/start.sh)"
