{{/* Chart name */}}
{{- define "temporal-stack.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Fully qualified app name */}}
{{- define "temporal-stack.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "temporal-stack.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Common labels */}}
{{- define "temporal-stack.labels" -}}
helm.sh/chart: {{ include "temporal-stack.chart" . }}
{{ include "temporal-stack.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: temporal
{{- end -}}

{{/* Selector labels */}}
{{- define "temporal-stack.selectorLabels" -}}
app.kubernetes.io/name: {{ include "temporal-stack.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* True when an identity allowlist (users and/or groups) is in force */}}
{{- define "temporal-stack.uiAllowlistEnabled" -}}
{{- and .Values.ui.auth.enabled (or (gt (len .Values.ui.auth.allowedUsers) 0) (gt (len .Values.ui.auth.allowedGroups) 0)) -}}
{{- end -}}

{{/* True when the group-sync sidecar (and its RBAC) should be deployed */}}
{{- define "temporal-stack.uiGroupSyncEnabled" -}}
{{- and .Values.ui.auth.enabled (gt (len .Values.ui.auth.allowedGroups) 0) -}}
{{- end -}}

{{/* Frontend service name that clients/UI connect to */}}
{{- define "temporal-stack.frontendService" -}}
{{- printf "%s-frontend" (include "temporal-stack.fullname" .) -}}
{{- end -}}

{{/*
Frontend gRPC port. Single source of truth is the frontend role's grpcPort —
the Service, the UI, the setup Job and PUBLIC_FRONTEND_ADDRESS all derive
from it, so they cannot drift apart.
*/}}
{{- define "temporal-stack.frontendPort" -}}
{{- .Values.temporal.services.frontend.grpcPort -}}
{{- end -}}

{{/* ServiceAccount for the Temporal server pods and the schema/setup Jobs */}}
{{- define "temporal-stack.serviceAccountName" -}}
{{- include "temporal-stack.fullname" . -}}
{{- end -}}

{{/* ServiceAccount for the UI pod (also the OAuth client when ui.auth is on) */}}
{{- define "temporal-stack.uiServiceAccountName" -}}
{{- printf "%s-ui" (include "temporal-stack.fullname" .) -}}
{{- end -}}

{{/*
Label the bundled PostgreSQL's NetworkPolicy keys on when
postgresql.primary.networkPolicy.allowExternal=false: only pods carrying
<postgres fullname>-client=true may reach 5432. Stamped on every DB client
pod (server roles + both Jobs) so flipping that value is a pure values change.
*/}}
{{- define "temporal-stack.dbClientLabel" -}}
{{ .Values.postgresql.fullnameOverride | default "temporal-postgresql" }}-client: "true"
{{- end -}}

{{/* Resolved database host: bundled postgres service unless overridden */}}
{{- define "temporal-stack.dbHost" -}}
{{- if .Values.database.host -}}
{{- .Values.database.host -}}
{{- else if .Values.postgresql.enabled -}}
{{- .Values.postgresql.fullnameOverride | default "temporal-postgresql" -}}
{{- else -}}
{{- fail "database.host is required when postgresql.enabled=false — otherwise the server pods would silently target the (absent) bundled postgres Service" -}}
{{- end -}}
{{- end -}}

{{/*
Resolved secret holding the DB password. Precedence: an explicit
database.existingSecret; else the Secret the bundled subchart was told to use
(postgresql.auth.existingSecret — Bitnami stops rendering its own Secret once
that is set); else the subchart-generated one.
*/}}
{{- define "temporal-stack.dbSecret" -}}
{{- if .Values.database.existingSecret -}}
{{- .Values.database.existingSecret -}}
{{- else if (dig "auth" "existingSecret" "" .Values.postgresql) -}}
{{- .Values.postgresql.auth.existingSecret -}}
{{- else if .Values.postgresql.enabled -}}
{{- .Values.postgresql.fullnameOverride | default "temporal-postgresql" -}}
{{- else -}}
{{- fail "database.existingSecret is required when postgresql.enabled=false — otherwise the server pods would reference the (absent) bundled postgres Secret" -}}
{{- end -}}
{{- end -}}

{{/*
Shared environment block for Temporal server pods and the schema job.
The auto-setup/admin-tools entrypoints read these to render config & wire the DB.
*/}}
{{- define "temporal-stack.dbEnv" -}}
- name: DB
  value: {{ .Values.database.driver | quote }}
- name: DB_PORT
  value: {{ .Values.database.port | quote }}
- name: POSTGRES_SEEDS
  value: {{ include "temporal-stack.dbHost" . | quote }}
- name: POSTGRES_USER
  value: {{ .Values.database.user | quote }}
- name: POSTGRES_PWD
  valueFrom:
    secretKeyRef:
      name: {{ include "temporal-stack.dbSecret" . }}
      key: {{ .Values.database.secretKey }}
- name: DBNAME
  value: {{ .Values.database.temporalDb | quote }}
- name: VISIBILITY_DBNAME
  value: {{ .Values.database.visibilityDb | quote }}
{{- end -}}

{{/*
Resolve a full image reference, prefixing the private registry when
.Values.global.imageRegistry — the key the bundled Bitnami subchart reads
natively — is set, so that one value covers every image in the release.

Takes a dict: (dict "root" $ "image" <image block with repository/tag>).

When empty the repository is used verbatim (public registries).
When set, the repository is appended to the registry exactly as written, so
`quay.io/openshift/origin-cli` mirrors to
`<registry>/quay.io/openshift/origin-cli` — the mirror must hold each image at
its repository path verbatim, matching the retag convention in the README's
mirror script. Docker Hub repositories are written without a `docker.io/`
segment here, so they land host-less under the registry.
*/}}
{{- define "temporal-stack.image" -}}
{{- $repo := .image.repository -}}
{{- $registry := dig "imageRegistry" "" (.root.Values.global | default dict) | default "" | trimSuffix "/" -}}
{{- if $registry -}}
{{- $repo = printf "%s/%s" $registry $repo -}}
{{- end -}}
{{- printf "%s:%s" $repo (.image.tag | toString) -}}
{{- end -}}
