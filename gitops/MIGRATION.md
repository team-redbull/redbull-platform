# Helmfile → Argo CD migration — remaining external steps

The `redbull-platform` repo changes are done (reduced Helmfile, `gitops/` scaffold,
`namespaces` label, trimmed values, docs). The steps below happen **outside this repo**
(other GitHub repos, CI, the cluster) and need the `REDBULL_WRITE_TOKEN` PAT + org/cluster
access. Do them in order — step 2 must precede deleting code-repo chart folders, or image
bumps break silently.

## 0. Create the PAT (you)

Fine-grained PAT named **`REDBULL_WRITE_TOKEN`** — **Contents: Read and write** on the
`helm-charts-*` repos (or all `team-redbull`). Store as an **organization** Actions
secret. (The `GITHUB_` prefix is reserved, hence `REDBULL_`.)

## 1. Create the four `helm-charts-*` repos, chart at repo root

```sh
# temporal: RENAME the existing repo in place (keeps history) — this IS the extraction
gh repo rename helm-charts-temporal --repo team-redbull/temporal-stack   # needs org admin

# the other three: new repos, copy the chart from the code repo, chart at root
for s in segments-manager workflows segment-connectivity; do
  gh repo create team-redbull/helm-charts-$s --private
done
# segments-manager: copy segments-manager/deploy/helm/* → helm-charts-segments-manager/
# workflows:        copy workflows/helm/workflows/*      → helm-charts-workflows/
# segment-connectivity: copy workflows/helm/segment-connectivity/* → helm-charts-segment-connectivity/
# then in each: git add/commit, and `git tag v0.1.0 && git push --tags`
```

The `revision:` in each `gitops/services/<env>/<svc>/app.yaml` is a **branch** (`main` =
latest prod), not a tag — so a fresh chart repo just needs its `main` branch populated;
Argo tracks that branch's HEAD. (A `v0.1.0` tag is still worth pushing as the image-version
counter's starting point, but no app pins it.) See README "Chart versions are branches".

## 2. Build the COMBINED temporal chart (`helm-charts-temporal`)

Fold the old `charts/temporal-postgresql` (Bitnami PostgreSQL wrapper) into
`helm-charts-temporal` as a **subchart dependency**, and wire sync waves (see CLAUDE.md
"Exception under Argo CD"):

- PostgreSQL subchart → sync-wave `"0"` (default).
- Schema Job → **Argo Sync hook** `argocd.argoproj.io/hook: Sync`,
  `argocd.argoproj.io/sync-wave: "1"`, `argocd.argoproj.io/hook-delete-policy:
  BeforeHookCreation`. **Remove** its Helm `pre-install`/`pre-upgrade` hook annotations —
  Argo maps those to PreSync (runs before Postgres) and reintroduces the deadlock.
- Server/frontend/UI → sync-wave `"2"`.
- Confirm `gitops/services/dev/temporal/values.yaml` keys (`postgresql.*`,
  `database.host`) match the combined chart's `_helpers`/subchart service names.

Once built, the local `charts/temporal-postgresql/` in this repo is dead — delete it.

## 3. Wire cross-repo chart bumps into `ghcr-build-push.yml`

In `team-redbull/.github`:

- Add a `chart-repo` input; use `secrets.REDBULL_WRITE_TOKEN`.
- `actions/checkout` the chart repo (`repository: team-redbull/helm-charts-<name>`,
  `token: ${{ secrets.REDBULL_WRITE_TOKEN }}`), bump `helm-image-path`, commit, `git tag`.
- Update callers (`workflows/.github/workflows/build.yml` — currently
  `helm-values-path: helm/workflows/values.yaml`, etc. — and the segments-manager caller)
  to pass `chart-repo` + the secret.

## 4. Delete the now-orphaned chart folders from the CODE repos

**Only after step 3 works** (bumps land in the new repos):

```
segments-manager:  rm -r deploy/helm
workflows:         rm -r helm/workflows helm/segment-connectivity   # KEEP helm/mock-segment-connectivity
```

## 5. Bootstrap + cluster apply (Argo CD already in `user1-argocd`)

```sh
# bootstrap layer (creates + labels namespaces, DBs, mock, crossplane, htpasswd)
helmfile sync

# confirm the namespaced GitOps instance's managed-by label landed
oc get ns temporal segments-manager redbull-workflows \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.labels.argocd\.argoproj\.io/managed-by}{"\n"}{end}'

# register a repo credential covering the whole group (URL prefix), in user1-argocd:
#   argocd repocreds add https://github.com/team-redbull/ --username <user> --password <token>
#   (or an equivalent Secret labeled argocd.argoproj.io/secret-type: repo-creds)

oc apply -f gitops/project.yaml
oc apply -f gitops/appset.yaml
```

Bring apps up with `automated` **off** first (edit the app or the ApplicationSet), verify
each diff, then enable `prune`/`selfHeal`. Order: `temporal` → `segments-manager` →
`workflows` → `segment-connectivity`.

## 6. Verify

- `argocd app manifests dev-temporal` vs the old split
  (`helmfile -l name=temporal-stack -l name=temporal-postgresql template` on the
  pre-migration commit) — expect only Argo tracking labels + wave annotations to differ.
- `kubectl get applications -n user1-argocd` → the 4 apps, Healthy/Synced.
- Temporal: Postgres Healthy → schema Job → server (no `schema_version does not exist`).
- E2E: create a segment → POST to `workflows-api` → submit→poll→complete against
  `mock-segment-connectivity` in the Temporal UI.
- Drift: `kubectl scale deploy/workflows -n redbull-workflows --replicas=0` → OutOfSync →
  self-heals.

## 7. Later (separate session)

Wire ESO + Vault per [SECRETS.md](SECRETS.md) — including the segments-manager Mongo-URL
composition (the one item needing a chart change).
