# Kubernetes (minikube) — scaffold

A Deployment + Service per app, a Postgres for vMCP, and an **Ingress** that mirrors the compose
nginx path map. This is a **scaffold for a later phase** — the working demo is `docker compose up`
at the repo root. The manifests render cleanly (`kubectl kustomize k8s/`) but haven't been rolled
out to a live cluster here.

## Contents

| File | What |
| --- | --- |
| `namespace.yaml` | the `platform` namespace |
| `secret.yaml` | Postgres creds + `DATABASE_URL` (**placeholder values — replace**) |
| `vmcp-db.yaml` | Postgres Deployment + PVC + Service |
| `home.yaml` / `quiz.yaml` / `vmcp.yaml` | Deployment + Service per app |
| `ingress.yaml` | path routing (`/`, `/cloud-developer-quiz`, `/vmcp`, `/mcp`) |
| `kustomization.yaml` | ties them together |

The Ingress forwards each matched path **unchanged** to its backend (no rewrite), the same contract
the base-path-aware apps rely on under the compose nginx.

## Bring it up on minikube (later)

```bash
minikube start
minikube addons enable ingress                 # installs ingress-nginx

# Build the images INTO minikube's docker daemon so the cluster can use them without a registry:
eval $(minikube docker-env)
docker build -t platform-home  ../portfolio-home
docker build -t platform-quiz  --build-arg BASE_PATH=/cloud-developer-quiz/ ../flashcards-app
docker build -t platform-vmcp  ../open-vMCP

kubectl apply -k k8s/
kubectl -n platform rollout status deploy/vmcp

# Access it:
minikube ip                                     # e.g. 192.168.49.2 → http://<ip>/
# or:  minikube tunnel     (then http://localhost/)
```

## Placeholders to fill before any non-local use

- **`secret.yaml`** — the Postgres password is a literal `vmcp`. Replace with a real secret
  (sealed-secrets / external secret store); never commit real values.
- **Image references** — `imagePullPolicy: IfNotPresent` assumes locally-built images. For CI/CD,
  push to a registry and pin tags (see `../.github/workflows/deploy.yml`).
- **Resource requests/limits, HPA, TLS** — not set; add before treating this as more than a demo.
