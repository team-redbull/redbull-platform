# redbull-platform — context for future sessions

One Helmfile deploys every team-redbull service onto an OpenShift cluster. See
`README.md` for the release table, usage, and configuration. This file covers
the non-obvious *why* behind the current shape, so it doesn't get re-litigated
or accidentally reverted.

## Why Postgres/Mongo are separate releases, not bundled subcharts

`temporal-stack`'s schema-init Job originally ran as a `post-install,post-upgrade`
Helm hook. With `helmDefaults.wait: true`, Helm waits for all Deployments to be
`Ready` *before* running post-install hooks — but the Temporal server pods can't
become ready without the schema existing yet. Deadlock: pods crash-loop on
`pq: relation "schema_version" does not exist`, the release sits in
`pending-install` until it times out.

Fix (in `team-redbull/temporal-stack`, commit `0e213ad`): the schema Job is now
`pre-install,pre-upgrade`. But a `pre-install` hook runs *before any resource in
the chart is created* — including a bundled Postgres subchart's StatefulSet. So
Postgres can no longer live inside `temporal-stack`; it has to already exist
when that chart installs.

Solution: `temporal-postgresql` (`charts/temporal-postgresql`, wrapping the
Bitnami `postgresql` chart) is its own helmfile release, sequenced before
`temporal-stack` via `needs:`. `segments-manager-mongodb` exists for the
identical reason relative to `segments-manager` (its Deployment can't come up
without Mongo already reachable, and helmfile's wait would otherwise block
similarly at scale — plus segments-manager has no schema-job pattern of its own,
this was done proactively for the same "DB must precede app" invariant).

**Do not re-bundle these into subcharts of their consuming chart** without
re-deriving this deadlock first.

## Why the htpasswd identity provider is a postsync hook, and merges into the existing provider

`charts/htpasswd-idp` provisions a bootstrap cluster login (`ocpadmin`,
granted cluster-admin) on every cluster this platform deploys onto. It
templates **no Kubernetes resources at all** — the release exists purely to
carry a `postsync` hook (`charts/htpasswd-idp/scripts/apply-oauth.sh`).

Two reasons this is imperative rather than Helm-templated:

1. `oauth.config.openshift.io/cluster`, the object that actually wires an
   identity provider into cluster login, is a singleton created by the
   cluster-version-operator (owned by a `ClusterVersion` ownerReference) that
   already exists before this Helmfile ever touches the cluster. A Helm
   template for `kind: OAuth, name: cluster` would try to *create* a resource
   that's already there, hitting the identical "invalid ownership metadata"
   failure documented below for the segments-manager-mongodb Secret and the
   workflows Namespace — just for this singleton instead.
2. Most clusters already have an HTPasswd provider configured out of band
   (this platform's dev sandbox shipped with one, `htpasswd_provider` /
   Secret `htpasswd`, containing users unrelated to this repo). Adding a
   *second* htpasswd provider just to stay Helm-native would show up as a
   confusing second option on the OpenShift login screen and fragment
   cluster users across two providers — an earlier version of this chart did
   exactly that (a standalone `redbull-platform` provider) before being
   corrected to merge into the existing one instead.

So the hook merges `htpasswdIdp.users` into whichever Secret backs the
cluster's existing HTPasswd-type provider (found via `oc get oauth cluster
-o jsonpath='{.spec.identityProviders[?(@.type=="HTPasswd")]...}'`), skipping
any username already present rather than overwriting it. Only on a cluster
with **no** HTPasswd provider at all does it fall back to creating one from
scratch, via `htpasswdIdp.bootstrapProviderName`/`bootstrapSecretName`, using
a JSON-patch `add` on `/spec/identityProviders/-` (never a `--type=merge`
replace of the whole list — that would delete every other provider already
configured on the cluster).

**Do not turn this into a Helm-owned `kind: OAuth`/`Secret` template**, and
do not make the "bootstrap a new provider" fallback the default behavior,
without re-deriving both points above first.

**Gotcha if you ever change which provider a username is issued through**:
OpenShift's identity-to-user mapping is sticky. The first successful login
permanently creates a `User` + `Identity` object (e.g. `identity
htpasswd_provider:ocpadmin`), and `mappingMethod: claim` (the default, used
here) refuses to let a *different* provider claim that same username
afterward — logins fail with a 500 (`AuthenticationError: user "X" cannot be
claimed by identity "Y" because it is already mapped to [Z]`), not a clean
401, which is easy to misdiagnose as a broken htpasswd file. Fix is `oc
delete identity <old-provider>:<user>` + `oc delete user <user>` before
retrying under the new provider.

## Naming collision gotcha

Bitnami subchart resources (Secrets, etc.) are commonly named after
`fullnameOverride`. The segments-manager Helm chart's own `fullname` template
collapses to `segments-manager` when the release is named `segments-manager`
(see its `_helpers.tpl` — `contains $name .Release.Name` logic), producing a
secret literally named `segments-manager-mongodb`. Naming the Mongo release's
`fullnameOverride` the same string causes a Helm ownership conflict on install
("invalid ownership metadata"). This is why `charts/segments-manager-mongodb`
uses `fullnameOverride: segments-mongodb` (no `-manager`) instead of the more
obvious `segments-manager-mongodb`.

## workflows charts: no chart ever creates its own Namespace

`team-redbull/workflows` used to ship a single `helm/connectivity` chart with
its own `templates/namespace.yaml` (unconditionally, then later gated behind
`.Values.createNamespace`) — handy for standalone use (e.g. a local kind
cluster) where nothing else provisions the namespace first, but a source of
Helm ownership conflicts here: this platform's `namespaces` release already
pre-creates `redbull-workflows` up front (same pattern as `temporal`,
`segments-manager`, etc.), so a second chart trying to create/adopt that same
`Namespace` object hits the same "invalid ownership metadata" failure as the
segments-manager-mongodb Secret collision above, just for a `Namespace`
instead of a `Secret`.

As of the `helm/workflow-worker` + `helm/connectivity` split (the brain now
has its own chart, decoupled from any one workflow domain — see
`team-redbull/workflows`' CLAUDE.md §1–2), **neither chart has a
`templates/namespace.yaml` or a `createNamespace`/`namespace` value at all**.
Both releases below rely entirely on `helmDefaults.createNamespace: false` +
their Helmfile-level `namespace: redbull-workflows` field, which requires that
namespace to already exist by the time they sync — guaranteed by `needs:
[default/namespaces]` on both releases.

**Do not add a per-chart Namespace template or `createNamespace` value back
into any `team-redbull/workflows` chart (or any future per-domain chart under
`helm/<domain>/`), and do not remove `redbull-workflows` from
`charts/namespaces/values.yaml`**, without re-deriving this conflict first —
every workflow-domain chart shares this one namespace, so its ownership
belongs solely to the `namespaces` release.

## No GHCR pull secret (images are public)

All `ghcr.io/team-redbull/*` images (including `segments-manager`) are public
packages — verified 2026-07-10 via `gh api orgs/team-redbull/packages`
(`"visibility":"public"`) and by pulling a manifest anonymously with no
credentials. There used to be a `ghcr-pull-secret` created by
`charts/namespaces` from `requiredEnv "GHCR_USER"`/`requiredEnv "GHCR_TOKEN"`,
which forced every developer to export a personal PAT before every
`helmfile sync`. That machinery has been removed entirely (not just disabled)
— it was solving a problem that doesn't exist for a public registry.

**If a `team-redbull` image ever goes private again**, pulls will fail with no
warning (no pull secret exists to catch it). At that point, re-add a
`kubernetes.io/dockerconfigjson` Secret (a prior version of this lived at
`charts/namespaces/templates/ghcr-pull-secret.yaml`, git history has it) and
wire it via `imagePullSecrets`/`image.pullSecrets` in that release's `values:`
block — but prefer a shared robot/service-account token created once directly
in-cluster over per-developer `requiredEnv` PATs, since the credential doesn't
need to vary per developer.

## OCI chart references in helmfile

Don't add a `repositories:` entry with `oci: true` for Bitnami/OCI charts —
that produces a double `oci://oci://...` URL bug in this helmfile version.
Reference OCI charts directly in the release's `chart:` field instead:
`chart: oci://registry-1.docker.io/bitnamicharts/postgresql`.

## Local machine gotcha (not project state, but recurring)

This developer's `~/Library/Caches/helm*` and `~/Library/Preferences/helm`
have previously ended up root-owned (residue from some earlier `sudo helm`
invocation), which breaks `helmfile template`/`sync` with permission-denied
errors. Fix is `sudo chown -R $(whoami):staff` on those paths — not a repo
issue, don't try to "fix" it in the helmfile.

## Related repos

- `team-redbull/temporal-stack` — Temporal server chart. Schema Job hook
  timing lives here (see above).
- `team-redbull/segment_manager` — original segments-manager chart/source,
  `deploy/helm` path. Still on the old Docker Hub-based build workflow.
- `team-redbull/segments-manager` (also cloned locally at
  `/Users/itayherzberg/Projctes/segments-manager`) — newer rework in progress,
  actively developed on `feature/mongodb-no-vrf`. Chart is still internally
  named/labeled `vlan-manager` (stale branding, not yet renamed) even though
  the repo and GHCR image are `segments-manager`.
- `team-redbull/.github` — new (this session) org-wide reusable workflows
  repo. Hosts `ghcr-build-push.yml`, the canonical build/version/GHCR-push/
  Helm-bump flow. `segments-manager`'s `build.yml` is a 9-line caller into it.
  Other service repos (`segment_manager`, `workflows`, `BareMetalHostUCS`,
  `ServerScanner`, `dhcp_scope_manager`) still have their own inline copies —
  migrate them to call the shared workflow rather than editing their local
  copies when the build flow needs to change.
- `team-redbull/workflows` — Temporal worker charts consuming `temporal-stack`
  + `segments-manager`: `helm/workflow-worker` (the brain, one shared release),
  `helm/connectivity` (the connectivity limb; the first of what will be
  several per-domain charts), and `helm/mock-connectivity` (test-only stand-in
  for the real "next" firewall service `connectivity` talks to — e2e/test
  environments only, never alongside a production `connectivity` release).
