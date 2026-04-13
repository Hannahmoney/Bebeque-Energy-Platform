{{/*
Expand the name of the chart.
*/}}
{{- define "bebeque-service.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Full name — used for resource names. Prefer fullnameOverride if set.
*/}}
{{- define "bebeque-service.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Common labels — applied to every resource.
*/}}
{{- define "bebeque-service.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ include "bebeque-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels — used in Deployment spec.selector and Service selector.
Must be stable across upgrades — never include chart version here.
*/}}
{{- define "bebeque-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "bebeque-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}