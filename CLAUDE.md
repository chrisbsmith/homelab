# Homelab

Personal single-node Kubernetes cluster managed by Flux GitOps. Based on onedr0p's cluster-template (k3s era); conventions loosely track github.com/onedr0p/home-ops.

## Working rules

- Make changes but **don't commit or push unless asked**. The user reviews and commits.
- Treat the live cluster as read-only unless told otherwise. Fix things in git; Flux applies them. One-off cluster operations (chown a volume, delete a pod, force a reconcile) need a go-ahead first.

## Cluster access

- Single node running k3s with Cilium as the CNI. A node reboot restarts everything at once.
- k3s is a hand-managed binary (no installer or config management); embedded etcd with scheduled snapshots. Upgrade one minor at a time: check Cilium supports the target Kubernetes version, take an etcd snapshot, verify the binary against the release checksums, keep the old binary for rollback, stop k3s, swap the binary, start. Running containers survive the restart.
- Kubeconfig is the repo's gitignored `./kubeconfig`. mise sets `KUBECONFIG` automatically **only inside the repo**; commands run from another directory fail with a missing-context error. Use an absolute `--kubeconfig` or run from the repo root.
- Distroless images have no shell/`ls`/`id`; inspect with `kubectl debug <pod> --target=<container> --image=busybox --profile=general` and look under `/proc/1/root/...`.

## Layout

- `kubernetes/flux/cluster/ks.yaml` is the root; it walks `kubernetes/apps/<namespace>/`.
- Each app: `kubernetes/apps/<namespace>/<app>/ks.yaml` (Flux Kustomization) + `app/` (`helmrelease.yaml`, `ocirepository.yaml`, `externalsecret.yaml`, `kustomization.yaml`). New apps must also be listed in the namespace's `kustomization.yaml`.
- `kubernetes/components/defaults` patches HelmReleases (install retries `-1`, upgrade retries `3`, `cleanupOnFail`) and adds `postBuild.substituteFrom: cluster-secrets`. `${SECRET_DOMAIN}` etc. come from that Secret. It only applies when the app's `ks.yaml` lists it under `spec.components` (or the HelmRelease sets its own `install`/`upgrade` remediation); without it, a single failed upgrade stalls the release with `RetriesExceeded`.
- Charts come from per-app `OCIRepository` sources (`chartRef`): upstream charts for infrastructure, bjw-s `app-template` for self-hosted apps.
- Secrets: `ExternalSecret` → `ClusterSecretStore` `onepassword` (1Password Connect). Never put secret values in git.
- `bootstrap/` holds the initial-install charts (cilium, coredns, external-secrets, …) and is still kept current by Renovate.

## Validation (flate)

- `task flux:test` → `flate test all`; `task flux:diff` → `flate diff all --base origin/main`. flate is pinned in `.mise.toml`.
- CI (`.github/workflows/flate.yaml`): `Flate - Test` is the blocking check. The diff job only comments on the PR and warns, because a broken `main` would otherwise block the PR that fixes it. `Flate - Image Check` fails if an image tag doesn't exist.
- Renovate opens most PRs. Pin images and actions as `tag@sha256:…` / `@<sha> # vX.Y.Z` to match existing files.

## Known gotchas

- **Chart mirrors disappear.** `ghcr.io/home-operations/charts-mirror/*` paths have started returning 403 (cilium and openebs did in Oct 2026). Prefer upstream OCI registries; check with `crane manifest <ref>`.
- **Storage `synology-csi-iscsi-retain`:** the CSI driver applies `fsGroup` only when the PV has `spec.csi.fsType` set. Older PVs have it empty, so `fsGroup` silently does nothing and non-root pods need a one-time chown of the volume. `fsType` is immutable on existing PVs.
- iSCSI volumes have thrown `input/output error` around node reboots; check `journalctl -k` on the node before blaming the app.
- **Non-root pods:** use pod-level `securityContext` (`runAsNonRoot`, `runAsUser/Group`, `fsGroup`, `fsGroupChangePolicy: OnRootMismatch`), as in `services/records` and `services/atuin`.
- **Grafana** first start on a fresh DB runs ~690 migrations (several minutes on this disk); its HelmRelease `timeout` is `10m` for that reason. A HelmRelease stuck in `RetriesExceeded` needs `flux reconcile hr <name> -n <ns> --force` after the fix.
- **Gatus** is deployed by the home-operations `gatus-sidecar` chart (`observability/gatus-sidecar`, needs Kubernetes >= 1.34); the sidecar discovers HTTPRoutes. Per-route control via annotations `gatus.home-operations.com/enabled` / `gatus.home-operations.com/endpoint`. Its generated config ConfigMap must be named `gatus-sidecar-configmap` to match the HelmRelease.
- **No Grafana Operator.** Grafana is the plain Helm chart: add dashboards to its `dashboards.default` list (or ConfigMaps labelled `grafana_dashboard`), never `GrafanaDashboard` CRs copied from other repos.
