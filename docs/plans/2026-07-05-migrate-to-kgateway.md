# Migrate Cluster Ingress to Gateway API via kgateway Implementation Plan

> **For agentic workers:** Steps use checkbox (`- [ ]`) syntax for tracking. Follow this repo's App-of-Apps / chainsaw conventions exactly — see `argoCD-apps/harbor-apps.yaml` and `docs/plans/2026-04-27-deploy-argo-events.md` for the canonical pattern this plan reuses.

> **Correction (2026-07-06):** this plan originally specified HTTP-01 for ACME. That's wrong — `*.verticon.com` DNS records resolve publicly to private LAN IPs (confirmed via `dig @1.1.1.1`/`dig @8.8.8.8`), so Let's Encrypt's validators can never open a connection to any of these hostnames, no matter what IP they point to. Caddy already works around this via DNS-01 (`dns.providers.cloudflare` module, confirmed on mullet via `caddy list-modules`). All HTTP-01 references below have been corrected to DNS-01. See issue [#109](https://github.com/jconlon/ops-microk8s/issues/109) for the Cloudflare API token bootstrap this now depends on.

**Goal:** Replace the manually-managed Caddy reverse proxy on `mullet` with a GitOps-managed Gateway API implementation. Deploy **kgateway** (CNCF sandbox, Envoy-based Gateway API implementation, formerly Gloo Gateway) and **cert-manager** via ArgoCD, stand up a single shared `Gateway` behind one MetalLB IP with automated Let's Encrypt DNS-01 (Cloudflare) certificates, migrate one low-risk HTTP(S) service as a proof of concept, then migrate the rest of the cluster's HTTP(S) services onto `HTTPRoute` objects, and finally cut DNS over and decommission the Caddyfile. Issue: [#108](https://github.com/jconlon/ops-microk8s/issues/108).

**Architecture:** kgateway installs as two Helm charts — `kgateway-crds` (Gateway API + kgateway CRDs) and `kgateway` (controller + default `GatewayClass` named `kgateway`, confirmed auto-created by the chart) — in the `kgateway-system` namespace. cert-manager installs via its standard Jetstack Helm chart into `cert-manager`. A single cluster-wide `Gateway` resource (`kgateway-gitops/resources/gateway.yaml`) listens on 80/443 and gets one MetalLB IP, `192.168.0.224` — the port-80 listener is retained for HTTP→HTTPS redirects but is no longer part of the ACME flow. A `ClusterIssuer` uses DNS-01 via Cloudflare (matching what Caddy already does) to issue certs, independent of the Gateway entirely. Each migrated service gets its own `HTTPRoute` attached to that one `Gateway`, replacing its dedicated MetalLB IP + Caddyfile block. Everything follows the existing App-of-Apps pattern (parent `Application` → per-component child `Application`s, sync waves separating CRD/controller install from CRD-instance resources) exactly as `argo-events-apps`/`harbor-apps` do today.

**Tech Stack:**
- kgateway Helm charts `kgateway-crds` + `kgateway`, OCI registry `oci://cr.kgateway.dev/kgateway-dev/charts/...`
- Gateway API CRDs: `GatewayClass`, `Gateway`, `HTTPRoute` (installed separately — the upstream v1.6.0 standard-channel bundle, vendored into this repo; `kgateway-crds` only installs kgateway's own extension CRDs, confirmed via `helm template`)
- cert-manager Helm chart `cert-manager` at `https://charts.jetstack.io`
- cert-manager CRDs: `ClusterIssuer`, `Certificate` (installed by the chart, `installCRDs: true`)
- Cloudflare API token (DNS-01 solver), bootstrapped via `teller` — see issue #109
- MetalLB LoadBalancer IP `192.168.0.224` for the shared Gateway
- Chainsaw for e2e testing; `just` for status/test recipes

---

## File Structure

### New files

| Path | Purpose |
|---|---|
| `kgateway-gitops/helm/kgateway-values.yaml` | kgateway controller Helm values |
| `argoCD-apps/kgateway-apps.yaml` | App-of-Apps parent → `argoCD-apps/kgateway/` |
| `argoCD-apps/kgateway/kgateway-crds-app.yaml` | Wave 1 — Gateway API + kgateway CRDs |
| `argoCD-apps/kgateway/kgateway-app.yaml` | Wave 2 — kgateway controller |
| `argoCD-apps/kgateway/kgateway-resources-app.yaml` | Wave 3 — `Gateway` + `HTTPRoute`s |
| `kgateway-gitops/resources/gateway.yaml` | Shared `Gateway` (HTTP+HTTPS listeners, MetalLB `.224`) |
| `kgateway-gitops/resources/httproutes/pgadmin-httproute.yaml` | POC `HTTPRoute` for pgAdmin |
| `kgateway-gitops/resources/httproutes/<service>-httproute.yaml` | One per migrated service (Task 5, added incrementally) |
| `cert-manager-gitops/helm/cert-manager-values.yaml` | cert-manager Helm values |
| `argoCD-apps/cert-manager-apps.yaml` | App-of-Apps parent → `argoCD-apps/cert-manager/` |
| `argoCD-apps/cert-manager/cert-manager-app.yaml` | Wave 1 — cert-manager controller + CRDs |
| `argoCD-apps/cert-manager/cert-manager-resources-app.yaml` | Wave 2 — `ClusterIssuer` |
| `cert-manager-gitops/resources/cluster-issuer.yaml` | Let's Encrypt `ClusterIssuer`, DNS-01 via `dns01.cloudflare` |
| `cert-manager-gitops/resources/certificates/` | Per-hostname `Certificate` resources |
| `kgateway-gitops/crds/gateway-api-standard-install.yaml` | Vendored upstream Gateway API core CRDs (v1.6.0) |
| `argoCD-apps/kgateway/gateway-api-crds-app.yaml` | Wave 0 — installs the vendored CRDs above |
| `tests/kgateway/chainsaw-test.yaml` | kgateway + Gateway + HTTPRoute health/reachability tests |
| `tests/cert-manager/chainsaw-test.yaml` | cert-manager health + ClusterIssuer readiness tests |

### Modified files

| Path | Change |
|---|---|
| `justfile` | Add `kgateway-status`, `test-kgateway`, `cert-manager-status`, `test-cert-manager` recipes |
| `tests/argocd/chainsaw-test.yaml` | Add `kgateway-apps-healthy` and `cert-manager-apps-healthy` steps |
| `CLAUDE.md` | Add kgateway/cert-manager to Key Components and Service Access; update "Adding a New DNS Name" procedure (Task 6) |
| `README.md` | Same additions as CLAUDE.md, mirrored |
| `scripts/README.md` | Document the new `HTTPRoute`-per-service bootstrap procedure |
| `docs/networking.html` | Replace Caddy-centric instructions with Gateway/HTTPRoute + ClusterIssuer procedure (Task 6; HTML only per `docs/CLAUDE.md`) |

---

## Architectural Decisions

### ACME challenge type: DNS-01 via Cloudflare, not HTTP-01
Confirmed empirically while debugging a stuck `pgadmin-tls` Certificate during Task 4: `*.verticon.com` DNS records resolve **publicly** to private LAN IPs (`dig @1.1.1.1 pgadmin.verticon.com` and `dig @8.8.8.8 pgadmin.verticon.com` both return `192.168.0.101`, mullet's LAN IP — not a real public address). HTTP-01 requires Let's Encrypt to open an actual connection to whatever IP the domain currently resolves to; since that will always be a private LAN address in this cluster's design, **no DNS answer could ever make HTTP-01 succeed** — cutting DNS over to the Gateway's IP in Task 6 wouldn't fix it either, since `192.168.0.224` is exactly as unreachable from the internet as mullet's IP is. This is not a sequencing problem, it's a fundamental incompatibility.

Caddy already solves this correctly: it has the `dns.providers.cloudflare` module built in (confirmed via `caddy list-modules` on mullet) and uses **DNS-01** — proving domain ownership by publishing a `_acme-challenge.<host>` TXT record via the Cloudflare API, which Let's Encrypt verifies with a plain DNS lookup (no connection to the domain required at all). cert-manager's `ClusterIssuer` needs the same mechanism: a `dns01.cloudflare` solver referencing a Cloudflare API token (`Zone:DNS:Edit` on `verticon.com`, separate from Caddy's own token) stored as a Kubernetes Secret. Bootstrapping that token is tracked in issue [#109](https://github.com/jconlon/ops-microk8s/issues/109) — Task 3 cannot reach a Ready `ClusterIssuer` until it's resolved.

One consequence: the Gateway's shared plain HTTP listener (port 80), originally built to serve HTTP-01 challenge responses, is **no longer needed for certificate issuance**. It's retained for HTTP→HTTPS redirect traffic (a separate, still-useful concern), but ACME no longer depends on it at all.

### One shared Gateway, one shared MetalLB IP (`192.168.0.224`)
Today every service gets its own MetalLB IP (`.201`–`.223` allocated, pool is `.200`–`.230` — nearly half consumed). kgateway's `HTTPRoute` model lets many hostnames share one `Gateway`/one LoadBalancer Service, the same way Caddy shares one host IP for many `Caddyfile` blocks today. `192.168.0.224` is the next free IP in the pool.

### Scope: HTTP(S) services only — not PostgreSQL, Ceph RGW, or raw TCP services
`HTTPRoute` operates at L7 (HTTP/HTTPS). PostgreSQL (`.210`/`.211`), Ceph RGW/S3 (`.204`), and any other raw-TCP MetalLB services are **out of scope** for this migration — they keep their dedicated MetalLB IPs unchanged. (Gateway API has an experimental `TCPRoute`/`TLSRoute` channel; adopting it for these is a separate, future decision, not part of #108.)

### kgateway and cert-manager: independent ArgoCD apps, same Helm-chart-app pattern as Harbor
Each gets its own App-of-Apps parent (`kgateway-apps`, `cert-manager-apps`) with per-component child `Application`s, mirroring `argoCD-apps/harbor-apps.yaml` → `argoCD-apps/harbor/*.yaml`. This keeps their lifecycles (chart upgrades, CRD versions) independent.

### Sync waves
- **kgateway**: wave 1 (`kgateway-crds`) → wave 2 (`kgateway` controller) → wave 3 (`kgateway-resources`: `Gateway` + `HTTPRoute`s). CRDs must exist before the controller starts; the controller must be running and the `GatewayClass` `Accepted` before any `Gateway`/`HTTPRoute` is applied.
- **cert-manager**: wave 1 (`cert-manager` chart, CRDs + controller together — `installCRDs: true`) → wave 2 (`cert-manager-resources`: `ClusterIssuer`). With the DNS-01 solver, the `ClusterIssuer` has no dependency on the kgateway `Gateway` at all — its only real dependency is the Cloudflare API token Secret existing (issue #109) before `cert-manager-resources` can reach `Ready`.

### kgateway chart version: pin to a stable release at implementation time
The only version confirmed via current docs is the rolling `v2.4.0-main` build tag, which is **not** appropriate for a production cluster. Before Task 1, check https://github.com/kgateway-dev/kgateway/releases for the latest stable tag and pin both `kgateway-crds` and `kgateway` charts to it (same version for both, per kgateway's own compatibility expectation).

### GatewayClass auto-creation (confirmed during implementation)
**Resolved:** the `kgateway` controller chart does auto-create the default `kgateway` `GatewayClass` — no `GatewayClass` manifest exists anywhere in this repo, and `kubectl get gatewayclass` showed `kgateway` `Accepted: True` immediately after the `kgateway` chart (Task 1, wave 2) synced.

### Core Gateway API CRDs are NOT installed by kgateway-crds (discovered during implementation)
`kgateway-crds` only installs kgateway's own extension CRDs (`gateway.kgateway.dev` group — `TrafficPolicy`, `Backend`, `GatewayParameters`, etc.), confirmed via `helm template` and via `kubectl get crd` after deploying it. The core Gateway API CRDs (`GatewayClass`, `Gateway`, `HTTPRoute`, `ReferenceGrant`, etc. — `gateway.networking.k8s.io` group) are a separate upstream project with no Helm chart of its own; they must be installed from the static manifest bundle at `https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.0/standard-install.yaml`. Vendored into this repo as `kgateway-gitops/crds/gateway-api-standard-install.yaml` and deployed as a new wave-0 `gateway-api-crds` app (ahead of `kgateway-crds`, wave 1) — see Task 1.

**Important:** this bundle's CRD annotations exceed the 262144-byte client-side-apply limit — the ArgoCD app deploying it **must** use `ServerSideApply=true` (upstream's own install instructions say `kubectl apply --server-side` for the same reason).

### cert-manager Gateway API support is not needed (superseded — see ACME challenge type above)
The Jetstack Helm chart's `config.enableGatewayAPI: true` only matters for a `gatewayHTTPRoute` ACME solver, which this plan no longer uses (DNS-01 via Cloudflare has no dependency on Gateway API at all). The value can be left enabled or disabled with no effect on cert issuance; this plan leaves it enabled since it was already applied before the DNS-01 correction and removing it would require an extra Helm upgrade for no benefit.

### Migration is incremental and reversible
Caddy keeps serving 100% of production traffic through Task 5. Every new `HTTPRoute` is validated side-by-side with the existing Caddy route (different IP, same hostname resolved manually) before any DNS record changes. DNS cutover is the single, easily-revertible last step (Task 6) — reverting means pointing the A record back at mullet's IP.

---

## Task 1: Deploy kgateway (CRDs + controller)

**Files:**
- Create: `kgateway-gitops/helm/kgateway-values.yaml`
- Create: `argoCD-apps/kgateway-apps.yaml`
- Create: `argoCD-apps/kgateway/kgateway-crds-app.yaml`
- Create: `argoCD-apps/kgateway/kgateway-app.yaml`

- [ ] **Step 1: Confirm red state**

  ```bash
  kubectl get ns kgateway-system 2>&1
  # Expected: Error from server (NotFound)
  kubectl get crd | grep gateway.networking.k8s.io
  # Expected: no output — Gateway API CRDs not installed yet
  ```

- [ ] **Step 2: Pin the kgateway chart version**

  Check https://github.com/kgateway-dev/kgateway/releases for the latest stable (non `-main`) tag. Use it for both charts below (referred to as `<KGW_VERSION>`).

- [ ] **Step 3: Create the Helm values file**

  `kgateway-gitops/helm/kgateway-values.yaml`:
  ```yaml
  # kgateway controller — Envoy-based Gateway API implementation.
  # Installs the default GatewayClass "kgateway" (verify after deploy — see plan's
  # Architectural Decisions note on GatewayClass auto-creation).
  # No AI Gateway extension enabled here — Agentgateway is a separate follow-on (issue #108 Task 7).

  # Defaults are sufficient for a first deployment: single replica controller,
  # standard RBAC, no AI extension. Revisit replica count if kgateway becomes
  # a single point of failure for all ingress traffic.
  ```

- [ ] **Step 4: Create ArgoCD App-of-Apps manifests**

  `argoCD-apps/kgateway-apps.yaml`:
  ```yaml
  apiVersion: argoproj.io/v1alpha1
  kind: Application
  metadata:
    name: kgateway-apps
    namespace: argocd
  spec:
    project: default
    source:
      repoURL: https://github.com/jconlon/ops-microk8s
      targetRevision: HEAD
      path: argoCD-apps/kgateway
    destination:
      server: https://kubernetes.default.svc
      namespace: argocd
    syncPolicy:
      automated:
        prune: true
        selfHeal: true
      syncOptions:
        - CreateNamespace=true
  ```

  `argoCD-apps/kgateway/kgateway-crds-app.yaml` (wave 1):
  ```yaml
  apiVersion: argoproj.io/v1alpha1
  kind: Application
  metadata:
    name: kgateway-crds
    namespace: argocd
    annotations:
      argocd.argoproj.io/sync-wave: "1"
  spec:
    project: default
    source:
      repoURL: oci://cr.kgateway.dev/kgateway-dev/charts/kgateway-crds
      chart: kgateway-crds
      targetRevision: "v2.3.5"
    destination:
      server: https://kubernetes.default.svc
      namespace: kgateway-system
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

  `argoCD-apps/kgateway/kgateway-app.yaml` (wave 2):
  ```yaml
  apiVersion: argoproj.io/v1alpha1
  kind: Application
  metadata:
    name: kgateway
    namespace: argocd
    annotations:
      argocd.argoproj.io/sync-wave: "2"
  spec:
    project: default
    sources:
      - repoURL: oci://cr.kgateway.dev/kgateway-dev/charts/kgateway
        chart: kgateway
        targetRevision: "v2.3.5"
        helm:
          valueFiles:
            - $values/kgateway-gitops/helm/kgateway-values.yaml
      - repoURL: https://github.com/jconlon/ops-microk8s
        targetRevision: HEAD
        ref: values
    destination:
      server: https://kubernetes.default.svc
      namespace: kgateway-system
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

- [ ] **Step 5: Verify file syntax**

  ```bash
  for f in kgateway-gitops/helm/kgateway-values.yaml \
           argoCD-apps/kgateway-apps.yaml \
           argoCD-apps/kgateway/kgateway-crds-app.yaml \
           argoCD-apps/kgateway/kgateway-app.yaml; do
    python3 -c "import sys; d=open('$f').read(); print('OK:', '$f', len(d), 'bytes')"
  done
  ```

- [ ] **Step 6: Commit**

  ```bash
  git add kgateway-gitops/helm/kgateway-values.yaml \
    argoCD-apps/kgateway-apps.yaml \
    argoCD-apps/kgateway/kgateway-crds-app.yaml \
    argoCD-apps/kgateway/kgateway-app.yaml
  git commit -m "feat: add kgateway Gateway API implementation (issue #108)"
  ```

  > Do not `kubectl apply` yet — bootstrap happens once Task 3's chainsaw tests are written and confirmed red, per the argo-events plan's established pattern.

---

## Task 2: Deploy cert-manager

**Files:**
- Create: `cert-manager-gitops/helm/cert-manager-values.yaml`
- Create: `argoCD-apps/cert-manager-apps.yaml`
- Create: `argoCD-apps/cert-manager/cert-manager-app.yaml`

- [ ] **Step 1: Confirm red state**

  ```bash
  kubectl get ns cert-manager 2>&1
  # Expected: Error from server (NotFound)
  ```

- [ ] **Step 2: Create the Helm values file**

  `cert-manager-gitops/helm/cert-manager-values.yaml`:
  ```yaml
  # cert-manager — automated TLS certificate issuance.
  # NOTE: ClusterIssuer uses DNS-01 via Cloudflare, not HTTP-01/gatewayHTTPRoute —
  # see this plan's Architectural Decisions (*.verticon.com resolves to private LAN
  # IPs, so HTTP-01 can never succeed here). enableGatewayAPI below is not required
  # for DNS-01 issuance; harmless to leave enabled, only relevant if a
  # gatewayHTTPRoute solver is added later.
  installCRDs: true
  config:
    apiVersion: controller.config.cert-manager.io/v1alpha1
    kind: ControllerConfiguration
    enableGatewayAPI: true
  ```

- [ ] **Step 3: Create ArgoCD App-of-Apps manifests**

  `argoCD-apps/cert-manager-apps.yaml`:
  ```yaml
  apiVersion: argoproj.io/v1alpha1
  kind: Application
  metadata:
    name: cert-manager-apps
    namespace: argocd
  spec:
    project: default
    source:
      repoURL: https://github.com/jconlon/ops-microk8s
      targetRevision: HEAD
      path: argoCD-apps/cert-manager
    destination:
      server: https://kubernetes.default.svc
      namespace: argocd
    syncPolicy:
      automated:
        prune: true
        selfHeal: true
      syncOptions:
        - CreateNamespace=true
  ```

  `argoCD-apps/cert-manager/cert-manager-app.yaml` (wave 1):
  ```yaml
  apiVersion: argoproj.io/v1alpha1
  kind: Application
  metadata:
    name: cert-manager
    namespace: argocd
    annotations:
      argocd.argoproj.io/sync-wave: "1"
  spec:
    project: default
    sources:
      - repoURL: https://charts.jetstack.io
        chart: cert-manager
        targetRevision: "v1.20.3"
        helm:
          valueFiles:
            - $values/cert-manager-gitops/helm/cert-manager-values.yaml
      - repoURL: https://github.com/jconlon/ops-microk8s
        targetRevision: HEAD
        ref: values
    destination:
      server: https://kubernetes.default.svc
      namespace: cert-manager
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

  > `v1.20.3` confirmed as the latest stable (non-prerelease) release via `gh api repos/cert-manager/cert-manager/releases` on 2026-07-05 (the earlier `v1.17.0` placeholder was stale — cert-manager's Gateway API support docs happened to be version-pinned to an older release). Re-check https://cert-manager.io/docs/releases/ before applying if this plan is executed much later.

- [ ] **Step 4: Verify file syntax and commit**

  ```bash
  for f in cert-manager-gitops/helm/cert-manager-values.yaml \
           argoCD-apps/cert-manager-apps.yaml \
           argoCD-apps/cert-manager/cert-manager-app.yaml; do
    python3 -c "import sys; d=open('$f').read(); print('OK:', '$f', len(d), 'bytes')"
  done
  git add cert-manager-gitops/helm/cert-manager-values.yaml \
    argoCD-apps/cert-manager-apps.yaml \
    argoCD-apps/cert-manager/cert-manager-app.yaml
  git commit -m "feat: add cert-manager with Gateway API support (issue #108)"
  ```

---

## Task 3: Shared Gateway + ClusterIssuer

**Files:**
- Create: `kgateway-gitops/resources/gateway.yaml`
- Create: `argoCD-apps/kgateway/kgateway-resources-app.yaml`
- Create: `cert-manager-gitops/resources/cluster-issuer.yaml`
- Create: `argoCD-apps/cert-manager/cert-manager-resources-app.yaml`
- Create: `tests/kgateway/chainsaw-test.yaml`
- Create: `tests/cert-manager/chainsaw-test.yaml`

- [ ] **Step 1: Confirm red state**

  ```bash
  chainsaw test tests/kgateway/ 2>&1 | head -5
  chainsaw test tests/cert-manager/ 2>&1 | head -5
  # Expected: directories don't exist yet / no assertions to run
  ```

- [ ] **Step 2: Create the shared Gateway manifest**

  `kgateway-gitops/resources/gateway.yaml`:
  ```yaml
  # Shared Gateway — one MetalLB IP fronts every HTTPRoute-migrated service.
  # Replaces the one-MetalLB-IP-per-service Caddy pattern.
  #
  # Confirmed pattern (Envoy Gateway docs — kgateway is Envoy-based, same model):
  # there is no single generic HTTPS listener with SNI fan-out across arbitrary
  # certs. Instead:
  #   - ONE shared "http" listener (port 80, all namespaces) — NOT used for ACME
  #     (cert-manager uses DNS-01 via Cloudflare; see Architectural Decisions).
  #     Retained for HTTP->HTTPS redirect traffic instead.
  #   - ONE HTTPS listener PER HOSTNAME is added here as each service migrates
  #     (Task 4 adds the first, Task 5 adds the rest) — each with its own
  #     `hostname:` and its own `certificateRefs` Secret, populated by a
  #     per-hostname cert-manager `Certificate` resource (see Task 4).
  # This mirrors Caddy's per-hostname Caddyfile blocks structurally — just
  # declared as Gateway listener entries instead of implied by Caddy automatic HTTPS.
  apiVersion: gateway.networking.k8s.io/v1
  kind: Gateway
  metadata:
    name: cluster-gateway
    namespace: kgateway-system
  spec:
    gatewayClassName: kgateway
    # kgateway creates its own Service for the data plane — it does NOT copy
    # metadata.annotations from the Gateway resource onto that Service (confirmed
    # empirically: an annotation there was silently ignored, MetalLB auto-assigned
    # an unrelated IP). The Gateway API spec's own infrastructure.annotations
    # field (Support: Extended, confirmed present on the installed v1.6.0 CRDs)
    # is what actually reaches the generated Service.
    infrastructure:
      annotations:
        # MetalLB pins this Gateway's Service to .224 (next free IP after Apicurio's .223).
        metallb.universe.tf/loadBalancerIPs: "192.168.0.224"
    listeners:
      - name: http
        protocol: HTTP
        port: 80
        allowedRoutes:
          namespaces:
            from: All
      # Per-hostname HTTPS listeners are appended below by Task 4 / Task 5,
      # e.g.:
      # - name: https-pgadmin
      #   protocol: HTTPS
      #   port: 443
      #   hostname: "pgadmin.verticon.com"
      #   tls:
      #     mode: Terminate
      #     certificateRefs:
      #       - name: pgadmin-tls
      #   allowedRoutes:
      #     namespaces:
      #       from: All
  ```

- [ ] **Step 3: Create the ClusterIssuer**

  > **Correction (2026-07-06):** originally implemented with an `http01.gatewayHTTPRoute` solver (shown further down in a strikethrough-style note for the record). That cannot work — see the Architectural Decisions section on ACME challenge type. The corrected target form is below; it requires the Cloudflare API token Secret from issue [#109](https://github.com/jconlon/ops-microk8s/issues/109) to exist first. **As of this writing, the committed `cert-manager-gitops/resources/cluster-issuer.yaml` still uses the old `http01` form** (the `pgadmin-tls` Certificate is stuck `pending` as a direct result) — updating it to the form below is the first step once #109's secret lands.

  `cert-manager-gitops/resources/cluster-issuer.yaml` (corrected target form):
  ```yaml
  apiVersion: cert-manager.io/v1
  kind: ClusterIssuer
  metadata:
    name: letsencrypt-http01   # name kept as-is to avoid renaming a resource other manifests already reference
  spec:
    acme:
      server: https://acme-v02.api.letsencrypt.org/directory
      email: jconlon@verticon.com
      privateKeySecretRef:
        name: letsencrypt-http01-account-key
      solvers:
        - dns01:
            cloudflare:
              apiTokenSecretRef:
                name: cloudflare-api-token-secret
                key: api-token
  ```

  > Start with the production ACME server directly since `*.verticon.com` domains are already established and not rate-limit-risk; if repeated failed attempts are expected during development, temporarily point `server` at `https://acme-staging-v02.api.letsencrypt.org/directory` and switch back before Task 4's real verification.

- [ ] **Step 4: Wire ArgoCD resources apps**

  `argoCD-apps/kgateway/kgateway-resources-app.yaml` (wave 3):
  ```yaml
  apiVersion: argoproj.io/v1alpha1
  kind: Application
  metadata:
    name: kgateway-resources
    namespace: argocd
    annotations:
      argocd.argoproj.io/sync-wave: "3"
  spec:
    project: default
    source:
      repoURL: https://github.com/jconlon/ops-microk8s
      targetRevision: HEAD
      path: kgateway-gitops/resources
    destination:
      server: https://kubernetes.default.svc
      namespace: kgateway-system
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

  > `HTTPRoute`s live in `kgateway-gitops/resources/httproutes/` as a subdirectory — add `directory: { recurse: true }` here once Task 4 adds the first `HTTPRoute` file (same silent-failure trap documented in the argo-events plan: without `recurse: true`, ArgoCD scans only the root and silently syncs zero of the subdirectory's resources).

  `argoCD-apps/cert-manager/cert-manager-resources-app.yaml` (wave 2):
  ```yaml
  apiVersion: argoproj.io/v1alpha1
  kind: Application
  metadata:
    name: cert-manager-resources
    namespace: argocd
    annotations:
      argocd.argoproj.io/sync-wave: "2"
  spec:
    project: default
    source:
      repoURL: https://github.com/jconlon/ops-microk8s
      targetRevision: HEAD
      path: cert-manager-gitops/resources
    destination:
      server: https://kubernetes.default.svc
      namespace: cert-manager
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

- [ ] **Step 5: Write chainsaw tests**

  `tests/kgateway/chainsaw-test.yaml`:
  ```yaml
  apiVersion: chainsaw.kyverno.io/v1alpha1
  kind: Test
  metadata:
    name: kgateway-healthy
  spec:
    description: kgateway controller, GatewayClass, and shared Gateway are healthy
    concurrent: false
    timeouts:
      assert: 5m
      exec: 60s
    steps:
      - name: kgateway-apps-synced
        try:
          - assert:
              resource:
                apiVersion: argoproj.io/v1alpha1
                kind: Application
                metadata:
                  name: kgateway
                  namespace: argocd
                status:
                  sync:
                    status: Synced
                  health:
                    status: Healthy
      - name: gatewayclass-accepted
        try:
          - assert:
              resource:
                apiVersion: gateway.networking.k8s.io/v1
                kind: GatewayClass
                metadata:
                  name: kgateway
                status:
                  (conditions[?type == 'Accepted'].status | [0]): "True"
      - name: gateway-programmed-with-metallb-ip
        try:
          - assert:
              resource:
                apiVersion: gateway.networking.k8s.io/v1
                kind: Gateway
                metadata:
                  name: cluster-gateway
                  namespace: kgateway-system
                status:
                  (conditions[?type == 'Programmed'].status | [0]): "True"
          - script:
              content: |
                IP=$(kubectl get gateway cluster-gateway -n kgateway-system \
                  -o jsonpath='{.status.addresses[0].value}')
                [ "$IP" = "192.168.0.224" ] || { echo "Expected 192.168.0.224, got: $IP"; exit 1; }
                echo "Gateway IP confirmed: $IP"
  ```

  `tests/cert-manager/chainsaw-test.yaml`:
  ```yaml
  apiVersion: chainsaw.kyverno.io/v1alpha1
  kind: Test
  metadata:
    name: cert-manager-healthy
  spec:
    description: cert-manager is deployed and the DNS-01 ClusterIssuer is Ready
    concurrent: false
    timeouts:
      assert: 5m
    steps:
      - name: cert-manager-apps-synced
        try:
          - assert:
              resource:
                apiVersion: argoproj.io/v1alpha1
                kind: Application
                metadata:
                  name: cert-manager
                  namespace: argocd
                status:
                  sync:
                    status: Synced
                  health:
                    status: Healthy
      - name: cert-manager-pods-running
        try:
          - assert:
              resource:
                apiVersion: apps/v1
                kind: Deployment
                metadata:
                  name: cert-manager
                  namespace: cert-manager
                status:
                  (availableReplicas >= `1`): true
      - name: cluster-issuer-ready
        try:
          - assert:
              resource:
                apiVersion: cert-manager.io/v1
                kind: ClusterIssuer
                metadata:
                  name: letsencrypt-http01
                status:
                  (conditions[?type == 'Ready'].status | [0]): "True"
  ```

- [ ] **Step 6: Confirm tests fail (red), then commit**

  ```bash
  chainsaw test tests/kgateway/ tests/cert-manager/
  # Expected: FAIL — nothing deployed yet
  git add kgateway-gitops/resources/gateway.yaml \
    argoCD-apps/kgateway/kgateway-resources-app.yaml \
    cert-manager-gitops/resources/cluster-issuer.yaml \
    argoCD-apps/cert-manager/cert-manager-resources-app.yaml \
    tests/kgateway/chainsaw-test.yaml \
    tests/cert-manager/chainsaw-test.yaml
  git commit -m "test: add kgateway Gateway and cert-manager ClusterIssuer with chainsaw coverage (issue #108)"
  ```

- [ ] **Step 7: Bootstrap — apply both parent apps**

  ```bash
  git push
  kubectl apply -f argoCD-apps/kgateway-apps.yaml
  kubectl apply -f argoCD-apps/cert-manager-apps.yaml
  kubectl get application -n argocd -w | grep -E "kgateway|cert-manager"
  ```

- [ ] **Step 8: Run tests to green**

  ```bash
  chainsaw test tests/kgateway/
  chainsaw test tests/cert-manager/
  # Expected: all steps PASS
  ```

### ── CHECKPOINT A ──
Confirm both chainsaw suites are green — `Gateway` `Programmed: True` with IP `192.168.0.224`, `ClusterIssuer` `Ready: True` — before creating any `HTTPRoute` for a real service.

---

## Task 4: POC — migrate pgAdmin to HTTPRoute

**Target service:** pgAdmin (`pgadmin.verticon.com`, currently `192.168.0.212` via Caddy) — internal-only tool, low blast radius if something breaks.

**Files:**
- Create: `kgateway-gitops/resources/httproutes/pgadmin-httproute.yaml`
- Create: `cert-manager-gitops/resources/certificates/pgadmin-certificate.yaml`
- Modify: `kgateway-gitops/resources/gateway.yaml` (add the `https-pgadmin` listener)
- Modify: `argoCD-apps/kgateway/kgateway-resources-app.yaml` (add `directory: { recurse: true }`)
- Modify: `argoCD-apps/cert-manager/cert-manager-resources-app.yaml` (add `directory: { recurse: true }`)
- Modify: `tests/kgateway/chainsaw-test.yaml` (append listener/Certificate/HTTPRoute + reachability assertions)

- [ ] **Step 1: Confirm red state**

  ```bash
  kubectl get httproute -n pgadmin 2>&1
  kubectl get certificate -n cert-manager pgadmin-tls 2>&1
  # Expected: no resources found for both
  ```

- [ ] **Step 2: Confirm the pgAdmin backend Service**

  ```bash
  kubectl get svc -n pgadmin
  # Confirm the actual Service name/port before writing the HTTPRoute below —
  # do not assume `pgadmin`/`80` without checking (see postgresql-gitops/pgadmin/).
  ```

- [ ] **Step 3: Create the per-hostname Certificate**

  `cert-manager-gitops/resources/certificates/pgadmin-certificate.yaml`:
  ```yaml
  # One Certificate per migrated hostname — cert-manager solves the ACME
  # DNS-01 challenge via the Cloudflare API (ClusterIssuer's dns01.cloudflare
  # solver — *.verticon.com resolves to private LAN IPs, so HTTP-01 cannot
  # work here), then writes the cert+key into the Secret named below. That
  # Secret is what the Gateway's https-pgadmin listener references in Task 4 Step 4.
  apiVersion: cert-manager.io/v1
  kind: Certificate
  metadata:
    name: pgadmin-tls
    namespace: kgateway-system
  spec:
    secretName: pgadmin-tls
    dnsNames:
      - pgadmin.verticon.com
    issuerRef:
      name: letsencrypt-http01
      kind: ClusterIssuer
  ```

  > `namespace: kgateway-system` — the Secret must live in the same namespace as the Gateway resource that references it in `certificateRefs`.

- [ ] **Step 4: Add the per-hostname HTTPS listener to the shared Gateway**

  Append to `kgateway-gitops/resources/gateway.yaml`'s `spec.listeners`:
  ```yaml
      - name: https-pgadmin
        protocol: HTTPS
        port: 443
        hostname: "pgadmin.verticon.com"
        tls:
          mode: Terminate
          certificateRefs:
            - name: pgadmin-tls
        allowedRoutes:
          namespaces:
            from: All
  ```

- [ ] **Step 5: Create the HTTPRoute**

  `kgateway-gitops/resources/httproutes/pgadmin-httproute.yaml`:
  ```yaml
  apiVersion: gateway.networking.k8s.io/v1
  kind: HTTPRoute
  metadata:
    name: pgadmin
    namespace: pgadmin
  spec:
    parentRefs:
      - name: cluster-gateway
        namespace: kgateway-system
        sectionName: https-pgadmin
    hostnames:
      - "pgadmin.verticon.com"
    rules:
      - backendRefs:
          - name: pgadmin   # confirmed in Step 2
            port: 80        # confirmed in Step 2
  ```

- [ ] **Step 6: Enable directory recursion for the new subdirectories**

  Update `argoCD-apps/kgateway/kgateway-resources-app.yaml` (adds `httproutes/`):
  ```yaml
    source:
      repoURL: https://github.com/jconlon/ops-microk8s
      targetRevision: HEAD
      path: kgateway-gitops/resources
    directory:
      recurse: true
  ```

  Update `argoCD-apps/cert-manager/cert-manager-resources-app.yaml` (adds `certificates/`):
  ```yaml
    source:
      repoURL: https://github.com/jconlon/ops-microk8s
      targetRevision: HEAD
      path: cert-manager-gitops/resources
    directory:
      recurse: true
  ```

- [ ] **Step 7: Extend chainsaw tests**

  Append to `tests/kgateway/chainsaw-test.yaml`:
  ```yaml
      - name: pgadmin-certificate-ready
        try:
          - assert:
              resource:
                apiVersion: cert-manager.io/v1
                kind: Certificate
                metadata:
                  name: pgadmin-tls
                  namespace: kgateway-system
                status:
                  (conditions[?type == 'Ready'].status | [0]): "True"
      - name: pgadmin-httproute-accepted
        try:
          - assert:
              resource:
                apiVersion: gateway.networking.k8s.io/v1
                kind: HTTPRoute
                metadata:
                  name: pgadmin
                  namespace: pgadmin
                status:
                  parents:
                    - conditions:
                        - type: Accepted
                          status: "True"
      - name: pgadmin-reachable-via-gateway
        try:
          - script:
              timeout: 30s
              content: |
                STATUS=$(curl -sk -o /dev/null -w "%{http_code}" \
                  -H "Host: pgadmin.verticon.com" https://192.168.0.224)
                [ "$STATUS" = "200" ] || [ "$STATUS" = "302" ] || \
                  { echo "Expected 200/302, got: $STATUS"; exit 1; }
                echo "pgAdmin reachable via Gateway: $STATUS"
  ```

- [ ] **Step 8: Verify, commit, and manually check**

  ```bash
  chainsaw test tests/kgateway/
  git add kgateway-gitops/resources/httproutes/pgadmin-httproute.yaml \
    kgateway-gitops/resources/gateway.yaml \
    cert-manager-gitops/resources/certificates/pgadmin-certificate.yaml \
    argoCD-apps/kgateway/kgateway-resources-app.yaml \
    argoCD-apps/cert-manager/cert-manager-resources-app.yaml \
    tests/kgateway/chainsaw-test.yaml
  git commit -m "feat: migrate pgAdmin to kgateway HTTPRoute as Gateway API POC (issue #108)"
  ```

### ── CHECKPOINT B (manual) ──
Verify pgAdmin in a real browser through the new path (e.g. a temporary `/etc/hosts` override pointing `pgadmin.verticon.com` at `192.168.0.224`, or a scratch DNS record) — confirm login page loads and TLS cert is valid and issued by Let's Encrypt — before migrating any other service or touching the real DNS record.

---

## Task 5: Migrate remaining HTTP(S) services (wave by wave)

Repeat the Task 4 pattern once per service — for each hostname, add: (1) a `Certificate` in `cert-manager-gitops/resources/certificates/`, (2) an `https-<service>` listener on the shared Gateway referencing that Certificate's Secret, (3) an `HTTPRoute` in `kgateway-gitops/resources/httproutes/` with `sectionName: https-<service>`, (4) matching chainsaw assertions (Certificate Ready, HTTPRoute Accepted, reachability). Do not enumerate every file here — each is a small, independently-committable change of the same shape as pgAdmin's.

**Suggested wave order (lowest → highest risk):**

| Wave | Service | Hostname | Current Caddy IP |
|---|---|---|---|
| 1 | Prometheus | prometheus.verticon.com | 192.168.0.202 |
| 1 | AlertManager | alertmanager.verticon.com | 192.168.0.203 |
| 2 | Grafana | grafana.verticon.com | 192.168.0.201 |
| 2 | Loki | loki.verticon.com | 192.168.0.220 |
| 3 | Harbor | registry.verticon.com | 192.168.0.219 |
| 4 | Argo Workflows | workflows.verticon.com | 192.168.0.209 |
| 4 | Argo Events | events.verticon.com | 192.168.0.221 |

Not in scope for `HTTPRoute` migration (raw TCP / non-HTTP protocols — keep dedicated MetalLB IPs): PostgreSQL primary/readonly (`.210`/`.211`), Ceph RGW/S3 (`.204`), vLLM if it remains accessed as a bare `/v1` API without a Caddy-fronted hostname today (confirm during this task whether vLLM has an HTTP hostname to migrate).

**Acceptance criteria per service (same as Task 4):** `Certificate` `Ready`; `HTTPRoute` `Accepted`; correct backend Service reachable through the Gateway with `Host` header; existing Caddy route for that hostname left untouched until Task 6.

**Verification:** extend `tests/kgateway/chainsaw-test.yaml` with one assertion block per migrated service (mirroring the `pgadmin-httproute-accepted` / `pgadmin-reachable-via-gateway` pair); `just test-kgateway` stays green after each wave.

### ── CHECKPOINT C ──
All services from the table above are reachable and cert-valid through `192.168.0.224` — confirmed by both chainsaw and a manual browser pass — before touching any DNS record.

---

## Task 6: DNS cutover and Caddy decommission

**Manual operator steps** (Caddyfile is on `mullet`, not in this repo — same convention as the argo-events plan's Task 4):

1. For each migrated hostname, repoint its Cloudflare A record from mullet's public IP to `192.168.0.224`.
2. Remove the corresponding block from `/etc/caddy/Caddyfile` on `mullet`.
3. `sudo caddy reload --config /etc/caddy/Caddyfile` (zero-downtime).
4. Once every block is removed, optionally `sudo systemctl stop caddy` (or leave it running, idle, in case a future non-HTTP service still needs it).

**Files to update:**
- `CLAUDE.md` / `README.md` — replace the Caddy-based "Adding a New DNS Name for a Service" procedure with: create an `HTTPRoute` in `kgateway-gitops/resources/httproutes/`, point the Cloudflare A record at `192.168.0.224`, done (no per-service MetalLB IP, no Caddyfile edit).
- `scripts/README.md` — document the new bootstrap procedure for adding a service.
- `docs/networking.html` — same content, converted to this repo's HTML doc template per `docs/CLAUDE.md` (no new `.md` docs).

- [ ] **Step 1: Confirm all Task 5 services are validated (Checkpoint C passed)**
- [ ] **Step 2: Cut over DNS + Caddyfile per the manual steps above (operator-performed)**
- [ ] **Step 3: Verify each hostname**

  ```bash
  for h in grafana prometheus alertmanager loki registry workflows events pgadmin; do
    echo "=== $h ==="; curl -sI https://$h.verticon.com | head -1
  done
  # Expected: HTTP/2 200 (or appropriate app-level redirect) for every hostname,
  # now served directly by 192.168.0.224 (DNS no longer resolves to mullet for these)
  ```

- [ ] **Step 4: Update docs and commit**

  ```bash
  git add CLAUDE.md README.md scripts/README.md docs/networking.html
  git commit -m "docs: replace Caddy DNS procedure with kgateway HTTPRoute procedure (issue #108)"
  ```

- [ ] **Step 5: Full regression pass**

  ```bash
  just test
  # Expected: all suites PASS, no regressions
  ```

---

## Task 7 (follow-on issue — not implemented here): kagent + Agentgateway

Per issue #108's stated scope, deploying kagent itself is tracked in a separate follow-on issue. It will reuse the `Gateway`/`HTTPRoute`/`ClusterIssuer` foundation built in Tasks 1–3, adding `agentgateway` alongside kgateway (same project family) and `AgentgatewayPolicy` CRDs (e.g. prompt-guard, rate limiting) fronting the in-cluster vLLM endpoint (`http://vllm-router-service.vllm.svc.cluster.local/v1`).

---

## Tricky Boundaries and Risk Notes

### GatewayClass auto-creation — resolved (see Architectural Decisions)
Confirmed during implementation: the `kgateway` chart auto-creates the `kgateway` `GatewayClass`. No further action needed.

### cert-manager `enableGatewayAPI` CRD-ordering crash loop (confirmed, hit in practice)
This one really happened, independent of the HTTP-01/DNS-01 correction: with `config.enableGatewayAPI: true` set, cert-manager's controller refuses to start at all if the core Gateway API CRDs aren't present yet — `"the Gateway API CRDs do not seem to be present, but ExperimentalGatewayAPISupport is set to true"` — and crash-loops rather than waiting/retrying. This was hit directly during Task 3 bootstrap (the `gateway-api-crds` wave-0 app synced a few seconds after the `cert-manager` pod's first start attempt). Fix was simply `kubectl delete pod -n cert-manager -l app.kubernetes.io/component=controller` once the CRDs existed — the next restart succeeds. If `enableGatewayAPI` is ever removed (see the note in Task 2 — it's not needed for DNS-01), this failure mode goes away entirely.

### TLS certificate wiring pattern (confirmed, listener part still applies — solver part corrected)
Per Envoy Gateway's own docs (kgateway is Envoy-based, same Gateway API model): there is **no single generic HTTPS listener with SNI fan-out across arbitrary certs**. The confirmed, standard pattern — used from Task 4 onward — is one HTTPS listener **per hostname** on the shared `Gateway`, each with its own `tls.certificateRefs` pointing at a Secret populated by its own per-hostname `Certificate` resource. This part is unaffected by the DNS-01 correction. What's no longer true: the plain HTTP listener (port 80) does **not** serve any ACME purpose now — DNS-01 issuance never touches the Gateway at all. That listener is retained only for HTTP→HTTPS redirect traffic, a separate concern from certificate issuance.

### `directory.recurse: true` silent-failure trap (two apps affected)
Identical to the trap documented in the argo-events plan, and it affects **both** new App-of-Apps trees starting in Task 4: `kgateway-resources-app`'s path (`kgateway-gitops/resources`) gains a `httproutes/` subdirectory, and `cert-manager-resources-app`'s path (`cert-manager-gitops/resources`) gains a `certificates/` subdirectory. Without `directory.recurse: true` on **both** apps, ArgoCD reports each `Synced`/`Healthy` while silently applying zero of the subdirectory's resources. Always verify with `kubectl get httproute -A` and `kubectl get certificate -A` after any sync that's supposed to add a new route/cert.

### MetalLB annotation key
Use the plural `metallb.universe.tf/loadBalancerIPs` (confirmed cluster-wide convention, e.g. `argo-events`, `loki`, `apicurio-registry`) — the singular `loadBalancerIP` is deprecated and may be silently ignored.

### Chart version pinning
Both `kgateway`'s chart version (`v2.3.5`, confirmed 2026-07-05) and cert-manager's (`v1.20.3`, confirmed 2026-07-05) need re-verification against current releases if this plan is executed significantly later — do not blindly apply the versions written here without checking release pages first.
