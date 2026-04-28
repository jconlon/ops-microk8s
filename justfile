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

# Verify puffer ACPI power key mitigations are in place (issue #59)
puffer-powerkey-status:
    #!/usr/bin/env bash
    echo "Checking puffer power key mitigations..."
    kubectl debug node/puffer --image=alpine:latest --quiet --rm \
      -- sh -c '
        grep -q "HandlePowerKey=ignore" /host/etc/systemd/logind.conf \
          && echo "PASS  HandlePowerKey=ignore" \
          || echo "FAIL  HandlePowerKey=ignore missing"
        grep -q "HandlePowerKeyLongPress=ignore" /host/etc/systemd/logind.conf \
          && echo "PASS  HandlePowerKeyLongPress=ignore" \
          || echo "FAIL  HandlePowerKeyLongPress=ignore missing"
        test -f /host/etc/udev/rules.d/99-ignore-power-button.udev \
          && echo "PASS  udev power button suppression rule" \
          || echo "FAIL  udev rule missing"
      ' 2>/dev/null

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

# ── Argo Workflows ────────────────────────────────────────────────────────────

# Show Argo Workflows pod status
argo-status:
    kubectl get pods -n argo-workflows -o wide

# Run Argo Workflows chainsaw tests
test-argo-workflows:
    chainsaw test tests/argo-workflows

# E2e build test: submit a minimal Alpine image via image-build-push WorkflowTemplate,
# verify the image appears in Harbor, then clean up the workflow and artifact.
# Requires: harbor-credentials secret, image-build-push WorkflowTemplate, tests/e2e-build/Dockerfile.
# NOTE: the robot account needs delete permission in Harbor for artifact cleanup to succeed.
test-build-e2e:
    #!/usr/bin/env bash
    set -euo pipefail
    NS=argo-workflows
    PROJECT=library
    REPO=kaniko-e2e-test
    TAG=e2e-$(date +%s)
    IMAGE="registry.verticon.com/$PROJECT/$REPO:$TAG"

    cleanup() {
        if [ -n "${WF_NAME:-}" ]; then
            echo ">>> Cleaning up workflow $WF_NAME..."
            kubectl delete workflow "$WF_NAME" -n $NS --ignore-not-found >/dev/null 2>&1 || true
        fi
    }
    trap cleanup EXIT

    echo ">>> Submitting kaniko build: $IMAGE"
    WF_NAME=$(argo submit -n $NS \
        --from workflowtemplate/image-build-push \
        -p repo-url=https://github.com/jconlon/ops-microk8s \
        -p image="$IMAGE" \
        -p context=tests/e2e-build \
        -o name)
    echo "    workflow: $WF_NAME"

    echo ">>> Waiting for completion (timeout: 10m)..."
    if ! argo wait -n $NS "$WF_NAME" --timeout 10m; then
        echo "FAIL  workflow did not succeed"
        argo logs -n $NS "$WF_NAME" 2>/dev/null || true
        exit 1
    fi
    echo "PASS  workflow succeeded"

    echo ">>> Verifying image in Harbor..."
    AUTH=$(kubectl get secret harbor-credentials -n $NS \
        -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | \
        python3 -c "import sys,json; d=json.load(sys.stdin); print(d['auths']['registry.verticon.com']['auth'])")
    DIGEST=$(curl -sf \
        -H "Authorization: Basic $AUTH" \
        "https://registry.verticon.com/api/v2.0/projects/$PROJECT/repositories/$REPO/artifacts/$TAG" | \
        python3 -c "import sys,json; print(json.load(sys.stdin)['digest'][:19])")
    echo "PASS  image present in Harbor: $DIGEST"

    echo ">>> Removing artifact from Harbor..."
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
        -H "Authorization: Basic $AUTH" \
        "https://registry.verticon.com/api/v2.0/projects/$PROJECT/repositories/$REPO/artifacts/$TAG")
    if [ "$HTTP" = "200" ] || [ "$HTTP" = "202" ]; then
        echo "PASS  artifact deleted"
    else
        echo "WARN  artifact deletion returned HTTP $HTTP — robot account may lack delete permission; clean up manually in Harbor"
    fi

    echo ">>> Done."

# ── Argo Events ───────────────────────────────────────────────────────────────

# Show Argo Events pod and resource status
argo-events-status:
    #!/usr/bin/env bash
    echo "=== Pods ==="
    kubectl get pods -n argo-events -o wide
    echo ""
    echo "=== EventBus / EventSource / Sensor ==="
    kubectl get eventbus,eventsource,sensor -n argo-events
    echo ""
    echo "=== Service IPs ==="
    kubectl get svc -n argo-events

# Run Argo Events chainsaw tests
test-argo-events:
    chainsaw test tests/argo-events

# ── Harbor ────────────────────────────────────────────────────────────────────

# Show Harbor pod status
harbor-status:
    kubectl get pods -n harbor -o wide

# Run Harbor chainsaw tests
test-harbor:
    chainsaw test tests/harbor

# ── vLLM ──────────────────────────────────────────────────────────────────────

# Show vLLM pod status and node placement
vllm-status:
    kubectl get pods -n vllm -o wide

# Run vLLM chainsaw tests
test-vllm:
    chainsaw test tests/vllm

# ── Loki ──────────────────────────────────────────────────────────────────────

# Show Loki + Promtail pod status
loki-status:
    kubectl get pods -n loki -o wide

# Run Loki chainsaw tests
test-loki:
    chainsaw test tests/loki

# Query syslog events for a node (default: puffer, last 24h)
loki-node-events node="puffer" since="24h":
    ops loki node-events {{node}} --since {{since}}

# Query shutdown/power/reboot events for a node (default: puffer, last 7d)
loki-shutdown-events node="puffer" since="7d":
    ops loki shutdown-events {{node}} --since {{since}}

# Query iDRAC hardware events for a Dell R320 node (default: puffer, last 7d)
loki-idrac node="puffer" since="7d":
    ops loki idrac {{node}} --since {{since}}

# Show last boot time + shutdown event count for all nodes
loki-reboot-history since="7d":
    ops loki reboot-history --since {{since}}

# Live tail syslog for a node (Ctrl+C to stop)
loki-tail node="puffer":
    ops loki tail {{node}}

# Query systemd journal stream for a node and filter term — first-line check
# before escalating to kubectl debug when investigating anomalies (issue #64).
# The journal stream captures logind, kernel errors, unit failures that rsyslog misses.
# Examples:
#   just loki-journal-check puffer "Power key" 24h
#   just loki-journal-check gold "OOM" 48h
#   just loki-journal-check whale "entered failed state" 7d
loki-journal-check node="puffer" filter="Power key" since="24h":
    #!/usr/bin/env bash
    echo "=== journal stream: node={{node}} filter='{{filter}}' since={{since}} ==="
    logcli --addr=http://192.168.0.220 \
      query "{job=\"journal\", node=\"{{node}}\"} |= \"{{filter}}\"" \
      --since={{since}} --limit=100 --timezone=Local
    echo ""
    echo "=== journal stream flowing? (last 5 min) ==="
    COUNT=$(logcli --addr=http://192.168.0.220 \
      query "{job=\"journal\", node=\"{{node}}\"}" \
      --since=5m --limit=1 --quiet 2>/dev/null | wc -l)
    if [ "$COUNT" -gt 0 ]; then
      echo "PASS  journal stream active for {{node}}"
    else
      echo "WARN  no journal entries in last 5 min — stream may be delayed or node down"
    fi

# Check syslog is flowing from all 8 nodes into Loki (last 15 minutes)
loki-node-logs:
    #!/usr/bin/env bash
    LOKI="http://192.168.0.220"
    START=$(date -u -d '15 minutes ago' +%s)000000000
    END=$(date -u +%s)000000000
    FAILED=0
    for node in mullet trout tuna whale gold squid puffer carp; do
      COUNT=$(curl -sfG \
        --data-urlencode "query={filename=\"/var/log/syslog\"} |= \" ${node} \"" \
        --data-urlencode "start=$START" \
        --data-urlencode "end=$END" \
        --data-urlencode "limit=1" \
        "$LOKI/loki/api/v1/query_range" | \
        python3 -c "import sys,json; d=json.load(sys.stdin); print(sum(len(s.get('values',[])) for s in d.get('data',{}).get('result',[])))")
      if [ "$COUNT" -gt 0 ]; then
        echo "PASS  $node"
      else
        echo "FAIL  $node — no syslog in last 15 min"
        FAILED=1
      fi
    done
    exit $FAILED
