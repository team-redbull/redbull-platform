{{- define "navigator.name" -}}
{{- .Release.Name | trunc 52 | trimSuffix "-" -}}
{{- end -}}

{{- define "navigator.labels" -}}
app.kubernetes.io/name: cluster-navigator
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "navigator.selectorLabels" -}}
app.kubernetes.io/name: cluster-navigator
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "navigator.secretName" -}}
{{- .Values.secret.existingSecret | default (include "navigator.name" .) -}}
{{- end -}}

{{/* Every group that grants a role. The server may read exactly these Groups and no others. */}}
{{- define "navigator.groups" -}}
{{- $groups := .Values.auth.adminGroups | default list -}}
{{- range $role, $members := .Values.auth.roleGroups -}}
{{- $groups = concat $groups $members -}}
{{- end -}}
{{- $groups | uniq | toJson -}}
{{- end -}}
