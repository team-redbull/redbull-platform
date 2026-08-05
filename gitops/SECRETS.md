# Secrets management for the Argo CD service layer (ESO + Vault) — design, not yet wired

**Status:** Vault is **not deployed yet**. Today secrets stay exactly as they were under
Helmfile — dev credentials are plaintext in the per-service `values.yaml`, and the
Segments Manager API token is created out-of-band with `oc create secret`. This file is
the plan a future session follows to move them into HashiCorp Vault via the External
Secrets Operator (ESO), **without re-deriving anything**. Read it end-to-end before
wiring ESO.

## Target design

```
Vault  ──(ClusterSecretStore)──▶  ESO  ──writes──▶  k8s Secret  ──existingSecret──▶  chart
```

1. Deploy ESO + a Vault `ClusterSecretStore` in the **bootstrap Helmfile** (same layer
   as crossplane/htpasswd-idp — it must exist before any app that references an
   `ExternalSecret`). Not an Argo app; it's platform bootstrap.
2. Add a small `platform-secrets` chart (its own repo in the helm-charts group, one Argo
   app, early — nothing depends on it being a *late* wave, but the app's Secrets must
   exist before the consuming app's pods start; rely on `retry`/`selfHeal`). It templates
   one `ExternalSecret` per secret below.
3. Charts consume the resulting k8s Secrets via **`existingSecret`** — a pattern the
   platform already uses (`database.existingSecret`, `secrets.existingSecret`), so **no
   chart changes** for most of the inventory. The one exception is the Mongo URL (below).

## Inventory to migrate

| Secret today | Where it lives now | ExternalSecret target |
|---|---|---|
| `temporalPostgresql.password` | `gitops/services/dev/temporal/values.yaml` → `postgresql.auth.postgresPassword` (plaintext) | Secret the bundled PostgreSQL subchart reads (`auth.existingSecret`) |
| `segmentsManagerMongodb.{rootPassword,password}` | `environments/default.yaml` (Helmfile mongodb release) | Secret the Bitnami mongodb chart reads (`auth.existingSecret`) |
| `segments-manager-token` (`SEGMENTS_MANAGER_API_TOKEN`) | `oc create secret` out-of-band in `redbull-workflows` | `ExternalSecret` → same Secret name; segment-lifecycle-worker already reads it via `secrets.existingSecret` |
| `htpasswdIdp.users[].password` | `environments/default.yaml` (Helmfile htpasswd-idp) | stays in the bootstrap Helmfile — switch to `requiredEnv`/Vault-pull so it leaves git |

## The non-obvious one — segments-manager Mongo URL

`gitops/services/dev/segments-manager/values.yaml` sets `mongodb.url` as a **connection
string with the password interpolated inline**:

```
mongodb://segments_manager:<PASSWORD>@segments-mongodb.segments-manager.svc.cluster.local:27017/segments_manager?authSource=segments_manager
```

That whole string cannot live in a git-tracked values file once the password is a
secret. Two-part fix:

1. **ESO composes the full URL** from Vault fields using `spec.target.template`, e.g.:
   ```yaml
   target:
     name: segments-manager-mongodb
     template:
       data:
         mongodb-url: "mongodb://{{ .user }}:{{ .password }}@segments-mongodb.segments-manager.svc.cluster.local:27017/segments_manager?authSource=segments_manager"
   ```
2. **The segments-manager chart must read the URL from the Secret** (`existingSecret` /
   env-from-secret) instead of taking `mongodb.url` as a plain value — a **small chart
   change in `helm-charts-segments-manager`**. Track it as part of this migration; it is
   the only chart edit ESO requires.

## When wiring this, also

- Remove the plaintext values from `gitops/services/dev/*/values.yaml` and
  `environments/default.yaml` once the `ExternalSecret`s are proven to populate the
  Secrets.
- The air-gapped env uses its own Vault; only the `ClusterSecretStore` address differs
  (same one-axis story as the git host — see README).
