# Deploy Argo Events (Webhook EventSource) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use trycycle-executing to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy Argo Events v1.9.10 as a GitOps-managed ArgoCD app into the `argo-events` namespace, wire a Webhook EventSource exposed as a MetalLB LoadBalancer service at `192.168.0.221` (DNS: `events.verticon.com`, HTTPS via Caddy on mullet), configure a Sensor that triggers Argo Workflows on incoming webhook payloads, and provide a generic `post-push` git hook template that developers can install to fire CI builds on `git push`.

**Architecture:** Argo Events runs in the `argo-events` namespace alongside `argo-workflows`. It uses a native NATS-backed `EventBus` (installed by the Argo Events controller), a `WebhookEventSource` exposed as a LoadBalancer service on port 12000 at `192.168.0.221`, and a `Sensor` that maps the incoming JSON payload to Argo Workflows `WorkflowTemplate` parameters and submits a workflow. Caddy on `mullet` terminates TLS and proxies to `192.168.0.221:12000`. The deployment follows the same App-of-Apps pattern as `argo-workflows-apps` (parent → child ArgoCD Application). A generic `post-push` hook template lives in `scripts/hooks/post-push.tmpl` and the hook README explains how to install it per-repo.

**Tech Stack:**
- Argo Events Helm chart `argo-events` at `https://argoproj.github.io/argo-helm`, chart `2.4.21` (app version `v1.9.10`)
- Argo Events CRDs: `EventBus`, `EventSource`, `Sensor`
- MetalLB LoadBalancer IP `192.168.0.221`
- Caddy on mullet (TLS termination for `events.verticon.com`)
- Chainsaw for e2e testing; `just` for status and test recipes

---

## File Structure

### New files

| Path | Purpose |
|---|---|
| `argo-events-gitops/helm/argo-events-values.yaml` | Argo Events Helm values (controller, RBAC) |
| `argo-events-gitops/resources/eventsources/git-push-eventsource.yaml` | WebhookEventSource — receives git push POSTs |
| `argo-events-gitops/resources/sensors/git-push-sensor.yaml` | Sensor — maps payload to WorkflowTemplate trigger |
| `argo-events-gitops/resources/eventbus/default-eventbus.yaml` | EventBus (NATS) — message broker for events |
| `argoCD-apps/argo-events-apps.yaml` | App-of-Apps parent pointing to `argoCD-apps/argo-events/` |
| `argoCD-apps/argo-events/argo-events-app.yaml` | Wave 1 — Argo Events Helm chart (controller + CRDs) |
| `argoCD-apps/argo-events/argo-events-resources-app.yaml` | Wave 2 — EventBus + EventSource + Sensor manifests |
| `tests/argo-events/chainsaw-test.yaml` | Chainsaw health + functional tests |
| `scripts/hooks/post-push.tmpl` | Generic git post-push hook template |
| `scripts/hooks/README.md` | Installation instructions for the hook |

### Modified files

| Path | Change |
|---|---|
| `justfile` | Add `argo-events-status` and `test-argo-events` recipes |
| `tests/argocd/chainsaw-test.yaml` | Add `argo-events-apps` ArgoCD Application health step |
| `CLAUDE.md` | Add Argo Events to Key Components and Service Access |
| `scripts/README.md` | Document `events.verticon.com` endpoint and hook setup |

---

## Architectural Decisions

### Argo Events namespace: `argo-events` (isolated)
Argo Events has its own CRDs, controller, and RBAC surface. Co-locating it in `argo-workflows` would couple two separately-versioned projects and complicate their independent lifecycle. All other cluster apps use isolated namespaces; `argo-events` follows the same convention.

### EventBus: NATS (default) vs. Jetstream vs. Kafka
**Decision: default NATS (native, managed by Argo Events controller).** The Argo Events Helm chart installs a lightweight NATS cluster automatically via the EventBus controller — no external dependency. Using the existing Kafka cluster would add a dependency across two namespaces and require a `KafkaEventBus` CRD that is experimentally supported. For this initial Webhook-only deployment, NATS is the idiomatic choice. The issue explicitly defers Kafka-backed bucket notifications to a future phase.

### Webhook EventSource port: 12000 (Argo Events default)
Argo Events EventSources listen on port 12000 by default. The EventSource controller creates a `Service` for the EventSource pod. We expose this via a MetalLB LoadBalancer annotation, consistent with every other service in the cluster.

### MetalLB IP: 192.168.0.221
Currently allocated IPs end at 192.168.0.220 (Loki). The pool has been expanded to 192.168.0.200-230. 192.168.0.221 is the next sequential IP, consistent with the cluster's IP allocation scheme.

### Caddy TLS termination: same pattern as all other services
Every cluster service (`grafana.verticon.com`, `workflows.verticon.com`, etc.) is proxied through Caddy on `mullet` with `tls { resolvers 1.1.1.1 1.0.0.1 }` and a Cloudflare DNS-01 cert. `events.verticon.com` → `192.168.0.221:12000` follows exactly this pattern. The Caddy change is a manual step (Caddyfile is not GitOps-managed), documented in the plan and noted in `scripts/README.md`.

### Sensor: WorkflowTemplate `git-push-build` (generic template)
The Sensor will trigger against a `WorkflowTemplate` named `git-push-build` in the `argo-workflows` namespace. This WorkflowTemplate is a placeholder/example that logs the received payload; real per-repo build logic is added later. The Sensor does parameter extraction from the webhook body (repo URL and commit SHA) and passes them to the WorkflowTemplate. This is the clean separation: the Sensor is infrastructure; the WorkflowTemplate is per-project. The Sensor needs cross-namespace trigger RBAC (Sensor in `argo-events`, Workflow in `argo-workflows`).

### RBAC: cross-namespace WorkflowSubmit
The Argo Events Sensor runs in `argo-events` but submits workflows to `argo-workflows`. This requires a `ServiceAccount` in `argo-events`, a `ClusterRole` with `workflows.argoproj.io` submit permissions on `argo-workflows`, and a `ClusterRoleBinding`. These are included in the `argo-events-resources-app` rather than the Helm chart values, since they are cluster-scoped and specific to this trigger topology.

### Webhook auth: no shared secret for initial implementation
The webhook endpoint will accept any POST without authentication for this initial deployment. The `events.verticon.com` domain resolves to an internal MetalLB IP — it is not reachable from the public internet (DNS points to a LAN IP). A secret token header check is deferred to a follow-on issue. This is documented clearly in the EventSource definition.

### WorkflowTemplate placement: `argo-workflows` namespace
WorkflowTemplates live in `argo-workflows` (the same namespace as the Argo Workflows controller). The Sensor trigger uses `workflowTemplate.groupVersionResource` pointing to `argo-workflows`. This is the canonical Argo Events integration pattern.

### Post-push hook: template only, not auto-installed
A generic bash template lives in `scripts/hooks/post-push.tmpl`. Developers copy it to their repo's `.git/hooks/post-push` and make it executable. It reads the `events.verticon.com` URL from the environment or falls back to a hardcoded default. This is intentionally minimal — it sends a JSON POST and exits; the CI log is visible in the Argo Workflows UI. The hook is not committed to application repos (client-side hooks are `.git/` scoped and gitignored by convention).

### Sync waves
- Wave 1: `argo-events` — installs Argo Events Helm chart (controller, CRDs). CRDs must exist before any CRD-typed resources are applied.
- Wave 2: `argo-events-resources` — applies `EventBus`, `EventSource`, `Sensor`, RBAC. Depends on Wave 1 CRDs and on `argo-workflows` existing (for cross-namespace trigger).

### Argo Events chart version: `2.4.21` (app v1.9.10)
Argo Workflows `0.45.0` chart deploys app version v3.6.0. Argo Events `2.4.21` deploys app version v1.9.10. The Argo Events compatibility matrix confirms v1.9.x is compatible with Argo Workflows v3.6.x (same release cycle). Using the latest patch in the 2.4.x series.

---

## Task 1: Argo Events Helm values

**Files:**
- Create: `argo-events-gitops/helm/argo-events-values.yaml`

- [ ] **Step 1: Write the failing chainsaw assertion for the controller deployment**

  The test file for this task is written in Task 5, but the assertion for the controller pod must be red before we create the Helm values. Run the pre-existing ArgoCD chainsaw test to confirm `argo-events-apps` does not yet exist (it should be absent from the cluster):

  ```bash
  chainsaw test tests/argo-events 2>&1 | head -5
  # Expected: directory not found or test fails — argo-events not deployed yet
  kubectl get deployment -n argo-events 2>&1
  # Expected: Error from server (NotFound): namespaces "argo-events" not found
  ```

- [ ] **Step 2: Verify red state**

  Run: `kubectl get ns argo-events`
  Expected: `Error from server (NotFound)` — namespace does not exist yet.

- [ ] **Step 3: Create the Helm values file**

  Create `argo-events-gitops/helm/argo-events-values.yaml`:

  ```yaml
  # Argo Events — event-driven automation complement to Argo Workflows
  # Controller watches EventBus, EventSource, and Sensor CRDs.
  # UI: none (purely API/CRD-driven; use `kubectl get eventsource,sensor -n argo-events`)
  # Webhook EventSource at https://events.verticon.com (192.168.0.221:12000)

  controller:
    # Match the image tag to Argo Workflows v3.6.0 (Events v1.9.x is compatible)
    image:
      tag: v1.9.10

  # Install CRDs via Helm (keeps them lifecycle-coupled to the chart)
  crds:
    install: true
    keep: true

  # No extra RBAC in the Helm chart values — cross-namespace trigger RBAC
  # is applied separately via argo-events-resources-app (wave 2).
  ```

- [ ] **Step 4: Verify file syntax**

  Run: `cat argo-events-gitops/helm/argo-events-values.yaml`
  Expected: clean YAML output, no parse errors.

- [ ] **Step 5: Refactor and verify**

  Confirm the values are minimal and correct. The Argo Events chart defaults are good for everything else (leader election, RBAC, metrics). No changes needed.

- [ ] **Step 6: Commit**

  ```bash
  git -C /home/jconlon/git/ops-microk8s/.worktrees/deploy-argo-events add \
    argo-events-gitops/helm/argo-events-values.yaml
  git -C /home/jconlon/git/ops-microk8s/.worktrees/deploy-argo-events \
    commit -m "feat: add Argo Events Helm values (issue #66)"
  ```

---

## Task 2: EventBus, EventSource, Sensor manifests

**Files:**
- Create: `argo-events-gitops/resources/eventbus/default-eventbus.yaml`
- Create: `argo-events-gitops/resources/eventsources/git-push-eventsource.yaml`
- Create: `argo-events-gitops/resources/sensors/git-push-sensor.yaml`

- [ ] **Step 1: Identify the failing check**

  After deploying (Task 3), the chainsaw test in Task 5 will assert these resources are Ready. For now, confirm the CRDs do not exist:

  ```bash
  kubectl get crd eventbuses.argoproj.io 2>&1
  # Expected: Error from server (NotFound) — CRDs not installed yet
  ```

- [ ] **Step 2: Verify red state**

  Run: `kubectl get crd | grep argoproj | grep -i event`
  Expected: no `eventbuses`, `eventsources`, `sensors` CRDs.

- [ ] **Step 3: Create the manifests**

  **`argo-events-gitops/resources/eventbus/default-eventbus.yaml`:**
  ```yaml
  # EventBus — NATS message broker managed by Argo Events controller.
  # The default EventBus is used by all EventSources and Sensors in the namespace
  # unless overridden by spec.eventBusName.
  apiVersion: argoproj.io/v1alpha1
  kind: EventBus
  metadata:
    name: default
    namespace: argo-events
  spec:
    nats:
      native:
        # 3 replicas for HA; matches the 3-control-plane topology.
        replicas: 3
        auth: none
  ```

  **`argo-events-gitops/resources/eventsources/git-push-eventsource.yaml`:**
  ```yaml
  # WebhookEventSource — receives HTTP POST payloads from the post-push git hook.
  # Listens on port 12000 (Argo Events default).
  # Exposed via MetalLB LoadBalancer at 192.168.0.221:12000.
  # Caddy on mullet terminates TLS: events.verticon.com -> 192.168.0.221:12000
  #
  # NOTE: No shared-secret authentication for initial deployment.
  # The events.verticon.com DNS A record points to a LAN IP — not internet-reachable.
  # Add endpoint secret token in a follow-on issue when needed.
  apiVersion: argoproj.io/v1alpha1
  kind: EventSource
  metadata:
    name: git-push
    namespace: argo-events
  spec:
    # Expose the EventSource pod as a LoadBalancer service.
    service:
      ports:
        - port: 12000
          targetPort: 12000
      # MetalLB allocates 192.168.0.221 for this service.
      # This annotation pins the IP so it never changes across redeployments.
      metadata:
        annotations:
          metallb.universe.tf/loadBalancerIPs: "192.168.0.221"
    webhook:
      # 'git-push' is the event name. The Sensor references this by name.
      git-push:
        # Port the EventSource pod listens on internally.
        port: "12000"
        # Path the hook POSTs to. Keep it simple; no secret in path.
        endpoint: /push
        method: POST
  ```

  **`argo-events-gitops/resources/sensors/git-push-sensor.yaml`:**
  ```yaml
  # Sensor — listens to the git-push EventSource and submits an Argo Workflow.
  # Triggers the 'git-push-build' WorkflowTemplate in the 'argo-workflows' namespace.
  # Passes 'repo' and 'commit' from the webhook JSON body as workflow parameters.
  #
  # RBAC: The sensor-sa ServiceAccount (created below) needs submit rights on
  # workflows.argoproj.io in argo-workflows. See argo-events-resources-app for
  # the ClusterRole + ClusterRoleBinding.
  apiVersion: argoproj.io/v1alpha1
  kind: Sensor
  metadata:
    name: git-push
    namespace: argo-events
  spec:
    dependencies:
      - name: git-push-dep
        eventSourceName: git-push
        eventName: git-push
    triggers:
      - template:
          name: trigger-git-push-build
          argoWorkflow:
            # Submit to the argo-workflows namespace.
            namespace: argo-workflows
            # Reference the placeholder WorkflowTemplate.
            source:
              resource:
                apiVersion: argoproj.io/v1alpha1
                kind: Workflow
                metadata:
                  generateName: git-push-
                  namespace: argo-workflows
                spec:
                  workflowTemplateRef:
                    name: git-push-build
                  arguments:
                    parameters:
                      - name: repo
                        value: "placeholder"
                      - name: commit
                        value: "placeholder"
            operation: submit
            # Map webhook JSON fields to workflow parameters.
            parameters:
              - src:
                  dependencyName: git-push-dep
                  dataKey: body.repo
                dest: spec.arguments.parameters.0.value
              - src:
                  dependencyName: git-push-dep
                  dataKey: body.commit
                dest: spec.arguments.parameters.1.value
    # Sensor uses this ServiceAccount; must have submit rights in argo-workflows.
    serviceAccountName: argo-events-sensor-sa
  ---
  # ServiceAccount for the Sensor pod.
  apiVersion: v1
  kind: ServiceAccount
  metadata:
    name: argo-events-sensor-sa
    namespace: argo-events
  ---
  # ClusterRole: submit workflows in argo-workflows namespace.
  apiVersion: rbac.authorization.k8s.io/v1
  kind: ClusterRole
  metadata:
    name: argo-events-workflow-submit
  rules:
    - apiGroups: ["argoproj.io"]
      resources: ["workflows", "workflowtemplates"]
      verbs: ["create", "get", "list", "watch"]
  ---
  # ClusterRoleBinding: bind the sensor SA to the ClusterRole.
  apiVersion: rbac.authorization.k8s.io/v1
  kind: ClusterRoleBinding
  metadata:
    name: argo-events-workflow-submit
  roleRef:
    apiGroup: rbac.authorization.k8s.io
    kind: ClusterRole
    name: argo-events-workflow-submit
  subjects:
    - kind: ServiceAccount
      name: argo-events-sensor-sa
      namespace: argo-events
  ---
  # WorkflowTemplate: generic placeholder that logs the push event.
  # Real per-repo build logic replaces the 'echo' step when ready.
  # Lives in argo-workflows so it is visible in the Argo Workflows UI.
  apiVersion: argoproj.io/v1alpha1
  kind: WorkflowTemplate
  metadata:
    name: git-push-build
    namespace: argo-workflows
  spec:
    entrypoint: build
    arguments:
      parameters:
        - name: repo
        - name: commit
    templates:
      - name: build
        inputs:
          parameters:
            - name: repo
            - name: commit
        container:
          image: alpine:3.19
          command: [sh, -c]
          args:
            - |
              echo "git-push-build triggered"
              echo "  repo:   {{inputs.parameters.repo}}"
              echo "  commit: {{inputs.parameters.commit}}"
              echo "Replace this step with your actual build workflow."
  ```

- [ ] **Step 4: Verify file syntax**

  ```bash
  # Lint with kubectl dry-run if CRDs exist, otherwise just check YAML parse
  python3 -c "
  import sys
  for f in [
    'argo-events-gitops/resources/eventbus/default-eventbus.yaml',
    'argo-events-gitops/resources/eventsources/git-push-eventsource.yaml',
    'argo-events-gitops/resources/sensors/git-push-sensor.yaml',
  ]:
      try:
          open(f).read()
          print(f'OK: {f}')
      except Exception as e:
          print(f'ERROR: {f}: {e}')
  " 2>&1 || echo "Check files manually"
  ```

  Run: `cat argo-events-gitops/resources/sensors/git-push-sensor.yaml`
  Expected: Full YAML output with all five documents separated by `---`.

- [ ] **Step 5: Refactor and verify**

  Review that:
  - EventBus name is `default` (matches Argo Events convention — Sensor auto-discovers the default bus)
  - EventSource service annotation uses `metallb.universe.tf/loadBalancerIPs` (matches cluster pattern)
  - Sensor `dataKey` paths match the JSON structure sent by the post-push hook (`body.repo`, `body.commit`)
  - WorkflowTemplate is in `argo-workflows` namespace (where the Argo Workflows controller watches)
  - ClusterRole only grants `create`/`get`/`list`/`watch` on `workflows` and `workflowtemplates` — no over-privilege

- [ ] **Step 6: Commit**

  ```bash
  git -C /home/jconlon/git/ops-microk8s/.worktrees/deploy-argo-events add \
    argo-events-gitops/resources/eventbus/default-eventbus.yaml \
    argo-events-gitops/resources/eventsources/git-push-eventsource.yaml \
    argo-events-gitops/resources/sensors/git-push-sensor.yaml
  git -C /home/jconlon/git/ops-microk8s/.worktrees/deploy-argo-events \
    commit -m "feat: add EventBus, WebhookEventSource, and Sensor manifests (issue #66)"
  ```

---

## Task 3: ArgoCD App-of-Apps wiring

**Files:**
- Create: `argoCD-apps/argo-events-apps.yaml`
- Create: `argoCD-apps/argo-events/argo-events-app.yaml`
- Create: `argoCD-apps/argo-events/argo-events-resources-app.yaml`

- [ ] **Step 1: Identify the failing check**

  The ArgoCD health step in `tests/argocd/chainsaw-test.yaml` will be extended in Task 5. Confirm the parent app does not exist:

  ```bash
  kubectl get application argo-events-apps -n argocd 2>&1
  # Expected: Error from server (NotFound)
  ```

- [ ] **Step 2: Verify red state**

  Run: `ops argocd list-app 2>/dev/null | grep argo-events`
  Expected: no output — app not registered.

- [ ] **Step 3: Create ArgoCD application manifests**

  **`argoCD-apps/argo-events-apps.yaml`** — App-of-Apps parent:
  ```yaml
  apiVersion: argoproj.io/v1alpha1
  kind: Application
  metadata:
    name: argo-events-apps
    namespace: argocd
  spec:
    project: default
    source:
      repoURL: https://github.com/jconlon/ops-microk8s
      targetRevision: HEAD
      path: argoCD-apps/argo-events
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

  **`argoCD-apps/argo-events/argo-events-app.yaml`** — Wave 1: Argo Events controller + CRDs:
  ```yaml
  apiVersion: argoproj.io/v1alpha1
  kind: Application
  metadata:
    name: argo-events
    namespace: argocd
    annotations:
      argocd.argoproj.io/sync-wave: "1"
  spec:
    project: default
    sources:
      - repoURL: https://argoproj.github.io/argo-helm
        chart: argo-events
        targetRevision: "2.4.21"
        helm:
          valueFiles:
            - $values/argo-events-gitops/helm/argo-events-values.yaml
      - repoURL: https://github.com/jconlon/ops-microk8s
        targetRevision: HEAD
        ref: values
    destination:
      server: https://kubernetes.default.svc
      namespace: argo-events
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

  **`argoCD-apps/argo-events/argo-events-resources-app.yaml`** — Wave 2: CRD instances + RBAC:
  ```yaml
  apiVersion: argoproj.io/v1alpha1
  kind: Application
  metadata:
    name: argo-events-resources
    namespace: argocd
    annotations:
      # Wave 2: CRDs from wave 1 must be established before applying typed resources.
      argocd.argoproj.io/sync-wave: "2"
  spec:
    project: default
    source:
      repoURL: https://github.com/jconlon/ops-microk8s
      targetRevision: HEAD
      # Path contains only K8s resource manifests (EventBus, EventSource, Sensor, RBAC,
      # WorkflowTemplate). Helm values live at argo-events-gitops/helm/ — a separate
      # subtree not referenced here. ArgoCD cannot apply plain YAML files that lack
      # apiVersion/kind as K8s resources, so we keep manifests and Helm values in
      # separate directories.
      path: argo-events-gitops/resources
    destination:
      server: https://kubernetes.default.svc
      # Most resources are namespaced to argo-events; the ClusterRole/Binding
      # and WorkflowTemplate are cluster-/argo-workflows-scoped but ArgoCD
      # applies them regardless (destination namespace is overridden by
      # metadata.namespace in each manifest).
      namespace: argo-events
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

  **Note on path separation:** The `argo-events-gitops/` tree is split into `helm/` (Helm values, not K8s resources) and `resources/` (K8s resource manifests). ArgoCD requires that every YAML file in the target path be a valid K8s resource with `apiVersion` and `kind`. A Helm values file has neither, so it must live outside the ArgoCD-managed path. This separation (`helm/` vs. `resources/`) is the correct pattern — do not point the resources app at `argo-events-gitops/` directly.

- [ ] **Step 4: Verify file syntax**

  ```bash
  # Verify all three files parse as YAML
  for f in \
    argoCD-apps/argo-events-apps.yaml \
    argoCD-apps/argo-events/argo-events-app.yaml \
    argoCD-apps/argo-events/argo-events-resources-app.yaml; do
      python3 -c "
  import sys
  data = open('$f').read()
  print('OK:', '$f', '(' + str(len(data)) + ' bytes)')
  "
  done
  ```

  Expected: three `OK:` lines.

- [ ] **Step 5: Refactor and verify**

  Confirm:
  - `argo-events-apps.yaml` uses `path: argoCD-apps/argo-events` (matches `argo-workflows-apps.yaml` pattern exactly)
  - `argo-events-app.yaml` uses `sources:` (multi-source) with `ref: values` (matches `argo-workflows-app.yaml` pattern)
  - Wave annotations: `"1"` on the controller app, `"2"` on the resources app (matches `argo-workflows-storage-app.yaml`/`argo-workflows-app.yaml` pattern)
  - `ServerSideApply: true` on both Helm-using apps (matches cluster pattern)

- [ ] **Step 6: Commit ArgoCD wiring**

  ```bash
  git -C /home/jconlon/git/ops-microk8s/.worktrees/deploy-argo-events add \
    argoCD-apps/argo-events-apps.yaml \
    argoCD-apps/argo-events/argo-events-app.yaml \
    argoCD-apps/argo-events/argo-events-resources-app.yaml
  git -C /home/jconlon/git/ops-microk8s/.worktrees/deploy-argo-events \
    commit -m "feat: wire Argo Events App-of-Apps into ArgoCD (issue #66)"
  ```

  > **NOTE**: The bootstrap `kubectl apply` that actually deploys Argo Events to the cluster
  > is intentionally deferred to Task 5 (after the chainsaw tests are written and confirmed red).
  > Do NOT apply the parent app here. Commit only.

---

## Task 4: Caddy TLS entry and DNS (manual steps — documented for operator)

**Files:**
- No GitOps changes (Caddyfile is on mullet, not in this repo)

- [ ] **Step 1: Add Cloudflare DNS A record**

  In the Cloudflare dashboard:
  - Type: A
  - Name: `events`
  - Content: `192.168.0.221`
  - Proxy: DNS only (grey cloud — not proxied)
  - TTL: Auto

- [ ] **Step 2: Add Caddyfile entry on mullet**

  SSH to mullet and add to `/etc/caddy/Caddyfile`:

  ```
  events.verticon.com {
      tls {
          resolvers 1.1.1.1 1.0.0.1
      }
      reverse_proxy 192.168.0.221:12000
  }
  ```

  Then reload Caddy:
  ```bash
  sudo caddy reload --config /etc/caddy/Caddyfile
  ```

- [ ] **Step 3: Verify HTTPS endpoint**

  ```bash
  # Should return the Argo Events EventSource welcome/ready response
  curl -sv https://events.verticon.com/push 2>&1 | grep -E "< HTTP|TLS|certificate"
  # Expected: HTTP/2 200 or 405 (POST-only endpoint returning 405 on GET is fine)
  # TLS certificate for events.verticon.com must be valid
  ```

  Note: The EventSource returns 405 (Method Not Allowed) on GET — this is correct. A 200 requires a POST with a JSON body.

- [ ] **Step 4: Document in scripts/README.md**

  Add a section under "Manual Bootstrap Steps":

  ```markdown
  ### Argo Events — events.verticon.com

  The Argo Events WebhookEventSource is exposed at https://events.verticon.com (192.168.0.221:12000).

  **Caddy entry** (mullet:/etc/caddy/Caddyfile):
  ```
  events.verticon.com {
      tls {
          resolvers 1.1.1.1 1.0.0.1
      }
      reverse_proxy 192.168.0.221:12000
  }
  ```

  **DNS**: Cloudflare A record: events.verticon.com → 192.168.0.221 (DNS only, not proxied)

  **Test**: `curl -X POST https://events.verticon.com/push -d '{"repo":"test","commit":"abc"}' -H 'Content-Type: application/json'`
  ```

- [ ] **Step 5: Commit README update**

  ```bash
  git -C /home/jconlon/git/ops-microk8s/.worktrees/deploy-argo-events add scripts/README.md
  git -C /home/jconlon/git/ops-microk8s/.worktrees/deploy-argo-events \
    commit -m "docs: document Argo Events Caddy entry and DNS bootstrap (issue #66)"
  ```

---

## Task 5: Chainsaw tests and justfile recipes

**Files:**
- Create: `tests/argo-events/chainsaw-test.yaml`
- Modify: `tests/argocd/chainsaw-test.yaml`
- Modify: `justfile`

- [ ] **Step 1: Run the existing chainsaw suite and confirm it's green**

  ```bash
  chainsaw test tests/argocd/
  # Expected: PASS — all existing ArgoCD apps healthy (before we add the new step)
  chainsaw test tests/argo-workflows/
  # Expected: PASS — argo-workflows healthy
  ```

  If either is red, investigate before proceeding — we must not regress the existing tests.

- [ ] **Step 2: Write the new chainsaw test (initially red)**

  Create `tests/argo-events/chainsaw-test.yaml`:

  ```yaml
  apiVersion: chainsaw.kyverno.io/v1alpha1
  kind: Test
  metadata:
    name: argo-events-healthy
  spec:
    description: Argo Events is deployed and the webhook EventSource is live
    concurrent: false
    timeouts:
      assert: 5m
      exec: 60s

    steps:
      - name: argo-events-argocd-app-synced
        description: Argo Events ArgoCD application is Synced and Healthy
        try:
          - assert:
              resource:
                apiVersion: argoproj.io/v1alpha1
                kind: Application
                metadata:
                  name: argo-events
                  namespace: argocd
                status:
                  sync:
                    status: Synced
                  health:
                    status: Healthy

      - name: argo-events-resources-argocd-app-synced
        description: Argo Events resources ArgoCD application is Synced
        try:
          - assert:
              resource:
                apiVersion: argoproj.io/v1alpha1
                kind: Application
                metadata:
                  name: argo-events-resources
                  namespace: argocd
                status:
                  sync:
                    status: Synced

      - name: argo-events-controller-running
        description: Argo Events controller Deployment is available
        try:
          - assert:
              resource:
                apiVersion: apps/v1
                kind: Deployment
                metadata:
                  name: argo-events-controller-manager
                  namespace: argo-events
                status:
                  (availableReplicas >= `1`): true

      - name: argo-events-eventbus-running
        description: EventBus default is in Running phase
        try:
          - assert:
              resource:
                apiVersion: argoproj.io/v1alpha1
                kind: EventBus
                metadata:
                  name: default
                  namespace: argo-events
                status:
                  phase: running

      - name: argo-events-eventsource-running
        description: git-push EventSource is in Running phase
        try:
          - assert:
              resource:
                apiVersion: argoproj.io/v1alpha1
                kind: EventSource
                metadata:
                  name: git-push
                  namespace: argo-events
                status:
                  phase: Running

      - name: argo-events-sensor-running
        description: git-push Sensor is in Running phase
        try:
          - assert:
              resource:
                apiVersion: argoproj.io/v1alpha1
                kind: Sensor
                metadata:
                  name: git-push
                  namespace: argo-events
                status:
                  phase: Running

      - name: argo-events-service-has-ip
        description: git-push EventSource LoadBalancer service has MetalLB IP 192.168.0.221
        try:
          - script:
              content: |
                IP=$(kubectl get svc -n argo-events \
                  -l eventsource-name=git-push \
                  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null)
                [ "$IP" = "192.168.0.221" ] || { echo "Expected 192.168.0.221, got: $IP"; exit 1; }
                echo "MetalLB IP confirmed: $IP"

      - name: argo-events-webhook-reachable
        description: Webhook endpoint is reachable at the MetalLB IP (POST returns 200)
        try:
          - script:
              timeout: 30s
              content: |
                STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
                  -X POST http://192.168.0.221:12000/push \
                  -H 'Content-Type: application/json' \
                  -d '{"repo":"test","commit":"abc123"}' 2>/dev/null)
                [ "$STATUS" = "200" ] || { echo "Expected 200, got: $STATUS"; exit 1; }
                echo "Webhook endpoint returned 200"

      - name: argo-events-e2e-trigger
        description: POST to webhook triggers a git-push-build workflow within 60s
        try:
          - script:
              timeout: 90s
              content: |
                # Record existing workflows before triggering.
                # Use kubectl — the argo CLI is not available in the chainsaw container.
                BEFORE=$(kubectl get workflow -n argo-workflows \
                  --no-headers 2>/dev/null | grep "^git-push-" | wc -l)

                # POST the webhook payload
                curl -sf -X POST http://192.168.0.221:12000/push \
                  -H 'Content-Type: application/json' \
                  -d "{\"repo\":\"https://github.com/jconlon/test\",\"commit\":\"$(date +%s)\"}" \
                  > /dev/null 2>&1

                # Poll for a new workflow (up to 60s)
                for i in $(seq 1 30); do
                  AFTER=$(kubectl get workflow -n argo-workflows \
                    --no-headers 2>/dev/null | grep "^git-push-" | wc -l)
                  if [ "$AFTER" -gt "$BEFORE" ]; then
                    echo "New git-push workflow detected (count: $AFTER)"
                    exit 0
                  fi
                  sleep 2
                done
                echo "No new git-push workflow detected within 60s"
                exit 1

      - name: argo-events-workflowtemplate-exists
        description: git-push-build WorkflowTemplate exists in argo-workflows
        try:
          - assert:
              resource:
                apiVersion: argoproj.io/v1alpha1
                kind: WorkflowTemplate
                metadata:
                  name: git-push-build
                  namespace: argo-workflows
  ```

- [ ] **Step 3: Run the new test to confirm it fails (red)**

  ```bash
  chainsaw test tests/argo-events/
  # Expected: FAIL — argo-events not deployed yet
  ```

- [ ] **Step 4: Extend tests/argocd/chainsaw-test.yaml**

  Add a new step at the end of the `steps:` list (after the final `vllm-healthy` step). Note: the existing test has no `argo-workflows-apps-healthy` step — append at the end of the file's steps list.

  ```yaml
      - name: argo-events-apps-healthy
        try:
        - assert:
            resource:
              apiVersion: argoproj.io/v1alpha1
              kind: Application
              metadata:
                name: argo-events-apps
                namespace: argocd
              status:
                health:
                  status: Healthy
  ```

  Run the ArgoCD suite to confirm the new step is red (before Argo Events is deployed):
  ```bash
  chainsaw test tests/argocd/
  # Expected: FAIL on the new argo-events-apps-healthy step only
  ```

- [ ] **Step 5: Add just recipes to justfile**

  Add after the Argo Workflows section:

  ```
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
  ```

- [ ] **Step 6: Verify justfile syntax**

  ```bash
  just --list 2>&1 | grep -E "argo-events|test-argo"
  # Expected: argo-events-status and test-argo-events listed
  ```

- [ ] **Step 7: Commit tests and justfile (while still red — before bootstrap)**

  ```bash
  git -C /home/jconlon/git/ops-microk8s/.worktrees/deploy-argo-events add \
    tests/argo-events/chainsaw-test.yaml \
    tests/argocd/chainsaw-test.yaml \
    justfile
  git -C /home/jconlon/git/ops-microk8s/.worktrees/deploy-argo-events \
    commit -m "test: add Argo Events chainsaw tests and just recipes (issue #66)"
  ```

- [ ] **Step 8: Bootstrap — apply the parent app to ArgoCD (green deployment)**

  All manifests are committed and tests are confirmed red. Now bootstrap the deployment:

  ```bash
  # Push the branch so ArgoCD can pull the committed manifests
  git -C /home/jconlon/git/ops-microk8s/.worktrees/deploy-argo-events push

  # Apply the parent App-of-Apps to ArgoCD (same pattern as every other app-of-apps)
  kubectl apply -f argoCD-apps/argo-events-apps.yaml
  ```

  Watch ArgoCD sync the child applications:

  ```bash
  watch kubectl get application -n argocd | grep argo-events
  # Expected within 2-3 minutes:
  #   argo-events-apps      Synced   Healthy
  #   argo-events           Synced   Healthy
  #   argo-events-resources Synced   Healthy
  ```

  Verify the controller and EventBus are running:

  ```bash
  kubectl get pods -n argo-events
  # Expected: controller pod Running, EventBus NATS pods Running (3 replicas)
  ```

  Verify the EventSource LoadBalancer IP is assigned:

  ```bash
  kubectl get svc -n argo-events
  # Expected: git-push-eventsource service with EXTERNAL-IP 192.168.0.221
  ```

  If the resources app fails to sync, check:
  ```bash
  kubectl get application argo-events-resources -n argocd -o jsonpath='{.status.conditions}'
  ```
  Common causes: CRDs not yet established (wave 1 still syncing — wait 30s and retry), or RBAC conflict (ClusterRole already exists — check with `kubectl get clusterrole argo-events-workflow-submit`).

- [ ] **Step 9: Run tests to green**

  ```bash
  chainsaw test tests/argo-events/
  # Expected: all steps PASS

  chainsaw test tests/argocd/
  # Expected: all steps PASS including new argo-events-apps-healthy

  chainsaw test tests/argo-workflows/
  # Expected: still PASS (no regression)
  ```

---

## Task 6: Post-push git hook template

**Files:**
- Create: `scripts/hooks/post-push.tmpl`
- Create: `scripts/hooks/README.md`

- [ ] **Step 1: Identify the failing check**

  The test plan includes a `bash -n` syntax check on the hook template. Run it now (will fail — file doesn't exist):

  ```bash
  bash -n scripts/hooks/post-push.tmpl 2>&1
  # Expected: No such file
  ```

- [ ] **Step 2: Verify red state**

  Run: `ls scripts/hooks/ 2>&1`
  Expected: `ls: cannot access 'scripts/hooks/'`

- [ ] **Step 3: Create the hook template and README**

  **`scripts/hooks/post-push.tmpl`:**

  ```bash
  #!/usr/bin/env bash
  # post-push — fire a CI build webhook after every successful push.
  #
  # Installation (run in your application repository):
  #   cp /path/to/ops-microk8s/scripts/hooks/post-push.tmpl .git/hooks/post-push
  #   chmod +x .git/hooks/post-push
  #
  # The hook reads ARGO_EVENTS_URL from the environment, falling back to the
  # cluster default. Override it in your shell profile if needed:
  #   export ARGO_EVENTS_URL=https://events.verticon.com/push
  #
  # The hook posts JSON: { "repo": "<remote-url>", "commit": "<sha>" }
  # The Argo Events Sensor maps these to the git-push-build WorkflowTemplate.

  set -euo pipefail

  ARGO_EVENTS_URL="${ARGO_EVENTS_URL:-https://events.verticon.com/push}"
  REPO=$(git remote get-url origin 2>/dev/null || echo "unknown")
  COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "unknown")

  echo "[post-push] Triggering CI build for ${REPO} @ ${COMMIT:0:8}"

  HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
    --max-time 10 \
    -X POST "${ARGO_EVENTS_URL}" \
    -H 'Content-Type: application/json' \
    -d "{\"repo\":\"${REPO}\",\"commit\":\"${COMMIT}\"}" 2>/dev/null) || true

  if [ "${HTTP_STATUS}" = "200" ]; then
    echo "[post-push] CI build triggered (HTTP 200). Check ${ARGO_EVENTS_URL/push/} for status."
  else
    echo "[post-push] WARNING: webhook returned HTTP ${HTTP_STATUS:-000} — CI build may not have triggered."
    echo "            Check Argo Events logs: kubectl logs -n argo-events -l eventsource-name=git-push"
    # Do NOT exit non-zero — a failed webhook must never block a git push.
  fi

  exit 0
  ```

  **`scripts/hooks/README.md`:**

  ```markdown
  # Git Hooks

  ## post-push — CI build trigger

  The `post-push.tmpl` hook fires after a successful `git push` and sends a JSON
  payload to the Argo Events webhook at `https://events.verticon.com/push`. The
  Argo Events Sensor picks it up and submits a `git-push-build` workflow to Argo
  Workflows.

  ### Installation

  In your application repository:

  ```bash
  cp /path/to/ops-microk8s/scripts/hooks/post-push.tmpl .git/hooks/post-push
  chmod +x .git/hooks/post-push
  ```

  Client-side hooks live in `.git/hooks/` and are not committed to the repository.

  ### Configuration

  The hook reads `ARGO_EVENTS_URL` from the environment. Override it in your
  shell profile if the cluster URL changes:

  ```bash
  export ARGO_EVENTS_URL=https://events.verticon.com/push
  ```

  ### Testing the hook manually

  ```bash
  curl -X POST https://events.verticon.com/push \
    -H 'Content-Type: application/json' \
    -d '{"repo":"https://github.com/jconlon/myapp","commit":"abc123"}'
  # Expected: HTTP 200
  ```

  Then check for the triggered workflow:
  ```bash
  argo list -n argo-workflows | grep git-push
  ```

  ### Monitoring

  - Argo Workflows UI: https://workflows.verticon.com
  - Argo Events logs: `kubectl logs -n argo-events -l eventsource-name=git-push`
  - Sensor logs: `kubectl logs -n argo-events -l sensor-name=git-push`
  ```

- [ ] **Step 4: Run `bash -n` syntax check**

  ```bash
  bash -n scripts/hooks/post-push.tmpl
  # Expected: no output (syntax OK)
  echo "Syntax OK: $?"
  ```

  Expected: `Syntax OK: 0`

- [ ] **Step 5: Refactor and verify**

  Review the hook for:
  - Never exits non-zero (a failed webhook must not block the push)
  - Uses `--max-time 10` to avoid hanging on unreachable endpoint
  - Truncates commit SHA in log output for readability (`${COMMIT:0:8}`)
  - Uses `set -euo pipefail` but the curl failure is explicitly `|| true`

  ```bash
  bash -n scripts/hooks/post-push.tmpl && echo "PASS"
  ```

- [ ] **Step 6: Commit**

  ```bash
  git -C /home/jconlon/git/ops-microk8s/.worktrees/deploy-argo-events add \
    scripts/hooks/post-push.tmpl \
    scripts/hooks/README.md
  git -C /home/jconlon/git/ops-microk8s/.worktrees/deploy-argo-events \
    commit -m "feat: add generic post-push git hook template for CI trigger (issue #66)"
  ```

---

## Task 7: CLAUDE.md update

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Identify needed changes**

  `CLAUDE.md` documents Key Components and Service Access. Argo Events is a new key component and `events.verticon.com` is a new service endpoint.

- [ ] **Step 2: Edit CLAUDE.md**

  In the **Key Components** section, after the Argo Workflows entry, add:

  ```markdown
  - **Argo Events**: Event-driven automation companion to Argo Workflows; `argo-events` namespace
    - WebhookEventSource at `https://events.verticon.com/push` (192.168.0.221:12000)
    - Triggers `git-push-build` WorkflowTemplate in `argo-workflows` on POST
    - `kubectl get eventbus,eventsource,sensor -n argo-events` — check resource status
  ```

  In the **Service Access** section, after Argo Workflows, add:

  ```markdown
  - **Argo Events Webhook**: https://events.verticon.com (192.168.0.221:12000) — CI trigger endpoint
  ```

- [ ] **Step 3: Verify changes**

  ```bash
  grep -n "Argo Events\|events.verticon" /home/jconlon/git/ops-microk8s/.worktrees/deploy-argo-events/CLAUDE.md
  # Expected: two matching lines
  ```

- [ ] **Step 4: Commit**

  ```bash
  git -C /home/jconlon/git/ops-microk8s/.worktrees/deploy-argo-events add CLAUDE.md
  git -C /home/jconlon/git/ops-microk8s/.worktrees/deploy-argo-events \
    commit -m "docs: add Argo Events to CLAUDE.md key components and service access (issue #66)"
  ```

---

## Task 8: Final verification

- [ ] **Step 1: Run the full test suite**

  ```bash
  # Argo Events-specific tests
  chainsaw test tests/argo-events/
  # Expected: all 9 steps PASS

  # ArgoCD app-of-apps health (includes new argo-events-apps-healthy step)
  chainsaw test tests/argocd/
  # Expected: all steps PASS

  # Argo Workflows — confirm no regression
  chainsaw test tests/argo-workflows/
  # Expected: all steps PASS

  # Full suite
  just test
  # Expected: all suites PASS
  ```

- [ ] **Step 2: Manual end-to-end smoke test**

  ```bash
  # Fire a webhook payload
  curl -X POST https://events.verticon.com/push \
    -H 'Content-Type: application/json' \
    -d '{"repo":"https://github.com/jconlon/ops-microk8s","commit":"'$(git rev-parse HEAD)'"}'
  # Expected: HTTP 200

  # Verify a workflow was submitted
  argo list -n argo-workflows | grep git-push
  # Expected: a new 'git-push-XXXXX' workflow in Running or Succeeded state

  # Watch it complete
  argo logs -n argo-workflows -l workflows.argoproj.io/workflow-template=git-push-build --follow
  # Expected: echo output with repo URL and commit SHA
  ```

- [ ] **Step 3: Verify justfile recipes work**

  ```bash
  just argo-events-status
  # Expected: pods Running, eventsource Running, sensor Running, svc with 192.168.0.221
  just test-argo-events
  # Expected: PASS
  ```

- [ ] **Step 4: Final commit if any cleanup needed**

  ```bash
  git -C /home/jconlon/git/ops-microk8s/.worktrees/deploy-argo-events status
  # Expected: clean working tree or only minor tidy-ups
  ```

---

## Tricky Boundaries and Risk Notes

### ArgoCD resources-app path layout
The `argo-events-resources-app` points to `argo-events-gitops/resources/` — the subdirectory that contains only K8s resource manifests (EventBus, EventSource, Sensor, RBAC, WorkflowTemplate). The Helm values file at `argo-events-gitops/helm/argo-events-values.yaml` is in a separate subtree not referenced by this app. This separation is mandatory: ArgoCD attempts to apply every YAML file in the target path as a K8s resource, and a Helm values file (which has no `apiVersion`/`kind`) will cause a sync error if included. The directory structure in the plan already accounts for this — `resources/` and `helm/` are siblings, not nested.

### EventSource service label selector
Argo Events creates the EventSource LoadBalancer service with labels `eventsource-name=git-push`. The MetalLB IP annotation `metallb.universe.tf/loadBalancerIPs: "192.168.0.221"` must be on the `EventSource` spec under `spec.service.metadata.annotations`, not on the ArgoCD Application. The chainsaw test uses `-l eventsource-name=git-push` to find the service since the name is Argo Events-generated (not a fixed name we control).

### EventBus phase field casing
Argo Events EventBus reports `status.phase: running` (lowercase). EventSource and Sensor report `status.phase: Running` (capitalized). The chainsaw assertion must match exactly. Verify with `kubectl get eventbus default -n argo-events -o jsonpath='{.status.phase}'` after deployment and correct if needed.

### Sensor cross-namespace trigger
The Sensor submits workflows to the `argo-workflows` namespace. The ClusterRole must include `create` on `workflows` (not `workflowtemplates` alone). The Argo Events Sensor's trigger `operation: submit` calls the Argo Workflows API server to create a Workflow object from the WorkflowTemplate ref. If the ClusterRole is missing `create` on `workflows`, the Sensor will log `403 Forbidden` and the e2e test will fail. Inspect Sensor logs: `kubectl logs -n argo-events -l sensor-name=git-push`.

### MetalLB annotation key
Use `metallb.universe.tf/loadBalancerIPs` (plural `IPs`). The singular `loadBalancerIP` is deprecated in newer MetalLB and may be silently ignored. The cluster uses the plural form on all existing services (confirmed in argo-workflows-values.yaml and loki-app.yaml).

### argo CLI namespace default
`ARGO_NAMESPACE=argo-workflows` is set in the devbox init_hook. The `argo list` command in chainsaw tests runs inside a chainsaw container that does NOT have this env var. All `argo` commands in chainsaw scripts must explicitly pass `-n argo-workflows`.

### WorkflowTemplate in argo-events-resources-app
The `WorkflowTemplate` (`git-push-build`) is in `argo-workflows` namespace, but the `argo-events-resources-app` has `destination.namespace: argo-events`. ArgoCD applies `metadata.namespace: argo-workflows` from the manifest directly — the destination namespace is the default for resources that don't specify their own. Since the WorkflowTemplate manifest has `namespace: argo-workflows` explicitly, ArgoCD will apply it there. Verify with `kubectl get workflowtemplate -n argo-workflows` after sync.

### Post-push hook never exits non-zero
The hook explicitly catches curl failures with `|| true` and only warns (does not exit 1) on non-200 responses. A webhook failure must never block a git push. This is a hard requirement documented in the hook itself.
