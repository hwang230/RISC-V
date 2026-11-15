#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORFS_FLOW_DIR="${ORFS_FLOW_DIR:-$HOME/eda/OpenROAD-flow-scripts}"
DOCKER_IMAGE="${DOCKER_IMAGE:-openroad/orfs:latest}"
FLOW_TARGET="${1:-place}"
FLOW_CONFIG="${2:-asic/config.mk}"
FLOW_WORK_HOME="${3:-asic/work}"

if [[ ! -f "$ORFS_FLOW_DIR/flow/Makefile" || ! -f "$ORFS_FLOW_DIR/env.sh" ]]; then
    echo "OpenROAD Flow Scripts not found at: $ORFS_FLOW_DIR" >&2
    echo "Set ORFS_FLOW_DIR to the local OpenROAD-flow-scripts checkout." >&2
    exit 2
fi

docker run --rm \
    --user "$(id -u):$(id -g)" \
    -v "$PROJECT_DIR:/work" \
    -v "$ORFS_FLOW_DIR:/host-orfs:ro" \
    -w /OpenROAD-flow-scripts/flow \
    "$DOCKER_IMAGE" \
    bash -lc 'source /OpenROAD-flow-scripts/env.sh && make DESIGN_CONFIG="/work/$2" WORK_HOME="/work/$3" NUM_CORES=4 "$1"' \
    bash "$FLOW_TARGET" "$FLOW_CONFIG" "$FLOW_WORK_HOME"
