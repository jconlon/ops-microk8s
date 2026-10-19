# Kured — Kubernetes Reboot Daemon

Automated rolling node reboots for the MicroK8s cluster. Kured safely drains and reboots one node at a time when a node needs a reboot, meaning either:

- `/var/run/reboot-required` exists (written by update-notifier during unattended-upgrades), **or**
- the running kernel (`uname -r`) is older than the newest installed kernel (`linux-version list | linux-version sort`).

The kernel check is required because on Livepatch nodes update-notifier deliberately **never** writes `/var/run/reboot-required` for kernel packages. It defers to Livepatch, and Livepatch's own apt hook only ever removes the flag. Without the check, Livepatch nodes stay on old kernels forever (issue #133). Both checks run as a single `rebootSentinelCommand` in `helm/kured-values.yaml`.

## Architecture

| Layer | Tool | Nodes |
|-------|------|-------|
| Live kernel patches (no reboot) | Livepatch via Ubuntu Pro Free | mullet, trout, whale, tuna, gold |
| Security package updates | unattended-upgrades | All 8 nodes |
| Safe rolling reboots when needed | kured | All 8 nodes |

## Deployment

Kured is deployed via ArgoCD as a Helm chart into `kube-system`. The ArgoCD Application is at `argoCD-apps/kured-app.yaml`.

Bootstrap (first time only):
```bash
kubectl apply -f argoCD-apps/kured-app.yaml
```

## Configuration

See `helm/kured-values.yaml`:
- **Reboot window**: 02:00–06:00 Eastern
- **Check period**: every 1 hour
- **Reboot trigger**: `rebootSentinelCommand` (sentinel file **or** newer installed kernel). This requires `useRebootSentinelHostPath: false`, otherwise the chart silently drops the command.
- **Drain timeout**: 2 hours (generous for Ceph workloads)
- **Tolerations**: runs on control plane nodes

## Node Setup (one-time, run on each node)

### 1. Unattended-Upgrades (all 8 nodes)

Copy and run on each node:
```bash
scp kured-gitops/node-setup/setup-unattended-upgrades.sh <node>:
ssh <node> sudo bash setup-unattended-upgrades.sh
```

Nodes: `mullet`, `trout`, `tuna`, `whale`, `gold`, `squid`, `puffer`, `carp`

### 2. Canonical Livepatch (5 nodes only)

Requires an Ubuntu Pro Free token from https://ubuntu.com/pro/dashboard (free for up to 5 machines).

```bash
scp kured-gitops/node-setup/setup-livepatch.sh <node>:
ssh <node> sudo bash setup-livepatch.sh <your-pro-token>
```

**Livepatch nodes** (Ubuntu Pro Free — 5 machine limit):
- `mullet` — Control Plane
- `trout` — Control Plane
- `whale` — Control Plane
- `tuna` — Worker
- `gold` — Ceph Storage

Livepatch nodes still reboot via kured when a new kernel is installed, through the kernel-version check above. Livepatch covers the gap between the kernel install and the next reboot window.

**kured-only nodes** (no Livepatch — Ceph tolerates rolling reboots):
- `squid` — Ceph Storage
- `puffer` — Ceph Storage
- `carp` — Ceph Storage

## Verification

```bash
# Check kured DaemonSet
kubectl get ds -n kube-system kured
kubectl get pods -n kube-system -l app.kubernetes.io/name=kured

# Check kured logs
kubectl logs -n kube-system -l app.kubernetes.io/name=kured --tail=50

# Check unattended-upgrades on a node
ssh <node> systemctl status unattended-upgrades

# Check Livepatch status on a Pro node
ssh mullet canonical-livepatch status

# Manually trigger a test reboot (on a non-critical node)
ssh squid sudo touch /var/run/reboot-required
```
