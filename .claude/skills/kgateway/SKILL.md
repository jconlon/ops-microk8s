---
name: kgateway
description: kgateway (Envoy/Gateway API) domain reference for this cluster — Gateway/HTTPRoute authoring, SNI-routing gotchas, and a troubleshooting checklist. Use when adding a new HTTP(S) service, debugging routing or cert issues, or editing kgateway-gitops/cert-manager-gitops resources.
---

# kgateway Expert

Adapted from kagent's bundled `kgateway-agent` system prompt. The original
included Helm install/upgrade instructions and `helm_upgrade`/`helm_repo_add`
tool access — **dropped entirely here**: this repo's rule is that ArgoCD owns
all Helm lifecycle management, and kgateway itself is deployed the same way
(bump `targetRevision` in the ArgoCD `Application`, never run `helm` by hand).
What's kept is the actual Gateway API domain knowledge and this cluster's
specific topology.

## This cluster's topology (source of truth: root `CLAUDE.md` / `README.md`)

- One shared `Gateway` (`cluster-gateway`, `kgateway-system` namespace) behind
  a single MetalLB IP `192.168.0.224` — one HTTP listener (redirect-only) plus
  one HTTPS listener per hostname, SNI-routed.
- Real Let's Encrypt certs per hostname via `cert-manager`'s DNS-01 solver
  (Cloudflare) — HTTP-01 is impossible here since `*.verticon.com` resolves to
  private LAN IPs.
- **Adding a new HTTP(S) service**: see README.md → "Adding a New DNS Name for
  a Service" for the exact 4-step procedure (Certificate, Gateway listener,
  HTTPRoute in the backend's own namespace, Cloudflare A record). Don't
  reinvent this — follow the documented pattern.
- Non-HTTP protocols (PostgreSQL, Kafka external broker) are **not** fronted
  by kgateway — they keep dedicated MetalLB IPs; Gateway API's experimental
  `TCPRoute` could handle these but isn't adopted yet.

## Known gotchas (already paid for once — don't rediscover them)

- kgateway routes HTTPS listeners by **TLS SNI**, not the HTTP `Host` header.
  `curl -H "Host: ..."` against the raw Gateway IP gets a TLS-level connection
  reset. Use `curl --resolve <host>:443:192.168.0.224 https://<host>/` instead.
- This machine's local resolver caches the old A record for its TTL right
  after a Cloudflare DNS change (up to ~1-2 min) — check with `dig @1.1.1.1`
  for the real, current answer before concluding something's broken.

## Gateway API resource model

- **GatewayClass** — cluster-scoped, names the controller implementation (`kgateway` here). One per cluster is the norm.
- **Gateway** — the listener set (protocol, port, hostname, TLS). This repo uses one shared `Gateway` with many per-hostname HTTPS listeners rather than one Gateway per service.
- **HTTPRoute** — binds hostnames/paths to a backend Service; lives in the backend's own namespace to avoid needing a `ReferenceGrant`.
- **Policies** (kgateway-specific CRDs) — traffic shaping, auth, rate limiting, AI Gateway features layered on top of the base spec.

### Minimal HTTPRoute pattern

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: <service>
  namespace: <backend-service-namespace>
spec:
  parentRefs:
    - name: cluster-gateway
      namespace: kgateway-system
      sectionName: https-<service>
  hostnames:
    - "<service>.verticon.com"
  rules:
    - backendRefs:
        - name: <backend-service-name>
          port: <backend-service-port>
```

## Troubleshooting checklist

1. `kubectl get gateway,httproute,certificate -A` — confirm the objects exist and check `AGE`/`ACCEPTED` columns.
2. `kubectl describe httproute <name> -n <ns>` — look at `status.parents[].conditions`: `Accepted` and `ResolvedRefs` should both be `True`. A `False` `ResolvedRefs` usually means the backend Service/port doesn't match — confirm with `kubectl get svc -n <ns>` rather than assuming.
3. `kubectl describe certificate <name> -n kgateway-system` — check `status.conditions` for `Ready`; if stuck, check the `cert-manager` pod logs and the Cloudflare DNS-01 challenge record.
4. `kubectl logs -n kgateway-system deploy/<kgateway-controller-deployment>` for reconcile errors.
5. Confirm DNS actually resolves to `192.168.0.224` from a public resolver (`dig @1.1.1.1 <host>`) before assuming a routing bug.
6. Test with SNI, not Host header (see gotcha above).

## Advanced kgateway features (for context, not yet used in this cluster)

AI Gateway (LLM-aware rate limiting/access control), gRPC and WebSocket
support, experimental `TCPRoute`/`TLSRoute` for non-HTTP protocols, and richer
authN/authZ policies than base Gateway API provides. Useful background if a
future service needs one of these — none of this cluster's current
`HTTPRoute`s use them.
