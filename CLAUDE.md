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

## GHCR pull secret

`segments-manager`'s image (`ghcr.io/team-redbull/segments-manager` or
`ghcr.io/<owner>/segments-manager` depending which fork is deployed) is private.
`charts/namespaces` creates `ghcr-pull-secret` in the `segments-manager`
namespace only (not cluster-wide — deliberately scoped down after an earlier
iteration that templated it across every namespace was rejected as
overengineered for current needs). Credentials come from `requiredEnv
"GHCR_USER"` / `requiredEnv "GHCR_TOKEN"` in `helmfile.yaml.gotmpl` — each
developer exports their own PAT (`read:packages` scope) in their shell profile
before running `helmfile sync`. Nothing is shared or committed. If another
release starts pulling private images, add its namespace to
`charts/namespaces` values' `ghcrPullSecret.namespaces` list and wire
`imagePullSecrets`/`image.pullSecrets` in that release's `values:` block.

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
- `team-redbull/workflows` (`helm/segment-allocation`) — Temporal worker chart
  consuming `temporal-stack` + `segments-manager`.
