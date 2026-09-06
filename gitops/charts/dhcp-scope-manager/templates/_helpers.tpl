{{/* Chart name */}}
{{- define "dhcp-scope-manager.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified app name.

The ApplicationSet sets releaseName to the service name in every environment, so
this collapses to "dhcp-scope-manager" everywhere and environments are separated
by namespace rather than by resource name.
*/}}
{{- define "dhcp-scope-manager.fullname" -}}
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

{{- define "dhcp-scope-manager.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "dhcp-scope-manager.labels" -}}
helm.sh/chart: {{ include "dhcp-scope-manager.chart" . }}
{{ include "dhcp-scope-manager.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: dhcp-scope-manager
{{- end -}}

{{- define "dhcp-scope-manager.selectorLabels" -}}
app.kubernetes.io/name: {{ include "dhcp-scope-manager.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Fail early on a psrp deployment with no target.

Without this the pods start, every request reaches validate_dhcp_environment,
and the whole service reports 503 with a reason buried in pod logs. A render-time
failure surfaces the same mistake in the Argo sync result instead.
*/}}
{{- define "dhcp-scope-manager.validate" -}}
{{- if eq .Values.dhcp.transport "psrp" -}}
{{- if not .Values.dhcp.serverHost -}}
{{- fail "dhcp.serverHost is required when dhcp.transport is 'psrp' — set it to the Windows DHCP server this API manages." -}}
{{- end -}}
{{- if eq .Values.winrm.auth "ntlm" -}}
{{- if not .Values.winrm.existingSecret -}}
{{- fail "winrm.existingSecret is required when winrm.auth is 'ntlm' — the password must come from a Secret, never from values.yaml (it lives in git)." -}}
{{- end -}}
{{- if not .Values.winrm.username -}}
{{- fail "winrm.username is required when winrm.auth is 'ntlm'." -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
