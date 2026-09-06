# `gitops/overrides/` — per-cluster value overrides (currently empty, and that is the point)

A service's configuration lives in **one** place: its chart's `values.yaml` under
`gitops/charts/<service>/`. The ApplicationSet passes **no** value files by default, so
what you read in that file is exactly what the cluster runs. No service in this repo
overrides anything today.

This folder exists for the case that genuinely cannot be expressed in the chart: a value
that differs **per cluster or per site** while the chart itself stays shared — the
air-gapped deployments, where the same chart is deployed onto a specific MCE or hosted
cluster with site-specific endpoints. It is not a place to park configuration that simply
belongs in the chart.

## Using it

1. Add `gitops/overrides/<service>.yaml` (the name is free; one file per concern reads
   better than one giant file).
2. Reference it from that service's `app.yaml`, repo-root relative:

   ```yaml
   # gitops/services/segments-manager/app.yaml
   namespace: segments-manager
   valueFiles:
     - gitops/overrides/segments-manager.yaml
   ```

The ApplicationSet rewrites those paths to be chart-relative (`../../../…`) — see the
`templatePatch` block in `gitops/appset.yaml`. Files are applied in the order listed,
after the chart's own `values.yaml`, so the last one wins.

## Why the files live HERE and not in `gitops/services/<service>/`

Next to `app.yaml` is the obvious place, and it is the one shape that must be avoided.

The git generator watches `gitops/services/<service>/app.yaml`. Deleting a service folder
is how a service is retired: the generator stops emitting it and the ApplicationSet
deletes its Application. That deletion needs the `resources-finalizer` cascade to run, the
cascade needs a successful reconcile, and the reconcile needs a successful **manifest
render**. If a referenced value file lived in the folder you just deleted, the render
fails (`values file … does not exist`), no resource tree is ever computed, nothing is
deleted from the cluster, and the finalizer holds the Application in `Progressing`
forever. Deleting the service breaks the very thing that makes deleting it possible.

That is not hypothetical — it is what happened on the air-gapped environment on
2026-07-28 (see `CLAUDE.md`). Keeping override files out of the watched folder means
removing a service is a single, safe commit.
