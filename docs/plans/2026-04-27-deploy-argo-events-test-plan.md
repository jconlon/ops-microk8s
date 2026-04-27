# Test Plan: Deploy Argo Events (Webhook EventSource) — Issue #66

**Implementation plan:** `docs/plans/2026-04-27-deploy-argo-events.md`
**Worktree:** `/home/jconlon/git/ops-microk8s/.worktrees/deploy-argo-events`
**Testing strategy:** Agreed in session — three layers: (1) ArgoCD sync + pod health via chainsaw, (2) Webhook HTTP reachability via direct MetalLB IP, (3) End-to-end trigger: POST to webhook produces a new Workflow within 60s. Also: extend `tests/argocd/chainsaw-test.yaml`, `just test-argo-events` recipe, and `bash -n` syntax check on the post-push hook template.

---

## Harness Requirements

No new harnesses need to be built. The implementation reuses and extends existing harnesses:

| Harness | What it does | Status | Tests that depend on it |
|---|---|---|---|
| **Chainsaw** (`chainsaw test tests/argo-events/`) | Kubernetes-native assertion framework; runs `assert` (resource field matching via JMESPath) and `script` (arbitrary bash) steps against the live cluster | Existing, in use for `tests/argo-workflows/`, `tests/argocd/`, `tests/loki/`, etc. | T1–T9 |
| **kubectl** (inside chainsaw containers) | Available in all chainsaw script steps; used for resource queries and workflow counting | Existing | T7, T8, T9 |
| **curl** (inside chainsaw containers) | Available in all chainsaw script steps; used for direct HTTP probing | Existing (used in `tests/argo-workflows/chainsaw-test.yaml`) | T7, T8 |
| **Existing `tests/argocd/chainsaw-test.yaml`** | App-of-Apps health suite; extended with one new step | Existing, extended | T10 |
| **bash** (local devbox shell) | Used for `bash -n` syntax check | Existing | T11 |

**Important constraint:** The `argo` CLI is **not** available in chainsaw containers (`ARGO_NAMESPACE` env var is also absent). All workflow queries in chainsaw script steps must use `kubectl get workflow -n argo-workflows`.

---

## Test Plan

### T1 — Argo Events controller is deployed and Synced via ArgoCD

- **Name:** Argo Events ArgoCD `argo-events` application syncs and its controller deployment becomes available
- **Type:** integration
- **Disposition:** new
- **Harness:** Chainsaw `tests/argo-events/chainsaw-test.yaml`
- **Preconditions:** `argo-events-apps.yaml` has been `kubectl apply`-ed. ArgoCD can reach GitHub and the Helm chart repo.
- **Actions:** Assert `Application` named `argo-events` in namespace `argocd` has `status.sync.status: Synced` and `status.health.status: Healthy`. Then assert `Deployment` named `argo-events-controller-manager` in namespace `argo-events` has `availableReplicas >= 1`.
- **Expected outcome:** Both assertions pass within the 5m timeout. Source of truth: ArgoCD Application sync status (ArgoCD API) and Kubernetes Deployment status (Kubernetes API).
- **Interactions:** Exercises ArgoCD multi-source Helm chart pull, CRD installation via `crds.install: true`, namespace creation via `CreateNamespace=true`, MetalLB (not directly — but `argo-events` app must be Healthy before MetalLB IP assignment in subsequent steps).

---

### T2 — Argo Events resources ArgoCD app syncs (EventBus, EventSource, Sensor, RBAC deployed)

- **Name:** Argo Events resources ArgoCD `argo-events-resources` application syncs with non-empty resource set
- **Type:** integration
- **Disposition:** new
- **Harness:** Chainsaw `tests/argo-events/chainsaw-test.yaml`
- **Preconditions:** T1 passed (CRDs established in wave 1). `argo-events-resources-app.yaml` has been applied by ArgoCD via the App-of-Apps.
- **Actions:** (a) Assert `Application` named `argo-events-resources` in namespace `argocd` has `status.sync.status: Synced`. (b) Script: `kubectl get eventbus,eventsource,sensor -n argo-events --no-headers | wc -l` must be `>= 3` (at least one of each).
- **Expected outcome:** App is Synced AND the resource count is ≥ 3. The second assertion guards against the silent `directory.recurse: true` omission failure mode documented in the plan: ArgoCD would report Synced with zero resources if the field is missing. Source of truth: ArgoCD Application status + Kubernetes resource API.
- **Interactions:** Exercises `directory.recurse: true` behavior, wave-2 sync ordering, ClusterRole/ClusterRoleBinding cross-namespace RBAC creation, WorkflowTemplate creation in `argo-workflows` namespace.

---

### T3 — EventBus is in Running phase

- **Name:** Default EventBus reaches Running phase (NATS cluster is up)
- **Type:** integration
- **Disposition:** new
- **Harness:** Chainsaw `tests/argo-events/chainsaw-test.yaml`
- **Preconditions:** T2 passed (EventBus manifest applied).
- **Actions:** Assert `EventBus` named `default` in namespace `argo-events` has `status.phase: running` (lowercase — this is the Argo Events convention for EventBus, distinct from EventSource/Sensor which use capitalized `Running`).
- **Expected outcome:** Phase is `running` within 5m. Source of truth: Argo Events EventBus controller sets this phase when the NATS StatefulSet is ready.
- **Interactions:** Exercises the Argo Events controller's NATS provisioning (3 replicas), PVC creation if needed, and the EventBus controller watch loop.

---

### T4 — WebhookEventSource is in Running phase

- **Name:** git-push EventSource reaches Running phase (webhook server pod is up)
- **Type:** integration
- **Disposition:** new
- **Harness:** Chainsaw `tests/argo-events/chainsaw-test.yaml`
- **Preconditions:** T3 passed (EventBus Running — EventSource requires a running EventBus to start).
- **Actions:** Assert `EventSource` named `git-push` in namespace `argo-events` has `status.phase: Running` (capitalized).
- **Expected outcome:** Phase is `Running` within 5m. Source of truth: Argo Events EventSource controller.
- **Interactions:** Exercises EventBus connectivity (EventSource pod subscribes to NATS on startup), LoadBalancer service creation.

---

### T5 — Sensor is in Running phase

- **Name:** git-push Sensor reaches Running phase (sensor pod is subscribed to EventBus)
- **Type:** integration
- **Disposition:** new
- **Harness:** Chainsaw `tests/argo-events/chainsaw-test.yaml`
- **Preconditions:** T3 passed (EventBus Running — Sensor also requires a running EventBus).
- **Actions:** Assert `Sensor` named `git-push` in namespace `argo-events` has `status.phase: Running` (capitalized).
- **Expected outcome:** Phase is `Running` within 5m. Source of truth: Argo Events Sensor controller.
- **Interactions:** Exercises cross-namespace RBAC (Sensor pod uses `argo-events-sensor-sa` ServiceAccount with `ClusterRole` that allows workflow submission to `argo-workflows`); if the `spec.template.serviceAccountName` field is at the wrong YAML path, the Sensor will start but log `403 Forbidden` — this would NOT prevent the phase reaching `Running` but will cause T8 to fail. T5 is a necessary precondition, not the primary RBAC gate.

---

### T6 — EventSource LoadBalancer service has MetalLB IP 192.168.0.221

- **Name:** git-push EventSource service is assigned MetalLB IP 192.168.0.221
- **Type:** integration
- **Disposition:** new
- **Harness:** Chainsaw `tests/argo-events/chainsaw-test.yaml`
- **Preconditions:** T4 passed (EventSource Running — the service is created by the EventSource controller).
- **Actions:** Script: `kubectl get svc -n argo-events -l eventsource-name=git-push -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}'`. Assert result equals `192.168.0.221`.
- **Expected outcome:** IP is exactly `192.168.0.221`. Source of truth: MetalLB IP pool (`192.168.0.200-192.168.0.230`) and the `metallb.universe.tf/loadBalancerIPs: "192.168.0.221"` annotation in `spec.service.metadata.annotations` of the EventSource manifest.
- **Interactions:** Exercises MetalLB LoadBalancer IP annotation handling (plural `loadBalancerIPs`), EventSource controller service creation with passthrough annotations.

---

### T7 — Webhook endpoint accepts POST at MetalLB IP (HTTP 200)

- **Name:** POSTing a JSON payload to http://192.168.0.221:12000/push returns HTTP 200
- **Type:** integration
- **Disposition:** new
- **Harness:** Chainsaw `tests/argo-events/chainsaw-test.yaml` (script step with `curl`)
- **Preconditions:** T6 passed (IP assigned). T4 passed (EventSource Running — pod listening on port 12000).
- **Actions:** `curl -sf -o /dev/null -w "%{http_code}" -X POST http://192.168.0.221:12000/push -H 'Content-Type: application/json' -d '{"repo":"test","commit":"abc123"}'`. Assert status code is `200`.
- **Expected outcome:** HTTP 200. Source of truth: Argo Events EventSource HTTP server spec — a valid POST to a configured endpoint returns 200.
- **Interactions:** Direct probe to MetalLB IP bypasses Caddy (TLS termination layer), testing the lowest-level network path. The Sensor receives this event and attempts workflow submission — a `403` RBAC error here would still return `200` to the caller (EventSource decouples receipt from trigger). The E2E test (T8) is the gate for RBAC correctness.

---

### T8 — End-to-end: POST triggers a new git-push-build Workflow within 60s

- **Name:** A webhook POST causes the Sensor to submit a new `git-push-*` Workflow to `argo-workflows` within 60 seconds
- **Type:** scenario
- **Disposition:** new
- **Harness:** Chainsaw `tests/argo-events/chainsaw-test.yaml` (script step, 90s timeout)
- **Preconditions:** T5 passed (Sensor Running). T7 passed (endpoint reachable). `git-push-build` WorkflowTemplate exists in `argo-workflows` (T9 verifies this independently).
- **Actions:**
  1. Record baseline: `BEFORE=$(kubectl get workflow -n argo-workflows --no-headers 2>/dev/null | grep "^git-push-" | wc -l)`
  2. Fire: `curl -sf -X POST http://192.168.0.221:12000/push -H 'Content-Type: application/json' -d '{"repo":"https://github.com/jconlon/test","commit":"<timestamp>"}'`
  3. Poll every 2s up to 60s: `AFTER=$(kubectl get workflow -n argo-workflows --no-headers | grep "^git-push-" | wc -l)` — succeed when `AFTER > BEFORE`.
- **Expected outcome:** A new `git-push-*` Workflow appears in `argo-workflows` within 60s. The Workflow need not complete successfully — its creation is the observable proof that the full chain (HTTP POST → EventSource → NATS EventBus → Sensor → cross-namespace WorkflowTemplate trigger) is functional. Source of truth: Argo Events Sensor trigger documentation (webhook payload → argoWorkflow trigger → workflow submit).
- **Interactions:** This test exercises the most interaction boundaries: MetalLB → EventSource pod → NATS EventBus → Sensor pod → ClusterRole RBAC → Argo Workflows API server → WorkflowTemplate lookup → Workflow creation. A failure here is the primary diagnostic signal for RBAC misconfiguration (wrong SA path, missing verbs), EventBus connectivity issues, or Sensor trigger parameter extraction errors (`body.repo`, `body.commit`).

---

### T9 — WorkflowTemplate git-push-build exists in argo-workflows namespace

- **Name:** `git-push-build` WorkflowTemplate exists and is visible to the Argo Workflows controller
- **Type:** integration
- **Disposition:** new
- **Harness:** Chainsaw `tests/argo-events/chainsaw-test.yaml`
- **Preconditions:** T2 passed (argo-events-resources app synced — WorkflowTemplate is in this app's resource tree).
- **Actions:** Assert `WorkflowTemplate` named `git-push-build` in namespace `argo-workflows` exists (any status accepted).
- **Expected outcome:** Resource exists. Source of truth: `argo-events-gitops/resources/sensors/git-push-sensor.yaml` (contains the WorkflowTemplate document). This is a separate assertion from T8 because a missing WorkflowTemplate is a distinct failure mode that produces a different error (Sensor logs `workflowtemplate not found`) from an RBAC failure.
- **Interactions:** Exercises ArgoCD cross-namespace resource application — `argo-events-resources-app` has `destination.namespace: argo-events` but the WorkflowTemplate manifest has `namespace: argo-workflows` explicitly. ArgoCD must honour the manifest's `metadata.namespace`.

---

### T10 — argo-events-apps ArgoCD Application is Healthy (ArgoCD suite gate)

- **Name:** `argo-events-apps` App-of-Apps is Healthy in the ArgoCD health suite
- **Type:** integration
- **Disposition:** extend (add new step to `tests/argocd/chainsaw-test.yaml`)
- **Harness:** Chainsaw `tests/argocd/chainsaw-test.yaml` — step appended after existing `vllm-healthy` step
- **Preconditions:** Argo Events fully deployed (all child applications Healthy).
- **Actions:** Assert `Application` named `argo-events-apps` in namespace `argocd` has `status.health.status: Healthy`.
- **Expected outcome:** App is Healthy. Source of truth: ArgoCD Application health propagation — a parent App-of-Apps is Healthy when all children are Healthy. This step ensures the deployment registers correctly in the global ArgoCD health suite used by `just test`.
- **Interactions:** Exercises the ArgoCD App-of-Apps health rollup from `argo-events` and `argo-events-resources` child applications.

---

### T11 — post-push hook template passes bash -n syntax check

- **Name:** `scripts/hooks/post-push.tmpl` is syntactically valid bash
- **Type:** unit
- **Disposition:** new
- **Harness:** `bash -n` in local devbox shell (not chainsaw — this is a static check on a committed file)
- **Preconditions:** `scripts/hooks/post-push.tmpl` has been created and committed.
- **Actions:** `bash -n scripts/hooks/post-push.tmpl && echo "Syntax OK: $?"`
- **Expected outcome:** Zero exit code, `Syntax OK: 0` output. Source of truth: bash syntax specification.
- **Interactions:** None — static analysis only. Does not exercise runtime behavior (curl invocation, git commands, env var fallback). Runtime behavior is exercised by T7 and T8 which validate the endpoint the hook targets.

---

### T12 — just recipes are registered and functional

- **Name:** `just argo-events-status` and `just test-argo-events` are listed and syntactically valid
- **Type:** integration
- **Disposition:** new
- **Harness:** `just --list` in local devbox shell; `just test-argo-events` executes chainsaw
- **Preconditions:** `justfile` has been updated with the new `argo-events` section.
- **Actions:** (a) `just --list | grep -E "argo-events-status|test-argo-events"` — both names must appear. (b) `just test-argo-events` — must execute chainsaw and produce PASS output (depends on T1–T9 passing).
- **Expected outcome:** Both recipe names appear in `just --list` output. `just test-argo-events` passes. Source of truth: `justfile` recipe definitions.
- **Interactions:** Exercises the justfile shebang-style recipe syntax, shell invocation of `kubectl` and `chainsaw`.

---

### T13 — Argo Workflows suite still passes (no regression)

- **Name:** Existing `tests/argo-workflows/chainsaw-test.yaml` still passes after Argo Events deployment
- **Type:** regression
- **Disposition:** existing (run unmodified)
- **Harness:** Chainsaw `tests/argo-workflows/chainsaw-test.yaml` — run with `chainsaw test tests/argo-workflows/`
- **Preconditions:** Argo Events fully deployed.
- **Actions:** Run `chainsaw test tests/argo-workflows/` and assert all 8 existing steps pass.
- **Expected outcome:** All steps pass, no regression. The Argo Events deployment should not affect Argo Workflows (separate namespace, no shared resources except the cross-namespace WorkflowTemplate and ClusterRole). Source of truth: `tests/argo-workflows/chainsaw-test.yaml` as committed.
- **Interactions:** The new `git-push-build` WorkflowTemplate in `argo-workflows` and the new `argo-events-workflow-submit` ClusterRole must not conflict with existing Argo Workflows resources.

---

## Test Execution Order

The tests above are ordered by dependency and value:

| Order | Test | Why first |
|---|---|---|
| 1 | T1 | Controller must be up before CRD resources can exist |
| 2 | T2 | Resources app must sync before EventBus/EventSource/Sensor are available; silent failure guard |
| 3 | T9 | WorkflowTemplate existence is prerequisite context for T8 |
| 4 | T3 | EventBus must be running before EventSource and Sensor can start |
| 5 | T4 | EventSource must be running before service IP is assigned |
| 6 | T5 | Sensor must be running before E2E trigger is meaningful |
| 7 | T6 | MetalLB IP must be assigned before HTTP probe |
| 8 | T7 | Endpoint reachability confirmed before E2E (isolates network vs trigger failures) |
| 9 | T8 | Highest-value: full E2E trigger chain — primary acceptance gate |
| 10 | T10 | ArgoCD suite gate — runs as part of `just test` |
| 11 | T11 | Static syntax check — catches hook errors before install |
| 12 | T12 | Just recipes — user-facing operational surface |
| 13 | T13 | Regression: run after all new tests pass |

All tests T1–T9 are implemented in `tests/argo-events/chainsaw-test.yaml` in the step order above. T10 is a new step appended to `tests/argocd/chainsaw-test.yaml`. T11 and T12 are local shell checks documented in the plan as verification steps. T13 runs `tests/argo-workflows/chainsaw-test.yaml` unchanged.

---

## Coverage Summary

### Covered

| Area | Tests |
|---|---|
| ArgoCD App-of-Apps parent health | T10 |
| Wave 1 (Helm chart) ArgoCD sync | T1 |
| Wave 2 (resources) ArgoCD sync + silent-failure guard | T2 |
| Controller deployment availability | T1 |
| EventBus Running phase (NATS) | T3 |
| EventSource Running phase | T4 |
| Sensor Running phase | T5 |
| MetalLB IP assignment (annotation path) | T6 |
| Webhook HTTP 200 on direct MetalLB IP | T7 |
| End-to-end trigger: POST → Workflow created | T8 |
| WorkflowTemplate existence in argo-workflows | T9 |
| Cross-namespace RBAC (indirectly, via T8 success) | T8 |
| post-push hook template bash syntax | T11 |
| just recipe registration | T12 |
| Argo Workflows regression | T13 |

### Explicitly Excluded (per agreed strategy)

| Area | Reason |
|---|---|
| Caddy TLS / `https://events.verticon.com` HTTPS test | Caddy config is a manual operator step; DNS propagation timing makes this unreliable in automated chainsaw. The HTTP probe at MetalLB IP (T7/T8) validates the underlying service. HTTPS is verified manually post-deploy as documented in Task 4 of the plan. |
| Ceph bucket notification EventSource | Deferred to future issue per scope decision in conversation |
| GitHub polling EventSource | Deferred to future issue |
| Cron EventSource | Deferred to future issue |
| Workflow completion / log content | Out of scope — `git-push-build` is a placeholder template; the E2E test (T8) only asserts workflow creation, not completion or output correctness. |
| Sensor log inspection for 403 errors | Not automated; operator checks `kubectl logs -n argo-events -l sensor-name=git-push` if T8 fails |
| Performance | No performance risk for a webhook receiver + workflow submission at this scale |

### Risk from Exclusions

The Caddy/HTTPS exclusion means the `events.verticon.com` TLS chain is not automatically tested. If Caddy is misconfigured or the Cloudflare DNS record is missing, the post-push hook will silently fail (it never exits non-zero). The hook README documents the manual test command. A future issue could add an HTTPS connectivity check to the chainsaw test once DNS propagation is stable.
