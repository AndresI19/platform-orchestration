# platform-orchestration

Orchestration for the personal platform: an **nginx** reverse proxy that reconciles three app
containers onto **one external port (8080)** by URL path, plus a `docker compose` stack for the
local demo and a **minikube** Kubernetes scaffold for later.

## Path map

| URL (through nginx `:8080`)        | Container        | What it is                                  |
| ---------------------------------- | ---------------- | ------------------------------------------- |
| `/`                                | `home` (:3000)   | Personal home page + project index          |
| `/cloud-developer-quiz/`           | `quiz` (:80)     | The flashcards quiz                          |
| `/vmcp/`                           | `vmcp` (:8001)   | open-vMCP Carbon dashboard                   |
| `/mcp`                             | `vmcp` (:8001)   | MCP endpoint for Claude Desktop              |

Each app is **base-path aware** (its Vite `base` / router / server all know their prefix), so nginx
forwards the prefix **unchanged** (`proxy_pass` with no URI part) and the app resolves its own
assets and routes beneath it. nginx resolves upstreams at request time via Docker's embedded DNS
(`resolver 127.0.0.11`), so it starts even if an app is briefly unavailable.

The sibling app repos are the build sources: `../portfolio-home`, `../flashcards-app`, `../open-vMCP`.

## Run the local demo (docker compose)

Colima must be running first (Linux): `colima start`.

```bash
docker compose up --build
# then open:
#   http://localhost:8080/                        (home)
#   http://localhost:8080/cloud-developer-quiz/    (quiz)
#   http://localhost:8080/vmcp/                    (vMCP dashboard)
#   http://localhost:8080/mcp                       (MCP endpoint)
```

Only nginx publishes a port; the apps and Postgres talk over the internal `platform` network by
service name. The `vmcp` container migrates + seeds its database on startup (see its entrypoint).

> If the `docker compose` CLI plugin isn't installed, the same stack can be run by hand with
> `docker build` + `docker run --network ... --network-alias ...` using the service names above as
> aliases — that is exactly what compose automates.

## Kubernetes (minikube) — scaffold for later

`k8s/` holds a Deployment + Service per app and an Ingress that mirrors the nginx path map, aimed at
a local **minikube** cluster. `.github/workflows/deploy.yml` is a stubbed CI/CD pipeline that builds
the images and applies the manifests. These are **not** wired up in this round — the working
deliverable is the compose demo. To bring the cluster up later:

```bash
minikube start
minikube addons enable ingress
# build images into minikube's docker, then:
kubectl apply -k k8s/
```

See `k8s/README.md` for the details and the intentionally-left placeholders.
