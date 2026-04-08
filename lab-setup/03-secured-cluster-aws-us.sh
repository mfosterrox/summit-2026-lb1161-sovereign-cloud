#!/bin/bash
# Verify pre-provisioned RHACS: Central and Secured Cluster on local-cluster; Secured Cluster on aws-us.
# Does not install or generate init bundles — no central-htpasswd or roxctl required.
#
# Optional: SECURED_CLUSTER_CONTEXT (default aws-us) — kube context for the second cluster check.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[RHACS-VERIFY]${NC} $1"; }
warning() { echo -e "${YELLOW}[RHACS-VERIFY]${NC} $1"; }
error() { echo -e "${RED}[RHACS-VERIFY] ERROR:${NC} $1" >&2; exit 1; }

CLUSTER_CONTEXT="${SECURED_CLUSTER_CONTEXT:-aws-us}"
RHACS_NAMESPACES=(stackrox rhacs-operator)

context_exists() {
    oc config get-contexts -o name 2>/dev/null | sed 's|^context/||' | grep -qx "$1"
}

if ! command -v oc >/dev/null 2>&1; then
    error "oc not found"
fi

deployment_ready() {
    local ns="$1"
    local name="$2"
    local ready desired
    ready=$(oc get deployment "$name" -n "$ns" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "")
    desired=$(oc get deployment "$name" -n "$ns" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "")
    if [ -z "$desired" ] || [ "$desired" = "0" ]; then
        return 1
    fi
    [ -n "$ready" ] && [ "$ready" = "$desired" ]
}

find_central_namespace() {
    local ns
    for ns in "${RHACS_NAMESPACES[@]}"; do
        if oc get route central -n "$ns" >/dev/null 2>&1; then
            echo "$ns"
            return 0
        fi
    done
    return 1
}

find_sensor_namespace() {
    local ns
    for ns in "${RHACS_NAMESPACES[@]}"; do
        if oc get deployment sensor -n "$ns" >/dev/null 2>&1; then
            echo "$ns"
            return 0
        fi
    done
    return 1
}

log "========================================================="
log "Verifying RHACS Central + Secured Cluster (pre-provisioned env)"
log "========================================================="

# --- local-cluster (Central + local Secured Cluster) ---
oc config use-context local-cluster >/dev/null 2>&1 || error "Cannot switch to local-cluster context"

CENTRAL_NS=""
if CENTRAL_NS=$(find_central_namespace); then
    :
else
    error "No route 'central' in stackrox or rhacs-operator on local-cluster"
fi

CENTRAL_HOST=$(oc get route central -n "$CENTRAL_NS" -o jsonpath='{.spec.host}' 2>/dev/null || true)
[ -n "$CENTRAL_HOST" ] || error "Could not read Central route host in namespace $CENTRAL_NS"

log "✓ Central route on local-cluster: namespace=$CENTRAL_NS host=$CENTRAL_HOST"

if oc get deployment central -n "$CENTRAL_NS" >/dev/null 2>&1; then
    if deployment_ready "$CENTRAL_NS" central; then
        log "✓ Deployment central is Available (ready=replicas) in $CENTRAL_NS"
    else
        error "Deployment central in $CENTRAL_NS is not fully ready: oc get deploy central -n $CENTRAL_NS"
    fi
else
    error "Deployment central not found in $CENTRAL_NS"
fi

SENSOR_NS_LOCAL=""
if SENSOR_NS_LOCAL=$(find_sensor_namespace); then
    if deployment_ready "$SENSOR_NS_LOCAL" sensor; then
        log "✓ Secured Cluster sensor on local-cluster: deployment/sensor ready in $SENSOR_NS_LOCAL"
    else
        error "Deployment sensor in $SENSOR_NS_LOCAL is not fully ready: oc get deploy sensor -n $SENSOR_NS_LOCAL"
    fi
else
    error "No deployment sensor in stackrox or rhacs-operator on local-cluster"
fi

if oc get crd securedclusters.platform.stackrox.io >/dev/null 2>&1; then
    if oc get securedcluster.platform.stackrox.io -A -o name 2>/dev/null | grep -q .; then
        log "✓ SecuredCluster CR(s) on local-cluster:"
        oc get securedcluster.platform.stackrox.io -A 2>/dev/null || true
    else
        warning "No SecuredCluster CR listed on local-cluster (sensor still verified above)"
    fi
fi

# --- aws-us (remote Secured Cluster reporting to Central) ---
if ! context_exists "$CLUSTER_CONTEXT"; then
    warning "No '$CLUSTER_CONTEXT' context in kubeconfig — skipping second-cluster Secured Cluster checks"
    log "========================================================="
    log "RHACS verification complete (local-cluster only)"
    log "========================================================="
    exit 0
fi

oc config use-context "$CLUSTER_CONTEXT" >/dev/null 2>&1 || error "Cannot switch to context $CLUSTER_CONTEXT"

SENSOR_NS_REMOTE=""
if SENSOR_NS_REMOTE=$(find_sensor_namespace); then
    if deployment_ready "$SENSOR_NS_REMOTE" sensor; then
        log "✓ Secured Cluster sensor on $CLUSTER_CONTEXT: deployment/sensor ready in $SENSOR_NS_REMOTE"
    else
        error "Deployment sensor in $SENSOR_NS_REMOTE on $CLUSTER_CONTEXT is not fully ready"
    fi
else
    error "No deployment sensor in stackrox or rhacs-operator on context $CLUSTER_CONTEXT"
fi

if oc get crd securedclusters.platform.stackrox.io >/dev/null 2>&1; then
    if oc get securedcluster.platform.stackrox.io -A -o name 2>/dev/null | grep -q .; then
        log "✓ SecuredCluster CR(s) on $CLUSTER_CONTEXT:"
        oc get securedcluster.platform.stackrox.io -A 2>/dev/null || true
    else
        warning "No SecuredCluster CR listed on $CLUSTER_CONTEXT (sensor deployment verified)"
    fi
fi

oc config use-context local-cluster >/dev/null 2>&1 || true

log "========================================================="
log "RHACS verification complete: Central + SCS on local-cluster; SCS on $CLUSTER_CONTEXT"
log "========================================================="
