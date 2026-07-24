# Standard app installs stay in this monorepo; separate repos are only for custom build/CI

While planning the Jellyfin deployment (ops-microk8s#116), we initially created a
separate `jconlon/jellyfin` repo before realizing every existing app followed one of
two different patterns and Jellyfin was being fit to the wrong one.

**Decision**: an app's GitOps manifests live inside this repo (`ops-microk8s`), following
the `rssbridge-gitops`/`wallabag-gitops` pattern, *unless* the app has custom code with
its own build/CI pipeline (e.g. `freshrss`'s Kafka streams pipeline, which owns image
builds and a Harbor project) — those legitimately own a separate repo with their own
ArgoCD app-of-apps (`argo/root-app.yaml`). A plain Helm-chart or raw-manifest install of
a third-party app is not sufficient reason for its own repo; it just adds ArgoCD/repo
surface area with nothing to build. The `jconlon/jellyfin` repo was archived once this
was recognized.
