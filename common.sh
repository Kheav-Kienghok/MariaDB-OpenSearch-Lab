#!/usr/bin/env bash
# Shared helpers, sourced by every script.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$ROOT/.env" ] || { echo "Missing $ROOT/.env (cp .env.example .env)"; exit 1; }
set -a; . "$ROOT/.env"; set +a
need_root() { [ "$(id -u)" -eq 0 ] || { echo "Run with sudo"; exit 1; }; }
