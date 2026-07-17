# platform-orchestration

Orchestration for the personal platform. It runs on **Kubernetes (minikube)**: a Deployment per app
behind an **nginx** router that reconciles them onto one port by URL path, with a **cloudflared**
tunnel serving the public site. This repo is the only place the platform's topology is described.

The sibling app repos are the build sources: `../project-platform` (home + platform-auth),
`../data-driven-quiz-server`, `../open-vMCP`, `../rs-mcp-server`.

## Path map

| URL                      | Service           | What it is                          |
| ------------------------ | ----------------- | ----------------------------------- |
| `/`                      | `home` (:3000)    | Personal home page + project index  |
| `/cloud-developer-quiz/` | `quiz` (:80)      | The flashcards quiz                 |
| `/vmcp/`                 | `vmcp` (:8001)    | open-vMCP Carbon dashboard          |
| `/mcp`                   | `vmcp` (:8001)    | MCP endpoint for Claude Desktop     |

Each app is **base-path aware** (its Vite `base`, router, and server all know their prefix), so nginx
forwards the prefix **unchanged** and the app resolves its own assets beneath it.

nginx — not the Ingress — owns the routing, because it also splits traffic by Host header, guards
`/mcp` on the front-end host, and rewrites the api host's `/api/…` onto the gateway's `/vmcp/api/…`.
None of that is expressible in a stock Ingress. See `k8s/README.md`.

## Run it

```bash
./k8s/minikube-up.sh                              # Colima → minikube → registry → bootstrap → deploy (helm)
kubectl -n platform port-forward svc/nginx 8081:8080
# http://localhost:8081/   /cloud-developer-quiz/   /vmcp/   /mcp
./k8s/deploy.sh                                   # redeploy after a code change
helm list -n platform                             # the six releases: platform-infra + one per service
helm history <release> ; helm rollback <release> <n>   # history + rollback, per component
```

The cluster has **no host-routable IP** — minikube runs inside a Colima QEMU VM, so `minikube ip` and
`minikube tunnel` do not work here. Local access is via `port-forward`. The public site is unaffected,
because cloudflared dials *out* from inside the cluster. `k8s/README.md` explains this in full; it is
the single most confusing thing about this setup.

## The public site

`./k8s/deploy.sh public` (which layers `charts/platform-infra/values-public.yaml`) adds the cloudflared connector and
repoints the apps at the real hostnames. It is already applied — **project-platform.me is served from
this cluster.**

| Host | Serves |
| --- | --- |
| `andres.project-platform.me` | the front ends (home, quiz, vMCP dashboard). Dashboard writes need a signed admin token, checked by the gateway. |
| `api-andres.project-platform.me` | the back end: `/mcp`, the read-only data API, `/health` |
| `project-platform.me`, `www.*` | 301 → `andres.*` |

## Secrets

Secrets are **sealed**, not committed in the clear. The `sealed-*.yaml` files are encrypted with the
cluster's public key and are safe to be in git; only the sealed-secrets controller can decrypt them.

```bash
./k8s/secrets.sh seal <name> [-n NS] [-o FILE] KEY=VALUE | KEY=@ENV_VAR   # KEY=@ENV_VAR reads .env
./k8s/secrets.sh show <name>            # decode the live Secret
./k8s/secrets.sh recover <sealed-file>  # decrypt with the master key, no cluster needed
```

A Helm chart needing a credential does **not** fetch anything — the controller already materialises
a real `Secret` from each sealed file, so the chart just references it by name (`existingSecret:`).
But a chart in a *new namespace* needs its own seal: our secrets are strict-scoped, bound
cryptographically to both namespace and name. See `k8s/README.md`.

`.env` (gitignored) holds the plaintext originals and is only needed when re-sealing.

> **The controller's private key is the only thing that can decrypt those files.** If the cluster is
> ever deleted and recreated, a fresh controller generates a new keypair and every committed
> `sealed-*.yaml` becomes permanently undecryptable. Back the key up, off this machine.

## Editable content

`resume.pdf` and the quiz's card decks live on a **PersistentVolume**, not in the images, so they can
be changed without a rebuild. Each Deployment seeds the volume from its own baked-in defaults on
first boot and never overwrites what is already there.

```bash
kubectl cp resume.pdf platform/$(kubectl -n platform get pod -l app=home -o name | cut -d/ -f2):/app/dist/client/resume.pdf
kubectl -n platform rollout restart deploy/quiz   # cards are read once at startup
```

## Surviving a reboot

Nothing starts on its own: Kubernetes restarts the workloads, but nothing restarts Kubernetes — the
minikube node is a container inside a Colima VM, and neither comes up by itself. Two **user** units
handle it, and both are needed:

```bash
mkdir -p ~/.config/systemd/user
cp systemd/colima.service systemd/platform.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable colima.service platform.service
sudo loginctl enable-linger "$USER"   # WITHOUT THIS, user units do not start at boot
```

**Copying the units into the repo is not installing them.** Both halves above are load-bearing, and
on 2026-07-14 a reboot took the site down because neither had been run: the units existed here, in
git, where systemd never looks. Verify with `systemctl --user is-enabled platform` and
`loginctl show-user "$USER" -p Linger` — the answers must be `enabled` and `Linger=yes`.

`loginctl enable-linger` is the half people miss: a user unit otherwise waits for an interactive
login, so the site stays down after a reboot until someone signs in.

`platform.service` runs [`systemd/platform-boot.sh`](systemd/platform-boot.sh), which is also the
by-hand recovery command — it is idempotent, and re-running it against a healthy stack costs ~4s:

```bash
./systemd/platform-boot.sh     # Colima → minikube → repoint kubeconfig → wait → verify the live site
```

A cold boot takes ~5 minutes, nearly all of it Colima's VM and the K8s control plane. It announces
both ends of the trip to Discord and to the desktop:

| | Discord | Desktop toast |
|---|---|---|
| **Start** | 🔄 booting, with hostname + uptime | best-effort — see below |
| **Finish** | ✅ up, with duration, pod count, and a per-route check of the live site | same |
| **Failure** | ❌ which step failed, and the `journalctl` line to run | urgency=critical |

The two channels are not equally reliable, and the script leans on the difference. Discord is
reachable as soon as the network is. The desktop toast needs `org.freedesktop.Notifications`, owned
by gnome-shell — which under linger does not exist yet when the machine boots, so `platform-boot.sh`
waits up to 2 minutes for a session to appear and sends the opening toast in the background rather
than making the site wait for a human to log in. **Discord is the channel that will actually deliver
a boot message.** Set `DISCORD_WEBHOOK_URL` in `.env` (or `PLATFORM_BOOT_WEBHOOK_URL` to send boot
alerts somewhere other than the home page's greeting channel); with neither set, the script logs and
carries on. A notification failure never fails a boot.

## Dev environment

Docker requires **Colima** on Linux (`colima start`). It runs an 8 CPU / 16 GiB VM; the defaults
(2 CPU / 4 GiB) are too small to hold a Kubernetes control plane plus ingress-nginx plus the stack.
