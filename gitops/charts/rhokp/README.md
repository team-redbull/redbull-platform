# rhokp-chart

> This chart is deployed by the `redbull-services` ApplicationSet from this repo
> (`gitops/services/rhokp/app.yaml`). Its `values.yaml` here is the single source of
> truth for the running configuration — no other values file is layered on top.


Helm chart to deploy [Red Hat Offline Knowledge Portal](https://access.redhat.com/products/red-hat-offline-knowledge-portal/) (RHOKP) on OpenShift, managed via ArgoCD.

RHOKP is an offline mirror of Red Hat's Knowledgebase, docs, CVEs and errata, shipped as a single container image. It's an add-on to a Red Hat Satellite subscription. This chart follows the official install/deploy steps:

- [Deploying RHOKP on OpenShift](https://developers.redhat.com/articles/2025/10/03/how-deploy-offline-knowledge-portal-openshift)
- [Installing RHOKP locally](https://developers.redhat.com/articles/2025/08/13/how-install-offline-knowledge-portal-local-system)
- [Red Hat Offline Knowledge Portal User Guide](https://docs.redhat.com/en/documentation/red_hat_offline_knowledge_portal/1)

## Prerequisites

1. Active Red Hat Satellite subscription with the RHOKP add-on.
2. Red Hat Customer Portal credentials, and an access key from the RHOKP Access Key Generator.
3. `registry.redhat.io` pull credentials (image is ~12GB: `registry.redhat.io/offline-knowledge-portal/rhokp-rhel9:latest`). For disconnected clusters, mirror the image to your private registry first (`podman pull` → `podman save` → transfer via jump host → `podman load`/push).
4. An OpenShift cluster with cluster-admin access, and ArgoCD (e.g. OpenShift GitOps) installed.

## Setup

The chart generates both required Secrets itself from `values.yaml`, so ArgoCD
sync alone is enough — no manual `oc create secret` steps needed:

```yaml
imagePullSecret:
  name: redhat-registry-secret
  dockerServer: registry.redhat.io
  dockerUsername: <rhn-support-user>
  dockerPassword: <password>

accessKey:
  secretName: rhokp-access-key
  secretKey: access-key
  secretValue: <YOUR_ACCESS_KEY>
```

> These credentials land in `values.yaml` in plaintext. Only do this if the
> Git repo/cluster is private and you accept that tradeoff — otherwise keep
> credentials out of Git (e.g. Sealed Secrets, External Secrets) and leave
> `dockerPassword`/`secretValue` empty; the chart skips creating the Secret
> when the corresponding password/value is unset, so you can still supply
> pre-created Secrets under the same names.

## Deploy via ArgoCD

Edit `values.yaml` in this repo directly (ArgoCD reads it straight from Git —
no per-environment overrides), commit, then create the Application:

```bash
oc apply -f argocd/application.yaml
```

Sync is manual (`syncPolicy` has no `automated` block — no auto-sync, prune,
or self-heal), so trigger it yourself after applying:

```bash
argocd app sync rhokp
```

## Key values

| Value                            | Default                                           | Notes                                                                                        |
| -------------------------------- | ------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| `image.repository` / `image.tag` | `offline-knowledge-portal/rhokp-rhel9` / `latest` | Official image path                                                                          |
| `accessKey.secretValue`          | `""`                                              | RHOKP access key; chart creates the Secret when set                                          |
| `imagePullSecret.dockerPassword` | `""`                                              | `registry.redhat.io` password; chart creates the pull Secret when set                        |
| `route.enabled`                  | `true`                                            | OpenShift Route; disable for an internal-only (ClusterIP-only) deployment                    |
| `resources`                      | 500m/1Gi requests, 2/4Gi limits                   | Not published by Red Hat — tune to your traffic                                              |

## Sync ordering

Resources carry `argocd.argoproj.io/sync-wave` annotations so one `argocd app
sync` brings the app up in the right order: Secrets/ServiceAccount (wave 0) →
Service/Deployment (wave 1) → Route (wave 2). This is still a single sync
operation — waves are ordered phases within it, not separate syncs — ArgoCD
just waits for each wave to be applied before starting the next.

See `values.yaml` for the full list.
