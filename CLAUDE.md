# CLAUDE.md — platform-orchestration

Guidance for Claude Code when working in this repo.

## What this is

The orchestration for the personal platform. It is **the only place the platform's topology is
described**: manifests, routing, secrets, and boot. Read `ARCHITECTURE.md` first — it has the full
stack, who talks to whom, and every port.

**There is no docker-compose.** It was deleted after the cutover; the platform runs on Kubernetes
(minikube), and the public site (`project-platform.me`) is served from this cluster right now.

## Commands

```bash
./k8s/minikube-up.sh                              # cold boot: Colima → minikube → build+load → apply
kubectl apply -k k8s/                             # the local stack
kubectl apply -k k8s/overlays/public/             # + the public cloudflared front door
kubectl -n platform port-forward svc/nginx 8081:8080   # local access — see below

./k8s/secrets.sh seal|show|recover|list           # secrets; run with no args for usage
kubectl kustomize k8s/                            # render without applying
```

## Three things that will waste your time if you don't know them

**1. `minikube ip`, `minikube tunnel`, and `minikube docker-env` all DO NOT WORK here.** Docker is
not a native daemon on this box — it lives inside a Colima QEMU VM, so the K8s node container sits in
the VM's network namespace. minikube assumes Docker is local and writes the node's unroutable bridge
IP (`192.168.49.2:8443`) into kubeconfig.

- Symptom: `kubectl` hangs, and `minikube start` dies with `apiserver healthz never reported
  healthy` — **while the control plane is perfectly healthy**, just unreachable.
- Fix: point kubeconfig at the port Colima forwards out. That port is reassigned on every
  `minikube start`, so re-derive it, never hard-code it:
  ```bash
  kubectl config set-cluster minikube --server="https://127.0.0.1:$(docker port minikube 8443 | head -1 | sed 's/.*://')"
  ```
- Consequences: build images with Colima's Docker and `minikube image load` them (not
  `docker-env`); reach the cluster with `port-forward` (not `minikube ip`).

`systemd/platform-boot.sh` and `k8s/minikube-up.sh` already handle all of this.

A corollary that costs six minutes if you miss it: **`minikube status` is not a usable health gate
here.** It probes that same unroutable IP, so it reports the cluster unhealthy even while the site is
serving — and code that gates `minikube start` on it will start an already-healthy cluster, which then
sits through the full `apiserver healthz never reported healthy` timeout before giving up. Gate on
`docker ps` + a `kubectl get --raw /healthz` after the repoint, as `platform-boot.sh` does.

**2. A ConfigMap change does not restart the pods that read it.** `platform-config` reaches the apps
as *environment variables*, which are read once at container start. After changing it:
`kubectl -n platform rollout restart deploy/home deploy/vmcp`.

The nginx conf is the exception — it is a **generated** ConfigMap (`configMapGenerator`) whose name
carries a content hash, so editing `k8s/base/nginx.conf` changes the Pod spec and rolls the
Deployment automatically. That is deliberate; don't convert it to a plain ConfigMap.

**3. Sealed secrets are strict-scoped.** Each is bound cryptographically to its namespace *and*
name. Applying `sealed-vmcp-db.yaml` into another namespace fails with `ErrUnsealFailed: no key could
decrypt secret` — not a permission you can grant. A Helm chart in a new namespace needs its own seal:
`./k8s/secrets.sh seal <name> -n <ns> -o <file> KEY=@ENV_VAR`.

## Layout

```
k8s/
├── kustomization.yaml        thin pointer at base/
├── minikube-up.sh            cold-boot bring-up
├── secrets.sh                seal / show / recover / list
├── base/                     the local stack
│   ├── nginx.conf            ← THE ROUTING TABLE. Path map + Host split. Read this first.
│   ├── nginx.yaml            the router (Deployment + Service)
│   ├── ingress.yaml          local entry point only; hands everything to nginx
│   ├── content.yaml          PVC: resume.pdf + card decks
│   ├── sealed-*.yaml         encrypted secrets — safe to commit
│   └── home|quiz|vmcp|vmcp-db|rs-mcp-server|fvt-traffic.yaml
└── overlays/public/          + cloudflared. THIS SERVES THE LIVE SITE.
systemd/                      colima.service, platform.service, platform-boot.sh
                              ↑ boot + reboot recovery. platform-boot.sh is idempotent and
                                notifies Discord + the desktop at both ends. See README.
```

## Why nginx and not Ingress annotations

Routing lives in `k8s/base/nginx.conf`, and the Ingress is a dumb front door that hands it
everything. Don't "simplify" this by moving the path map into Ingress rules — the conf also splits by
Host, makes the *public* dashboard API read-only, and rewrites the api host's `/api/…` onto the
gateway's `/vmcp/api/…`. Those need `configuration-snippet`, disabled by default since
CVE-2021-25742. One routing table, not two.

## Conventions

- Images are tagged `platform-*` and side-loaded. The prefix is not cosmetic: with
  `imagePullPolicy: IfNotPresent` and a bare name like `home`, a cache miss sends the kubelet to
  Docker Hub for `docker.io/library/home` — a real image that isn't ours.
- The public overlay is a **cutover**, not an addition. Cloudflare load-balances across every
  connector on a tunnel, so two connectors *split* live traffic rather than failing over.
- `.env` is gitignored and is no longer read at runtime. It is only the plaintext source you re-seal
  from.

## Sharp edges

- **This repo has a private remote** (`AndresI19/platform-orchestration`). The committed `sealed-*.yaml`
  are safe to publish — they are encrypted — but the gitignored `.env` and the sealed-secrets private
  key must never be. A security audit (2026-07-13) cleared the history before the first push; the only
  plaintext secret ever committed was a since-rotated demo DB password in files deleted at the cutover.
- **The sealed-secrets private key is the only thing that can decrypt the committed `sealed-*.yaml`
  files.** It is NOT in this repo (verified). Recreate the cluster without a backup of it and the
  sealed secrets are lost permanently.
- Colima's default VM (2 CPU / 4 GiB) cannot hold a K8s control plane plus ingress-nginx plus the
  stack. It runs 8 CPU / 16 GiB.
