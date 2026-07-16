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
