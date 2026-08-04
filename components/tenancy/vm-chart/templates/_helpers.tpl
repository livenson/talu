{{/* Common labels stamped on every object this chart renders. project-uuid is the manager join key. */}}
{{- define "talu-vm.labels" -}}
talu.io/project-uuid: {{ .Values.projectUuid | quote }}
talu.io/slug: {{ .Values.slug | quote }}
app.kubernetes.io/managed-by: talu-vm-chart
{{- end -}}

{{/* Fail fast on the required identity fields. */}}
{{- define "talu-vm.validate" -}}
{{- if not .Values.projectUuid }}{{ fail "vm-chart: projectUuid is required" }}{{- end -}}
{{- if not .Values.slug }}{{ fail "vm-chart: slug is required" }}{{- end -}}
{{- if not .Values.name }}{{ fail "vm-chart: name is required" }}{{- end -}}
{{- if and .Values.size .Values.memory }}{{ fail "vm-chart: set size OR memory, not both — an instancetype cannot be overridden by the VM (KubeVirt rejects it)" }}{{- end -}}
{{- if and (not .Values.size) (not .Values.memory) }}{{ fail "vm-chart: one of size (preferred) or memory (legacy) is required" }}{{- end -}}
{{- end -}}
