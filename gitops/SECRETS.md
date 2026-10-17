# Secrets: Vault on the hub, External Secrets Operator on every cluster

**Status:** the platform is **live** on the hub (`ocp-2qsc5`) and on `ocp-64spr`: Vault runs
on the hub, ESO runs on both, and each cluster has a Ready `vault` ClusterSecretStore.
**No service chart has been migrated yet.** Their secrets are still where they were
(plaintext in `values.yaml`, committed, or `oc create secret` by hand). Migrating them is a
manual, chart-by-chart job; [§5](#5-migrating-a-chart-the-recipe) is the recipe.

Contents

1. [How it fits together](#1-how-it-fits-together)
2. [Vault layout: where a secret goes](#2-vault-layout-where-a-secret-goes)
3. [Operating Vault](#3-operating-vault)
4. [Onboarding a cluster](#4-onboarding-a-cluster)
5. [Migrating a chart: the recipe](#5-migrating-a-chart-the-recipe)
6. [One secret, many consumers](#6-one-secret-many-consumers)
7. [Generated passwords (nobody types them)](#7-generated-passwords-nobody-types-them)
8. [Day 2: change, rotate, restart](#8-day-2-change-rotate-restart)
9. [What to migrate](#9-what-to-migrate)
10. [Troubleshooting](#10-troubleshooting)
11. [Known gaps](#11-known-gaps)

---

## 1. How it fits together

```
 HUB (ocp-2qsc5)                                          REMOTE (ocp-64spr, any MCE)
 ┌───────────────────────────────────────────┐            ┌─────────────────────────────┐
 │ Vault  (Helmfile release `vault`)         │            │ ESO (helm release           │
 │  3 pods, raft, TLS = service-ca cert      │◀─ Route ───│  external-secrets)          │
 │  auth/k8s-hub        auth/k8s-ocp-64spr   │  (public   │  ClusterSecretStore `vault` │
 │  kv/shared/  kv/clusters/<cluster>/       │   cert)    │   → login k8s-<cluster>     │
 │                                           │            │                             │
 │ ESO (Argo app external-secrets)           │── Token ──▶│ (Vault calls TokenReview on │
 │  ClusterSecretStore `vault`               │   Review   │  this cluster's API)        │
 │   → https://vault-active.vault.svc:8200   │            │                             │
 └───────────────────────────────────────────┘            └─────────────────────────────┘
          ExternalSecret ──▶ k8s Secret ──existingSecret / secretKeyRef──▶ pod
```

- **Vault** is the one place secrets are created, versioned, audited and access-controlled.
  It is a Helmfile bootstrap release, not an Argo app: it is stateful, order-sensitive
  (every ClusterSecretStore waits on it), and its init/unseal needs an admin kubeconfig.
  Chart: `charts/vault`. Its postsync hooks are `charts/vault/scripts/init-unseal.sh` and
  `configure.sh`.
- **ESO** runs on every cluster, from the upstream Helm chart (not OLM), vendored at
  `gitops/charts/external-secrets/charts/`. It reads from Vault and writes ordinary
  Kubernetes Secrets. Pods never talk to Vault. The same chart serves every cluster:
  - **hub**: the Argo app `gitops/services/external-secrets/`.
  - **remote clusters**: today a plain `helm install` of the same chart (`ocp-64spr` is a
    test cluster). Pushing it from hub Argo instead is supported and documented in
    [§4](#4-onboarding-a-cluster); only how ESO gets *installed* differs.
- **Login.** Each cluster's ESO logs in at its own `auth/k8s-<cluster>` mount, as SA
  `external-secrets/vault-auth`, with a short-lived token minted for audience `vault`. Vault
  checks that token with the cluster's own TokenReview API, so nothing long-lived is stored
  on either side. The role it gets is the policy `cluster-<cluster>`. On a **remote** cluster
  Vault makes that TokenReview call *with the login token itself*, so the token must also be
  valid for that API server. That is why remote installs set
  `vault.apiServerAudience=https://kubernetes.default.svc` ([§10](#10-troubleshooting)).
- **Why the hub's Argo needed extra RBAC.** OpenShift GitOps cannot write CRDs or webhook
  configurations out of the box. `charts/argocd-rbac` (Helmfile) grants that.

## 2. Vault layout: where a secret goes

All static secrets live in **KV v2 at `kv/`**. KV v2 keeps every version, so you can roll a
value back with `vault kv rollback`.

| Path | Who can read | Use it for |
|---|---|---|
| `kv/shared/<name>` | **every** cluster | something identical everywhere: the DHCP API token, a registry pull secret, a CA bundle |
| `kv/clusters/<cluster>/<service>/<name>` | **only** `<cluster>` | everything else, under the cluster the service runs on. Most hub services: `kv/clusters/hub/segments-manager/mongo` |
| `kv/clusters/<cluster>/generated/<...>` | `<cluster>`, which can also **write** it | values ESO generates and pushes ([§7](#7-generated-passwords-nobody-types-them)) |

One Vault entry holds **several fields** (`user`, `password`, `host`, …). Store a credential
as its parts, not as a ready-made connection string ([§6](#6-one-secret-many-consumers)).

The scope is per cluster, not per namespace: any namespace on a cluster can read that
cluster's whole subtree through the `vault` ClusterSecretStore. That is a deliberate
trade-off for one platform team. If a namespace ever needs to be walled off, give it its
own namespaced `SecretStore` with its own Vault role and policy instead of the cluster-wide store.

## 3. Operating Vault

All commands assume a kubeconfig pointed at the **hub**. Helmfile hooks use the *current*
context, like `apply-oauth.sh`, so make sure it is the hub before syncing.

**Install / upgrade / re-configure** (idempotent; re-run after any change to
`environments/default.yaml` `vault:`):

```bash
helmfile -l name=vault sync      # chart, then init-unseal.sh, then configure.sh
```

**The CLI.** Every Vault pod carries the CLI, already pointed at itself with the right
CA and TLS server name:

```bash
oc exec -it -n vault vault-0 -- sh
export VAULT_TOKEN=...               # see "Root token" below
vault status
vault operator raft list-peers       # expect 1 leader + 2 followers
```

**The UI.** At `https://vault-vault.<hub apps domain>` (Route `vault` in namespace `vault`).

**Root token / unseal keys: LAB MODE.** `environments/default.yaml` sets
`vault.initSecret: vault-init`, so the first sync stored the 5 unseal keys and the root
token in **Secret `vault/vault-init`**. That is what lets the hook unseal unattended, and it
means **anyone who can read that Secret owns Vault**. Fine for a sandbox. For anything
long-lived:

1. Copy `init.json` out of the Secret into your password manager or offline storage, split
   across people.
2. `oc delete secret vault-init -n vault`.
3. Set `vault.initSecret: ""`. From then on the hook never initializes on its own, and
   unsealing needs `VAULT_UNSEAL_KEYS="k1 k2 k3" helmfile -l name=vault sync`.
4. Stop using the root token day to day. Create a human login instead:
   `vault write auth/userpass/users/<you> password=<pw> token_policies=secrets-admin`,
   then `vault token revoke <root>`. You can always mint a new root token with
   `vault operator generate-root` and the unseal keys.

**After a pod restart, Vault comes back SEALED.** The key that decrypts its data lives
only in memory. That happens on a node drain, an OpenShift upgrade, an eviction or an OOM.
A sealed pod is NotReady (503).
- **One pod sealed:** no outage. The other two keep a raft majority, and a new leader is
  elected within seconds.
- **Two or more sealed:** quorum is lost, so every ClusterSecretStore turns not-Ready and ESO
  stops refreshing. **Existing Kubernetes Secrets stay as they are**, so running pods are
  unaffected; only changes stop flowing.

**Auto-unseal sidecar (lab mode).** Each Vault pod carries an `auto-unseal` container
(`charts/vault/values.yaml` `server.extraContainers`). Every 5s it checks its own pod and,
if sealed, submits the threshold keys from the `unseal-keys` field of `vault/vault-init`. It
mounts only that field: no root token, no `init.json`. The Vault container mounts none
of it. Verified on the hub:
- each pod deleted alone came back unsealed and Ready in about 20s;
- deleting two pods at once (quorum lost, the leader included) recovered fully in 26s,
  with all three raft peers back and both clusters' stores Ready again;
- no hook or human was involved in either case.

Watch it with `oc logs -n vault vault-0 -c auto-unseal`.

It changes **nothing** about the security model: the keys were already in that Secret. With
`vault.initSecret: ""` the Secret doesn't exist and the sidecar idles. Unsealing is then
manual again: `VAULT_UNSEAL_KEYS="k1 k2 k3" helmfile -l name=vault sync` (the hook handles
every sealed pod; re-running is always safe). For production air-gapped, replace the
sidecar with a real trust root: **transit** auto-unseal from a small separate Vault, or an
**HSM** (PKCS#11 needs Vault Enterprise; OpenBao has it in the community build). See [§11](#11-known-gaps).

Changing the sidecar block needs each pod **deleted by hand**: the StatefulSet's
`updateStrategy` is `OnDelete`, so a sync alone does not restart anything. Delete them one
at a time; each comes back and unseals itself.

**Why `wait: false`** on the release: a sealed pod is never Ready, and only the postsync
hook unseals it. `helmDefaults.wait` would wait for Ready before running postsync, which
never comes. The hook does its own waiting.

## 4. Onboarding a cluster

Two halves: Vault must know the cluster, and the cluster needs ESO. Vault's side is always
the same. ESO can be installed by hand (what `ocp-64spr` uses) or pushed by hub Argo.

1. **Tell Vault about it.** Add an entry to `environments/default.yaml` `vault.clusters`:
   ```yaml
   - name: <name>                      # = auth/k8s-<name>, policy cluster-<name>
     host: https://api.<cluster>:6443
     caCert: |                         # public: the CA that signs that URL's cert
       -----BEGIN CERTIFICATE-----     # on OpenShift: kube-apiserver-lb-signer from
       ...                             #   oc get cm -n openshift-kube-apiserver kube-apiserver-server-ca
   ```
   Then `helmfile -l name=vault sync` against the hub. Vault must be able to reach that
   API URL (it calls TokenReview there).
2. **Install ESO on it**, using one of the two ways below.
3. **Prove it**: `charts/vault/scripts/smoke-test.sh <hub-ctx> <cluster-ctx> <name> hub`.
   All 7 checks must pass, including that it is **denied** the hub's subtree.

The values every remote install needs (the same in both ways):

| Value | Why |
|---|---|
| `clusterName=<name>` | selects `auth/k8s-<name>` and policy `cluster-<name>`; must equal the `vault.clusters` entry |
| `vault.server=https://vault-vault.<hub apps domain>` | the hub Vault Route |
| `vault.caConfigMap=` (empty) | the hub's ingress cert is publicly trusted. If it isn't, create a ConfigMap with its CA in `external-secrets` and name it here |
| `vault.apiServerAudience=https://kubernetes.default.svc` | **required on remote clusters**, or every login is a 403 ([§10](#10-troubleshooting)) |

### 2a. By hand with Helm (current, `ocp-64spr`)

Two steps, because one Helm install cannot both create the CRDs and a ClusterSecretStore
of that new kind ("no matches for kind"):

```bash
H=(--kube-context <cluster-ctx> -n external-secrets
   --set clusterName=<name>
   --set vault.server=https://vault-vault.apps.cluster-2qsc5.2qsc5.sandbox5410.opentlc.com
   --set vault.caConfigMap=
   --set vault.apiServerAudience=https://kubernetes.default.svc)
helm upgrade --install external-secrets gitops/charts/external-secrets "${H[@]}" \
  --create-namespace --set vault.createClusterSecretStore=false --wait   # 1. operator + CRDs
helm upgrade external-secrets gitops/charts/external-secrets "${H[@]}"    # 2. + the store
```

Upgrading ESO later is the second command again. Nothing reconciles it, so drift and
upgrades are on you. That is the price of keeping it outside Argo.

### 2b. Pushed by hub Argo (the GitOps way)

1. Register the cluster: `scripts/register-argo-cluster.sh <hub-ctx> <cluster-ctx> <name>`
   (creates `argocd-manager`, cluster-admin, on the cluster, and the hub's cluster Secret).
2. Add `gitops/services/external-secrets-<name>/app.yaml`:
   ```yaml
   namespace: external-secrets
   destination:
     cluster: <name>
   overrides:
     spec:
       source:
         path: gitops/charts/external-secrets
         helm:
           releaseName: external-secrets
           parameters:
             - { name: clusterName, value: <name> }
             - { name: vault.server, value: "https://vault-vault.<hub apps domain>" }
             - { name: vault.caConfigMap, value: "" }
             - { name: vault.apiServerAudience, value: "https://kubernetes.default.svc" }
       syncPolicy:
         syncOptions: [ServerSideApply=true, RespectIgnoreDifferences=true, CreateNamespace=true]
       ignoreDifferences:   # same block as gitops/services/external-secrets/app.yaml
         - { group: admissionregistration.k8s.io, kind: ValidatingWebhookConfiguration, jqPathExpressions: [".webhooks[]?.clientConfig.caBundle"] }
         - { kind: Secret, name: external-secrets-webhook, jsonPointers: [/data] }
   ```
3. Push, then **restart the applicationset-controller pod** (it caches the git generator).

Two things learned on `ocp-64spr` before it moved to 2a:
- **Registering a cluster is not scoped to this repo.** Every hub ApplicationSet with a
  `clusters: {}` generator picks it up within minutes. Today those are the day-2
  `falcon-/lynx-/orca-app-projects` sets, which put three AppProjects into the new cluster's
  `openshift-gitops`. Check `oc get applications -n openshift-gitops | grep <name>`.
- **The first sync waits for hub Argo to cache the whole remote cluster.** On a cluster with
  ODF + CNV that was still not done after several minutes, and the app showed `Unknown`
  the whole time, with no error.
- **Unregistering:** delete the hub Secret `cluster-<name>`. The generated apps then cannot
  cascade into a cluster Argo no longer knows, so clear their finalizers (after checking
  what they own) and delete the leftovers by hand.

## 5. Migrating a chart: the recipe

The goal is that **only the value lives in Vault, and the chart wiring changes once**. The
Deployment does not change at all: the `ExternalSecret` creates a Secret with **the same
name and keys** that `templates/secret.yaml` creates today.

### 5.1 Put the value in Vault (once per secret)

```bash
vault kv put kv/clusters/hub/segments-manager/mongo user=segments_manager password='…'
```

Or use the UI. This is the one manual step, and it happens once per secret and once per
rotation, not once per deploy.

### 5.2 Give the chart a mode switch

Replace the body of `templates/secret.yaml` with three modes, so local/kind installs keep
working without Vault:

```yaml
# values.yaml
secrets:
  # inline   — render a Secret from the values below (local dev / kind only)
  # external — render an ExternalSecret that pulls from Vault (every real cluster)
  # existing — render nothing; a Secret named `name` already exists
  mode: external
  name: segments-manager-mongodb        # the Secret name the Deployment already uses
  vaultPath: clusters/hub/segments-manager/mongo
  refreshInterval: 1h
  inline: {}                            # only read when mode: inline
```

```yaml
# templates/secret.yaml
{{- if eq .Values.secrets.mode "inline" }}
apiVersion: v1
kind: Secret
metadata:
  name: {{ .Values.secrets.name }}
type: Opaque
stringData:
  {{- toYaml .Values.secrets.inline | nindent 2 }}
{{- else if eq .Values.secrets.mode "external" }}
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: {{ .Values.secrets.name }}
spec:
  refreshInterval: {{ .Values.secrets.refreshInterval }}
  secretStoreRef:
    kind: ClusterSecretStore
    name: vault
  target:
    name: {{ .Values.secrets.name }}
    creationPolicy: Owner
  dataFrom:
    - extract:
        key: {{ .Values.secrets.vaultPath }}   # every field in the Vault entry becomes a key
{{- end }}
```

`dataFrom.extract` copies every field of the Vault entry as a key, so the Vault field names
must match the keys the Deployment reads. If they don't, or you need only some fields, use
`data:` with explicit `secretKey` → `remoteRef: { key, property }` pairs. To build one value
out of several fields, see [§6](#6-one-secret-many-consumers).

### 5.3 Cut over (per chart, in this order)

1. Put the value in Vault (5.1).
2. **Check who owns the existing Secret, and diff its keys against Vault**:
   `oc get secret <name> -n <ns> -o json | jq '{keys: (.data|keys), owner: .metadata.ownerReferences, labels: .metadata.labels}'`.
   - **Created by `oc create secret`** (no owner): ESO's `creationPolicy: Owner` **adopts it
     silently and REPLACES its whole `data`**. Every key not in the ExternalSecret is gone,
     with no error and no warning. Verified on ESO 2.11: a hand-made Secret with `value` +
     `extra` came out with only `value`, status `SecretSynced`. So, before the first sync,
     make sure the Vault entry carries **every key** the existing Secret has. If you are
     unsure, use `creationPolicy: Merge` for the first sync: ESO then only writes its own
     keys and leaves the rest. Diff, then switch to `Owner`.
   - **Rendered by the chart today** (Argo/Helm owns it): switching `templates/secret.yaml`
     to the ExternalSecret in **one commit** is correct. Argo prunes its Secret and ESO
     creates the new one within seconds. Expect a short window where the Secret is missing;
     pods that are already running keep their env.
3. Dry-run as usual (CLAUDE.md "Verifying a chart before pushing"):
   `helm template <svc> gitops/charts/<svc> -n <ns> | oc apply --dry-run=server -f -`.
4. Push, then confirm `oc get externalsecret -n <ns>` shows `SecretSynced` and the Secret
   has the keys you expect.
5. **Delete the plaintext** from `values.yaml` / `environments/default.yaml`.
6. **Rotate anything that was ever committed.** git history is permanent, so moving the
   value is not enough: change it in Vault *and* in the system it protects ([§8](#8-day-2-change-rotate-restart)).

## 6. One secret, many consumers

Several apps in different namespaces need the same Mongo credential.

- **Store it once, as parts**: `kv/clusters/hub/segments-manager/mongo` with `user`,
  `password`, `host`, `port`, `db`. Rotate in one place.
- **A Kubernetes copy per namespace is unavoidable**, because a pod can only read Secrets
  from its own namespace. Those copies are *derived* from Vault, not maintained, so they are
  not real duplication.
- **Each app builds the format it needs** with `target.template`:

  ```yaml
  target:
    name: segments-manager-mongodb
    template:
      data:
        mongodb-url: "mongodb://{{ .user }}:{{ .password }}@{{ .host }}:{{ .port }}/{{ .db }}?authSource={{ .db }}"
  dataFrom:
    - extract:
        key: clusters/hub/segments-manager/mongo
  ```

  Another app can read the same entry as plain `MONGO_USER`/`MONGO_PASSWORD` with `data:`.
  This replaces the hand-synced password in `gitops/charts/segments-manager/values.yaml`
  `mongodb.url` + `environments/default.yaml` `segmentsManagerMongodb.password`.

Which object to use:

| Situation | Use |
|---|---|
| The format is app-specific (the usual case) | `ExternalSecret` **in the app's own chart**, so the app owns its Secret |
| The Secret is identical in many namespaces | one `ClusterExternalSecret` with a `namespaceSelectors` label, in a platform chart |
| The value is needed on several **clusters** | put it under `kv/shared/`, and each cluster's own ExternalSecret reads it |

Default to per-app ExternalSecrets. A ClusterExternalSecret depends on namespace labels
being right, and when one is missing the Secret simply never appears in that namespace.

## 7. Generated passwords (nobody types them)

For a password no human needs to know (an app-to-DB password, say), let ESO generate it and
push it to Vault. Every other consumer then reads it back like any other secret:

```yaml
apiVersion: generators.external-secrets.io/v1alpha1
kind: Password
metadata: { name: mongo-app-password }
spec: { length: 32, digits: 5, symbols: 0, noUpper: false, allowRepeat: true }
---
apiVersion: external-secrets.io/v1alpha1
kind: PushSecret
metadata: { name: mongo-app-password }
spec:
  refreshInterval: 1h
  updatePolicy: IfNotExists          # generate ONCE; Replace would re-roll it every refresh
  deletionPolicy: None               # keep the value in Vault if this object goes away
  secretStoreRefs: [{ kind: ClusterSecretStore, name: vault }]
  selector:
    generatorRef: { apiVersion: generators.external-secrets.io/v1alpha1, kind: Password, name: mongo-app-password }
  data:
    - match:
        secretKey: password
        remoteRef: { remoteKey: clusters/hub/generated/segments-manager-mongo, property: password }
```

A cluster can write only under its own `kv/clusters/<cluster>/generated/`. The smoke test
exercises this path.

## 8. Day 2: change, rotate, restart

| Task | How |
|---|---|
| Change a value | `vault kv put` (replace) or `vault kv patch` (one field), or the UI |
| Get it into the cluster now | wait `refreshInterval`, or `oc annotate externalsecret <n> -n <ns> force-sync=$(date +%s) --overwrite` |
| Undo a change | `vault kv rollback -version=<n> kv/<path>` |
| Who read/changed what | the `stdout` audit device: `oc logs -n vault vault-0 \| grep '"path":"kv/data/…'` |

**Pods don't restart when a Secret changes.** Env vars are read once at start; mounted files
update in place after about a minute. So either:

- the app re-reads the mounted file, or
- add [Stakater Reloader](https://github.com/stakater/Reloader) and annotate the Deployment
  `secret.reloader.stakater.com/reload: "<secret>"`. It isn't installed; add it to
  `gitops/charts/external-secrets` as a dependency when the first chart needs it, or
- `oc rollout restart deploy/<x>` by hand.

**Rotating a database password needs two changes.** Changing it in Vault only changes
what *clients* send. The Bitnami charts set the password inside the DB **only on first
init**, so the database still expects the old one, and every client then fails to log in.
The order is:

1. Change it in the database (`db.changeUserPassword(...)` / `ALTER USER ... PASSWORD ...`).
2. Change it in Vault.
3. Force-sync and restart the clients.

The same applies to any credential checked by another system (an API token is checked by
its API server, and so on).

## 9. What to migrate

A starting list, **not** the full inventory:

| Secret | Today | Notes |
|---|---|---|
| `temporal` Postgres password | `gitops/charts/temporal/values.yaml` `postgresql.auth.postgresPassword` (plaintext) | Bitnami subchart reads `auth.existingSecret` |
| segments-manager Mongo root + app password | `environments/default.yaml` `segmentsManagerMongodb` (Helmfile) | DB side: Bitnami `auth.existingSecret`. App side: compose the URL ([§6](#6-one-secret-many-consumers)); the chart supports `mongodb.existingSecret` |
| `segments-manager-token` | `oc create secret` in `redbull-workflows` | segment-lifecycle-worker reads it via `secrets.existingSecret` |
| `kubevirt-redfish-secret` (`config.yaml`) | `oc create secret` in `kubevirt-redfish` | chart mounts `config.existingSecret` |
| `dhcp-scope-manager-token` (`api-token`) | **committed**: `gitops/charts/dhcp-scope-manager/charts/dhcp-api-token/values.yaml` (public repo) | → `kv/shared/dhcp-api-token`; it is consumed on the hub *and* every MCE. **Rotate.** The air-gapped copy holds a different value; never sync it across |
| `dhcp-api-token` (`DHCP_API_TOKEN`) | `oc create secret` in `redbull-workflows`, a *copy* of the above | read the same `kv/shared/dhcp-api-token`; one rotation then covers both |
| `htpasswdIdp.users[].password` | `environments/default.yaml` | stays Helmfile; switch to `requiredEnv` or a Vault lookup so it leaves git |

To find the rest:

```bash
grep -rln "kind: Secret" gitops/charts/*/templates charts/*/templates
grep -rnE "password|token|secret|apiKey" gitops/charts/*/values.yaml environments/default.yaml
oc get secret -A -o json | jq -r '.items[] | select(.type=="Opaque") | select(.metadata.ownerReferences==null) | "\(.metadata.namespace)/\(.metadata.name)"'   # hand-made ones
```

## 10. Troubleshooting

Start with `oc get clustersecretstore vault -o yaml` (the condition message) and
`oc get externalsecret -A`, then the ESO controller log
(`oc logs -n external-secrets deploy/external-secrets`), which carries Vault's error.

| Symptom | Cause | Fix |
|---|---|---|
| **remote** store not Ready, `unable to create client`, log: `403 permission denied` on `auth/k8s-<c>/login` | the login token has only audience `vault`. Vault reviews it *with itself* as bearer, and the remote API server answers that review with 401 | `vault.apiServerAudience=https://kubernetes.default.svc`. To confirm: `oc create token vault-auth -n external-secrets --audience vault`, then POST a TokenReview with it as bearer → `401` |
| store not Ready, `permission denied` on `auth/k8s-<c>/login` (hub, or with the audience set) | role binds a different SA/namespace, or audience mismatch | SA must be `external-secrets/vault-auth`, audience `vault` (chart values must match `vault.eso` in `environments/default.yaml`) |
| store not Ready, `service account name not authorized` | same as above | same |
| store not Ready on a remote cluster, TokenReview errors / `x509` from Vault | wrong `caCert` or `host` in `vault.clusters`, or Vault can't reach that API | fix the entry and re-sync `vault`; the CA must sign the *external* API cert (lb-signer) |
| store not Ready, `x509: certificate signed by unknown authority` from ESO | ESO doesn't trust Vault's cert | hub: `vault.caConfigMap: openshift-service-ca.crt`; remote: the hub ingress CA, unless it's publicly trusted |
| store not Ready, `503` / `Vault is sealed` | a Vault pod restarted | `helmfile -l name=vault sync` ([§3](#3-operating-vault)) |
| ExternalSecret `SecretSyncedError`, `403` | path outside the cluster's policy (`kv/shared/`, own `kv/clusters/<c>/`) | move the secret, or fix `remoteRef.key`. **The key has no `kv/` prefix**: the store adds it |
| app breaks right after cut-over, Secret `SecretSynced` but a key is missing | `creationPolicy: Owner` took over a hand-made Secret and replaced its data | add the key to the Vault entry and force-sync; [§5.3](#53-cut-over-per-chart-in-this-order) step 2 |
| external-secrets app `OutOfSync` on the hub, `cannot patch customresourcedefinitions` | `argocd-rbac` release missing | `helmfile -l name=argocd-rbac sync` |
| ESO webhook `CrashLoopBackOff` (`/tmp/certs/tls.crt: no such file`) right after install | it started before the cert-controller wrote its cert | `oc rollout restart deploy/external-secrets-webhook deploy/external-secrets-cert-controller -n external-secrets` |

## 11. Known gaps

- **Lab-mode keys.** The unseal keys and root token are in `vault/vault-init` ([§3](#3-operating-vault)),
  and the auto-unseal sidecar depends on them being there. Anyone who can read that Secret,
  or an etcd backup, can unseal Vault and read everything. At minimum for production: etcd
  encryption on, the root token removed from the Secret, tight RBAC on `vault`. Better:
  replace the sidecar with transit auto-unseal (a second small Vault) or an HSM.
- **No SSO for humans.** The `secrets-admin` policy exists, and the userpass mount has no
  users. OpenShift OAuth → Vault OIDC is the natural next step.
- **No Reloader yet** ([§8](#8-day-2-change-rotate-restart)).
- **No backup.** Take raft snapshots with `vault operator raft snapshot save`; a CronJob that
  writes them to object storage is the usual shape. Losing all three PVCs loses every secret.
- **Air-gapped.** Mirror `registry.connect.redhat.com/hashicorp/vault:2.0.4-ubi` and
  `ghcr.io/external-secrets/external-secrets:v2.11.0`, and point `charts/vault`'s Helmfile
  repo at the internal chart mirror. Everything else is a URL: Vault's Route host in each
  remote `app.yaml`, and the cluster list in `environments/default.yaml`.
