# k8s/

Kubernetes manifests land here in later phases — intentionally empty in Phase 0.

- **Phase 1:** ArgoCD app-of-apps (`argocd/`), base Deployments/Services for
  api, worker, web.
- **Phase 3:** Flagger `Canary` resources + Linkerd mesh config for progressive
  delivery with automatic rollback.
- **Phase 4:** ServiceMonitors / PodMonitors for the observability stack.

Nothing is applied by hand: from Phase 1 on, ArgoCD syncs this directory and
Git is the single source of truth for the cluster.
