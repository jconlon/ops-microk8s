# ops-microk8s task runner
# Run `just` to list available recipes

# Default: list recipes
default:
    @just --list

# ── Testing ───────────────────────────────────────────────────────────────────

# Run all chainsaw e2e tests
test:
    chainsaw test tests/

# Run a specific test suite (cluster, storage, gpu, postgresql, argocd)
test-suite suite:
    chainsaw test tests/{{suite}}

# Run tests with verbose output
test-verbose:
    chainsaw test tests/ --verbose

# ── Cluster ───────────────────────────────────────────────────────────────────

# Show node uptime and reboot-required status
node-status:
    ops cluster node-status

# Show node uptime only
node-uptime:
    ops cluster node-uptime

# Check Ceph cluster health
ceph-status:
    kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph status

# Show all non-running pods across the cluster
pods-unhealthy:
    kubectl get pods -A --no-headers | grep -v Running | grep -v Completed

# ── ArgoCD ────────────────────────────────────────────────────────────────────

# Login to ArgoCD
argocd-login:
    ops argocd login

# List all ArgoCD applications
argocd-apps:
    ops argocd list-app

# ── PostgreSQL ────────────────────────────────────────────────────────────────

# Show CloudNativePG cluster status
pg-status:
    kubectl cnpg status production-postgresql -n postgresql-system

# Open interactive psql session to FreshRSS database
freshrss-psql:
    ops freshrss psql

# ── GPU ───────────────────────────────────────────────────────────────────────

# Show GPU resources on whale
gpu-status:
    kubectl get node whale -o jsonpath='{.status.allocatable}' | tr ',' '\n' | grep nvidia

# Show GPU operator pod status
gpu-pods:
    kubectl get pods -n gpu-operator

# ── vLLM ──────────────────────────────────────────────────────────────────────

# Show vLLM pod status and node placement
vllm-status:
    kubectl get pods -n vllm -o wide

# Run vLLM chainsaw tests
test-vllm:
    chainsaw test tests/vllm
