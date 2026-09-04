#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

# The calcom image is built in CI (.github/workflows/build-calcom-image.yml)
# and published to GHCR — this VPS only pulls it, it never builds the
# Next.js/Prisma monorepo locally (see docker-compose.yml for why).
docker compose pull
docker compose up -d
