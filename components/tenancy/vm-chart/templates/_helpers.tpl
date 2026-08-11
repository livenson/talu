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
{{- include "talu-vm.validateRestore" . -}}
{{- end -}}

{{/*
Restore/import validation. Every rule here exists because the failure it prevents is SILENT:
an import URL under the wrong source renders nothing, and an untrusted imported guest boots green
while rejecting every human login (docs/architecture/drim-target.md §4.3).
*/}}
{{- define "talu-vm.validateRestore" -}}
{{- $isImport := eq .Values.source "import" -}}
{{- /* `| default dict` throughout: an overlay that sets `restore:` with no body (or nulls it) must
       reach the messages below, not a nil-pointer panic from the template engine. */ -}}
{{- $restore := .Values.restore | default dict -}}
{{- $rootUrl := ($restore.root | default dict).url | default "" -}}
{{- if and $isImport (not $rootUrl) }}{{ fail "vm-chart: source=import requires restore.root.url — the disk to boot from" }}{{- end -}}
{{- if and $rootUrl (not $isImport) }}{{ fail (printf "vm-chart: restore.root.url is set but source=%s — the URL would be silently ignored; set source=import" .Values.source) }}{{- end -}}
{{- if and $isImport (not $restore.acknowledgeGuestTrust) }}{{ fail "vm-chart: source=import requires restore.acknowledgeGuestTrust=true — an imported guest does not trust this site's SSH User CA and cloud-init does not re-run on a provisioned disk, so the VM would boot healthy and reject every human login (docs/architecture/drim-target.md §4.3)" }}{{- end -}}
{{- $seen := dict -}}
{{- range $d := (.Values.dataDisks | default list) -}}
  {{- if or (eq $d.name "rootdisk") (eq $d.name "cloudinit") }}{{ fail (printf "vm-chart: dataDisks name %q collides with a fixed volume name" $d.name) }}{{- end -}}
  {{- if hasKey $seen $d.name }}{{ fail (printf "vm-chart: duplicate dataDisks name %q" $d.name) }}{{- end -}}
  {{- $_ := set $seen $d.name true -}}
{{- end -}}
{{- end -}}

{{/*
Render a DataVolume `spec.source` block from a disk's (url, secretRef, certConfigMap).
An empty url yields `blank: {}` — a new, empty volume. Shared by the imported root disk and every
data disk so the two paths cannot drift.
*/}}
{{- define "talu-vm.dvSource" -}}
{{- $url := .url | default "" -}}
{{- if not $url }}
blank: {}
{{- else if hasPrefix "s3://" $url }}
s3:
  url: {{ $url | quote }}
  {{- if .secretRef }}
  secretRef: {{ .secretRef | quote }}
  {{- end }}
  {{- if .certConfigMap }}
  certConfigMap: {{ .certConfigMap | quote }}
  {{- end }}
{{- else }}
http:
  url: {{ $url | quote }}
  {{- if .secretRef }}
  secretRef: {{ .secretRef | quote }}
  {{- end }}
  {{- if .certConfigMap }}
  certConfigMap: {{ .certConfigMap | quote }}
  {{- end }}
{{- end }}
{{- end -}}
