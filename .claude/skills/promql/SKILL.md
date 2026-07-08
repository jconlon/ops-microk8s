---
name: promql
description: Reference for writing, explaining, and debugging PromQL queries — Prometheus data model, syntax, functions, and common patterns (rate, histogram_quantile, error rate, SLOs). Use whenever constructing or troubleshooting a PromQL query against this cluster's Prometheus/Grafana stack.
---

# PromQL Query Reference

Adapted from kagent's bundled `promql-agent` system prompt. This content is
mostly Prometheus domain knowledge, not cluster-specific — the only addition
here is *how to actually run a query against this cluster*.

## Running a query here

- **Grafana Explore**: https://grafana.verticon.com → Explore → Prometheus datasource.
- **Direct API** (useful for scripting or a quick check without opening a browser):
  ```bash
  curl -s --data-urlencode 'query=<promql>' https://prometheus.verticon.com/api/v1/query | jq
  # range query:
  curl -s --data-urlencode 'query=<promql>' \
    --data-urlencode 'start=<unix_ts>' --data-urlencode 'end=<unix_ts>' --data-urlencode 'step=60' \
    https://prometheus.verticon.com/api/v1/query_range | jq
  ```
- **Discover what's available** before guessing metric/label names:
  ```bash
  curl -s https://prometheus.verticon.com/api/v1/label/__name__/values | jq       # all metric names
  curl -s https://prometheus.verticon.com/api/v1/labels | jq                       # all label names
  curl -s https://prometheus.verticon.com/api/v1/label/<label>/values | jq         # values for one label
  curl -s https://prometheus.verticon.com/api/v1/targets | jq                       # scrape target health
  ```

## Prometheus data model

- **Metrics**: named measurements, with HELP/TYPE metadata.
- **Time series**: a metric plus a unique label combination.
- **Samples**: `(timestamp, value)` tuples per time series.

Metric types:
- **Counter** — monotonically increasing (`_total` suffix convention). Always wrap in `rate()`/`irate()`/`increase()`, never read the raw value.
- **Gauge** — can go up or down (e.g. memory usage, temperature).
- **Histogram** — bucketed observations (`_bucket`, `_sum`, `_count` suffixes); use with `histogram_quantile()`.
- **Summary** — pre-computed quantiles, own suffixes.

## Syntax cheat sheet

**Vector types**: instant vector (most recent sample), range vector (`metric[5m]`), scalar, string.

**Label matchers**: `{label="value"}` exact · `{label!="value"}` negative · `{label=~"regex"}` regex · `{label!~"regex"}` negative regex.

**Time ranges**: units `ms s m h d w y` · range vector `metric[5m]` · offset `metric offset 1h` · subquery `function(metric[5m])[1h:10m]`.

**Operators**: arithmetic `+ - * / % ^` · comparison `== != > < >= <=` · logical/set `and or unless` · aggregations `sum avg min max count topk bottomk` · group modifiers `by without` · vector matching `on ignoring group_left group_right`.

**Key functions**: `rate()` `irate()` `increase()` `changes()` `delta()` for counters/gauges over time; `<aggr>_over_time()` family; `histogram_quantile()`; `predict_linear()` `deriv()` for trend/capacity work.

## Best practices

1. Always `rate()`/`irate()` a counter — never chart it raw.
2. Pick time windows deliberately: too short starves the query of data points, too long averages out real spikes.
3. Watch label cardinality — high-cardinality label combinations (e.g. per-request IDs) blow up query cost.
4. Match subquery resolution to what you actually need: `max_over_time(rate(http_requests_total[5m])[1h:1m])`.
5. Remember the 5-minute staleness window — a target that stopped scraping doesn't immediately read as absent.
6. Aggregate at the level the question is actually asked at (per-pod vs per-node vs cluster-wide).
7. Prefer the simplest query that answers the question.

## Common patterns

```promql
# Request rate
rate(http_requests_total{job="service"}[5m])

# Error rate (ratio)
sum(rate(http_requests_total{job="service", status=~"5.."}[5m]))
  / sum(rate(http_requests_total{job="service"}[5m]))

# Latency percentile
histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket{job="service"}[5m])) by (le))

# Resource usage by pod
sum(container_memory_usage_bytes{namespace="production"}) by (pod)

# Availability
sum(up{job="service"}) / count(up{job="service"})
```

## Advanced patterns worth knowing

- **SLOs**: error budgets, multi-window burn-rate alerting.
- **Capacity planning**: `predict_linear()` for growth projection, saturation metrics.
- **Comparative analysis**: current vs. historical (`offset`), cross-environment comparisons.

## When answering a query request

Give: the query itself, a short explanation of how it works, any assumptions
made about metric/label names (verify against `/api/v1/label/__name__/values`
rather than guessing when it matters), alternatives if relevant, and any
known limitations (e.g. cardinality cost, staleness edge cases).
