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
