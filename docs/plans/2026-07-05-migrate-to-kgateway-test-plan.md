# Test Plan: Migrate Cluster Ingress to Gateway API via kgateway — Issue #108

**Implementation plan:** `docs/plans/2026-07-05-migrate-to-kgateway.md`
**Testing strategy:** Four layers, matching the argo-events precedent: (1) ArgoCD sync + controller health via chainsaw, (2) Gateway API resource status (`GatewayClass`/`Gateway`/`HTTPRoute`/`ClusterIssuer` conditions), (3) direct HTTP(S) reachability via the shared MetalLB IP (bypassing DNS/Caddy), (4) post-cutover public-hostname regression pass. `just test-kgateway` / `just test-cert-manager` recipes; extend `tests/argocd/chainsaw-test.yaml`.

---

## Harness Requirements

| Harness | What it does | Status | Tests that depend on it |
|---|---|---|---|
| **Chainsaw** (`chainsaw test tests/kgateway/`, `tests/cert-manager/`) | Kubernetes-native assertion framework — `assert` (JMESPath field matching) and `script` (bash) steps against the live cluster | Existing, reused pattern from `tests/argo-events/`, `tests/loki/`, etc. | T1–T9 |
| **kubectl** (inside chainsaw containers) | Resource status queries, Gateway address lookup | Existing | T3, T5, T6, T9 |
| **curl** (inside chainsaw containers) | Direct HTTP(S) probing of the shared Gateway IP with `Host` header overrides | Existing (same pattern as `tests/argo-events/chainsaw-test.yaml`) | T6, T8 |
| **Existing `tests/argocd/chainsaw-test.yaml`** | App-of-Apps health suite | Existing, extended with two new steps | T10 |
| **bash** (local devbox shell) | Manual per-hostname curl loop after DNS cutover | Existing | T11 |

**Important constraint (carried over from the argo-events test plan):** chainsaw script steps have `kubectl`/`curl` but not the `argo` CLI, and no cluster-specific env vars from the devbox `init_hook`. Any `Host`-header probing must be explicit in the script, not rely on DNS resolution (DNS still points at Caddy until Task 6).

---

## Test Plan

### T1 — kgateway controller deployed and Synced via ArgoCD

- **Name:** `kgateway` ArgoCD Application syncs and its controller becomes healthy
- **Type:** integration
- **Disposition:** new
- **Harness:** Chainsaw `tests/kgateway/chainsaw-test.yaml`
- **Preconditions:** `kgateway-apps.yaml` applied; `kgateway-crds` (wave 1) already Synced.
- **Actions:** Assert `Application` `kgateway` in `argocd` has `status.sync.status: Synced` and `status.health.status: Healthy`.
- **Expected outcome:** Passes within 5m. Source of truth: ArgoCD Application status.
- **Interactions:** Exercises OCI Helm chart pull, CRD-then-controller wave ordering.

---

### T2 — GatewayClass kgateway is Accepted

- **Name:** Default `GatewayClass` named `kgateway` reports `Accepted: True`
- **Type:** integration
- **Disposition:** new
- **Harness:** Chainsaw `tests/kgateway/chainsaw-test.yaml`
- **Preconditions:** T1 passed.
- **Actions:** Assert `GatewayClass` `kgateway` has an `Accepted` condition with status `True`.
- **Expected outcome:** Passes within 5m. **This test is also the empirical answer to the plan's open item** on whether the chart auto-creates the GatewayClass — if it never appears, this test's failure is the signal to add an explicit `GatewayClass` manifest.
- **Interactions:** Exercises kgateway controller's class-acceptance reconciliation loop.

---

### T3 — Shared Gateway is Programmed with the correct MetalLB IP

- **Name:** `cluster-gateway` in `kgateway-system` is `Programmed: True` with address `192.168.0.224`
- **Type:** integration
- **Disposition:** new
- **Harness:** Chainsaw `tests/kgateway/chainsaw-test.yaml`
- **Preconditions:** T2 passed.
- **Actions:** (a) Assert `Gateway` `cluster-gateway` has `Programmed: True`. (b) Script: `kubectl get gateway cluster-gateway -n kgateway-system -o jsonpath='{.status.addresses[0].value}'` equals `192.168.0.224`.
- **Expected outcome:** Both pass. Source of truth: Gateway API status + MetalLB IP pool assignment via the `metallb.universe.tf/loadBalancerIPs` annotation.
- **Interactions:** Exercises MetalLB LoadBalancer Service creation for a Gateway API `Gateway` (first use of this pattern in the cluster — every prior service used a plain `Service`, not a `Gateway`).

---

### T4 — cert-manager deployed and Synced via ArgoCD

- **Name:** `cert-manager` ArgoCD Application syncs; controller/webhook/cainjector pods available
- **Type:** integration
- **Disposition:** new
- **Harness:** Chainsaw `tests/cert-manager/chainsaw-test.yaml`
- **Preconditions:** `cert-manager-apps.yaml` applied.
- **Actions:** Assert `Application` `cert-manager` Synced/Healthy; assert `Deployment` `cert-manager` in `cert-manager` namespace has `availableReplicas >= 1`.
- **Expected outcome:** Passes within 5m.
- **Interactions:** Exercises Jetstack Helm chart with `config.enableGatewayAPI: true` and `installCRDs: true`.

---

### T5 — ClusterIssuer letsencrypt-http01 is Ready

> **Correction (2026-07-06):** the `ClusterIssuer` uses a **DNS-01** solver (Cloudflare), not `http01.gatewayHTTPRoute` as originally written here — `*.verticon.com` resolves to private LAN IPs, so HTTP-01 can never succeed (see the implementation plan's Architectural Decisions). The resource is still named `letsencrypt-http01` (kept as-is to avoid a rename) but the mechanism is DNS-01.

- **Name:** `ClusterIssuer` reaches `Ready: True`
- **Type:** integration
- **Disposition:** new
- **Harness:** Chainsaw `tests/cert-manager/chainsaw-test.yaml`
- **Preconditions:** T4 passed (cert-manager running). Depends on the Cloudflare API token Secret existing (issue #109) — no dependency on `cluster-gateway` at all with DNS-01.
- **Actions:** Assert `ClusterIssuer` `letsencrypt-http01` has a `Ready` condition with status `True`.
- **Expected outcome:** Passes within 5m. A failure here most likely means the Cloudflare API token Secret is missing or has insufficient permissions (`Zone:DNS:Edit` on `verticon.com`) — check `kubectl describe clusterissuer letsencrypt-http01` for the specific ACME error.
- **Interactions:** Exercises cert-manager's ACME account registration against Let's Encrypt's production directory and its Cloudflare DNS-01 solver wiring (creating/polling/cleaning up `_acme-challenge` TXT records via the Cloudflare API).

---

### T6 — pgAdmin HTTPRoute accepted and reachable via the shared Gateway (POC)

- **Name:** POC: `pgadmin` `HTTPRoute` is `Accepted`; a `Host`-header probe to `192.168.0.224` returns the pgAdmin login page
- **Type:** scenario
- **Disposition:** new
- **Harness:** Chainsaw `tests/kgateway/chainsaw-test.yaml`
- **Preconditions:** T3 and T5 passed. `pgadmin-httproute.yaml` applied (Task 4). `directory.recurse: true` set on `kgateway-resources-app`.
- **Actions:** (a) Assert `Certificate` `pgadmin-tls` has `status.conditions[type=Ready].status: "True"`. (b) Assert `HTTPRoute` `pgadmin` has `status.parents[].conditions[type=Accepted].status: "True"`. (c) Script: `curl -sk -H "Host: pgadmin.verticon.com" https://192.168.0.224` returns HTTP 200 or 302.
- **Expected outcome:** All three pass. This is the primary acceptance gate for the entire POC — the full chain (ACME DNS-01 solve via Cloudflare → Certificate issued → Gateway's `https-pgadmin` listener terminates TLS with that cert → HTTPRoute → backend Service → pgAdmin pod) must work end-to-end.
- **Interactions:** Exercises HTTPRoute backendRef resolution, Gateway API's `directory.recurse: true` requirement on both `kgateway-resources-app` and `cert-manager-resources-app` (silent-failure risk if missing — same trap as argo-events), and the confirmed per-hostname listener+Certificate pattern from the plan's Architectural Decisions (this test is the first live proof of it working, not just a documented assumption).

---

### T7 — Existing Caddy route to pgAdmin still works (no regression during POC)

- **Name:** `https://pgadmin.verticon.com` via Caddy/mullet (existing DNS, unchanged) still returns 200
- **Type:** regression
- **Disposition:** new
- **Harness:** Manual (local devbox `curl`) — not chainsaw, since DNS still points at mullet and chainsaw runs in-cluster
- **Preconditions:** POC deployed (T6 passed). DNS/Caddy untouched (Task 6 not yet performed).
- **Actions:** `curl -sI https://pgadmin.verticon.com | head -1` from a workstation with normal DNS resolution.
- **Expected outcome:** HTTP 200, served by Caddy/mullet exactly as before — proves the migration so far is additive, not disruptive.
- **Interactions:** None new — this is a negative-control check that nothing in Tasks 1–4 touched the production path.

---

### T8 — Per-service HTTPRoute reachability (Task 5, repeated per service)

- **Name:** Each migrated service's `HTTPRoute` is `Accepted` and reachable via `Host`-header probe to `192.168.0.224`
- **Type:** integration (repeated)
- **Disposition:** new (one instance per service in the Task 5 wave table)
- **Harness:** Chainsaw `tests/kgateway/chainsaw-test.yaml` — one assertion pair appended per service, same shape as T6
- **Preconditions:** T6 passed and Checkpoint B manually confirmed (pattern proven once before repeating).
- **Actions:** Same as T6's two assertions, parameterized per service/hostname/backend.
- **Expected outcome:** All pass for every service in the Task 5 table before Checkpoint C.
- **Interactions:** Each instance exercises a different backend Service — first real proof that the shared Gateway correctly routes by `Host` header/hostname match across multiple concurrent `HTTPRoute`s (not just a single-route Gateway as in T6).

---

### T9 — kgateway-apps / cert-manager-apps Healthy (ArgoCD suite gate)

- **Name:** Both App-of-Apps parents are `Healthy` in the global ArgoCD health suite
- **Type:** integration
- **Disposition:** extend (`tests/argocd/chainsaw-test.yaml`, two new steps)
- **Harness:** Chainsaw `tests/argocd/chainsaw-test.yaml`
- **Preconditions:** kgateway and cert-manager fully deployed (Task 3 complete).
- **Actions:** Assert `Application` `kgateway-apps` and `Application` `cert-manager-apps` (both in `argocd`) have `status.health.status: Healthy`.
- **Expected outcome:** Both Healthy. Ensures the deployment registers in the suite used by `just test`.
- **Interactions:** ArgoCD App-of-Apps health rollup, same pattern as the existing `argo-events-apps-healthy` step.

---

### T10 — Post-cutover: every migrated hostname resolves and serves valid TLS via the Gateway

- **Name:** Public DNS cutover (Task 6) is correct — every migrated hostname now resolves to `192.168.0.224` and serves a valid cert
- **Type:** regression / scenario
- **Disposition:** new
- **Harness:** Manual bash loop (local devbox shell), documented in the plan's Task 6 Step 3 — not automated in chainsaw since it depends on public DNS propagation timing (same exclusion rationale as the argo-events plan's Caddy/HTTPS test)
- **Preconditions:** Task 6 DNS cutover and Caddyfile cleanup performed.
- **Actions:** `for h in grafana prometheus alertmanager loki registry workflows events pgadmin; do curl -sI https://$h.verticon.com | head -1; done`.
- **Expected outcome:** HTTP 200 (or app-appropriate redirect) for every hostname, now genuinely served end-to-end through the Gateway — not just the direct-IP probes used in T6/T8.
- **Interactions:** First real-world test of the full path: public DNS → `192.168.0.224` → kgateway → HTTPRoute → backend, with no Caddy involved at all.

---

### T11 — Full regression: `just test` after full migration

- **Name:** Entire chainsaw suite passes after kgateway/cert-manager migration and Caddy decommission
- **Type:** regression
- **Disposition:** existing (run unmodified, plus the two new suites)
- **Harness:** `just test`
- **Preconditions:** Task 6 complete.
- **Actions:** Run `just test`.
- **Expected outcome:** All suites (`cluster`, `storage`, `gpu`, `postgresql`, `argocd`, `kafka`, `kafka-connect`, `apicurio`, `loki`, `harbor`, `freshrss`, `vllm`, plus new `kgateway`/`cert-manager`) pass. No suite depends on Caddy directly, so removing it should not regress anything outside the newly-migrated hostnames.
- **Interactions:** Broadest possible regression check; also confirms PostgreSQL/Ceph RGW/S3 TCP services (explicitly out of scope for this migration) were left untouched.

---

## Test Execution Order

| Order | Test | Why first |
|---|---|---|
| 1 | T1 | Controller must be Synced before GatewayClass can be Accepted |
| 2 | T2 | GatewayClass Accepted required before a Gateway can use it |
| 3 | T3 | Gateway must be Programmed with the right IP before ClusterIssuer can solve against it |
| 4 | T4 | cert-manager must be running before its ClusterIssuer can exist |
| 5 | T5 | ClusterIssuer Ready is a precondition for any real certificate issuance |
| 6 | T6 | POC — the primary proof that the whole chain works, gates Checkpoint B |
| 7 | T7 | Confirms POC was non-disruptive before proceeding |
| 8 | T8 | Repeated once trust is established from T6, gates Checkpoint C |
| 9 | T9 | ArgoCD suite gate — part of `just test` from here on |
| 10 | T10 | Only meaningful after Task 6's DNS cutover |
| 11 | T11 | Final full-suite regression |

---

## Coverage Summary

### Covered

| Area | Tests |
|---|---|
| kgateway ArgoCD sync + controller health | T1 |
| GatewayClass acceptance (resolves the plan's open item) | T2 |
| Shared Gateway programmed + correct MetalLB IP | T3 |
| cert-manager ArgoCD sync + pod health | T4 |
| ClusterIssuer readiness (DNS-01 via Cloudflare) | T5 |
| POC end-to-end reachability + TLS | T6 |
| Non-regression of existing Caddy path during POC | T7 |
| Per-service HTTPRoute reachability (repeated) | T8 |
| ArgoCD App-of-Apps health suite gate | T9 |
| Post-cutover public hostname + TLS validation | T10 |
| Full-suite regression, incl. confirming TCP services untouched | T11 |

### Explicitly Excluded

| Area | Reason |
|---|---|
| Automated public-DNS/HTTPS chainsaw test | Public DNS propagation timing makes this unreliable in an automated in-cluster runner; T6/T8 (direct MetalLB IP probes) validate the underlying service, T10 is the manual post-cutover check — same exclusion rationale as the argo-events plan's Caddy/HTTPS test. |
| Gateway API `TCPRoute`/`TLSRoute` for PostgreSQL/Ceph RGW | Explicitly out of scope per this plan's Architectural Decisions — those services keep dedicated MetalLB IPs. |
| kagent / Agentgateway functional tests | Task 7 is a follow-on issue, not implemented here. |
| Let's Encrypt staging-vs-production issuance correctness | Assumed correct based on cert-manager's own conformance; only presence of `Ready: True` and a working TLS handshake (T6/T8/T10) is verified, not certificate chain/OCSP details. |
| Load/performance testing of the shared Gateway | No performance risk expected at this traffic scale (same reasoning as the argo-events plan); revisit only if kgateway becomes a bottleneck after full migration. |

### Risk from Exclusions

The lack of an automated DNS/HTTPS chainsaw check means a bad Cloudflare A-record edit or a missed Caddyfile removal in Task 6 would only be caught by the manual T10 loop. Since Task 6 is explicitly incremental (one hostname at a time is implied though not enforced by tooling — the operator should treat the `for h in ...` loop in T10 as a per-hostname gate, not a batch-and-check-once step) and easily revertible (repoint the A record back to mullet), the blast radius of a mistake here is a few minutes of downtime for one hostname, not the whole cluster.
