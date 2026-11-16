#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKER_IMAGE="${DOCKER_IMAGE:-openroad/orfs@sha256:31c5fd29e541059e36ad87b197ece981c04d2ce3a1f2035976fe266ec0e521cb}"
FLOW_TARGET="${1:-place}"
FLOW_CONFIG="${2:-asic/config.mk}"
FLOW_WORK_HOME="${3:-asic/work}"

docker run --rm \
    --cpus=4 \
    --user "$(id -u):$(id -g)" \
    -v "$PROJECT_DIR:/work" \
    -w /OpenROAD-flow-scripts/flow \
    "$DOCKER_IMAGE" \
    bash -lc 'source /OpenROAD-flow-scripts/env.sh && make DESIGN_CONFIG="/work/$2" WORK_HOME="/work/$3" NUM_CORES=4 "${@:4}" "$1"' \
    bash "$FLOW_TARGET" "$FLOW_CONFIG" "$FLOW_WORK_HOME" "${@:4}"
