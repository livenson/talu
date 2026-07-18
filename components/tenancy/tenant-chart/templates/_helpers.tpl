{{/* Common labels stamped on every tenant object. project-uuid is the manager join key. */}}
{{- define "talu-tenant.labels" -}}
talu.io/project-uuid: {{ .Values.projectUuid | quote }}
talu.io/slug: {{ .Values.slug | quote }}
app.kubernetes.io/managed-by: talu-tenant-chart
{{- end -}}

{{/* Fail fast on the required identity fields. */}}
{{- define "talu-tenant.validate" -}}
{{- if not .Values.projectUuid }}{{ fail "tenant-chart: projectUuid is required" }}{{- end -}}
{{- if not .Values.slug }}{{ fail "tenant-chart: slug is required" }}{{- end -}}
{{- end -}}
