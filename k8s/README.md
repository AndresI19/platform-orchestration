# Kubernetes (minikube)

**This is how the platform runs.** Every in-cluster workload, every route, the vhost split, the
read-only public API, the MCP endpoint, and the cloudflared tunnel — verified serving
project-platform.me from this cluster. (The FVT traffic runner used to live here too; it now runs on
the host and hits the public API from outside — see platform-cicd.) The docker-compose stack it was
ported from has been deleted; there is one way to run the platform now.

## Layout

```
charts/
├── platform-infra/             release 1 of 6 — what the services sit behind
│   ├── values.yaml             local defaults; platform.version comes from deploy.sh --set
│   ├── values-public.yaml      + cloudflared and the real hostnames — the public site
│   ├── files/nginx.conf        THE ROUTING TABLE — path map + vhost split
│   └── templates/              postgres.yaml (the two dbs), nginx.yaml, cloudflared.yaml,
│                               config.yaml, ingress.yaml, hooks/version-writer.yaml
├── service/                    releases 2–6 — the generic service chart. Each service is this chart
│                               plus its OWN repo's deploy/<name>.values.yaml. No values live here.
└── lib/                        the shared platform.app helper; vendored by `helm dependency build`
k8s/
├── minikube-up.sh              cold-boot bring-up (delegates to deploy.sh)
├── deploy.sh                   build → side-load → six helm upgrades. THE local deploy.
├── registry.sh · secrets.sh
└── bootstrap/                  applied once with kubectl, deliberately NOT owned by Helm:
    ├── namespace.yaml
    ├── deployer-rbac.yaml      the least-privilege CI identity
    ├── pvcs.yaml               the three PVCs — kept out of Helm so the data is never at risk
    └── sealed-*.yaml           encrypted secrets — safe to commit
```

## Bring it up

```bash
./k8s/minikube-up.sh          # cold boot: Colima → minikube → registry → bootstrap → deploy
kubectl -n platform port-forward svc/nginx 8081:8080
```

Then `http://localhost:8081/`, `/cloud-developer-quiz/`, `/vmcp/`, and `/mcp`.

To redeploy after a code change: `./k8s/deploy.sh`. It deploys **six releases** — `platform-infra`
plus one per service — so history and rollback are per component: `helm history quiz` lists that
service's revisions and `helm rollback quiz <n>` reverts it alone, without touching its siblings.
(That independence is the whole reason for the split; one release covering every app forced CI to
deploy with `--reuse-values`, which quietly made the release, not the chart, the source of truth.)
The reported platform version moves with `platform-infra`, whose post-rollback hook rewrites it.
Secrets and the PVCs are **bootstrap**: `kubectl apply -f k8s/bootstrap/` once,
before the first deploy (`minikube-up.sh` does this for you). The secrets are sealed into those
manifests, so there is no out-of-band `kubectl create secret` step. See
[Secrets are sealed](#secrets-are-sealed).

## Two things that are not what the minikube docs say

Both come from the same root cause: **Docker on this box is not a native daemon.** It runs inside a
Colima QEMU VM, so the K8s node container lives in the VM's network namespace, not the host's.

**1. The kubeconfig minikube writes points at an unroutable address.** minikube sees a unix socket,
concludes Docker is local, and writes the node's bridge address `192.168.49.2:8443`. That IP is only
reachable from inside the VM. From the host, every `kubectl` call hangs — and `minikube start` itself
exits with `apiserver healthz never reported healthy`, which reads as a broken cluster when in fact
the control plane is perfectly healthy and merely unreachable. Colima *does* forward the node's
published port out to the host, so the fix is to point kubeconfig there:

```bash
kubectl config set-cluster minikube --server="https://127.0.0.1:$(docker port minikube 8443 | head -1 | sed 's/.*://')"
```

Docker assigns that port at container-create time, so **it changes on every `minikube start`** —
which is why `minikube-up.sh` re-derives it rather than hard-coding it.

**2. `minikube docker-env` does not work here**, for the same reason — it exports `DOCKER_HOST`
pointing at that same dead IP. Build with Colima's Docker and side-load instead:

```bash
docker build -t home ../portfolio-home
docker tag home platform-home:latest
minikube image load platform-home:latest
```

The `platform-` prefix matters: with `imagePullPolicy: IfNotPresent` and a bare tag like `home`, a
cache miss sends the kubelet to Docker Hub for `docker.io/library/home` — a real name that isn't
ours. A miss on `platform-home` fails loudly instead.

A corollary: **`minikube ip` and `minikube tunnel` don't reach the host either.** Local access is via
`kubectl port-forward`, which tunnels over the (working) apiserver connection. The public path is
unaffected — cloudflared dials *out* from inside the cluster, so it never needs host routing at all.

## What changed in the port

| Compose | Kubernetes | Why |
| --- | --- | --- |
| `nginx` + `nginx/nginx.conf` | `nginx.yaml` + `files/nginx.conf` inlined into a ConfigMap, rolled by a checksum annotation | The conf stays the single routing table. See below. |
| `resolver 127.0.0.11` (Docker DNS) | `resolver 10.96.0.10` (CoreDNS) + **FQDN upstreams** | nginx's resolver ignores `/etc/resolv.conf` search domains, so short names like `home` would NXDOMAIN. Every upstream is now `home.platform.svc.cluster.local`. |
| `depends_on: condition: service_healthy` | `initContainer` running `pg_isready` | vMCP's entrypoint migrates+seeds before serving, so it must not start against a booting Postgres. A readinessProbe is too late — the entrypoint has already failed. |
| `profiles: [public]` | `values-public.yaml` (`./k8s/deploy.sh public`) | Same opt-in semantics: a plain `./k8s/deploy.sh` cannot publish the site — cloudflared is gated on a value that is off by default. |
| `.env` interpolation | `platform-config` ConfigMap + `platform-secrets` Secret | Same runtime-config contract: one image serves local and public, the overlay patches config rather than rebuilding. |
| n/a | `absolute_redirect off` | **New.** nginx built absolute `Location:` headers from its listen port and `$scheme`. Invisible under compose (published port was also 8080, dev was http); through a port-forward it redirected to a dead port, and behind Cloudflare's TLS termination it would bounce https visitors to `http://`. |

### Why nginx survived, instead of becoming Ingress annotations

The original scaffold's Ingress re-derived the path map as Ingress rules. That left two routing
tables to keep in sync, and it could only express the easy half. `nginx.conf` also:

- makes the **public** dashboard API read-only (`limit_except GET HEAD OPTIONS`) — verified: `POST`
  returns 403, `GET` returns 200;
- answers `/mcp` on the front-end host with a 404 naming the api host, so a misconfigured MCP client
  fails loudly rather than getting the SPA's catch-all HTML with a 200;
- rewrites the api host's clean `/api/…` onto the gateway's own `/vmcp/api/…`.

None of those are expressible in a stock Ingress — they need `configuration-snippet`, disabled by
default since CVE-2021-25742. So routing lives in exactly one file and the Ingress is a dumb front
door that hands everything to nginx.

The chart hashes `files/nginx.conf` into a `checksum/config` annotation on the pod template, so editing
the conf changes the Pod spec, which rolls the Deployment. (kustomize did this by hashing the conf into
the ConfigMap's *name* via `configMapGenerator`; Helm has no generator, so the checksum annotation is
the equivalent.) Without such a trigger, a ConfigMap updates in place while the running nginx keeps
serving the old routing table — `apply` reports success and nothing happens.

## Secrets are sealed

Nothing in this repo holds a credential in the clear. `sealed-*.yaml` files are **SealedSecrets**:
encrypted with the cluster's public key, decryptable only by the sealed-secrets controller, and only
into the namespace + name they were sealed for. They are meant to be committed.

`./k8s/secrets.sh` is the front door:

```bash
./k8s/secrets.sh seal <name> [-n NS] [-o FILE] KEY=VALUE | KEY=@ENV_VAR   # KEY=@ENV_VAR reads .env
./k8s/secrets.sh show <name> [-n NS]              # decode the LIVE Secret (see Postgres note below)
./k8s/secrets.sh recover <sealed-file>            # decrypt with the master key — no cluster needed
./k8s/secrets.sh list
```

`KEY=@ENV_VAR` pulls the value from `.env` rather than argv, so credentials never reach your shell
history or the process list.

### Installing a Helm chart that needs a secret

**There is nothing to "fetch".** The controller already materialises a real Kubernetes `Secret` from
each committed SealedSecret at apply time — `kubectl -n platform get secrets` lists them right now.
A chart just references one by name; nearly all of them expose this as `existingSecret` /
`existingSecretName` / `envFrom`. (This is the difference from HashiCorp Vault, where an agent pulls
secrets at *runtime*. Sealed Secrets pushes them in at *apply* time.)

What you cannot do is reuse a sealed file **in another namespace**. Ours are strict-scoped, i.e.
cryptographically bound to both namespace and name. Applying `sealed-vmcp-db.yaml` into `monitoring`
does not fail with a permission error you can grant your way around — the controller simply reports
`ErrUnsealFailed: no key could decrypt secret`, because the namespace is part of what was encrypted.
A chart in a new namespace needs its own seal:

```bash
./k8s/secrets.sh seal grafana-admin -n monitoring \
  -o charts/grafana/sealed-grafana-admin.yaml \
  admin-user=admin admin-password=@GRAFANA_PASSWORD
```

The Postgres password is generated, not chosen, and **has no plaintext copy on disk** — it exists
only inside the sealed manifest and the database itself. `./k8s/secrets.sh show vmcp-db` is how you
read it back.

Rotating it means changing it **inside the running database** as well as in the secret —
`POSTGRES_PASSWORD` is only read by `initdb`, i.e. on a fresh volume, so changing the secret alone
leaves the database still expecting the old password:

```bash
kubectl -n platform exec deploy/vmcp-db -- psql -U vmcp -d vmcp -c "ALTER USER vmcp WITH PASSWORD '<new>';"
# …re-seal with the new value, apply, then: kubectl -n platform rollout restart deploy/vmcp
```

> **Back up the controller's private key, off this machine.** It is the only thing that can decrypt
> the committed `sealed-*.yaml` files. Delete and recreate the cluster and a fresh controller
> generates a *new* keypair — every sealed file in git becomes permanently undecryptable. The
> encrypted manifests are not a backup; the key is.
>
> ```bash
> kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > key.yaml
> ```

## Editable content on a volume

`resume.pdf` and the quiz's card decks are **not baked into the images** — they live on the
`platform-content` PVC, so changing a card's wording or dropping in a new résumé does not mean
rebuilding and reloading a 500MB image.

Each Deployment carries an initContainer that copies its own baked-in defaults onto the volume with
`cp -n`, so a fresh cluster comes up populated, the images still run standalone, and a restart never
stamps the image's version over content you have edited.

Two sharp edges worth knowing:

- **`home` mounts `resume.pdf` as a single file** (`subPath`). A `subPath` that does not exist yet is
  created by the kubelet as an empty **directory** — which is why the seed initContainer must run
  first, and why it is an initContainer rather than a Job.
- **The quiz reads its cards once, at startup.** Editing a deck on the volume does nothing until
  `kubectl -n platform rollout restart deploy/quiz`.

`ReadWriteOnce` is honest rather than aspirational: minikube's hostPath provisioner is single-node and
RWO is enforced per *node*, so `home` and `quiz` can both mount it. A real multi-node cluster would
need RWX (an NFS/CSI class) or one volume per app.

## The public site

`values-public.yaml` (deploy with `./k8s/deploy.sh public`) adds cloudflared and repoints the apps at
the real hostnames. **It is applied — project-platform.me is served from this cluster**, and the
compose connector is gone.

If you ever run a second connector (another host, a rebuilt cluster), understand what that does:
Cloudflare treats every connector registered against a tunnel as an HA replica and load-balances
across them. Two connectors do not fail over — they **split live traffic**, with no way for a visitor
to tell which stack answered. Stop the old connector before starting a new one.

Note that the overlay patches `VMCP_API_BASE` and `CORS_ORIGINS` in a plain ConfigMap, and those
reach the pods as **environment variables**, which are read once at container start. Applying the
overlay therefore does *not* restart the pods that consume them:

```bash
./k8s/deploy.sh public
kubectl -n platform rollout restart deploy/home deploy/vmcp   # ConfigMap env is read once at start
```

## Still rough before any non-local use

- **No TLS, no HPA, no PodDisruptionBudgets.** Cloudflare terminates TLS today, so the cluster speaks
  plain http internally — fine behind the tunnel, not fine if anything else is ever pointed at it.
- **Resource requests/limits are guesses**, set to keep the stack schedulable on a 4 CPU / 8 GiB
  node, not measured against real load.
- **`fvt-traffic` no longer runs in the cluster** — it moved to the host (a compose service under
  platform-cicd) and now reaches the gateway through the public API. Its `while true` entrypoint never
  exited, so it was a poor fit for a CronJob Pod anyway; and because vMCP verifies JWTs now, it signs
  in to `platform-auth` for a real token rather than minting the forged bearer it used to.
