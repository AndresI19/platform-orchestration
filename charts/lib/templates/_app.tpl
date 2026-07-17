{{/*
platform.app — renders a Deployment (and, unless service:false, a Service) for one platform service.
Called from charts/service's deployment.yaml with dict "name" <string> "app" <values entry> "root" $.

Shared boilerplate lives here: pod + container securityContext (uid 1000, read-only fs),
imagePullPolicy, the always-present /tmp emptyDir, the `app` label. What varies rides in the values
entry — env, initContainers, volumeMounts/volumes, probes, port, strategy — spliced in with toYaml.
An initContainer omitting `image` inherits the app image, so the seed steps (home, quiz) copy from
exactly the version being deployed.
*/}}
{{- define "platform.app" -}}
{{- $name := .name -}}
{{- $app := .app -}}
{{- $ns := .root.Release.Namespace -}}
{{- $img := printf "%s:%s" $app.image.repo $app.image.tag -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ $name }}
  namespace: {{ $ns }}
  labels:
    app: {{ $name }}
spec:
  replicas: {{ $app.replicas | default 1 }}
  {{- with $app.strategy }}
  strategy:
    type: {{ . }}
  {{- end }}
  selector:
    matchLabels: { app: {{ $name }} }
  template:
    metadata:
      labels: { app: {{ $name }} }
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000
        seccompProfile: { type: RuntimeDefault }
      {{- with $app.initContainers }}
      initContainers:
        {{- range . }}
        - name: {{ .name }}
          image: {{ .image | default $img }}
          imagePullPolicy: IfNotPresent
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
          command: {{ .command | toJson }}
          {{- with .volumeMounts }}
          volumeMounts:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          resources:
            {{- toYaml .resources | nindent 12 }}
        {{- end }}
      {{- end }}
      containers:
        - name: {{ $name }}
          image: {{ $img }}
          imagePullPolicy: IfNotPresent
          {{- with $app.port }}
          ports: [{ containerPort: {{ . }} }]
          {{- end }}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
          {{- with $app.env }}
          env:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          volumeMounts:
            {{- with $app.volumeMounts }}
            {{- toYaml . | nindent 12 }}
            {{- end }}
            - { name: tmp, mountPath: /tmp }
          {{- with $app.probe }}
          readinessProbe:
            {{- include "platform.httpProbe" (dict "probe" . "port" $app.port) | nindent 12 }}
          {{- end }}
          {{- with $app.livenessProbe }}
          livenessProbe:
            {{- include "platform.httpProbe" (dict "probe" . "port" $app.port) | nindent 12 }}
          {{- end }}
          resources:
            {{- toYaml $app.resources | nindent 12 }}
      volumes:
        {{- with $app.volumes }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
        - { name: tmp, emptyDir: {} }
{{- if ne $app.service false }}
---
apiVersion: v1
kind: Service
metadata:
  name: {{ $name }}
  namespace: {{ $ns }}
spec:
  selector: { app: {{ $name }} }
  ports: [{ port: {{ $app.port }}, targetPort: {{ $app.port }} }]
{{- end }}
{{- end -}}
