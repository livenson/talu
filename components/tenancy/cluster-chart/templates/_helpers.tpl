{{/* Common labels stamped on every tenant-cluster object. project-uuid is the manager join key. */}}
{{- define "talu-cluster.labels" -}}
talu.io/project-uuid: {{ .Values.projectUuid | quote }}
app.kubernetes.io/managed-by: talu-cluster-chart
{{- end -}}

{{/* The tenant namespace: explicit value, else a dedicated "kaas-<name>". */}}
{{- define "talu-cluster.namespace" -}}
{{- .Values.namespace | default (printf "kaas-%s" .Values.name) -}}
{{- end -}}

{{/* The Secret Kamaji publishes with the tenant admin kubeconfig (key: admin.conf). */}}
{{- define "talu-cluster.adminKubeconfigSecret" -}}
{{- printf "%s-admin-kubeconfig" .Values.name -}}
{{- end -}}

{{/* Fail fast on required fields. */}}
{{- define "talu-cluster.validate" -}}
{{- if not .Values.projectUuid }}{{ fail "cluster-chart: projectUuid is required" }}{{- end -}}
{{- if not .Values.name }}{{ fail "cluster-chart: name is required" }}{{- end -}}
{{- if not .Values.debugPublicKey }}{{ fail "cluster-chart: debugPublicKey is required (operator break-glass into node guests; CAPK skips its own keypair under managed-by: kamaji)" }}{{- end -}}
{{- end -}}
