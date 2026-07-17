{{/*
Shared HTTP probe body — the httpGet / initialDelaySeconds / periodSeconds lines common to the
readiness and liveness probes. Takes a dict {probe, port}; the caller supplies the probe key
(readinessProbe: / livenessProbe:) and the 12-space indent via `nindent`.
*/}}
{{- define "platform.httpProbe" -}}
httpGet: { path: {{ .probe.path }}, port: {{ .port }} }
initialDelaySeconds: {{ .probe.initialDelaySeconds }}
periodSeconds: {{ .probe.periodSeconds | default 10 }}
{{- end -}}

{{/*
Shared container hardening — the securityContext body every platform container carries: no privilege
escalation, a read-only root filesystem, and all Linux capabilities dropped. One source of truth for
what "hardened" means, so tightening it happens in a single place. The caller supplies the
`securityContext:` line and the 12-space indent via `nindent`. Optional `add` is a list of
capabilities to add back (only fix-perms needs CHOWN); omitted, none are added.
*/}}
{{- define "platform.containerSecurity" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities: { drop: ["ALL"]{{ with .add }}, add: {{ . | toJson }}{{ end }} }
{{- end -}}
