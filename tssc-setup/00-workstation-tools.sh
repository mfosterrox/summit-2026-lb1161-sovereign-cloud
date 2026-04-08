#!/bin/bash
# Bastion / lab workstation tools for TSSC module (matches module-03 setup).
# Installs podman (RHEL/Fedora) and cosign + gitsign via Red Hat TSSC installer script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[TSSC-TOOLS]${NC} $1"; }
warning() { echo -e "${YELLOW}[TSSC-TOOLS]${NC} $1"; }
error() { echo -e "${RED}[TSSC-TOOLS] ERROR:${NC} $1" >&2; exit 1; }

COSIGN_GITSIGN_INSTALLER_URL="${COSIGN_GITSIGN_INSTALLER_URL:-https://raw.githubusercontent.com/redhat-tssc-tmm/security-roadshow/main/cosign_gitsign_installer.sh}"

log "Installing workstation tools (podman, cosign, gitsign)..."

if command -v podman &>/dev/null; then
    log "✓ podman already present: $(command -v podman)"
else
    if command -v dnf &>/dev/null; then
        log "Installing podman via dnf..."
        if [ "$(id -u)" -eq 0 ]; then
            dnf -y install podman
        else
            sudo dnf -y install podman
        fi
        log "✓ podman installed"
    else
        warning "dnf not found; skipping podman (install podman manually if needed)"
    fi
fi

log "Running cosign / gitsign installer..."
if ! curl -fsSL "$COSIGN_GITSIGN_INSTALLER_URL" | bash; then
    error "cosign/gitsign installer failed (check network and URL: $COSIGN_GITSIGN_INSTALLER_URL)"
fi

log "✓ cosign / gitsign installer completed"
if command -v cosign &>/dev/null; then
    cosign version || true
fi
if command -v gitsign &>/dev/null; then
    gitsign --version 2>/dev/null || gitsign version 2>/dev/null || true
fi

log "Workstation tools step finished."
