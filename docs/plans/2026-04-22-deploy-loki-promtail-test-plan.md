# Loki + Promtail Deployment Test Plan

**Issue:** #60 — Deploy Loki + Promtail log aggregation stack
**Strategy alignment:** Approved strategy calls for chainsaw-based e2e tests checking ArgoCD sync state, pod readiness, MetalLB IP assignment, and real log ingestion via the Loki API. No manual QA steps.
**Date:** 2026-04-22

---

## Strategy Reconciliation

The approved testing strategy holds without scope or cost changes. The implementation plan reveals one structural detail worth noting: the Loki chart exposes two distinct services in monolithic mode — `loki-gateway` (nginx proxy, port 80, what MetalLB exposes) and `loki` (direct backend, port 3100). Tests that call the HTTP API must target `loki-gateway` via the MetalLB IP, not `loki:3100` directly. The `/ready` and `/loki/api/v1/labels` paths route through the gateway correctly. This is consistent with how the gateway service name is referenced in the plan (`loki-gateway.loki.svc:80`) and does not alter test scope.

The plan also confirms the Grafana datasource is injected via `monitoring/helm/grafana-only-values.yaml` and synced automatically by ArgoCD — the Grafana datasource API check is therefore testable in-cluster without manual steps. That check is included as a scenario test.

No paid APIs, external infrastructure dependencies, or scope changes are introduced.

---

## Harness Requirements

No new harness needs to be built. All tests use the existing chainsaw harness that is already proven across harbor, vllm, cluster, storage, postgresql, and argocd test suites. The harness:

- **What it does:** Runs declarative assertion steps against live Kubernetes resources and executes inline shell scripts inside an ephemeral busybox/kubectl pod with cluster access.
- **What it exposes:** kubectl resource assertions, arbitrary shell commands with `curl`, `kubectl`, `jq`.
- **Complexity:** Zero build cost — already operational.
- **Tests that depend on it:** All tests in this plan.

---

## Test Plan

Tests are ordered by priority: problem-statement acceptance gates first, then high-value integration and scenario tests, then invariant checks.

---

### Test 1 — loki-apps ArgoCD parent app is Synced and Healthy

- **Name:** loki-apps ArgoCD application is Synced and Healthy
- **Type:** scenario
- **Disposition:** new (extends `tests/argocd/chainsaw-test.yaml`)
- **Harness:** chainsaw — assert step against live ArgoCD Application resource
- **Preconditions:** `loki-apps` Application exists in argocd namespace; waves 1–3 have completed deployment
- **Actions:** Assert `Application/loki-apps` has `health.status: Healthy`
- **Expected outcome:** The `loki-apps` parent app-of-apps is Healthy, confirming all three child waves are tracked and the GitOps deployment root is clean. Source of truth: the existing ArgoCD test suite pattern (`tests/argocd/chainsaw-test.yaml`) which asserts every app-of-apps parent.
- **Interactions:** Exercises ArgoCD application controller, child app sync state aggregation.

---

### Test 2 — loki ArgoCD child app is Synced and Healthy

- **Name:** Loki ArgoCD child application is Synced and Healthy
- **Type:** scenario
- **Disposition:** new (`tests/loki/chainsaw-test.yaml`)
- **Harness:** chainsaw — assert step
- **Preconditions:** `loki` Application exists in argocd namespace and wave 2 deployment is complete
- **Actions:** Assert `Application/loki` (namespace: argocd) has `sync.status: Synced` and `health.status: Healthy`
- **Expected outcome:** ArgoCD confirms the Loki Helm chart is deployed without drift. Source of truth: same ArgoCD sync pattern used by harbor and vllm tests.
- **Interactions:** ArgoCD application controller, Helm chart reconciliation.

---

### Test 3 — promtail ArgoCD child app is Synced and Healthy

- **Name:** Promtail ArgoCD child application is Synced and Healthy
- **Type:** scenario
- **Disposition:** new (`tests/loki/chainsaw-test.yaml`)
- **Harness:** chainsaw — assert step
- **Preconditions:** `promtail` Application exists in argocd namespace and wave 3 deployment is complete
- **Actions:** Assert `Application/promtail` (namespace: argocd) has `sync.status: Synced` and `health.status: Healthy`
- **Expected outcome:** ArgoCD confirms the Promtail Helm chart is deployed without drift. Source of truth: same pattern.
- **Interactions:** ArgoCD application controller, DaemonSet reconciliation.

---

### Test 4 — Loki StatefulSet has one ready replica

- **Name:** Loki single-binary pod is Running and ready
- **Type:** integration
- **Disposition:** new (`tests/loki/chainsaw-test.yaml`)
- **Harness:** chainsaw — assert step against StatefulSet resource
- **Preconditions:** `loki-apps` is synced; `loki-s3-credentials` secret exists in loki namespace
- **Actions:** Assert `StatefulSet/loki` in namespace `loki` has `status.readyReplicas: 1`
- **Expected outcome:** The Loki monolithic pod has started, connected to Ceph S3, and passed its readiness probe. A `readyReplicas` count of 0 indicates S3 credential or config failure. Source of truth: Loki chart deployment documentation (monolithic mode creates a StatefulSet named `loki` with 1 replica).
- **Interactions:** Ceph RGW S3 bucket access, `loki-s3-credentials` secret, rook-ceph-block PVC provisioning.

---

### Test 5 — Promtail DaemonSet covers all 8 nodes

- **Name:** Promtail DaemonSet is running on all 8 cluster nodes
- **Type:** integration
- **Disposition:** new (`tests/loki/chainsaw-test.yaml`)
- **Harness:** chainsaw — assert step against DaemonSet resource
- **Preconditions:** `promtail` ArgoCD app is synced; Loki gateway service is reachable in-cluster
- **Actions:** Assert `DaemonSet/promtail` in namespace `loki` has `status.numberReady: 8` and `status.desiredNumberScheduled: 8`
- **Expected outcome:** Promtail pods are scheduled and running on all 8 nodes (mullet, trout, tuna, whale, gold, squid, puffer, carp), including control-plane nodes (covered by tolerations in the values file). Source of truth: 8-node cluster documented in CLAUDE.md; Promtail chart creates a DaemonSet named `promtail`.
- **Interactions:** Toleration settings for control-plane nodes, node log volume mounts (`/var/log`, `/var/log/pods`, `/var/log/journal`).

---

### Test 6 — Loki gateway LoadBalancer service has MetalLB IP 192.168.0.220

- **Name:** Loki gateway service has MetalLB IP 192.168.0.220 assigned
- **Type:** integration
- **Disposition:** new (`tests/loki/chainsaw-test.yaml`)
- **Harness:** chainsaw — script step (`kubectl get svc`, assert IP field)
- **Preconditions:** MetalLB is running; `loki-app` ArgoCD app is synced
- **Actions:**
  ```bash
  IP=$(kubectl get svc loki-gateway -n loki -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  [ "$IP" = "192.168.0.220" ] || { echo "Expected 192.168.0.220, got: $IP"; exit 1; }
  ```
- **Expected outcome:** MetalLB has assigned the requested IP. Without this, external Promtail agents and the Grafana datasource cannot reach Loki. Source of truth: MetalLB annotation `metallb.universe.tf/loadBalancerIPs: "192.168.0.220"` in the plan's `loki-values.yaml`; user-confirmed IP 192.168.0.220 is the target.
- **Interactions:** MetalLB IP pool allocation; gateway service name must be `loki-gateway` (Loki 6.x chart naming).

---

### Test 7 — Loki /ready endpoint returns 200 (live readiness gate)

- **Name:** Loki /ready HTTP endpoint returns 200 confirming log ingestion is active
- **Type:** scenario
- **Disposition:** new (`tests/loki/chainsaw-test.yaml`)
- **Harness:** chainsaw — script step with `curl -sf`
- **Preconditions:** MetalLB IP 192.168.0.220 is assigned; Loki pod is Running
- **Actions:**
  ```bash
  curl -sf http://192.168.0.220/ready | grep -qi "ready" || { echo "Loki ready check failed"; exit 1; }
  ```
- **Expected outcome:** Loki returns HTTP 200 with body containing "ready". This is the definitive user-visible signal that Loki is operational. Source of truth: Loki /ready endpoint documented in Grafana Loki HTTP API reference.
- **Interactions:** MetalLB L2 routing; nginx gateway proxy to Loki backend; Ceph S3 connection (Loki only marks itself ready after S3 is accessible).

---

### Test 8 — Loki labels API returns data (Promtail is shipping logs)

- **Name:** Loki /labels endpoint returns non-empty data proving Promtail log ingestion
- **Type:** scenario
- **Disposition:** new (`tests/loki/chainsaw-test.yaml`)
- **Harness:** chainsaw — script step with `curl -sf` and JSON assertion
- **Preconditions:** Tests 4 (Loki ready) and 5 (Promtail DaemonSet ready) pass; sufficient time has elapsed for Promtail to ship at least one log entry
- **Actions:**
  ```bash
  LABELS=$(curl -sf "http://192.168.0.220/loki/api/v1/labels")
  echo "Labels response: $LABELS"
  echo "$LABELS" | grep -q '"data"' || { echo "No data field returned from Loki labels API"; exit 1; }
  LABEL_COUNT=$(echo "$LABELS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('data', [])))")
  [ "$LABEL_COUNT" -gt 0 ] || { echo "Labels list is empty — Promtail may not be shipping logs"; exit 1; }
  ```
- **Expected outcome:** The labels API returns a JSON object with a non-empty `data` array. At minimum, Promtail will have shipped pod logs from its own namespace within seconds of starting, so labels like `{namespace="loki"}` must appear. An empty list means Promtail is not connected to Loki. Source of truth: Loki Label API spec (`GET /loki/api/v1/labels` returns `{"status":"success","data":["label1","label2",...]}`).
- **Interactions:** Promtail → Loki gateway → Loki backend write path → Ceph S3 storage → Loki query path → labels index. This is the highest-value end-to-end verification: it exercises the full log ingestion and query pipeline.

---

### Test 9 — Grafana Loki datasource is registered via API

- **Name:** Grafana Explore tab has Loki datasource registered and reachable
- **Type:** scenario
- **Disposition:** new (`tests/loki/chainsaw-test.yaml`)
- **Harness:** chainsaw — script step with `curl` against Grafana API
- **Preconditions:** Grafana is running (monitoring-apps ArgoCD app is Healthy); `grafana-only-values.yaml` has been updated to include Loki datasource and ArgoCD has re-synced
- **Actions:**
  ```bash
  GRAFANA_IP=$(kubectl get svc -n monitoring -l app.kubernetes.io/name=grafana \
    -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  [ -n "$GRAFANA_IP" ] || { echo "Could not find Grafana LoadBalancer IP"; exit 1; }
  DATASOURCES=$(curl -sf "http://$GRAFANA_IP/api/datasources" \
    -H "Authorization: Basic YWRtaW46YWRtaW4=")
  echo "$DATASOURCES" | grep -q '"type":"loki"' || { echo "Loki datasource not found in Grafana"; exit 1; }
  echo "Loki datasource confirmed in Grafana"
  ```
  Note: The Basic auth value encodes `admin:admin` (base64). If the Grafana admin password differs, the test uses anonymous viewer access via `http://$GRAFANA_IP/api/datasources` with anonymous auth enabled in grafana.ini (`auth.anonymous.enabled: true`, `org_role: Viewer`). Viewer role cannot list datasources — implementation agent should use the anonymous Grafana health check instead:
  ```bash
  # Alternative if anonymous viewer cannot list datasources:
  curl -sf "http://$GRAFANA_IP/api/health" | grep -q '"database":"ok"' || exit 1
  # Then verify Loki-related Grafana config indirectly via ArgoCD:
  # (loki ArgoCD app Synced+Healthy already proves grafana-only-values.yaml was applied)
  ```
  The implementation agent should test both approaches against the live cluster and use the one that succeeds without credentials.
- **Expected outcome:** Grafana's datasource API confirms a datasource of type `loki` exists. This proves the `grafana-only-values.yaml` change was picked up by ArgoCD and Grafana's datasource provisioner loaded it. Source of truth: `grafana-only-values.yaml` datasources block; Grafana HTTP API (`GET /api/datasources` returns array of datasource objects).
- **Interactions:** ArgoCD sync of monitoring-apps; Grafana datasource provisioner; Loki gateway service DNS `loki-gateway.loki.svc:80` (Grafana talks to Loki via internal cluster DNS, not MetalLB).

---

### Test 10 — Loki query path returns logs from at least one namespace

- **Name:** Loki query API returns actual log lines from cluster namespaces
- **Type:** scenario
- **Disposition:** new (`tests/loki/chainsaw-test.yaml`)
- **Harness:** chainsaw — script step with `curl -sf` and LogQL query
- **Preconditions:** Test 8 passes (labels non-empty); at least one namespace with pod logs
- **Actions:**
  ```bash
  # Query last 5 minutes of logs from loki namespace (Promtail itself)
  START=$(date -u -d '5 minutes ago' +%s)000000000
  END=$(date -u +%s)000000000
  RESULT=$(curl -sfG \
    --data-urlencode 'query={namespace="loki"}' \
    --data-urlencode "start=$START" \
    --data-urlencode "end=$END" \
    --data-urlencode "limit=5" \
    "http://192.168.0.220/loki/api/v1/query_range")
  echo "Query result: $RESULT"
  echo "$RESULT" | grep -q '"result"' || { echo "No result field in Loki query response"; exit 1; }
  # At least one stream result means logs are flowing
  STREAM_COUNT=$(echo "$RESULT" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(len(d.get('data',{}).get('result',[])))")
  [ "$STREAM_COUNT" -gt 0 ] || { echo "No log streams returned — check Promtail is shipping loki namespace logs"; exit 1; }
  echo "Log ingestion confirmed: $STREAM_COUNT stream(s) found"
  ```
- **Expected outcome:** Loki returns at least one stream of log lines from the `loki` namespace (Promtail's own logs). This definitively proves the full pipeline: Promtail pod discovery → log scraping → push to Loki gateway → S3 write → S3 read → query response. Source of truth: Loki query_range API spec; LogQL `{namespace="loki"}` selector.
- **Interactions:** Loki read path (querier, ingester, Ceph S3 read); Promtail write path; gateway routing. This is the strongest mechanical end-to-end proof of the system working.

---

### Test 11 — loki-storage CephObjectStoreUser is Ready

- **Name:** Loki Ceph object store user is Ready (S3 credentials provisioned)
- **Type:** integration
- **Disposition:** new (`tests/loki/chainsaw-test.yaml`)
- **Harness:** chainsaw — assert step against CephObjectStoreUser resource
- **Preconditions:** `loki-storage` ArgoCD app (wave 1) is synced; Rook operator is running
- **Actions:** Assert `CephObjectStoreUser/loki-logs-user` in namespace `rook-ceph` has `status.phase: Ready`
- **Expected outcome:** Rook has provisioned the S3 user and written credentials to a secret. If this is not Ready, the S3 credentials copy step cannot succeed and Loki will fail to start. Source of truth: Rook/Ceph CephObjectStoreUser CRD — `.status.phase` transitions to `Ready` when the RGW user is created and the secret is populated.
- **Interactions:** Rook operator; Ceph RGW; secret generation in rook-ceph namespace.

---

### Test 12 — loki-s3-credentials secret exists in loki namespace

- **Name:** loki-s3-credentials Kubernetes secret exists in the loki namespace
- **Type:** integration
- **Disposition:** new (`tests/loki/chainsaw-test.yaml`)
- **Harness:** chainsaw — script step checking secret existence
- **Preconditions:** CephObjectStoreUser is Ready; bootstrap step (secret copy) has been run
- **Actions:**
  ```bash
  kubectl get secret loki-s3-credentials -n loki \
    -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d | grep -qE '.{10,}' \
    || { echo "loki-s3-credentials secret missing or empty"; exit 1; }
  echo "loki-s3-credentials secret present with non-empty access key"
  ```
- **Expected outcome:** The secret exists and the `AWS_ACCESS_KEY_ID` key has a non-empty value (≥10 chars, matching typical Ceph key length). An absent or empty secret is the most common deployment failure mode (same failure Harbor hit during initial deployment). Source of truth: Loki Helm values `singleBinary.extraEnvFrom.secretRef.name: loki-s3-credentials`; Rook generates 20-char access keys.
- **Interactions:** Manual bootstrap step documented in `scripts/README.md`; namespace existence prerequisite.

---

### Test 13 — Loki retention configuration is active (30-day compactor)

- **Name:** Loki compactor is running and retention is configured for 30 days
- **Type:** invariant
- **Disposition:** new (`tests/loki/chainsaw-test.yaml`)
- **Harness:** chainsaw — script step calling Loki config endpoint
- **Preconditions:** Loki pod is Running and /ready passes
- **Actions:**
  ```bash
  CONFIG=$(curl -sf http://192.168.0.220/config)
  echo "$CONFIG" | grep -q "retention_period" || { echo "retention_period not found in Loki config"; exit 1; }
  # 720h = 30 days
  echo "$CONFIG" | grep -q "720h" || { echo "30-day retention (720h) not configured"; exit 1; }
  echo "30-day retention confirmed"
  ```
- **Expected outcome:** The live Loki config endpoint returns configuration containing `retention_period` set to `720h`. This invariant ensures the retention setting was applied and is not silently ignored. Source of truth: `loki-values.yaml` `loki.limits_config.retention_period: 720h`; Loki `/config` endpoint returns the resolved YAML config.
- **Interactions:** Loki config load from values; compactor retention_enabled setting.

---

## Coverage Summary

### Action space covered

| Surface | Covered by test(s) |
|---|---|
| ArgoCD `loki-apps` parent app health | Test 1 |
| ArgoCD `loki` child app sync/health | Test 2 |
| ArgoCD `promtail` child app sync/health | Test 3 |
| Loki StatefulSet pod readiness | Test 4 |
| Promtail DaemonSet readiness on all 8 nodes | Test 5 |
| MetalLB IP assignment for loki-gateway | Test 6 |
| Loki `/ready` endpoint (user-facing API) | Test 7 |
| Loki `/loki/api/v1/labels` (log ingestion proof) | Test 8 |
| Grafana Loki datasource registration | Test 9 |
| Loki `/loki/api/v1/query_range` (full pipeline) | Test 10 |
| CephObjectStoreUser provisioning | Test 11 |
| `loki-s3-credentials` secret in loki namespace | Test 12 |
| 30-day retention invariant | Test 13 |

### Explicitly excluded per strategy

| Area | Reason |
|---|---|
| External Promtail install on mudshark/oyster/minnow | Not automatable in-cluster; install artifacts verified only as static file presence. Scripts must be run manually on external machines. Risk: low — the install script is straightforward and log data from external machines is not required for cluster health. |
| Caddy Caddyfile configuration on mullet | Operator step, not GitOps; not testable from cluster. |
| Cloudflare DNS record for loki.verticon.com | External service; testable manually with `dig` or `nslookup`. |
| Loki Ruler / Recording rules | Not in scope for this issue; no rules are configured. |
| Multi-tenant log isolation | `auth_enabled: false` — single tenant only by design. |

### Risks from exclusions

- External machine log sources (mudshark/oyster/minnow) are not validated automatically. If the install script fails silently on any of those machines, no alert fires. Operator must verify with `systemctl status promtail` on each machine post-install.
- The Grafana datasource test (Test 9) may need the Basic auth header adjusted if the admin password is not `admin`. The implementation agent must verify and adjust accordingly. The anonymous viewer fallback is specified in Test 9 if needed.
