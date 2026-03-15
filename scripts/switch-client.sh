#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $(basename "$0") <agave|vexor>"
  exit 1
fi

TARGET="$1"

case "$TARGET" in
  agave)
    sudo systemctl stop vexor-validator || true
    sudo systemctl start solana-validator
    ;;
  vexor)
    sudo systemctl stop solana-validator || true
    sudo systemctl start vexor-validator
    ;;
  *)
    echo "Unknown target: $TARGET"
    exit 1
    ;;
esac

sudo systemctl status "${TARGET}-validator" --no-pager || true
