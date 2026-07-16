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
./k8s/minikube-up.sh                              # cold boot: Colima → minikube → registry → bootstrap → deploy
kubectl apply -f k8s/bootstrap/                   # namespace, sealed secrets, PVCs, deployer RBAC (once, before deploy)
./k8s/deploy.sh                                   # build → side-load → helm upgrade --install. THE only deploy.
./k8s/deploy.sh public                            # + the public cloudflared front door (values-public.yaml)
kubectl -n platform port-forward svc/nginx 8081:8080   # local access — see below

helm history platform                             # release revisions
helm rollback platform <n>                        # revert to a revision — images AND reported version move together
helm template platform chart                      # render without applying
./k8s/secrets.sh seal|show|recover|list           # secrets; run with no args for usage
```

## Pre-PR checks

```bash
helm lint chart
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

The nginx conf is the exception — the chart hashes `chart/files/nginx.conf` into a `checksum/config`
annotation on the pod template, so editing the conf changes the Pod spec and rolls the Deployment
automatically. (This replaces kustomize's `configMapGenerator` hashed name — Helm has no generator.)
Don't remove the annotation.

**3. Sealed secrets are strict-scoped.** Each is bound cryptographically to its namespace *and*
name. Applying `sealed-vmcp-db.yaml` into another namespace fails with `ErrUnsealFailed: no key could
decrypt secret` — not a permission you can grant. This is exactly why the SealedSecrets live in
`k8s/bootstrap/` and are NOT in the Helm chart: the chart keeps the namespace `platform` and every
Secret name unchanged, so the existing seals work as-is. Moving to a NEW namespace would need
re-sealing every one: `./k8s/secrets.sh seal <name> -n <ns> -o <file> KEY=@ENV_VAR`.

## Layout

```
chart/                        the Helm chart — the platform's topology, ONE release named `platform`
├── Chart.yaml
├── values.yaml               local defaults; image tags + versions come from deploy.sh --set
├── values-public.yaml        + cloudflared and the real hostnames. THIS SERVES THE LIVE SITE.
├── files/nginx.conf          ← THE ROUTING TABLE. Path map + Host split. Read this first.
└── templates/
    ├── _app.tpl              generic Deployment(+Service) renderer for the six apps
    ├── apps.yaml             ranges over .Values.apps
    ├── postgres.yaml         platform-db + vmcp-db
    ├── nginx.yaml            the router + its ConfigMap (checksum-rolled)
    ├── cloudflared.yaml      gated on .Values.cloudflared.enabled
    ├── config.yaml · ingress.yaml
    └── hooks/version-writer.yaml   writes platform-version.json onto the content PVC
k8s/
├── minikube-up.sh            cold-boot bring-up (delegates to deploy.sh)
├── deploy.sh                 build → side-load → helm upgrade --install. THE only supported deploy.
├── registry.sh               the registry + the CA trust both docker daemons need. Idempotent.
├── secrets.sh                seal / show / recover / list
└── bootstrap/                applied once with kubectl, deliberately NOT owned by Helm:
    ├── namespace.yaml
    ├── deployer-rbac.yaml    the least-privilege CI identity
    ├── pvcs.yaml             the three PVCs — kept out of Helm so the data is never at risk
    └── sealed-*.yaml         encrypted secrets — safe to commit
systemd/                      colima.service, platform.service, platform-boot.sh
                              ↑ boot + reboot recovery. See README.
```

## Versions

`k8s/deploy.sh` is the only thing that decides what version a component is. Per component:

- **in sync with main** → the repo's latest git tag, e.g. `0.1.4`
- **differs from main** → that tag, suffixed: `0.1.4-snapshot`

"Differs" means uncommitted edits, untracked files, *or* commits not yet on `main` — anything that
makes the image something other than what `main` describes. The diff is **scoped to the component's
subtree**, because two components share a repo (`home` + `platform-auth`, both in project-platform) and
editing one must not stamp the other as a snapshot. The tag is repo-wide, because that is what a git
tag is.

The version reaches the running app as a **file baked into the image** (`ARG VERSION` → `VERSION`),
which the app reads at startup and serves from `/version`. It is also an OCI label, so an image can be
identified without running it.

### The platform's own version

**This repo has a version too, and it is the one exception to all of the above.** It ships no image —
it *is* the description of what gets deployed — so its version has nothing to ride in. Same rule
(latest tag, `-snapshot` when it differs from main; first tag is `0.1.0`), different delivery: the
deploy writes `platform-version.json` onto the **PersistentVolume**, next to the résumé and the card
decks, for the same reason those are there. `home` mounts the volume read-only at `/content`, reads
the spec **per request**, and serves it as `platform`.

Three things about that are deliberate:

- **Per request, not at startup.** A deploy rewrites the file. Read once at boot, home would report
  whatever platform version it happened to start with, and need a pointless rollout to tell the truth.
  Rewriting the spec updates the site with **no rollout at all** — a spec-only deploy takes ~10s.
- **home mounts `/content` read-only**, and the write happens through a separate pod — the
  version-writer Helm hook (`post-install,post-upgrade,post-rollback`), which mounts the PVC
  read-write. A public web server has no business rewriting the record of what is deployed.
- **The `/content` mount is a directory, not a `subPath`.** A `subPath` is resolved once at mount
  time, so the container would keep reading the inode it started with and never see a redeploy.

> **A deploy no longer dirties this repo — the old `-snapshot`-forever hole is CLOSED by the Helm
> migration.** deploy.sh used to write image pins into a tracked `kustomization.yaml`, so it had to
> EXCLUDE that file from the platform's own diff (`component_version "$ROOT" ':!…'`) or the platform
> reported `-snapshot` from its first deploy onward, forever. Helm passes the tags as `--set` values
> instead, writing nothing to the working tree, so the diff needs no special-case and the platform
> version is honest again — including catching a genuine hand edit that the exclusion used to hide.

> **The writer `chmod 0644`s the spec and ASSERTS the mode.** The version-writer hook renders the
> file from Helm values, writes it, and asserts the mode is `644` before exiting — so home's
> DIFFERENT user can read it. A `test -r` check would NOT catch a bad mode: the writer runs as root,
> and root can read a `0600` file, so the question is whether a different user can. Because it is a
> `--wait`/`--atomic` hook, a failed write rolls the whole deploy back rather than landing a
> `/version` that reports `null`. (Historically this bit as a `kubectl cp` tar stream carrying a
> local `0600` mode into the volume.)

`GET /version` → `{ version, platform }` · `GET /api/versions` → `{ platform, components: {…} }`.
`platform` is a sibling of `components`, not one of them: it has no image, no Pod and no Service.

**The version is half the image tag** (`platform-home:0.1.4-b8450b4`), and that is load-bearing, not
cosmetic. Cutting a git tag changes no source, so on a content-addressed tag alone a release would
produce an identical tag, skip the build as "content unchanged", skip the cluster push as "already
present", leave the Pod spec byte-identical — and never deploy. The `VERSION` file *is* image content,
so it has to be part of the image's identity. A pleasant side effect: `kubectl get deploy` shows the
running version without opening anything.

The home page displays it. `GET /api/versions` on the home server fans out to every component over
service DNS and answers as one object; the browser asks once per page load and **never polls** (a
version cannot change without new pods). The fan-out is server-side because `rs-mcp-server` and
`platform-auth` have no public `/version` route, and in production the API is a different origin.

## The image registry, and the trust that makes it usable

`k8s/registry.sh` — idempotent, run by **both** boot paths (`minikube-up.sh` and `platform-boot.sh`),
and safe to run by hand. A no-op takes ~2s.

It owns three things, and only the first is obvious:

1. a `registry:2` container serving **TLS** on minikube's docker network, at a **pinned** `192.168.49.10`
2. our CA, trusted by the **colima VM's** docker daemon — the one that **pushes**
3. our CA, trusted by the **minikube node's** docker daemon — the one that **pulls** for the kubelet

**Why it runs on every boot instead of being a setup step.** (2) lives in the colima VM's `/etc` and
(3) in the node container's `/etc`. Both survive a `stop`; both are **destroyed by a `delete`**.
Installed by hand they work perfectly — right up until the cluster is recreated, when every pull
fails with `x509: certificate signed by unknown authority` and nothing in git explains why. That is
the same failure shape as the systemd units that existed as files nobody had ever installed.

**Why TLS and not `--insecure-registry`.** Docker refuses a plain-HTTP registry no matter how
reachable it is — reachability and trust are different problems. `--insecure-registry` is only
accepted by minikube at **cluster creation**, so taking it would mean `minikube delete`, destroying
the sealed-secrets keypair. A CA we issue ourselves is read from
`/etc/docker/certs.d/registry:5000/ca.crt` with **no daemon restart and no cluster recreate**.

Sharp edges, each of which has already bitten once:

- **Trust is compared by fingerprint, not by presence.** A stale CA from a previous generation is
  worse than none: it fails identically while looking installed.
- **The registry's IP is pinned.** Colima's daemon is not on minikube's network, so it cannot resolve
  container names and needs an `/etc/hosts` entry — and docker reassigns IPs on restart. Unpinned,
  a restart silently sends pushes to whatever container took the old address.
- **The CA private key is deliberately NOT in the VM mount** (`.registry-ca/`, not `.platform-vm/`).
  Anything that can read it can mint a trusted cert for any host on this machine.
- **Colima mounts exactly one host directory** (`.platform-vm/`), narrowed from its default of all of
  `$HOME`. A path outside it does not exist inside the VM: a bind mount of it silently resolves to an
  **empty directory** — which is how this registry first crash-looped, from `/tmp`. The narrowing is
  what stops any container (notably a future CI runner holding the docker socket) from bind-mounting
  `~/.ssh`, `.env`, or the sealed-secrets master key.

## Why nginx and not Ingress annotations

Routing lives in `chart/files/nginx.conf`, and the Ingress is a dumb front door that hands it
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
