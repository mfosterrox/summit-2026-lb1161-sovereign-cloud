#!/bin/bash
# Verify DataScienceCluster and dashboard route (no changes to the cluster).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[AI-CHECK]${NC} $1"; }
warn() { echo -e "${YELLOW}[AI-CHECK]${NC} $1"; }
fail() { echo -e "${RED}[AI-CHECK] FAIL:${NC} $1" >&2; exit 1; }

DSC_CR_NAME="default-dsc"
DSC_NAMESPACE="redhat-ods-applications"

log "========================================================="
log "OpenShift AI — DataScienceCluster verification"
log "========================================================="
log ""

log "Checking OpenShift CLI..."
if ! oc whoami &>/dev/null; then
  fail "Not logged in. Run: oc login"
fi
log "✓ Connected as $(oc whoami)"

REQUIRED_CONTEXT="local-cluster"
CURRENT_CONTEXT=$(oc config current-context 2>/dev/null || echo "")
if [ "$CURRENT_CONTEXT" != "$REQUIRED_CONTEXT" ]; then
  if ! oc config get-contexts "$REQUIRED_CONTEXT" &>/dev/null; then
    fail "Context '$REQUIRED_CONTEXT' not found"
  fi
  oc config use-context "$REQUIRED_CONTEXT" &>/dev/null || fail "Could not switch to $REQUIRED_CONTEXT"
  log "✓ Using context $REQUIRED_CONTEXT"
else
  log "✓ Context $REQUIRED_CONTEXT"
fi

log ""
log "Checking DataScienceCluster CRD..."
oc get crd datascienceclusters.datasciencecluster.opendatahub.io &>/dev/null \
  || fail "DataScienceCluster CRD not found"

log "Checking namespace $DSC_NAMESPACE..."
oc get namespace "$DSC_NAMESPACE" &>/dev/null || fail "Namespace '$DSC_NAMESPACE' not found"

log "Checking DataScienceCluster $DSC_CR_NAME..."
oc get datasciencecluster "$DSC_CR_NAME" -n "$DSC_NAMESPACE" &>/dev/null \
  || fail "DataScienceCluster '$DSC_CR_NAME' not found in $DSC_NAMESPACE"

DSC_STATUS=$(oc get datasciencecluster "$DSC_CR_NAME" -n "$DSC_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
[ "$DSC_STATUS" = "Ready" ] || fail "DataScienceCluster phase is '${DSC_STATUS:-unknown}' (expected Ready). Try: oc describe datasciencecluster $DSC_CR_NAME -n $DSC_NAMESPACE"

log "Checking dashboard route..."
DASHBOARD_ROUTE=$(oc get route rhods-dashboard -n "$DSC_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -z "$DASHBOARD_ROUTE" ]; then
  DASHBOARD_ROUTE=$(oc get route -n "$DSC_NAMESPACE" -l app=odh-dashboard -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")
fi
if [ -z "$DASHBOARD_ROUTE" ]; then
  warn "No rhods-dashboard / odh-dashboard route found yet (DSC is Ready — route may differ by version)"
else
  log "✓ Dashboard host: $DASHBOARD_ROUTE"
fi

log ""
log "✓ DataScienceCluster checks passed (Ready)"
log ""
log "Quick status:"
oc get datasciencecluster "$DSC_CR_NAME" -n "$DSC_NAMESPACE" 2>/dev/null || true
log ""
