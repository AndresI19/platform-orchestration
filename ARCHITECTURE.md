# Platform Architecture

The full stack as it runs **today** (2026-07-13): five app repos, eight workloads, one Kubernetes
namespace, one Cloudflare tunnel. This is a description of what exists, not a plan.

- **Runs on:** minikube, inside a Colima QEMU VM, on one Fedora box.
- **Public entry:** a Cloudflare tunnel, dialled *outbound* from inside the cluster. No open ports.
- **Manifests:** `k8s/` in this repo. There is no docker-compose any more.

---

## 1. The whole picture

```
                          ┌─────────────────┐        ┌──────────────────────┐
   a visitor ────TLS────► │   Cloudflare    │        │  Claude Desktop /    │
                          │   (terminates   │ ◄──────│  any MCP client      │
                          │      TLS)       │  TLS   └──────────────────────┘
                          └────────┬────────┘
                                   │  outbound tunnel — NOT an inbound port
╔══════════════════════════════════╪═══════════════════════════════════════════════════╗
║  minikube cluster · namespace: platform                                               ║
║                                   │                                                   ║
║                          ┌────────▼────────┐                                          ║
║                          │  cloudflared    │  dials OUT to Cloudflare; no Service     ║
║                          └────────┬────────┘                                          ║
║                                   │ http (plain — TLS ended at Cloudflare)            ║
║                          ┌────────▼────────┐                                          ║
║       Ingress ─────────► │  nginx  :8080   │  ◄── THE ROUTER. Splits by Host AND path ║
║   (local access only)    └───┬────┬────┬───┘      Config: chart/files/nginx.conf      ║
║                              │    │    │                                              ║
║          ┌───────────────────┘    │    └────────────────┐                             ║
║          │                        │                     │                             ║
║   ┌──────▼──────┐        ┌────────▼────────┐   ┌────────▼─────────┐                   ║
║   │ home :3000  │        │  quiz  :80      │   │  vmcp  :8001     │                   ║
║   │ portfolio-  │        │  data-driven-   │   │  open-vMCP       │                   ║
║   │ home        │        │  quiz-server    │   │  (the gateway)   │                   ║
║   └──────┬──────┘        └────────┬────────┘   └──┬────────┬──────┘                   ║
║          │                        │               │        │                          ║
║          │ mounts                 │ mounts        │        │ SQL                      ║
║          │ resume.pdf             │ cards/        │        │                          ║
║          │   ┌────────────────────▼───┐           │   ┌────▼────────────┐             ║
║          └──►│ PVC: platform-content  │           │   │ vmcp-db :5432   │             ║
║              └────────────────────────┘           │   │ postgres:16     │             ║
║                                                   │   └────┬────────────┘             ║
║                                        MCP (SSE)  │        │ PVC: vmcp-db             ║
║                                   ┌───────────────┘        └──────────────            ║
║                                   │                                                   ║
║                        ┌──────────▼──────────┐                                        ║
║                        │ rs-mcp-server :8000 │   ◄─ FVT suite, replayed from the HOST  ║
║                        │ 17 RuneScape tools  │      via the public API (see note ▽)    ║
║                        └──────────┬──────────┘                                        ║
║                                   │                                                   ║
╚═══════════════════════════════════╪═══════════════════════════════════════════════════╝
                                    │ outbound HTTPS
              ┌─────────────────────┼──────────────────────┬──────────────────┐
              ▼                     ▼                      ▼                  ▼
     runescape.wiki      prices.runescape.wiki   secure.runescape.com   mcp.deepwiki.com
     oldschool.…wiki     (OSRS GE prices)        (hiscores)             (2nd MCP upstream,
     (MediaWiki API)                                                     reached from vmcp)
```

> ▽ **The FVT traffic runner is no longer in the cluster.** It used to be a `fvt-traffic` Deployment
> that dialled `vmcp` over cluster DNS. It now runs on the **host** (a compose service under
> platform-cicd) and reaches the gateway through the **public** API — `https://api-andres.project-platform.me`,
> in the front door with every other visitor. Two things forced the move: vMCP now *verifies* JWTs, so
> the runner has to sign in to `platform-auth` for a real token like any client (an in-cluster forgery
> was silently rejected); and exercising the same public path a real user takes is a better smoke test
> than an internal shortcut. It authenticates as the `fvt-runner` account and its `FVT_CODE` lives in
> the host's `.env`, not a cluster Secret.

---

## 2. Front ends — what links where

Three separate front ends, each a Vite build, each mounted under a different prefix by nginx. They
are **base-path aware**: nginx forwards the prefix *unchanged* (`proxy_pass` with no URI part), and
each app resolves its own assets beneath it.

| Front end | Repo | Prefix | Vite `base` | How the prefix is set |
| --- | --- | --- | --- | --- |
| Home page | `portfolio-home` | `/` | *(none)* | It lives at the root, so it has no `base`. |
| Quiz | `data-driven-quiz-server` | `/cloud-developer-quiz/` | `BASE_PATH` | **Build arg AND runtime env** — must match, or assets 404. |
| vMCP dashboard | `open-vMCP` (`web/`) | `/vmcp/` | hardcoded `/vmcp/` | `web/vite.config.ts` |

### Cross-links between front ends

- **Home → quiz, home → dashboard**: ordinary links in `portfolio-home/src/client/data.ts`.
- **Home → gateway (live data)**: `src/client/liveness.ts` polls the vMCP API to light up
  "is it up?" badges. It reads its API origin from `GET /api/config`, which returns `VMCP_API_BASE`.
- **Dashboard → home**: the "← Home" link is `HOME_URL` (set to `/`), served to the SPA at runtime
  via `GET /vmcp/config.json`.

That `config.json`/`api/config` indirection is the reason **one image serves both local and public**:
the API origin is resolved at *runtime*, not baked in at build. Locally it is empty (same-origin);
publicly it is the API host. No rebuild between the two.

---

## 3. Back ends — who talks to whom

| From | To | Protocol | Why |
| --- | --- | --- | --- |
| `cloudflared` | `nginx:8080` | HTTP | The public front door. Outbound-dialled; no inbound port. |
| Ingress | `nginx:8080` | HTTP | Local access only (`kubectl port-forward`). Not on the public path. |
| `nginx` | `home:3000`, `quiz:80`, `vmcp:8001` | HTTP | Path/host routing. |
| `vmcp` | `rs-mcp-server:8000/sse` | **MCP over SSE** | Registered upstream. Seeded by `SEED_URL_RS_MCP`. |
| `vmcp` | `mcp.deepwiki.com/mcp` | **MCP over Streamable HTTP** | Second upstream, external. |
| `vmcp` | `vmcp-db:5432` | Postgres | Registry, users, and the `tool_calls` telemetry table. |
| `fvt-traffic` *(host, not in-cluster)* | public API → `vmcp:8001/mcp/rs-mcp` | **MCP over Streamable HTTP** | Replays the FVT suite *through* the gateway, entering by the public front door. |
| `rs-mcp-server` | RuneScape wiki / GE / hiscores | HTTPS | Live game data. In-process LRU+TTL cache in front. |
| `home` | Discord webhook | HTTPS | The optional "who are you?" greeting. Unset → logs to stdout. |

### The transport detail that surprises people

**vMCP is an SSE ↔ Streamable-HTTP adapter, and that is not incidental.**

- **Downstream** (client → gateway) it speaks **Streamable HTTP only**. There is no SSE server
  endpoint on the gateway.
- **Upstream** (gateway → server) it speaks whatever the registry row says — `rs-mcp` is registered
  as `sse`, because **rs-mcp-server only speaks SSE** (`/sse` + `/messages/`; it has *no* `/mcp`
  route at all).

So a modern MCP client that only does Streamable HTTP cannot talk to `rs-mcp-server` directly — it
reaches it *through* the gateway. That is a real capability of the gateway, not just a proxy hop.

### Tool namespacing depends on which endpoint you hit

| Endpoint | Tool names | Used by |
| --- | --- | --- |
| `POST /mcp` (aggregate) | **prefixed**: `rs-mcp__search_wiki` | Claude Desktop — fronts every upstream at once |
| `POST /mcp/rs-mcp` (passthrough) | **unprefixed**: `search_wiki` | `fvt-traffic` — so the FVT suite runs unmodified |

That is exactly why `fvt-traffic` targets the per-slug route: the test suite asserts bare tool names.

---

## 4. Public hostnames

All three arrive on `nginx:8080` and are split by `Host` header (`chart/files/nginx.conf`).

| Host | Serves | Notes |
| --- | --- | --- |
| `andres.project-platform.me` | home, quiz, vMCP dashboard | Dashboard API is **read-only** here (`limit_except GET HEAD OPTIONS` → `POST` gets 403). `/mcp` deliberately 404s with a message naming the api host. |
| `api-andres.project-platform.me` | `/mcp`, `/api/…`, `/health` | The MCP endpoint an agent connects to. `/api/…` is rewritten onto the gateway's own `/vmcp/api/…`. |
| `project-platform.me`, `www.*` | 301 → `andres.*` | Keeps the apex free for a future platform landing page. |
| *(any other Host)* | everything, **writable** | `default_server` — the admin surface, reached by `kubectl port-forward`. |

The split is the point: **the public dashboard cannot be edited by a stranger.** vMCP's write API is
unauthenticated in v1, so administration is confined to the default vhost, which is only reachable
from inside the cluster.

---

## 5. State

Only two things in the whole platform are stateful.

| What | Where | Contents | If you delete it |
| --- | --- | --- | --- |
| `vmcp-db` PVC | Postgres | server registry, users, `tool_calls` telemetry | Registry re-seeds on boot from `config/servers.seed.json`; call history is lost (fvt-traffic repopulates it within 4h). |
| `platform-content` PVC | `resume.pdf`, `cards/*.yaml` | editable content | Re-seeded from the images' baked-in defaults by each Deployment's initContainer. |

Everything else is stateless and rebuildable from an image. Note the in-process state that is *not*
durable and does not survive a restart or scale-out: **home's rate limiter** (an in-memory `Map`),
**rs-mcp-server's cache** (an in-process `OrderedDict`), and **vMCP's MCP sessions** (an in-process
`Map` — which is why vMCP is **single-replica only**).

---

## 6. Ports

| Service | Port | Health check |
| --- | --- | --- |
| `nginx` | 8080 | `GET /api/health` (proxied to home — proves routing works, not just that nginx is listening) |
| `home` | 3000 | `GET /api/health` |
| `quiz` | 80 | `GET /cloud-developer-quiz/api/health` |
| `vmcp` | 8001 | `GET /health` |
| `rs-mcp-server` | 8000 | `GET /health` |
| `vmcp-db` | 5432 | `pg_isready` |

Nothing is published to the host. Local access is `kubectl port-forward svc/nginx 8081:8080` —
`minikube ip` and `minikube tunnel` **do not work here** (see `k8s/README.md`).

---

## 7. Secrets and config

- **Secrets are sealed** (`sealed-*.yaml`), encrypted with the cluster's public key and safe to
  commit. The controller decrypts them into real `Secret` objects at apply time. Managed via
  `./k8s/secrets.sh`. They are strict-scoped: bound cryptographically to namespace **and** name.
- **Config is a plain ConfigMap** (`platform-config`), set to public values by `values-public.yaml`.
  `VMCP_API_BASE`, `CORS_ORIGINS`, `HOME_URL`.

Because those reach the pods as **environment variables**, changing the ConfigMap does *not* restart
the pods that read them — `rollout restart` is required. (The nginx conf is different: the chart hashes
it into a `checksum/config` pod annotation, so editing it rolls the Deployment on its own.)

---

## 8. The repos

| Repo | Role | Stack |
| --- | --- | --- |
| `platform-orchestration` | This repo. Chart, routing, secrets, boot. | Kubernetes / Helm |
| `portfolio-home` | The home page. **Owns `@platform/ui`**, the shared design system. | TS, Vite, Express |
| `data-driven-quiz-server` | The quiz. Vendors `@platform/ui` as a git submodule. | TS, Vite, Express, zod |
| `open-vMCP` | The MCP gateway + Carbon dashboard. | TS, Express 5, React, Postgres, Drizzle |
| `rs-mcp-server` | 17 RuneScape MCP tools. | Python 3.12, Starlette, MCP SDK |

`@platform/ui` flows one way: `portfolio-home/packages/platform-ui` is the source of truth, and the
quiz consumes it by vendoring portfolio-home as a submodule at `vendor/portfolio-home`. It ships raw
TS/CSS with no build step. `serveClient()` — the Express static+SPA middleware and the `/api/health`
endpoint that **both** front ends rely on — lives in that package, not in either app.

---

## 9. Known rough edges

This repository is public. The notes below are the engineering debt worth knowing about; the
security posture of each component is tracked in that component's own repo, not enumerated here.

- **Authorisation is a routing-layer control, not an application one.** The public surfaces are
  constrained by nginx rather than by the apps themselves. That works, but it means the routing
  config is load-bearing for more than routing — treat changes to it as security changes.
- **`fvt-traffic` runs on the host, not in the cluster.** Its entrypoint is a `while true` loop that
  never exits, so it was never a good CronJob; it now lives as a compose service under platform-cicd,
  hitting the public API from outside — which also means it signs in to `platform-auth` for a real
  verified token instead of the in-cluster forgery vMCP now rejects.
- **vMCP is single-replica** (in-process session map) and its aggregate `tools/list` opens a fresh
  connection to *every* upstream on each request, while the dashboard polls every 5s.
- **Sealed-secrets' private key is the only thing** that can decrypt the committed `sealed-*.yaml`
  files. Recreate the cluster without a backup of it and they are lost for good.
- **Resource requests/limits are guesses**, sized to keep the stack schedulable rather than measured
  against real load. No HPA, no PodDisruptionBudgets, no TLS inside the cluster.
