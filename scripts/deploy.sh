#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

CAL_DIY_TAG="v6.2.0"
VENDOR_DIR="vendor/cal.diy"

if [ -d "$VENDOR_DIR/.git" ]; then
  git -C "$VENDOR_DIR" fetch --tags origin
  git -C "$VENDOR_DIR" checkout "$CAL_DIY_TAG"
else
  git clone --branch "$CAL_DIY_TAG" --depth 1 https://github.com/calcom/cal.diy.git "$VENDOR_DIR"
fi

docker compose up -d --build
