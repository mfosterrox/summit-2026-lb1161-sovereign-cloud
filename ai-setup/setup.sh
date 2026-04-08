#!/bin/bash
# Verify Red Hat OpenShift AI is installed (operator + DataScienceCluster). Read-only checks only.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=resolve-dashboard-host.sh
source "${SCRIPT_DIR}/resolve-dashboard-host.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[AI-SETUP]${NC} $1"; }
warn() { echo -e "${YELLOW}[AI-SETUP]${NC} $1"; }
error() { echo -e "${RED}[AI-SETUP] ERROR:${NC} $1" >&2; exit 1; }
info() { echo -e "${BLUE}[AI-SETUP]${NC} $1"; }

while [[ $# -gt 0 ]]; do
  case $1 in
    --help|-h)
      echo "Usage: $0"
      echo ""
      echo "Runs read-only verification that OpenShift AI is installed:"
      echo "  1. Operator / CSV / CRD (01-operator.sh)"
      echo "  2. DataScienceCluster Ready + dashboard route (02-cluster.sh)"
      echo ""
      echo "Requires: oc, logged in, context local-cluster (script will switch if present)."
      exit 0
      ;;
    *)
      error "Unknown option: $1. Use --help."
      ;;
  esac
done

OPERATOR_SCRIPT="${SCRIPT_DIR}/01-operator.sh"
CLUSTER_SCRIPT="${SCRIPT_DIR}/02-cluster.sh"
[ -f "$OPERATOR_SCRIPT" ] || error "Missing $OPERATOR_SCRIPT"
[ -f "$CLUSTER_SCRIPT" ] || error "Missing $CLUSTER_SCRIPT"

log "========================================================="
log "Red Hat OpenShift AI — verification"
log "========================================================="
log ""

bash "$OPERATOR_SCRIPT"
bash "$CLUSTER_SCRIPT"

log "========================================================="
log "All checks passed"
log "========================================================="
log ""
info "Useful commands:"
log "  oc get pods -n redhat-ods-operator"
log "  oc get datasciencecluster -n redhat-ods-applications"
log "  oc get pods -n redhat-ods-applications"
log ""

DSC_NAMESPACE="redhat-ods-applications"
DASHBOARD_ROUTE=$(ai_resolve_dashboard_host || true)

log "========================================================="
log "OpenShift AI access (informational)"
log "========================================================="
if [ -n "$DASHBOARD_ROUTE" ]; then
  log "Dashboard URL: https://$DASHBOARD_ROUTE"
else
  warn "Dashboard host not resolved; try: oc get route -n $DSC_NAMESPACE; oc get route -n openshift-ingress | egrep 'rhods-dashboard|data-science-gateway'"
fi
log "Username: admin (or your OpenShift identity provider user)"

ADMIN_PASSWORD=""
if [ -n "${ACS_PORTAL_PASSWORD:-}" ]; then
  ADMIN_PASSWORD="$ACS_PORTAL_PASSWORD"
elif [ -f ~/.bashrc ]; then
  ADMIN_PASSWORD=$(grep -E "^export ACS_PORTAL_PASSWORD=" ~/.bashrc | sed 's/^export ACS_PORTAL_PASSWORD="\(.*\)"/\1/' | sed "s/^export ACS_PORTAL_PASSWORD='\(.*\)'/\1/" | sed 's/^export ACS_PORTAL_PASSWORD=\(.*\)/\1/' | head -1 || true)
fi
if [ -z "$ADMIN_PASSWORD" ]; then
  KUBEADMIN_PASSWORD_B64=$(oc get secret kubeadmin -n kube-system -o jsonpath='{.data.password}' 2>/dev/null || echo "")
  [ -n "$KUBEADMIN_PASSWORD_B64" ] && ADMIN_PASSWORD=$(echo "$KUBEADMIN_PASSWORD_B64" | base64 -d 2>/dev/null || echo "")
fi
[ -z "$ADMIN_PASSWORD" ] && [ -n "${OPENSHIFT_ADMIN_PASSWORD:-}" ] && ADMIN_PASSWORD="$OPENSHIFT_ADMIN_PASSWORD"
[ -z "$ADMIN_PASSWORD" ] && [ -n "${AWS_OPENSHIFT_KUBEADMIN_PASSWORD:-}" ] && ADMIN_PASSWORD="$AWS_OPENSHIFT_KUBEADMIN_PASSWORD"

if [ -n "$ADMIN_PASSWORD" ]; then
  log "Password: $ADMIN_PASSWORD"
else
  log "Password: (set ACS_PORTAL_PASSWORD / use kubeadmin secret / cluster credentials)"
fi
log "========================================================="
log ""
