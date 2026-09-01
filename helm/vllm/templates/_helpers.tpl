{{- define "vllm.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "vllm.fullname" -}}
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

{{- define "vllm.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{ include "vllm.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "vllm.selectorLabels" -}}
app.kubernetes.io/name: {{ include "vllm.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
