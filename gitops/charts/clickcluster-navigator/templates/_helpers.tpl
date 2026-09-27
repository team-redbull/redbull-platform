{{/*
Expand the name of the chart.
*/}}
{{- define "clickcluster-navigator.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "clickcluster-navigator.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "clickcluster-navigator.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "clickcluster-navigator.labels" -}}
helm.sh/chart: {{ include "clickcluster-navigator.chart" . }}
{{ include "clickcluster-navigator.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "clickcluster-navigator.selectorLabels" -}}
app.kubernetes.io/name: {{ include "clickcluster-navigator.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "clickcluster-navigator.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "clickcluster-navigator.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Create the name of the secret to use for authentication
*/}}
{{- define "clickcluster-navigator.secretName" -}}
{{- if .Values.auth.existingSecret }}
{{- .Values.auth.existingSecret }}
{{- else }}
{{- include "clickcluster-navigator.fullname" . }}-auth
{{- end }}
{{- end }}

{{/*
Create the name of the config secret
*/}}
{{- define "clickcluster-navigator.configSecretName" -}}
{{- include "clickcluster-navigator.fullname" . }}-config
{{- end }}

{{/*
Create the name of the PVC
*/}}
{{- define "clickcluster-navigator.pvcName" -}}
{{- if .Values.persistence.existingClaim }}
{{- .Values.persistence.existingClaim }}
{{- else }}
{{- include "clickcluster-navigator.fullname" . }}-data
{{- end }}
{{- end }}
