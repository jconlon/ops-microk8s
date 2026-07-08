---
name: observability
description: Correlates Prometheus metrics and Grafana dashboard lookup with Kubernetes resource state for this cluster. Use for troubleshooting performance/resource issues, finding relevant dashboards, or interpreting metrics trends. Pairs with the promql skill for query construction and k8s-troubleshoot for resource-state correlation.
---

# Observability (Prometheus + Grafana + K8s correlation)

Adapted from this repo's own custom `observability-agent` Agent CR
(`kagent-gitops/resources/observability-agent.yaml`), which itself replaced
kagent's bundled version — the bundled 31-tool grafana-mcp toolset alone
overflowed the local vLLM model's 8192-token context window, so it was
curated down to read-only Prometheus + dashboard lookup. That token-budget
constraint doesn't apply here (no MCP tool schemas to load), so this skill
just carries forward the curated *scope* — read-only querying and dashboard
lookup, not dashboard mutation, alerting rules, oncall, or Loki search (Loki
has its own patterns — see `scripts/loki.nu` / `just loki-*` recipes instead).

## Core capability

Query Prometheus metrics, find relevant Grafana dashboards and inspect their
panel queries, and correlate both with live Kubernetes resource state to
explain performance bottlenecks or resource pressure. For the query-writing
part, use the **promql** skill. For the "is this pod actually unhealthy"
part, use the **k8s-troubleshoot** skill or `just pods-unhealthy` /
`just node-status` / `just ceph-status`.

## Prometheus (direct API)

```bash
curl -s --data-urlencode 'query=<promql>' https://prometheus.verticon.com/api/v1/query | jq
curl -s https://prometheus.verticon.com/api/v1/label/__name__/values | jq   # discover metric names
curl -s https://prometheus.verticon.com/api/v1/labels | jq                   # discover label names
curl -s https://prometheus.verticon.com/api/v1/label/<label>/values | jq     # discover label values
```

## Grafana (direct API)

Grafana admin password:
```bash
kubectl --namespace monitoring get secret grafana -o jsonpath="{.data.admin-password}" | base64 -d
```

```bash
# List datasources (resolve a UID before querying a specific one)
curl -s -u "admin:$GRAFANA_ADMIN_PW" http://192.168.0.201/api/datasources | jq

# Search dashboards
curl -s -u "admin:$GRAFANA_ADMIN_PW" "http://192.168.0.201/api/search?query=<term>" | jq

# Get a dashboard by UID (includes panel definitions/queries)
curl -s -u "admin:$GRAFANA_ADMIN_PW" http://192.168.0.201/api/dashboards/uid/<uid> | jq
```

Never echo the password itself into a response — fetch it into a shell
variable and use it in the same command, per this session's no-secrets rule.
External access is https://grafana.verticon.com if working from outside a
shell with cluster network access.

## What this skill deliberately does not cover

- **Dashboard creation/editing/versioning/permissions** — out of scope by
  original design (context-budget curation); if you need to create or modify
  a dashboard, that's a distinct, heavier-weight task — say so explicitly
  rather than guessing at the Grafana provisioning/API-write path.
- **Alerting rules, oncall schedules, incident tracking** — not covered here.
- **Loki / log search** — use `ops loki <subcommand>` / `just loki-*` instead (see `scripts/README.md`).

## Response shape

When answering an observability question: state the metric/dashboard you
looked at, the actual query or API call used, the result, and — if relevant —
which Kubernetes resources it correlates to (pod/node/namespace). Don't
present a metric trend without grounding it in what's actually running.
