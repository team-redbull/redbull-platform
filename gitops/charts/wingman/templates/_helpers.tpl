{{/*
Expand chart name.
*/}}
{{- define "wingman.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Full image reference: [registry/]repository:tag[@digest]. `image.registry`
prefixes every image, nginx's included (an air-gapped mirror); a digest, when
set, is what the node pulls, and the tag stays for people. An empty tag fails
the render, naming `key`, with `example`: the chart's appVersion is never
stamped, so it cannot stand in for the release (ADR-0059).
Called with (dict "registry" .Values.image.registry "image" .Values.image.<name>
"key" "image.<name>.tag" "example" "<a tag>").
*/}}
{{- define "wingman.image" -}}
{{- $image := .image | default dict -}}
{{- if not $image.tag -}}
  {{- fail (printf "%s is empty: set it to the release to deploy, for example --set %s=%s (docs/ops/images.md)" .key .key .example) -}}
{{- end -}}
{{- $ref := $image.repository -}}
{{- if .registry -}}
  {{- $ref = printf "%s/%s" .registry $ref -}}
{{- end -}}
{{- $ref = printf "%s:%s" $ref $image.tag -}}
{{- if $image.digest -}}
  {{- $ref = printf "%s@%s" $ref $image.digest -}}
{{- end -}}
{{- $ref -}}
{{- end }}

{{/*
A Wingman image: day1, day2 or web (the three share one release tag).
Called with (list $ "day1").
*/}}
{{- define "wingman.serviceImage" -}}
{{- $root := index . 0 -}}
{{- $name := index . 1 -}}
{{- include "wingman.image" (dict "registry" $root.Values.image.registry "image" (index $root.Values.image $name) "key" (printf "image.%s.tag" $name) "example" "3.33.0") -}}
{{- end }}

{{/*
The nginx image. Nodes pull its digest, so a tag of another image kept from
earlier values (helm upgrade --reset-then-reuse-values) beside the chart's
digest would pull nothing: that fails the render instead. $pinned repeats
values.yaml's image.nginx (tests/repo/test_chart_nginx.py holds them equal).
*/}}
{{- define "wingman.nginxImage" -}}
{{- $nginx := .Values.image.nginx -}}
{{- $pinned := dict "repository" "registry.access.redhat.com/ubi9/nginx-124" "tag" "9.8" "digest" "sha256:d5cec86a9adf972dbfa0d87b134e7c404706cc1920fc2e6a2b146e290276f219" -}}
{{- if and $nginx.digest (eq $nginx.digest $pinned.digest) (ne $nginx.tag $pinned.tag) -}}
  {{- fail (printf `image.nginx.tag is %q but image.nginx.digest is the chart's, for %s:%s: set image.nginx.digest to the digest of the image you mean, or to "" to pull it by its tag (docs/upgrade/3.32-to-3.33.md)` $nginx.tag $pinned.repository $pinned.tag) -}}
{{- end -}}
{{- include "wingman.image" (dict "registry" .Values.image.registry "image" $nginx "key" "image.nginx.tag" "example" $pinned.tag) -}}
{{- end }}

{{/*
Common labels
*/}}
{{- define "wingman.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: wingman
{{- end }}

{{/*
Selector labels for a component
*/}}
{{- define "wingman.selectorLabels" -}}
app.kubernetes.io/name: wingman
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: {{ . }}
{{- end }}

{{/*
Namespace — use override if set, else release namespace
*/}}
{{- define "wingman.namespace" -}}
{{- .Values.namespace | default .Release.Namespace }}
{{- end }}

{{/*
ServiceAccount name
*/}}
{{- define "wingman.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
  {{- .Values.serviceAccount.name | default "wingman" }}
{{- else }}
  {{- .Values.serviceAccount.name | default "default" }}
{{- end }}
{{- end }}

{{/*
The Secret day1 and day2 load with envFrom: secrets.existingSecret when set
(the chart then renders none, ADR-0070), else the chart's own wingman-secrets.
Values kept from a release before 3.62 have no secrets map: the chart's own.
*/}}
{{- define "wingman.existingSecret" -}}
{{- dig "existingSecret" "" (.Values.secrets | default dict) -}}
{{- end }}

{{- define "wingman.secretName" -}}
{{- include "wingman.existingSecret" . | default "wingman-secrets" -}}
{{- end }}

{{/*
True when the chart renders the OAuthClient: on OpenShift, without dev login,
unless auth.oauthClient.create is false (it is then created by hand).
*/}}
{{- define "wingman.rendersOAuthClient" -}}
{{- if and .Values.openshiftRoute.enabled (not .Values.devAuth.enabled) (dig "oauthClient" "create" true .Values.auth) -}}true{{- end }}
{{- end }}

{{/*
OAuth redirect URI — use explicit value or derive from route.host
*/}}
{{- define "wingman.oauthRedirectUri" -}}
{{- if .Values.auth.oauthRedirectUri -}}
  {{- .Values.auth.oauthRedirectUri -}}
{{- else if .Values.openshiftRoute.enabled -}}
  {{- printf "https://%s/login" .Values.route.host -}}
{{- else if .Values.ingress.enabled -}}
  {{- printf "http://%s/login" .Values.ingress.host -}}
{{- else -}}
  {{- "" -}}
{{- end }}
{{- end }}

{{/*
A TLS verification setting, as the services read it ("true", "false" or a CA
bundle path): a boolean as "true" or "false", a string as given, unset or empty
as "true" (what the services do with an empty one). One helper for all five
sslVerify keys: before 3.33, `default "true"` turned a boolean false into "true".
Called with the value: (include "wingman.tlsVerify" .Values.serverScan.sslVerify).
*/}}
{{- define "wingman.tlsVerify" -}}
{{- if kindIs "bool" . -}}
  {{- ternary "true" "false" . -}}
{{- else -}}
  {{- . | default "true" -}}
{{- end -}}
{{- end }}

{{/*
True if a CA bundle is configured
*/}}
{{- define "wingman.hasCA" -}}
{{- if .Values.tls.caBundle -}}true{{- end }}
{{- end }}

{{/*
Every pod runs as OpenShift's restricted-v2 SCC expects, as server-scan's and
herzi's do: non-root, the runtime's seccomp profile, no runAsUser (OpenShift
assigns the UID; each image's USER is numeric for runAsNonRoot elsewhere).
*/}}
{{- define "wingman.podSecurityContext" -}}
runAsNonRoot: true
seccompProfile:
  type: RuntimeDefault
{{- end }}

{{/*
Every container: no privilege escalation, no capabilities, and a read-only
root. A container that must write gets an emptyDir at that path only.
*/}}
{{- define "wingman.containerSecurityContext" -}}
allowPrivilegeEscalation: false
capabilities:
  drop: ["ALL"]
readOnlyRootFilesystem: true
{{- end }}
