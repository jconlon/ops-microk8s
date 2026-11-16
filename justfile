# ops-microk8s task runner
# Run `just` to list available recipes

# Default: list recipes
default:
    @just --list

# ── Testing ───────────────────────────────────────────────────────────────────

# Run all chainsaw e2e tests
test:
    chainsaw test tests/

# Run a specific test suite (one per directory under tests/, e.g. cluster, kafka, kgateway)
test-suite suite:
    chainsaw test tests/{{suite}}

# Run tests with verbose output
test-verbose:
    chainsaw test tests/ --verbose

# Run unit tests for the scripts/ Python helpers (e.g. decode_atom_entries.py)
test-freshrss-scripts:
    python3 -m pytest scripts/test_decode_atom_entries.py -v

# ── Cluster ───────────────────────────────────────────────────────────────────

# Verify puffer ACPI power key mitigations are in place (issue #59)
puffer-powerkey-status:
    ops cluster puffer-powerkey

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
    ops cluster pods-unhealthy

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

# End-to-end CI pipeline validation: Kaniko build -> Harbor checks -> PR check -> cleanup
# (3–10 min; run after CI pipeline changes). Steps and prerequisites: `ops ci build-e2e --help`
test-build-e2e:
    ops ci build-e2e

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

# ── Jellyfin ──────────────────────────────────────────────────────────────────

# Show Jellyfin pod status and node placement
jellyfin-status:
    kubectl get pods -n jellyfin -o wide

# Run Jellyfin chainsaw tests
test-jellyfin:
    chainsaw test tests/jellyfin

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
    ops loki journal-check {{node}} '{{filter}}' --since {{since}}

# Query syslog for a specific node using the node label (available since 2026-05-12
# pipeline_stages fix — streams before that date lack the label).
# Faster and more accurate than loki-node-events which searches line content.
# Examples:
#   just loki-syslog-node whale
#   just loki-syslog-node mullet 6h "disk"
#   just loki-syslog-node tuna 24h "error"
loki-syslog-node node="mullet" since="1h" filter="":
    ops loki syslog-node {{node}} --since {{since}} --filter '{{filter}}'

# ── Docs ──────────────────────────────────────────────────────────────────────

# Open the docs index in a browser
docs:
    xdg-open docs/index.html

# Open the Loki troubleshooting guide in a browser
loki-docs:
    xdg-open docs/loki-troubleshooting.html

# Open the cluster reference in a browser
cluster-docs:
    xdg-open docs/cluster.html

# Open the node hardware reference in a browser
nodes-docs:
    xdg-open docs/nodes.html

# Open the backups reference in a browser
backup-docs:
    xdg-open docs/backups.html

# Open the object storage design in a browser
object-storage-docs:
    xdg-open docs/object-storage-design.html

# Open the music library monitoring reference in a browser
music-docs:
    xdg-open docs/music-library-monitoring.html

# Run FreshRSS chainsaw tests
test-freshrss:
    chainsaw test tests/freshrss

# Run Kafka Connect chainsaw tests
test-kafka-connect:
    chainsaw test tests/kafka-connect

# Open the PostgreSQL databases reference in a browser
postgresql-docs:
    xdg-open docs/postgresql.html

# Open the networking reference in a browser
networking-docs:
    xdg-open docs/networking.html

# Open the tmux copy/paste cheat sheet in a browser
tmux-docs:
    xdg-open docs/tmux-copy-paste-cheatsheet.html

# Open the kured memory leak reference in a browser
kured-docs:
    xdg-open docs/kured.html

# Open the alerting & notifications reference in a browser
notifications-docs:
    xdg-open docs/notifications.html

# Open the vLLM reference in a browser
vllm-docs:
    xdg-open docs/vllm.html

# ── Backups ───────────────────────────────────────────────────────────────────

# Show restic backup timer status and latest snapshots
backup-status:
    #!/usr/bin/env bash
    echo "=== Restic backup timer ==="
    systemctl status restic-backup.timer restic-backup.service --no-pager 2>&1 | \
      grep -E "Active:|Trigger:|Finished|status="
    echo ""
    echo "=== Latest snapshots ==="
    teller run --config ~/dotfiles/restic/restic/.teller-restic-ceph.yml -- \
      restic snapshots --latest 5 2>&1 | grep -v "^-\*-"

# ── GitHub ───────────────────────────────────────────────────────────────────

# List open GitHub issues
issues:
    gh issue list --repo jconlon/ops-microk8s

# Show details of a GitHub issue by number
issue issue:
    #!/usr/bin/env bash
    gh issue view {{issue}} --repo jconlon/ops-microk8s \
      --json number,title,state,labels,body,comments,url \
      | jq -r '
        "# [\(.state)] #\(.number) — \(.title)",
        "URL: \(.url)",
        (if (.labels | length) > 0 then "Labels: \(.labels | map(.name) | join(", "))" else empty end),
        "",
        .body,
        (if (.comments | length) > 0 then (
          "\n---",
          (.comments[] | "\n**\(.author.login)** \(.createdAt[:10])\n\(.body)")
        ) else empty end)
      '

# Check syslog is flowing from all 8 nodes into Loki (last 15 minutes)
loki-node-logs:
    ops loki node-logs
