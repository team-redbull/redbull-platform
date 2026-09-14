#!/usr/bin/env bash
# Vendors this chart into every gitops/charts/<operator> that declares it.
#
# WHY A COPY AND NOT `repository: file://../operator-olm`: on the air-gapped GitLab each
# chart is its own repo under the helm-charts group. There is no shared checkout there,
# so a relative-path dependency cannot resolve and a symlink arrives dangling. A consumer
# chart directory must be copyable to its own repo root VERBATIM. The committed artifact
# is the price of one portable shape.
#
#   ./vendor.sh            package and drop the .tgz into every consumer
#   ./vendor.sh --check    verify each consumer declares the current version (exit 1 if not)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
charts="$(cd "$here/.." && pwd)"
version="$(awk '/^version:/ {print $2; exit}' "$here/Chart.yaml")"
mode="${1:-vendor}"
rc=0

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
[[ "$mode" == "--check" ]] || helm package "$here" -d "$tmp" >/dev/null

for chart in "$charts"/*/Chart.yaml; do
  grep -q 'name: operator-olm' "$chart" || continue
  dir="$(dirname "$chart")"
  name="$(basename "$dir")"
  [[ "$name" == "operator-olm" ]] && continue

  # The declared dependency version must match this chart. Nothing breaks at render
  # time if it drifts — charts/ is already populated, so Helm never resolves — but the
  # declaration would be lying about what is actually vendored.
  declared="$(awk '/name: operator-olm/{f=1} f&&/version:/{print $2; exit}' "$chart")"
  if [[ "$declared" != "$version" ]]; then
    echo "VERSION: $name declares operator-olm $declared, chart is $version"
    rc=1
  fi

  if [[ "$mode" == "--check" ]]; then
    if [[ ! -f "$dir/charts/operator-olm-$version.tgz" ]]; then
      echo "MISSING: $name has no charts/operator-olm-$version.tgz"
      rc=1
    fi
  else
    mkdir -p "$dir/charts"
    rm -f "$dir"/charts/operator-olm-*.tgz
    cp "$tmp"/operator-olm-"$version".tgz "$dir/charts/"
    echo "vendored operator-olm $version -> $name"
  fi
done

exit $rc
