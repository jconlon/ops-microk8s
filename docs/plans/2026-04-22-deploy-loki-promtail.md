# Deploy Loki + Promtail Log Aggregation Stack — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use trycycle-executing to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy Grafana Loki + Promtail as a GitOps-managed ArgoCD app-of-apps, with Ceph RGW S3 for log storage, a LoadBalancer at 192.168.0.220, Loki added as a Grafana datasource, and Promtail as a DaemonSet on all 8 cluster nodes; produce install artifacts for external Ubuntu machines (mudshark, oyster, minnow).

**Architecture:** Loki runs in monolithic mode (single-binary, `loki` namespace) behind a MetalLB LoadBalancer at 192.168.0.220:80 (HTTP, Caddy terminates TLS externally). Log chunks are stored in a Ceph RGW S3 bucket (`loki-logs`) backed by a dedicated `CephObjectStoreUser`. Promtail runs as a DaemonSet (ArgoCD wave 3) and scrapes both OS syslog and Kubernetes pod logs. Grafana's datasource config is extended in-place via `monitoring/helm/grafana-only-values.yaml` to add the Loki source. Deployment follows the exact app-of-apps pattern used by Harbor (waves: storage → main-app → promtail).

**Tech Stack:**
- Grafana Loki Helm chart `grafana/loki` at `https://grafana.github.io/helm-charts`
- Grafana Promtail Helm chart `grafana/promtail` at `https://grafana.github.io/helm-charts`
- Rook/Ceph `CephObjectStoreUser` → Ceph RGW bucket `loki-logs`
- MetalLB LoadBalancer IP `192.168.0.220`
- Chainsaw for e2e testing; `just` for status recipes
- Chart versions: `loki 6.28.0` (app Loki 3.3.x), `promtail 6.16.6`

---

## File Structure

### New files

| Path | Purpose |
|---|---|
| `loki-gitops/storage/loki-ceph-user.yaml` | CephObjectStoreUser — Rook creates S3 creds in `rook-ceph` |
| `loki-gitops/helm/loki-values.yaml` | Loki Helm values — monolithic mode, Ceph S3, MetalLB 192.168.0.220 |
| `loki-gitops/helm/promtail-values.yaml` | Promtail Helm values — DaemonSet scraping K8s pods + OS syslog |
| `argoCD-apps/loki-apps.yaml` | App-of-apps parent that points to `argoCD-apps/loki/` |
| `argoCD-apps/loki/loki-storage-app.yaml` | Wave 1 — CephObjectStoreUser → `rook-ceph` namespace |
| `argoCD-apps/loki/loki-app.yaml` | Wave 2 — Loki Helm chart → `loki` namespace |
| `argoCD-apps/loki/promtail-app.yaml` | Wave 3 — Promtail Helm chart → `loki` namespace |
| `tests/loki/chainsaw-test.yaml` | Chainsaw health tests |
| `scripts/promtail-external/promtail-external.yaml` | Promtail config for external Ubuntu machines |
| `scripts/promtail-external/promtail.service` | systemd unit for external Promtail |
| `scripts/promtail-external/install.sh` | Install script for mudshark/oyster/minnow |

### Modified files

| Path | Change |
|---|---|
| `monitoring/helm/grafana-only-values.yaml` | Add Loki datasource to `datasources.yaml` |
| `justfile` | Add `loki-status` and `test-loki` recipes |
| `tests/argocd/chainsaw-test.yaml` | Add `loki-apps` ArgoCD Application health step |
| `README.md` | Add Loki section (service access, log sources, Caddy entry) |
| `scripts/README.md` | Document Loki S3 bootstrap and external Promtail install |
| `CLAUDE.md` | Update Key Components and Service Access for Loki |

---

## Architectural Decisions

### Loki monolithic vs. simple-scalable vs. distributed
**Decision: monolithic.** This cluster has 8 nodes and a single Prometheus instance. Monolithic mode (single binary, all components in one pod) is the correct choice for this scale — simple-scalable requires at least 3 replicas and a shared object store with high I/O that would add operational overhead for no benefit. Monolithic is the Grafana-recommended starting point for clusters under ~300 GB/day log volume.

### Loki storage: Ceph RGW S3 (object storage) vs. PVC
**Decision: Ceph RGW S3.** This is what the issue specifies, and it's architecturally superior. S3 backend avoids PVC block device limitations, has no capacity ceiling (RGW scales horizontally), and aligns with how Harbor already uses Ceph RGW. Loki's monolithic mode with S3 backend stores both the TSDB index and chunks in S3, eliminating the need for a separate index store.

### Ceph user: CephObjectStoreUser vs. CephObjectBucketClaim (OBC)
**Decision: CephObjectStoreUser**, same as Harbor. OBC is simpler but requires the `objectbucket.io` CRD operator (rook-ceph-operator's OBC controller). `CephObjectStoreUser` is always available in Rook/Ceph and provides the same S3 credentials. We create the bucket name `loki-logs` in the Loki Helm values — Loki creates it on first run if it doesn't exist (Loki's S3 client uses `s3ForcePathStyle: true` and handles bucket creation).

### Loki namespace: `loki` (isolated) vs. `monitoring`
**Decision: `loki` namespace.** All other apps use their own namespace. Grafana, Prometheus, and Alertmanager share `monitoring` only because they were deployed together as kube-prometheus-stack. Loki is a separate chart from a separate team — co-locating it in `monitoring` would couple unrelated apps and complicate RBAC.

### Grafana datasource: values file vs. ConfigMap
**Decision: extend `monitoring/helm/grafana-only-values.yaml`.** The existing Grafana ArgoCD app already uses this file for datasources. Adding Loki there keeps all datasource config in one place, and ArgoCD's `selfHeal: true` will sync the change to the running Grafana without manual intervention. No separate ConfigMap or operator is needed.

### Sync waves
- Wave 1: `loki-storage` — creates `CephObjectStoreUser` in `rook-ceph`. Must complete before Loki tries to authenticate to S3.
- Wave 2: `loki` — deploys Loki Helm chart. Needs S3 creds to exist (manually copied after wave 1 completes, same as Harbor).
- Wave 3: `promtail` — deploys Promtail DaemonSet. Needs Loki endpoint up before scraping, but ArgoCD will retry.

### S3 credentials: manual copy from rook-ceph to loki namespace
Rook auto-creates the S3 secret in `rook-ceph` namespace; Loki pod runs in `loki` namespace; K8s secrets are namespace-scoped. We must copy. Same exact pattern as Harbor's `harbor-s3-credentials`. This is documented in `scripts/README.md` and cannot be automated via GitOps (credentials are dynamic).

### MetalLB IP: 192.168.0.220 (last in range)
Confirmed 192.168.0.220 is free. It is the last IP in the MetalLB range (200–220), easy to remember, no conflicts.

### HTTP vs. TLS for Loki
Loki listens on HTTP/3100 internally. The Loki service is exposed via MetalLB on port 80. Caddy on mullet terminates TLS and proxies to 192.168.0.220:80. Promtail (in-cluster and external) talks directly to the MetalLB IP on port 80 — no TLS needed since this is LAN-only traffic. The `externalURL` in Loki config is `http://192.168.0.220` (no DNS needed for Loki itself — Promtail and Grafana use the IP directly).

### External Promtail install (mudshark, oyster, minnow)
Promtail binary via systemd service, not Docker (avoids Docker dependency on LAN machines). Config file at `/etc/promtail/promtail.yaml`, binary at `/usr/local/bin/promtail`. Points to `http://192.168.0.220/loki/api/v1/push`. Scrapes `/var/log/syslog`, `/var/log/kern.log`, `/var/log/auth.log` with hostname as the `host` label.

---

## Task 1: Create Ceph S3 storage user

**Files:**
- Create: `loki-gitops/storage/loki-ceph-user.yaml`

- [ ] **Step 1: Write the failing test**

There is no pre-existing test for the Ceph user. The final test is in `tests/loki/chainsaw-test.yaml` (Task 7). For this task, the manual verification is: after ArgoCD syncs wave 1, `kubectl get cephobjectstoreuser loki-logs-user -n rook-ceph` should show `PHASE: Ready`.

No test file to write yet — proceed to implementation.

- [ ] **Step 2: Create the CephObjectStoreUser manifest**

Create `loki-gitops/storage/loki-ceph-user.yaml`:

```yaml
apiVersion: ceph.rook.io/v1
kind: CephObjectStoreUser
metadata:
  name: loki-logs-user
  namespace: rook-ceph
  labels:
    app: loki
spec:
  store: rook-ceph-rgw
  displayName: "Loki Log Aggregation"
  quotas:
    maxBuckets: 2
    maxSize: "500Gi"
    maxObjects: -1

# Rook auto-creates a secret in rook-ceph namespace:
#   kubectl get secret <status.info.secretName> -n rook-ceph
# Copy to loki namespace after ArgoCD wave 1 syncs:
#   ACCESS_KEY=$(kubectl get secret <secretName> -n rook-ceph -o jsonpath='{.data.AccessKey}' | base64 -d)
#   SECRET_KEY=$(kubectl get secret <secretName> -n rook-ceph -o jsonpath='{.data.SecretKey}' | base64 -d)
#   kubectl create secret generic loki-s3-credentials \
#     --namespace loki \
#     --from-literal=AWS_ACCESS_KEY_ID="$ACCESS_KEY" \
#     --from-literal=AWS_SECRET_ACCESS_KEY="$SECRET_KEY" \
#     --dry-run=client -o yaml | kubectl apply -f -
```

- [ ] **Step 3: Commit**

```bash
cd /home/jconlon/git/ops-microk8s/.worktrees/deploy-loki-promtail
git add loki-gitops/storage/loki-ceph-user.yaml
git commit -m "feat: add CephObjectStoreUser for Loki log storage"
```

---

## Task 2: Create Loki Helm values

**Files:**
- Create: `loki-gitops/helm/loki-values.yaml`

- [ ] **Step 1: Write the Loki Helm values file**

Loki 3.x (chart `6.28.0`) uses a single `loki` key at the top of `values.yaml`. The monolithic deployment type is set via `deploymentMode: SingleBinary`. S3 storage is configured under `loki.storage`.

Create `loki-gitops/helm/loki-values.yaml`:

```yaml
# Loki — monolithic single-binary mode
# Ceph RGW S3 backend for log chunks and TSDB index
# MetalLB LoadBalancer at 192.168.0.220
# Accessible at http://192.168.0.220 (Caddy terminates TLS externally as loki.verticon.com)

deploymentMode: SingleBinary

loki:
  auth_enabled: false  # single-tenant; no multi-tenant token required

  commonConfig:
    replication_factor: 1  # monolithic single instance — no replication needed

  storage:
    type: s3
    s3:
      endpoint: http://rook-ceph-rgw-rook-ceph-rgw.rook-ceph.svc:80
      region: us-east-1
      bucketnames: loki-logs
      s3ForcePathStyle: true
      insecure: true  # no TLS to internal Ceph RGW

  # Storage config secret: loki-s3-credentials must exist in loki namespace
  # Keys: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
  # Created manually by copying from Rook-generated secret in rook-ceph namespace

  schemaConfig:
    configs:
      - from: "2024-01-01"
        store: tsdb
        object_store: s3
        schema: v13
        index:
          prefix: loki_index_
          period: 24h

  limits_config:
    retention_period: 720h  # 30 days

  compactor:
    retention_enabled: true
    retention_delete_delay: 2h
    working_directory: /var/loki/compactor

  rulerConfig:
    storage:
      type: local
      local:
        directory: /rules
    rule_path: /rules-temp

singleBinary:
  replicas: 1
  persistence:
    enabled: true
    storageClass: rook-ceph-block
    size: 10Gi

# Expose Loki via MetalLB LoadBalancer — HTTP only (Caddy terminates TLS)
gateway:
  enabled: true
  service:
    type: LoadBalancer
    port: 80
    annotations:
      metallb.universe.tf/loadBalancerIPs: "192.168.0.220"

# Disable bundled Grafana agent/Promtail — we deploy Promtail separately
monitoring:
  selfMonitoring:
    enabled: false
    grafanaAgent:
      installOperator: false

# ServiceMonitor for Prometheus scraping
monitoring:
  serviceMonitor:
    enabled: true
    labels:
      release: prometheus-stack

# Disable built-in tests (they require kubectl exec access we don't need)
test:
  enabled: false

# Disable Loki canary (not needed for single-cluster)
lokiCanary:
  enabled: false
```

**Note on the `monitoring` key duplication:** The Loki Helm chart has a single `monitoring:` section that covers both `selfMonitoring` and `serviceMonitor`. The yaml above must be merged into a single `monitoring:` block:

```yaml
monitoring:
  selfMonitoring:
    enabled: false
    grafanaAgent:
      installOperator: false
  serviceMonitor:
    enabled: true
    labels:
      release: prometheus-stack
```

The actual file must use a single `monitoring:` key. The implementation agent must write the file with merged content.

- [ ] **Step 2: Commit**

```bash
git add loki-gitops/helm/loki-values.yaml
git commit -m "feat: add Loki Helm values (monolithic, Ceph S3, MetalLB 192.168.0.220)"
```

---

## Task 3: Create Promtail Helm values

**Files:**
- Create: `loki-gitops/helm/promtail-values.yaml`

- [ ] **Step 1: Write the Promtail Helm values file**

Promtail chart `6.16.6` ships a DaemonSet. The key config points:
- Loki endpoint: `http://loki-gateway.loki.svc:80` (internal cluster DNS, no MetalLB needed for in-cluster traffic)
- Scrape: K8s pod logs + system journal + OS log files (`/var/log/syslog`, `/var/log/kern.log`, `/var/log/auth.log`)
- MicroK8s uses `/var/snap/microk8s/common/var/lib/kubelet` — Promtail's auto-config for K8s pods works via `/var/log/pods` which is a symlink, not kubelet-specific

Create `loki-gitops/helm/promtail-values.yaml`:

```yaml
# Promtail — DaemonSet on all 8 cluster nodes
# Ships K8s pod logs + OS syslog/kern/auth to Loki
# Loki endpoint: internal ClusterDNS (no MetalLB hop needed)

config:
  logLevel: warn
  serverPort: 3101

  clients:
    - url: http://loki-gateway.loki.svc:80/loki/api/v1/push

  snippets:
    # K8s pod logs — auto-detected from container runtime
    pipelineStages:
      - cri: {}

    scrapeConfigs: |
      # === Kubernetes Pod Logs ===
      - job_name: kubernetes-pods
        kubernetes_sd_configs:
          - role: pod
        relabel_configs:
          - source_labels: [__meta_kubernetes_pod_node_name]
            target_label: node
          - source_labels: [__meta_kubernetes_namespace]
            target_label: namespace
          - source_labels: [__meta_kubernetes_pod_name]
            target_label: pod
          - source_labels: [__meta_kubernetes_pod_container_name]
            target_label: container
          - source_labels: [__meta_kubernetes_pod_label_app_kubernetes_io_name]
            target_label: app
          - replacement: /var/log/pods/*$1/*.log
            separator: /
            source_labels:
              - __meta_kubernetes_pod_uid
              - __meta_kubernetes_pod_container_name
            target_label: __path__
          - action: replace
            regex: true/(.*)
            replacement: /var/log/pods/*$1/*.log
            separator: /
            source_labels:
              - __meta_kubernetes_pod_annotationpresent_kubectl_kubernetes_io_last_applied_configuration
              - __meta_kubernetes_pod_uid
              - __meta_kubernetes_pod_container_name
            target_label: __path__

      # === OS Syslog / Kernel / Auth logs ===
      - job_name: node-syslog
        static_configs:
          - targets: [localhost]
            labels:
              job: syslog
              __path__: /var/log/{syslog,kern.log,auth.log}
        relabel_configs:
          - target_label: node
            replacement: ${NODE_NAME}

      # === systemd journal ===
      - job_name: systemd-journal
        journal:
          max_age: 12h
          labels:
            job: systemd-journal
        relabel_configs:
          - source_labels: [__journal__hostname]
            target_label: node
          - source_labels: [__journal__systemd_unit]
            target_label: unit
          - source_labels: [__journal_priority_keyword]
            target_label: severity

# DaemonSet resource limits
resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 200m
    memory: 256Mi

# Volume mounts — OS logs + pod logs
defaultVolumes:
  - name: containers
    hostPath:
      path: /var/log/containers
  - name: pods
    hostPath:
      path: /var/log/pods
  - name: syslog
    hostPath:
      path: /var/log
  - name: journal
    hostPath:
      path: /var/log/journal

defaultVolumeMounts:
  - name: containers
    mountPath: /var/log/containers
    readOnly: true
  - name: pods
    mountPath: /var/log/pods
    readOnly: true
  - name: syslog
    mountPath: /var/log
    readOnly: true
  - name: journal
    mountPath: /var/log/journal
    readOnly: true

# Tolerations — run on all nodes including control plane
tolerations:
  - key: node-role.kubernetes.io/master
    operator: Exists
    effect: NoSchedule
  - key: node-role.kubernetes.io/control-plane
    operator: Exists
    effect: NoSchedule

# NODE_NAME env var for syslog relabeling
extraEnv:
  - name: NODE_NAME
    valueFrom:
      fieldRef:
        fieldPath: spec.nodeName

serviceMonitor:
  enabled: true
  labels:
    release: prometheus-stack
```

- [ ] **Step 2: Commit**

```bash
git add loki-gitops/helm/promtail-values.yaml
git commit -m "feat: add Promtail Helm values (DaemonSet, K8s + syslog + journal)"
```

---

## Task 4: Create ArgoCD Application manifests

**Files:**
- Create: `argoCD-apps/loki-apps.yaml`
- Create: `argoCD-apps/loki/loki-storage-app.yaml`
- Create: `argoCD-apps/loki/loki-app.yaml`
- Create: `argoCD-apps/loki/promtail-app.yaml`

- [ ] **Step 1: Write the parent app-of-apps**

Create `argoCD-apps/loki-apps.yaml` (identical pattern to `harbor-apps.yaml`, `kafka-apps.yaml`, etc.):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: loki-apps
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/jconlon/ops-microk8s
    targetRevision: HEAD
    path: argoCD-apps/loki
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
```

- [ ] **Step 2: Write wave 1 — Ceph storage app**

Create `argoCD-apps/loki/loki-storage-app.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: loki-storage
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  project: default
  source:
    repoURL: https://github.com/jconlon/ops-microk8s
    targetRevision: HEAD
    path: loki-gitops/storage
  destination:
    server: https://kubernetes.default.svc
    namespace: rook-ceph
  syncPolicy:
    automated:
      prune: false
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 3: Write wave 2 — Loki Helm app**

Create `argoCD-apps/loki/loki-app.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: loki
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  project: default
  sources:
    - repoURL: https://grafana.github.io/helm-charts
      chart: loki
      targetRevision: "6.28.0"
      helm:
        valueFiles:
          - $values/loki-gitops/helm/loki-values.yaml
    - repoURL: https://github.com/jconlon/ops-microk8s
      targetRevision: HEAD
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: loki
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
```

- [ ] **Step 4: Write wave 3 — Promtail Helm app**

Create `argoCD-apps/loki/promtail-app.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: promtail
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "3"
spec:
  project: default
  sources:
    - repoURL: https://grafana.github.io/helm-charts
      chart: promtail
      targetRevision: "6.16.6"
      helm:
        valueFiles:
          - $values/loki-gitops/helm/promtail-values.yaml
    - repoURL: https://github.com/jconlon/ops-microk8s
      targetRevision: HEAD
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: loki
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
```

- [ ] **Step 5: Commit**

```bash
git add argoCD-apps/loki-apps.yaml argoCD-apps/loki/
git commit -m "feat: add ArgoCD app-of-apps for Loki + Promtail (3-wave deploy)"
```

---

## Task 5: Add Loki datasource to Grafana

**Files:**
- Modify: `monitoring/helm/grafana-only-values.yaml`

The existing Grafana ArgoCD app uses `selfHeal: true` — editing this values file will trigger a resync that adds the Loki datasource to the running Grafana instance automatically.

- [ ] **Step 1: Run existing test to verify current state (red check)**

The `tests/argocd/chainsaw-test.yaml` monitoring-apps step asserts `monitoring-apps Healthy`. It currently passes. Adding the Loki datasource will cause a brief resync. Verify the test passes before and after:

```bash
chainsaw test tests/argocd
```

Expected: PASS (pre-change baseline)

- [ ] **Step 2: Add Loki datasource to grafana values**

In `monitoring/helm/grafana-only-values.yaml`, under `grafana.datasources.datasources.yaml.datasources:`, add the Loki entry after the existing Alertmanager entry:

```yaml
        - name: "Loki"
          type: loki
          uid: loki
          url: http://loki-gateway.loki.svc:80
          access: proxy
          jsonData:
            maxLines: 1000
            timeout: 60
```

The full `datasources:` section after the change:

```yaml
  datasources:
    datasources.yaml:
      apiVersion: 1
      datasources:
        - name: "Prometheus"
          type: prometheus
          uid: prometheus
          url: http://prometheus-kube-prometheus-prometheus.monitoring:80/
          access: proxy
          isDefault: true
          jsonData:
            httpMethod: POST
            timeInterval: 30s
        - name: "Alertmanager"
          type: alertmanager
          uid: alertmanager
          url: http://alertmanager-kube-promethe-alertmanager.monitoring:9093/
          access: proxy
          jsonData:
            handleGrafanaManagedAlerts: false
            implementation: prometheus
        - name: "Loki"
          type: loki
          uid: loki
          url: http://loki-gateway.loki.svc:80
          access: proxy
          jsonData:
            maxLines: 1000
            timeout: 60
```

- [ ] **Step 3: Commit**

```bash
git add monitoring/helm/grafana-only-values.yaml
git commit -m "feat: add Loki datasource to Grafana"
```

---

## Task 6: Create external Promtail install artifacts

**Files:**
- Create: `scripts/promtail-external/promtail-external.yaml`
- Create: `scripts/promtail-external/promtail.service`
- Create: `scripts/promtail-external/install.sh`

These are install artifacts for mudshark, oyster, minnow (non-cluster Ubuntu machines). They run Promtail as a systemd service shipping logs to Loki's MetalLB IP.

- [ ] **Step 1: Write the Promtail config for external machines**

Create `scripts/promtail-external/promtail-external.yaml`:

```yaml
# Promtail config for non-cluster Ubuntu machines
# Install to /etc/promtail/promtail.yaml
# Ships syslog, kern.log, auth.log, journal to Loki at http://192.168.0.220

server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /var/lib/promtail/positions.yaml

clients:
  - url: http://192.168.0.220/loki/api/v1/push

scrape_configs:
  - job_name: syslog
    static_configs:
      - targets: [localhost]
        labels:
          job: syslog
          host: __HOSTNAME__
          __path__: /var/log/{syslog,kern.log,auth.log}

  - job_name: systemd-journal
    journal:
      max_age: 12h
      labels:
        job: systemd-journal
        host: __HOSTNAME__
    relabel_configs:
      - source_labels: [__journal__systemd_unit]
        target_label: unit
      - source_labels: [__journal_priority_keyword]
        target_label: severity
```

- [ ] **Step 2: Write the systemd unit**

Create `scripts/promtail-external/promtail.service`:

```ini
[Unit]
Description=Promtail log shipper (Loki agent)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=promtail
ExecStart=/usr/local/bin/promtail -config.file=/etc/promtail/promtail.yaml -config.expand-env=true
Restart=on-failure
RestartSec=5s

# Allow reading system logs
SupplementaryGroups=adm systemd-journal

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 3: Write the install script**

Create `scripts/promtail-external/install.sh`:

```bash
#!/usr/bin/env bash
# Install Promtail as a systemd service on a non-cluster Ubuntu machine.
# Ships syslog/kern/auth and systemd journal to Loki at http://192.168.0.220
#
# Usage: sudo bash install.sh [HOSTNAME]
# Example: sudo bash install.sh mudshark
#
# Requires: curl, systemd, Ubuntu 22.04 or 24.04
set -euo pipefail

LOKI_IP="192.168.0.220"
PROMTAIL_VERSION="3.3.2"
ARCH="amd64"
HOSTNAME_LABEL="${1:-$(hostname)}"

echo "==> Installing Promtail $PROMTAIL_VERSION for $HOSTNAME_LABEL → Loki at $LOKI_IP"

# Create promtail user (no login shell, no home directory)
id promtail &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin promtail
usermod -aG adm promtail
usermod -aG systemd-journal promtail

# Download Promtail binary
DOWNLOAD_URL="https://github.com/grafana/loki/releases/download/v${PROMTAIL_VERSION}/promtail-linux-${ARCH}.zip"
curl -fsSL -o /tmp/promtail.zip "$DOWNLOAD_URL"
unzip -o /tmp/promtail.zip -d /tmp/
install -m 755 /tmp/promtail-linux-${ARCH} /usr/local/bin/promtail
rm -f /tmp/promtail.zip /tmp/promtail-linux-${ARCH}

# Create directories
mkdir -p /etc/promtail /var/lib/promtail
chown promtail:promtail /var/lib/promtail

# Install config (replace __HOSTNAME__ placeholder)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
sed "s/__HOSTNAME__/${HOSTNAME_LABEL}/g" "${SCRIPT_DIR}/promtail-external.yaml" > /etc/promtail/promtail.yaml
chown promtail:promtail /etc/promtail/promtail.yaml
chmod 640 /etc/promtail/promtail.yaml

# Install systemd unit
cp "${SCRIPT_DIR}/promtail.service" /etc/systemd/system/promtail.service

# Enable and start
systemctl daemon-reload
systemctl enable promtail
systemctl restart promtail

echo "==> Promtail installed and started. Check status:"
echo "    systemctl status promtail"
echo "    journalctl -u promtail -f"
```

- [ ] **Step 4: Commit**

```bash
git add scripts/promtail-external/
git commit -m "feat: add external Promtail install artifacts for mudshark/oyster/minnow"
```

---

## Task 7: Create chainsaw tests

**Files:**
- Create: `tests/loki/chainsaw-test.yaml`
- Modify: `tests/argocd/chainsaw-test.yaml`

- [ ] **Step 1: Write the failing Loki test**

Create `tests/loki/chainsaw-test.yaml`. At the time of writing, Loki is not yet deployed — running `chainsaw test tests/loki` will FAIL (expected at this stage):

```bash
chainsaw test tests/loki
```

Expected: FAIL with "Resource not found" or similar (confirms test is valid and red)

- [ ] **Step 2: Write the test file**

Create `tests/loki/chainsaw-test.yaml`:

```yaml
apiVersion: chainsaw.kyverno.io/v1alpha1
kind: Test
metadata:
  name: loki-healthy
spec:
  description: Loki + Promtail log aggregation stack is healthy
  concurrent: false
  timeouts:
    assert: 5m
    exec: 60s

  steps:
    - name: loki-argocd-app-synced
      description: Loki ArgoCD application is Synced and Healthy
      try:
        - assert:
            resource:
              apiVersion: argoproj.io/v1alpha1
              kind: Application
              metadata:
                name: loki
                namespace: argocd
              status:
                sync:
                  status: Synced
                health:
                  status: Healthy

    - name: promtail-argocd-app-synced
      description: Promtail ArgoCD application is Synced and Healthy
      try:
        - assert:
            resource:
              apiVersion: argoproj.io/v1alpha1
              kind: Application
              metadata:
                name: promtail
                namespace: argocd
              status:
                sync:
                  status: Synced
                health:
                  status: Healthy

    - name: loki-pod-running
      description: Loki single-binary pod is Running
      try:
        - assert:
            resource:
              apiVersion: apps/v1
              kind: StatefulSet
              metadata:
                name: loki
                namespace: loki
              status:
                readyReplicas: 1

    - name: promtail-daemonset-ready
      description: Promtail DaemonSet has all 8 nodes covered
      try:
        - assert:
            resource:
              apiVersion: apps/v1
              kind: DaemonSet
              metadata:
                name: promtail
                namespace: loki
              status:
                numberReady: 8
                desiredNumberScheduled: 8

    - name: loki-service-has-ip
      description: Loki gateway LoadBalancer service has MetalLB IP 192.168.0.220
      try:
        - script:
            content: |
              IP=$(kubectl get svc loki-gateway -n loki -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
              [ "$IP" = "192.168.0.220" ] || { echo "Expected 192.168.0.220, got: $IP"; exit 1; }

    - name: loki-ready-endpoint
      description: Loki /ready endpoint returns 200 (log ingestion active)
      try:
        - script:
            timeout: 30s
            content: |
              curl -sf http://192.168.0.220/ready | grep -q "ready" || { echo "Loki ready check failed"; exit 1; }

    - name: loki-has-labels
      description: Loki labels endpoint returns data (Promtail is shipping logs)
      try:
        - script:
            timeout: 30s
            content: |
              LABELS=$(curl -sf http://192.168.0.220/loki/api/v1/labels)
              echo "Labels response: $LABELS"
              echo "$LABELS" | grep -q '"data"' || { echo "No labels returned from Loki"; exit 1; }
```

- [ ] **Step 3: Extend the ArgoCD test to include loki-apps**

In `tests/argocd/chainsaw-test.yaml`, add a new step after the `cosmo-apps-healthy` step (before `vllm-healthy`):

```yaml
  - name: loki-apps-healthy
    try:
    - assert:
        resource:
          apiVersion: argoproj.io/v1alpha1
          kind: Application
          metadata:
            name: loki-apps
            namespace: argocd
          status:
            health:
              status: Healthy
```

- [ ] **Step 4: Run existing tests to confirm baseline is green**

```bash
chainsaw test tests/argocd
```

Expected: PASS (7 steps all green before loki-apps-healthy is added — the new step will fail until Loki is deployed, which is expected)

After adding the step, `chainsaw test tests/argocd` will fail on `loki-apps-healthy` until Loki is deployed. This is the expected red state.

- [ ] **Step 5: Commit**

```bash
git add tests/loki/chainsaw-test.yaml tests/argocd/chainsaw-test.yaml
git commit -m "test: add chainsaw tests for Loki + Promtail and extend argocd test"
```

---

## Task 8: Add just recipes

**Files:**
- Modify: `justfile`

- [ ] **Step 1: Add loki-status and test-loki recipes**

In `justfile`, after the `# ── vLLM` section, add a new `# ── Loki` section:

```just
# ── Loki ──────────────────────────────────────────────────────────────────────

# Show Loki + Promtail pod status
loki-status:
    kubectl get pods -n loki -o wide

# Run Loki chainsaw tests
test-loki:
    chainsaw test tests/loki
```

- [ ] **Step 2: Run just to confirm syntax**

```bash
just --list
```

Expected: output includes `loki-status` and `test-loki` (no parse errors)

- [ ] **Step 3: Commit**

```bash
git add justfile
git commit -m "feat: add just recipes for Loki status and tests"
```

---

## Task 9: Document in README, CLAUDE.md, and scripts/README.md

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`
- Modify: `scripts/README.md`

- [ ] **Step 1: Add Loki section to README.md**

In `README.md`, under `### Service Access`, add:
```
- **Loki**: http://loki.verticon.com (192.168.0.220:80) — log aggregation
```

Add a new `## Loki Log Aggregation` section after the existing Harbor section. Include:
- Service URL: `http://loki.verticon.com` (Caddy proxies from mullet)
- Direct IP: `http://192.168.0.220`
- Grafana integration: available in the Explore tab → Loki datasource
- Log sources: all 8 cluster nodes (pod logs + OS syslog + journal), external machines via Promtail systemd service
- Query examples using LogQL:
  ```
  {namespace="harbor"} |= "error"
  {node="puffer"} |= "Power key"
  {job="syslog", node="gold"} |= "nvme"
  ```
- Caddyfile entry for mullet:
  ```
  loki.verticon.com {
      reverse_proxy 192.168.0.220:80
      tls {
          resolvers 1.1.1.1 1.0.0.1
      }
  }
  ```
- External Promtail install: point to `scripts/promtail-external/install.sh`

- [ ] **Step 2: Update CLAUDE.md**

In `CLAUDE.md` under `### Key Components`, add:
```
- **Loki**: Grafana Loki log aggregation at 192.168.0.220 (`loki` namespace) — all pod logs + OS syslog; Grafana datasource at http://loki-gateway.loki.svc:80
```

In `CLAUDE.md` under `### Service Access`, add:
```
- **Loki**: http://loki.verticon.com (192.168.0.220:80)
```

- [ ] **Step 3: Update scripts/README.md**

Add a new section `### Loki S3 credentials bootstrap` documenting:

```bash
# After ArgoCD wave 1 syncs the CephObjectStoreUser, get the Rook-generated secret name:
SECRET_NAME=$(kubectl get cephobjectstoreuser loki-logs-user -n rook-ceph \
  -o jsonpath='{.status.info.secretName}')

# Copy S3 credentials to loki namespace
ACCESS_KEY=$(kubectl get secret $SECRET_NAME -n rook-ceph -o jsonpath='{.data.AccessKey}' | base64 -d)
SECRET_KEY=$(kubectl get secret $SECRET_NAME -n rook-ceph -o jsonpath='{.data.SecretKey}' | base64 -d)
kubectl create secret generic loki-s3-credentials \
  --namespace loki \
  --from-literal=AWS_ACCESS_KEY_ID="$ACCESS_KEY" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$SECRET_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
```

And a section `### External Promtail install (mudshark/oyster/minnow)`:

```bash
# On each external Ubuntu machine:
# Copy scripts/promtail-external/ to the machine, then:
sudo bash scripts/promtail-external/install.sh <hostname>
# e.g.:  sudo bash install.sh mudshark
```

- [ ] **Step 4: Commit**

```bash
git add README.md CLAUDE.md scripts/README.md
git commit -m "docs: add Loki documentation to README, CLAUDE.md, and scripts/README.md"
```

---

## Task 10: Apply to ArgoCD and run tests

This task is the cutover — it requires the S3 credentials bootstrap step (documented above) and then ArgoCD sync. Because it involves live cluster state, the implementation agent should document the steps but recognize that some steps (like the S3 credentials copy) must be performed by the operator.

- [ ] **Step 1: Apply the parent app-of-apps**

```bash
kubectl apply -f argoCD-apps/loki-apps.yaml
```

This registers `loki-apps` with ArgoCD. ArgoCD then discovers and deploys `loki-storage`, `loki`, and `promtail` in wave order.

- [ ] **Step 2: Wait for wave 1 — CephObjectStoreUser**

```bash
kubectl wait cephobjectstoreuser loki-logs-user -n rook-ceph \
  --for=jsonpath='{.status.phase}'=Ready --timeout=5m
```

- [ ] **Step 3: Get the Rook-generated S3 secret name**

```bash
kubectl get cephobjectstoreuser loki-logs-user -n rook-ceph \
  -o jsonpath='{.status.info.secretName}'
```

Note: Rook generates a secret with a non-obvious name like `rook-ceph-object-user-rook-ceph-rgw-loki-logs-user`. Use the `.status.info.secretName` field, not a guessed name.

- [ ] **Step 4: Create `loki` namespace and S3 credentials secret**

```bash
kubectl create namespace loki --dry-run=client -o yaml | kubectl apply -f -

SECRET_NAME=$(kubectl get cephobjectstoreuser loki-logs-user -n rook-ceph \
  -o jsonpath='{.status.info.secretName}')
ACCESS_KEY=$(kubectl get secret "$SECRET_NAME" -n rook-ceph \
  -o jsonpath='{.data.AccessKey}' | base64 -d)
SECRET_KEY=$(kubectl get secret "$SECRET_NAME" -n rook-ceph \
  -o jsonpath='{.data.SecretKey}' | base64 -d)
kubectl create secret generic loki-s3-credentials \
  --namespace loki \
  --from-literal=AWS_ACCESS_KEY_ID="$ACCESS_KEY" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$SECRET_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
```

**Note:** Loki Helm chart in monolithic mode reads S3 credentials from environment variables `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` OR from the `loki.storage.s3.accessKeyId` / `secretAccessKey` values. We use environment variables via the existing secret to avoid credentials in the values file. The Loki chart has `loki.storage.s3.secretAccessKey` and `loki.storage.s3.accessKeyId` fields, but these go into the values file in plaintext. Instead, we reference the secret via `loki.existingSecretForConfig` — but this requires placing the full config in the secret. The cleanest approach for this cluster's pattern is to use `loki.storage.s3.accessKeyId` and `secretAccessKey` pointing to the `loki-s3-credentials` secret via `extraEnvFrom`:

```yaml
# In loki-values.yaml, the singleBinary extraEnvFrom section:
singleBinary:
  replicas: 1
  persistence:
    enabled: true
    storageClass: rook-ceph-block
    size: 10Gi
  extraEnvFrom:
    - secretRef:
        name: loki-s3-credentials
```

This injects `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` as environment variables into the Loki pod. Loki's S3 client (an AWS SDK wrapper) automatically reads these env vars. The `loki-values.yaml` must include this `extraEnvFrom` block.

Update `loki-gitops/helm/loki-values.yaml` to add `singleBinary.extraEnvFrom` as shown above. Then recommit.

- [ ] **Step 5: Watch ArgoCD sync waves**

```bash
kubectl get applications -n argocd | grep -E "loki|promtail"
```

Expected progression:
```
loki-storage  Synced    Healthy
loki          Synced    Healthy
promtail      Synced    Healthy
loki-apps     Synced    Healthy
```

- [ ] **Step 6: Run tests**

```bash
just test-loki
```

Expected: all 7 steps pass.

```bash
just test
```

Expected: all suites pass (baseline regression check).

- [ ] **Step 7: Commit any fixes needed during deployment**

Fix and commit any issues discovered during deployment (e.g., wrong Loki chart version, gateway service name, volume mount paths on MicroK8s).

---

## Post-deployment: Caddy + DNS

These are operator steps (not automatable via GitOps):

1. **Cloudflare DNS**: Add A record `loki.verticon.com` → mullet's public IP (same as all other services)

2. **Caddyfile on mullet** (`sudo vi /etc/caddy/Caddyfile`), add:

```
loki.verticon.com {
    reverse_proxy 192.168.0.220:80
    request_body {
        max_size 0
    }
    tls {
        resolvers 1.1.1.1 1.0.0.1
    }
}
```

`max_size 0` disables Caddy's body size limit for log ingestion (Promtail external agents send bulk pushes).

3. **Reload Caddy**: `sudo systemctl reload caddy`

---

## Loki chart version notes

The Loki chart has undergone significant breaking changes between 5.x and 6.x. Key points for `6.28.0`:
- `deploymentMode: SingleBinary` replaces the old `singleBinary: {}` top-level toggle
- `loki.storage.s3.endpoint` is used instead of `loki.storage.bucketNames` at top level
- The gateway (nginx proxy in front of Loki read/write paths) is enabled by default and exposes port 80 — this is what we expose via MetalLB, not the internal `3100` port
- The gateway service is named `loki-gateway` (not `loki`) — important for Promtail's `clients.url` and the chainsaw test

**Troubleshooting chart version:** If `6.28.0` is not available at sync time (ArtifactHub may have moved), use `6.27.0` or `"*"` (latest). The implementation agent should verify the chart version before committing by checking `https://grafana.github.io/helm-charts` or ArtifactHub.

---

## Completion Checklist

Before the implementation is complete, verify:
- [ ] `just test-loki` passes all 7 steps
- [ ] `just test` passes all pre-existing suites (no regressions)
- [ ] `kubectl get pods -n loki` shows all pods Running
- [ ] Loki `/ready` endpoint responds at `http://192.168.0.220/ready`
- [ ] Loki labels endpoint returns data (Promtail is shipping logs)
- [ ] Grafana Explore → Loki datasource is available
- [ ] `loki-apps` appears in `tests/argocd/chainsaw-test.yaml` and passes
