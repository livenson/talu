{{/* Common labels stamped on every tenant-cluster object. project-uuid is the manager join key. */}}
{{- define "talu-cluster.labels" -}}
talu.io/project-uuid: {{ .Values.projectUuid | quote }}
app.kubernetes.io/managed-by: talu-cluster-chart
{{- end -}}

{{/* Fail fast on required fields. */}}
{{- define "talu-cluster.validate" -}}
{{- if not .Values.projectUuid }}{{ fail "cluster-chart: projectUuid is required" }}{{- end -}}
{{- if not .Values.name }}{{ fail "cluster-chart: name is required" }}{{- end -}}
{{- if not .Values.debugPublicKey }}{{ fail "cluster-chart: debugPublicKey is required (operator break-glass into node guests; CAPK skips its own keypair under managed-by: kamaji)" }}{{- end -}}
{{- end -}}
