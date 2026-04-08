#!/bin/bash
# Master script to execute lab setup scripts in order (00 → 02).
# 00: roxctl CLI · 01: RHACS Central CR (local-cluster) · 02: Compliance Operator (each cluster).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

context_exists() {
    local name="$1"
    oc config get-contexts -o name 2>/dev/null | sed 's|^context/||' | grep -qx "$name"
}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[SETUP-MASTER]${NC} $1"
}

error() {
    echo -e "${RED}[SETUP-MASTER] ERROR:${NC} $1" >&2
    exit 1
}

warning() {
    echo -e "${YELLOW}[SETUP-MASTER] WARNING:${NC} $1"
}

# Primary phase: roxctl, Central config, Compliance on local-cluster
SCRIPTS=(
    "00-install-roxctl.sh"
    "01-central-configuration.sh"
    "02-compliance-operator-install.sh"
)

log "========================================================="
log "Starting master setup script"
log "========================================================="
log "Script directory: $SCRIPT_DIR"
log ""

# Check if all scripts exist
MISSING_SCRIPTS=()
for script in "${SCRIPTS[@]}"; do
    if [ ! -f "$SCRIPT_DIR/$script" ]; then
        MISSING_SCRIPTS+=("$script")
    fi
done

if [ ${#MISSING_SCRIPTS[@]} -gt 0 ]; then
    error "The following required scripts are missing: ${MISSING_SCRIPTS[*]}"
fi

log "Found all ${#SCRIPTS[@]} required scripts"
log ""

# Execute each script in order
TOTAL=${#SCRIPTS[@]}
CURRENT=0
FAILED_SCRIPTS=()

# Store original context
ORIGINAL_CONTEXT=$(oc config current-context 2>/dev/null || echo "")

for idx in "${!SCRIPTS[@]}"; do
    script="${SCRIPTS[$idx]}"
    CURRENT=$((idx + 1))
    
    log "========================================================="
    log "Executing script $CURRENT/$TOTAL: $script"
    log "========================================================="
    
    # 00–02 expect local-cluster unless overridden (second pass sets TARGET_CLUSTER_CONTEXT for 02 only)
    if [[ "$script" =~ ^0[0-2]- ]] && [ -z "${TARGET_CLUSTER_CONTEXT:-}" ]; then
        log "Ensuring local-cluster context for script $script..."
        if oc config use-context local-cluster >/dev/null 2>&1; then
            log "✓ Switched to local-cluster context"
        else
            warning "Failed to switch to local-cluster context. Script will use current context."
        fi
    fi
    
    # Make sure script is executable
    chmod +x "$SCRIPT_DIR/$script"
    
    # Execute the script
    if bash "$SCRIPT_DIR/$script"; then
        log "✓ Successfully completed: $script"
    else
        EXIT_CODE=$?
        error "✗ Script failed: $script (exit code: $EXIT_CODE)"
        FAILED_SCRIPTS+=("$script")
    fi
    
    log ""
done

# Compliance Operator on second cluster (aws-us) when that context exists
if context_exists aws-us; then
    log "========================================================="
    log "Compliance Operator: aws-us cluster"
    log "========================================================="
    if oc config use-context aws-us >/dev/null 2>&1; then
        log "✓ Switched to aws-us context"
        TARGET_CLUSTER_CONTEXT=aws-us bash "$SCRIPT_DIR/02-compliance-operator-install.sh"
        log "✓ Completed compliance operator setup for aws-us"
    else
        warning "Could not switch to aws-us; skipping second-cluster compliance install"
    fi
    if oc config use-context local-cluster >/dev/null 2>&1; then
        log "✓ Switched back to local-cluster context"
    fi
    log ""
else
    log "No aws-us context in kubeconfig; skipping Compliance Operator install on second cluster"
    log ""
fi

# Restore original context if it was set
if [ -n "$ORIGINAL_CONTEXT" ]; then
    log "Restoring original context: $ORIGINAL_CONTEXT"
    oc config use-context "$ORIGINAL_CONTEXT" >/dev/null 2>&1 || true
fi

# Summary
log "========================================================="
log "Setup Summary"
log "========================================================="
log "Total scripts executed: $TOTAL"

if [ ${#FAILED_SCRIPTS[@]} -eq 0 ]; then
    log "✓ All scripts completed successfully!"
    log "========================================================="
    
    # Display RHACS URL and password if RHACS is installed
    log ""
    log "========================================================="
    log "RHACS Access Information"
    log "========================================================="
    
    # Detect RHACS namespace - check stackrox first (newer installations), then rhacs-operator (older installations)
    RHACS_NAMESPACE=""
    if oc get route central -n "stackrox" -o jsonpath='{.spec.host}' >/dev/null 2>&1; then
        RHACS_NAMESPACE="stackrox"
    elif oc get route central -n "rhacs-operator" -o jsonpath='{.spec.host}' >/dev/null 2>&1; then
        RHACS_NAMESPACE="rhacs-operator"
    fi
    
    if [ -z "$RHACS_NAMESPACE" ]; then
        log "RHACS Central URL: Not found (route 'central' not found in 'stackrox' or 'rhacs-operator' namespace)"
        log "Admin Password: Not found (RHACS not detected)"
    else
        # Get RHACS Central URL from route
        CENTRAL_ROUTE=$(oc get route central -n "$RHACS_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
        if [ -n "$CENTRAL_ROUTE" ]; then
            # Check if route uses TLS
            CENTRAL_TLS=$(oc get route central -n "$RHACS_NAMESPACE" -o jsonpath='{.spec.tls}' 2>/dev/null || echo "")
            if [ -n "$CENTRAL_TLS" ] && [ "$CENTRAL_TLS" != "null" ]; then
                CENTRAL_URL="https://${CENTRAL_ROUTE}"
            else
                CENTRAL_URL="http://${CENTRAL_ROUTE}"
            fi
            log "RHACS Central URL: $CENTRAL_URL"
        else
            log "RHACS Central URL: Not found (route 'central' not found in namespace '$RHACS_NAMESPACE')"
        fi
        
        # Get admin password from secret
        ADMIN_PASSWORD_B64=""
        if oc get secret central-htpasswd -n "$RHACS_NAMESPACE" >/dev/null 2>&1; then
            # Secret exists, try to extract password
            ADMIN_PASSWORD_B64=$(oc get secret central-htpasswd -n "$RHACS_NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null || echo "")
            
            # If password key not found, try alternative key names
            if [ -z "$ADMIN_PASSWORD_B64" ]; then
                ADMIN_PASSWORD_B64=$(oc get secret central-htpasswd -n "$RHACS_NAMESPACE" -o jsonpath='{.data.adminPassword}' 2>/dev/null || echo "")
            fi
            
            # If still not found, try to get all keys and use the first one
            if [ -z "$ADMIN_PASSWORD_B64" ]; then
                SECRET_DATA=$(oc get secret central-htpasswd -n "$RHACS_NAMESPACE" -o json 2>/dev/null || echo "")
                if [ -n "$SECRET_DATA" ] && command -v jq >/dev/null 2>&1; then
                    FIRST_KEY=$(echo "$SECRET_DATA" | jq -r '.data | keys[0]' 2>/dev/null || echo "")
                    if [ -n "$FIRST_KEY" ] && [ "$FIRST_KEY" != "null" ]; then
                        ADMIN_PASSWORD_B64=$(echo "$SECRET_DATA" | jq -r ".data.$FIRST_KEY" 2>/dev/null || echo "")
                    fi
                fi
            fi
            
            # If still not found, try environment variable as fallback
            if [ -z "$ADMIN_PASSWORD_B64" ] && [ -n "$ACS_PORTAL_PASSWORD" ]; then
                ADMIN_PASSWORD_B64="$ACS_PORTAL_PASSWORD"
            fi
        elif [ -n "$ACS_PORTAL_PASSWORD" ]; then
            # Secret doesn't exist but environment variable is available
            ADMIN_PASSWORD_B64="$ACS_PORTAL_PASSWORD"
        fi
        
        if [ -n "$ADMIN_PASSWORD_B64" ]; then
            ADMIN_PASSWORD=$(echo "$ADMIN_PASSWORD_B64" | base64 -d 2>/dev/null || echo "")
            if [ -n "$ADMIN_PASSWORD" ]; then
                log "Admin Username: admin"
                log "Admin Password: $ADMIN_PASSWORD"
            else
                log "Admin Password: Could not decode password from secret"
            fi
        else
            log "Admin Password: Not found (secret 'central-htpasswd' not accessible in namespace '$RHACS_NAMESPACE' and ACS_PORTAL_PASSWORD not set)"
        fi
    fi
    
    log "========================================================="
    log ""
    exit 0
else
    error "✗ Failed scripts: ${FAILED_SCRIPTS[*]}"
fi
