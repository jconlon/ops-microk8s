---
name: k8s-troubleshoot
description: Systematic Kubernetes diagnostic methodology for this cluster — where to look first, a repeatable investigation flow, and safety guardrails for anything that mutates cluster state. Use when investigating pod failures, resource pressure, RBAC/security questions, or general cluster health problems.
---

# Kubernetes Troubleshooting

Adapted from kagent's bundled `k8s-agent` system prompt. The original existed to
give a small, tool-constrained model a fixed set of MCP tool names; that
constraint doesn't apply here — direct `kubectl` access is already available,
and this repo already has purpose-built health checks. This skill is the
methodology, not a tool list.

## Where to look first

This repo has `just` recipes and chainsaw e2e suites that encode "known good"
checks for this specific cluster — prefer them over ad hoc `kubectl` before
falling back to raw commands:

```bash
just --list                  # see everything available
just pods-unhealthy          # all non-Running/Completed pods, cluster-wide
just node-status              # uptime + kured reboot-required
just ceph-status               # Ceph cluster health
just pg-status                  # CloudNativePG cluster status
just test-suite <name>            # cluster, storage, gpu, postgresql, argocd, kafka, ...
```

Only drop to raw `kubectl get/describe/logs` once you know *what* is broken,
or when the just recipes don't cover the resource in question.

## Diagnostic workflow

1. **Initial assessment** — state what you understand about the symptom before touching anything.
2. **Gather information** — `kubectl get <kind> -A -o wide`, `kubectl describe`, `kubectl logs` (`--previous` for crash-looped containers), `kubectl get events --sort-by=.lastTimestamp`.
3. **Analysis** — explain the likely cause in plain terms before proposing an action.
4. **Recommendation** — state the specific command(s) you're about to run and why.
5. **Action** — start with the least intrusive step; escalate only as needed.
6. **Verification** — show the command/output that proves the fix worked (matches this project's `/verify` convention — don't declare success on a diff alone).
7. **Knowledge sharing** — briefly note the underlying Kubernetes concept if it's non-obvious, so the fix is understandable later.

## Safety guardrails

- Prefer read-only inspection (`get`, `describe`, `logs`, `get -o yaml`) before anything that mutates state.
- Before `delete`, `patch`, `scale`, `cordon/drain`, or editing a resource in place: state what you're about to do and why, and — per this session's standing rules — confirm before hard-to-reverse or shared-impact actions rather than assuming approval.
- Least privilege: don't reach for `kubectl exec` into a container when logs/events already answer the question.
- A resource being "stuck" (Terminating, CrashLoopBackOff, stuck finalizer) is a signal to look for *why* before forcing it away — check `kubectl get <kind> <name> -o jsonpath='{.metadata.finalizers}'` and controller logs first (see the kagent-agent-pruning incident in this repo's history for a real example of a controller fighting a deletion).

## Common inspection commands

| Need | Command |
|---|---|
| Resource overview | `kubectl get <kind> -A -o wide` |
| Full detail on one object | `kubectl describe <kind> <name> -n <ns>` |
| Recent cluster events | `kubectl get events -n <ns> --sort-by=.lastTimestamp` |
| Container logs | `kubectl logs <pod> -n <ns> [-c <container>] [--previous]` |
| Raw manifest | `kubectl get <kind> <name> -n <ns> -o yaml` |
| API resources available | `kubectl api-resources` |
| Patch in place | `kubectl patch <kind> <name> -n <ns> --type=merge -p '<json>'` |
| Exec into a container (last resort) | `kubectl exec -it <pod> -n <ns> -- <cmd>` |

## Limitations carried over from the original agent design

The bundled agent explicitly could not touch anything outside the cluster and
had no host filesystem access — those constraints don't apply to a Claude Code
session (which has a shell), so don't self-limit there. What *does* still
apply: this cluster is real shared infrastructure (see root `CLAUDE.md`) —
treat destructive or cluster-wide actions with the same caution the original
prompt asked for.
