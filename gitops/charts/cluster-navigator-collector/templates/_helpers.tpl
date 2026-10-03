{{- define "collector.name" -}}
{{- .Release.Name | trunc 52 | trimSuffix "-" -}}
{{- end -}}

{{- define "collector.labels" -}}
app.kubernetes.io/name: cluster-navigator-collector
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "collector.tokenSecret" -}}
{{- .Values.ingestToken.existingSecret | default (printf "%s-ingest" (include "collector.name" .)) -}}
{{- end -}}
