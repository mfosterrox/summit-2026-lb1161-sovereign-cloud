#!/bin/bash
#
# Lab wrapper: runs the single monitoring-setup installer (certificates, stack, RHACS auth).
# Requires: oc, openssl, curl, envsubst; ROX_CENTRAL_ADDRESS + ROX_API_TOKEN.
#
set -euo pipefail
LAB_SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$LAB_SETUP_DIR")"
INSTALL="$PROJECT_ROOT/monitoring-setup/install.sh"
if [[ ! -x "$INSTALL" ]] && [[ -f "$INSTALL" ]]; then
  chmod +x "$INSTALL"
fi
if [[ ! -f "$INSTALL" ]]; then
  echo "[MONITORING] ERROR: install script not found: $INSTALL" >&2
  exit 1
fi
exec bash "$INSTALL" "$@"
