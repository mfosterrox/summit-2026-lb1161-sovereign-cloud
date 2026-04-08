#!/bin/bash
# Deploy RHACS Secured Cluster Services on aws-us, registering to Central on local-cluster.
# Prerequisites: roxctl (00), Central reachable on local-cluster, kube contexts local-cluster + aws-us.
#
# Optional: export INIT_BUNDLE_FILE=/path/to/existing-secrets.yaml to skip roxctl generation (file must exist).
# Optional: INIT_BUNDLE_LABEL — name for the bundle in Central (default lab-aws-us-<random>, avoids duplicate-name errors).
# Optional: RHACS_SECURED_NAMESPACE (default rhacs-operator) — target ns on aws-us for operator + SecuredCluster.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[SCS-AWS-US]${NC} $1"; }
warning() { echo -e "${YELLOW}[SCS-AWS-US]${NC} $1"; }
error() { echo -e "${RED}[SCS-AWS-US] ERROR:${NC} $1" >&2; exit 1; }

CLUSTER_CONTEXT="${SECURED_CLUSTER_CONTEXT:-aws-us}"
CLUSTER_NAME="${SECURED_CLUSTER_NAME:-aws-us}"
RHACS_SECURED_NAMESPACE="${RHACS_SECURED_NAMESPACE:-rhacs-operator}"

context_exists() {
    oc config get-contexts -o name 2>/dev/null | sed 's|^context/||' | grep -qx "$1"
}

if ! context_exists "$CLUSTER_CONTEXT"; then
    log "No '$CLUSTER_CONTEXT' context in kubeconfig; skipping Secured Cluster install on second cluster."
    exit 0
fi

if ! command -v oc >/dev/null 2>&1; then
    error "oc not found"
fi

if ! command -v roxctl >/dev/null 2>&1; then
    error "roxctl not found. Run 00-install-roxctl.sh first."
fi

log "========================================================="
log "Secured Cluster Services → Central (local-cluster) + deploy on $CLUSTER_CONTEXT"
log "========================================================="

oc config use-context local-cluster >/dev/null 2>&1 || error "Cannot switch to local-cluster context"

CENTRAL_NS=""
for ns in stackrox rhacs-operator; do
    if oc get secret central-htpasswd -n "$ns" >/dev/null 2>&1 && oc get route central -n "$ns" >/dev/null 2>&1; then
        CENTRAL_NS="$ns"
        break
    fi
done
if [ -z "$CENTRAL_NS" ]; then
    error "Could not find route 'central' and secret 'central-htpasswd' in stackrox or rhacs-operator on local-cluster"
fi
log "✓ Central namespace on local-cluster: $CENTRAL_NS"

CENTRAL_ROUTE=$(oc get route central -n "$CENTRAL_NS" -o jsonpath='{.spec.host}' 2>/dev/null || true)
[ -n "$CENTRAL_ROUTE" ] || error "Could not read central route host"

CENTRAL_TLS=$(oc get route central -n "$CENTRAL_NS" -o jsonpath='{.spec.tls}' 2>/dev/null || echo "")
if [ -n "$CENTRAL_TLS" ] && [ "$CENTRAL_TLS" != "null" ]; then
    ROX_ENDPOINT="${CENTRAL_ROUTE}:443"
else
    ROX_ENDPOINT="${CENTRAL_ROUTE}"
fi
log "✓ ROX endpoint: $ROX_ENDPOINT"

ADMIN_PASSWORD_B64=$(oc get secret central-htpasswd -n "$CENTRAL_NS" -o jsonpath='{.data.password}' 2>/dev/null || true)
if [ -z "$ADMIN_PASSWORD_B64" ]; then
    ADMIN_PASSWORD_B64=$(oc get secret central-htpasswd -n "$CENTRAL_NS" -o jsonpath='{.data.adminPassword}' 2>/dev/null || true)
fi
[ -n "$ADMIN_PASSWORD_B64" ] || error "Could not read admin password from central-htpasswd"
ADMIN_PASSWORD=$(echo "$ADMIN_PASSWORD_B64" | base64 -d 2>/dev/null || true)
[ -n "$ADMIN_PASSWORD" ] || error "Could not decode admin password"

mkdir -p "${SCRIPT_DIR}/init-bundles"
INIT_BUNDLES_DIR="${SCRIPT_DIR}/init-bundles"
RANDOM_SUFFIX=$((RANDOM % 100000))

if [ -n "${INIT_BUNDLE_FILE:-}" ]; then
    [ -f "$INIT_BUNDLE_FILE" ] || error "INIT_BUNDLE_FILE is set but file not found: $INIT_BUNDLE_FILE"
    log "Using existing init bundle: $INIT_BUNDLE_FILE"
else
    ROX_INIT_BUNDLE_NAME="${INIT_BUNDLE_LABEL:-lab-aws-us-${RANDOM_SUFFIX}}"
    INIT_BUNDLE_FILE="${INIT_BUNDLES_DIR}/${CLUSTER_NAME}-init-bundle-${RANDOM_SUFFIX}.yaml"
    export ROX_ENDPOINT
    export ROX_ADMIN_PASSWORD="$ADMIN_PASSWORD"
    export ROX_INSECURE_CLIENT_SKIP_TLS_VERIFY="${ROX_INSECURE_CLIENT_SKIP_TLS_VERIFY:-true}"
    log "Generating init bundle '$ROX_INIT_BUNDLE_NAME' with roxctl..."
    roxctl central init-bundles generate "$ROX_INIT_BUNDLE_NAME" \
        --output-secrets "$INIT_BUNDLE_FILE" \
        --insecure-skip-tls-verify
    log "✓ Init bundle written to $INIT_BUNDLE_FILE"
fi

if ! grep -q "kind: Secret" "$INIT_BUNDLE_FILE" 2>/dev/null; then
    error "Init bundle does not look like Kubernetes Secrets YAML: $INIT_BUNDLE_FILE"
fi
if grep -q "00000000-0000-0000-0000-000000000000" "$INIT_BUNDLE_FILE" 2>/dev/null; then
    error "Init bundle contains wildcard cluster ID; regenerate from Central (see RH Solution 6972449)"
fi

oc config use-context "$CLUSTER_CONTEXT" >/dev/null 2>&1 || error "Cannot switch to context $CLUSTER_CONTEXT"

log "Ensuring namespace $RHACS_SECURED_NAMESPACE on $CLUSTER_CONTEXT..."
oc get ns "$RHACS_SECURED_NAMESPACE" >/dev/null 2>&1 || oc create namespace "$RHACS_SECURED_NAMESPACE"

if ! oc get crd securedclusters.platform.stackrox.io >/dev/null 2>&1; then
    log "RHACS operator not detected (no SecuredCluster CRD); installing from OperatorHub..."
    if ! oc get operatorgroup rhacs-operator-group -n "$RHACS_SECURED_NAMESPACE" >/dev/null 2>&1; then
        oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: rhacs-operator-group
  namespace: ${RHACS_SECURED_NAMESPACE}
spec: {}
EOF
    fi
    oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhacs-operator
  namespace: ${RHACS_SECURED_NAMESPACE}
spec:
  channel: stable
  name: rhacs-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
    log "Waiting for SecuredCluster CRD (up to 300s)..."
    for _ in $(seq 1 60); do
        oc get crd securedclusters.platform.stackrox.io >/dev/null 2>&1 && break
        sleep 5
    done
    oc get crd securedclusters.platform.stackrox.io >/dev/null 2>&1 || \
        error "Timed out waiting for rhacs-operator / SecuredCluster CRD"
fi
log "✓ SecuredCluster CRD available"

for secret in sensor-tls admission-control-tls collector-tls; do
    oc delete secret "$secret" -n "$RHACS_SECURED_NAMESPACE" --ignore-not-found=true >/dev/null 2>&1 || true
done

log "Applying init bundle secrets to $RHACS_SECURED_NAMESPACE..."
oc apply -f "$INIT_BUNDLE_FILE" -n "$RHACS_SECURED_NAMESPACE"

CENTRAL_ENDPOINT="$ROX_ENDPOINT"
CENTRAL_ENDPOINT="${CENTRAL_ENDPOINT#https://}"
CENTRAL_ENDPOINT="${CENTRAL_ENDPOINT#http://}"
CENTRAL_ENDPOINT="${CENTRAL_ENDPOINT%%/*}"
CENTRAL_ENDPOINT="${CENTRAL_ENDPOINT%/}"
[[ "$CENTRAL_ENDPOINT" == *:* ]] || CENTRAL_ENDPOINT="${CENTRAL_ENDPOINT}:443"

log "Applying SecuredCluster (centralEndpoint=$CENTRAL_ENDPOINT)..."
oc apply -f - <<EOF
apiVersion: platform.stackrox.io/v1alpha1
kind: SecuredCluster
metadata:
  name: ${CLUSTER_NAME}
  namespace: ${RHACS_SECURED_NAMESPACE}
spec:
  clusterName: "${CLUSTER_NAME}"
  centralEndpoint: "${CENTRAL_ENDPOINT}"
  auditLogs:
    collection: Auto
  admissionControl:
    enforcement: Enabled
    bypass: BreakGlassAnnotation
    failurePolicy: Ignore
    dynamic:
      disableBypass: false
    replicas: 1
    tolerations:
      - key: node-role.kubernetes.io/master
        operator: Exists
        effect: NoSchedule
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
        effect: NoSchedule
  scanner:
    scannerComponent: Disabled
  scannerV4:
    scannerComponent: AutoSense
    indexer:
      replicas: 1
    tolerations:
      - key: node-role.kubernetes.io/master
        operator: Exists
        effect: NoSchedule
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
        effect: NoSchedule
  collector:
    collectionMethod: EBPF
    tolerations:
      - key: node-role.kubernetes.io/master
        operator: Exists
        effect: NoSchedule
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
        effect: NoSchedule
  sensor:
    tolerations:
      - key: node-role.kubernetes.io/master
        operator: Exists
        effect: NoSchedule
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
        effect: NoSchedule
  processBaselines:
    autoLock: Enabled
EOF

log "✓ SecuredCluster applied; sensor will connect to Central on local-cluster"
warning "If pods stay Pending, check node capacity and: oc get pods -n $RHACS_SECURED_NAMESPACE"

oc config use-context local-cluster >/dev/null 2>&1 || true
log "========================================================="
log "Secured Cluster setup for $CLUSTER_CONTEXT complete"
log "========================================================="
