#!/usr/bin/env bash
# Brings the whole platform up after a reboot and announces both ends of the trip. The single boot
# entry point: Colima (the Docker runtime VM) -> minikube -> kubeconfig repoint -> wait for workloads
# -> verify the public site serves. Invoked by platform.service; every step is idempotent, so it is
# equally safe to run by hand after a crash.
#
# It deliberately does NOT build or load images: the minikube node's Docker daemon keeps its images
# across a stop/start, so a reboot only needs the cluster STARTED, not repopulated. Use
# k8s/minikube-up.sh when the images themselves need to change.
set -Eeuo pipefail   # -E so the ERR trap below still fires for a failure inside a function

# A systemd unit's PATH does not include Homebrew, where colima/minikube/kubectl live.
export PATH="/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SITE="${PLATFORM_SITE_URL:-https://project-platform.me}"
STARTED_AT="$(date +%s)"
STEP="startup"

# Notifications — two channels, NOT equally reliable at boot; the script leans on that difference:
#   Discord — reachable as soon as the network is (before anything else here runs). The channel that
#             will actually deliver a boot message, so the one that matters.
#   Desktop — notify-send needs org.freedesktop.Notifications, owned by gnome-shell. Under
#             `loginctl enable-linger` this runs at BOOT, before any graphical session exists, so
#             usually nobody is listening yet. desktop_notify therefore WAITS for the daemon, and the
#             opening message is backgrounded so that wait never delays the platform coming back.
# Neither may ever fail the boot: every call is best-effort and swallows its own errors.

# The webhook is a credential, read from the gitignored .env rather than committed.
# PLATFORM_BOOT_WEBHOOK_URL sends boot alerts somewhere other than the home page's greeting channel;
# unset, they share it.
webhook_url() {
  local url="${PLATFORM_BOOT_WEBHOOK_URL:-}"
  if [[ -z "$url" && -r "$REPO/.env" ]]; then
    url="$(sed -n 's/^PLATFORM_BOOT_WEBHOOK_URL=//p' "$REPO/.env" | head -1)"
    [[ -z "$url" ]] && url="$(sed -n 's/^DISCORD_WEBHOOK_URL=//p' "$REPO/.env" | head -1)"
  fi
  printf '%s' "$url"
}

# Discord takes JSON, so interpolated values must be escaped. jq isn't guaranteed on a boot PATH; this
# handles the three characters that can actually appear in these messages.
json_escape() {
  local s=${1//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  printf '%s' "$s"
}

# discord_notify <title> <body> <color-decimal>
discord_notify() {
  local url; url="$(webhook_url)"
  if [[ -z "$url" ]]; then
    echo "notify: no webhook configured (set DISCORD_WEBHOOK_URL in .env); skipping Discord" >&2
    return 0
  fi
  local payload
  payload=$(printf '{"username":"platform","embeds":[{"title":"%s","description":"%s","color":%s}]}' \
    "$(json_escape "$1")" "$(json_escape "$2")" "$3")
  # --retry covers the case where the network is still settling at boot.
  curl -fsS --max-time 15 --retry 3 --retry-connrefused \
    -H 'Content-Type: application/json' -d "$payload" "$url" -o /dev/null 2>/dev/null \
    || echo "notify: Discord post failed (continuing)" >&2
}

# desktop_notify <title> <body> <urgency> <seconds-to-wait-for-a-notification-daemon>
desktop_notify() {
  # A systemd user unit gets no DBUS_SESSION_BUS_ADDRESS, but the user bus socket is always at
  # /run/user/$UID/bus once `systemd --user` is running — which linger guarantees.
  export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus}"
  local waited=0 limit="${4:-0}"
  while ! gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
        --method org.freedesktop.DBus.NameHasOwner org.freedesktop.Notifications 2>/dev/null \
        | grep -q true; do
    (( waited >= limit )) && { echo "notify: no desktop notification daemon after ${limit}s; skipping" >&2; return 0; }
    sleep 2; waited=$(( waited + 2 ))
  done
  notify-send --app-name=platform --urgency="$3" --icon=network-server "$1" "$2" 2>/dev/null \
    || echo "notify: notify-send failed (continuing)" >&2
}

# ---------------------------------------------------------------------------------------------

fail() {
  trap - ERR   # the notifiers below must not re-enter this handler
  local secs=$(( $(date +%s) - STARTED_AT ))
  discord_notify "❌ Platform boot FAILED" \
    "**$(hostname)** — failed during **${STEP}** after ${secs}s.
The site is likely still down. Logs: \`journalctl --user -u platform -b\`" 15548997  # red
  desktop_notify "Platform boot failed" "Failed during ${STEP} after ${secs}s — the site is still down." critical 15
}
trap fail ERR

# --- announce the reboot ----------------------------------------------------------------------
# Backgrounded: it may sit up to two minutes waiting for GNOME, and the platform must not wait with it.
# The bring-up below takes minutes, so this child always finishes first.
desktop_notify "Platform booting" "$(hostname) rebooted — bringing the cluster back up." normal 120 &

discord_notify "🔄 Platform booting" \
  "**$(hostname)** rebooted (up $(cut -d. -f1 /proc/uptime)s) — starting Colima, then minikube, then the stack.
Expect the site back in ~5 minutes." 3447003  # blue

# --- 1. Colima: the Docker runtime ------------------------------------------------------------
# Docker here is not a system daemon — it is a QEMU VM that does not start itself, and the minikube
# node is a container INSIDE it. Nothing below works until this is up. platform.service also pulls in
# colima.service; this call is the idempotent fast path (and makes the script runnable standalone).
STEP="colima start"
echo "==> Colima"
colima status &>/dev/null || colima start

# "Started" for a oneshot unit only means `colima start` returned — the docker socket can still be a
# moment behind it. Poll rather than assume.
STEP="waiting for the docker socket"
for _ in $(seq 1 60); do
  docker info >/dev/null 2>&1 && break
  sleep 2
done
docker info >/dev/null 2>&1 || { echo "docker never came up; is colima running?" >&2; exit 1; }
echo "    docker ready"

# --- 2. minikube ------------------------------------------------------------------------------
# The step that is easy to forget, and the one everything else depends on. minikube writes the node's
# bridge IP (192.168.49.2:8443) into kubeconfig; that address exists only inside Colima's VM network
# namespace, so from the host every kubectl call hangs. Colima forwards the node's published port out,
# and Docker REASSIGNS that port on every container start, so re-read it each boot. See k8s/README.md.
repoint_kubeconfig() {
  local port
  port="$(docker port minikube 8443 2>/dev/null | head -1 | sed 's/.*://')"
  [[ -n "$port" ]] || return 1
  kubectl config set-cluster minikube --server="https://127.0.0.1:${port}" >/dev/null
  echo "    apiserver -> https://127.0.0.1:${port}"
}
node_running() { docker ps --format '{{.Names}}' | grep -qx minikube; }
apiserver_answers() { kubectl --request-timeout=10s get --raw /healthz &>/dev/null; }

STEP="minikube"
echo "==> minikube"
# `minikube status` is USELESS as a gate here: it probes that same unroutable 192.168.49.2 and reports
# the cluster unhealthy even while the site serves. Gating on it (as this script used to) runs
# `minikube start` on EVERY boot, and against a healthy cluster that start sits through a SIX-MINUTE
# "apiserver healthz never reported healthy" timeout. So gate on what is true: is the node container
# up, and does the apiserver answer once kubeconfig points at the forwarded port?
if node_running && repoint_kubeconfig && apiserver_answers; then
  echo "    already running"
else
  # Expect a non-zero exit with "apiserver healthz never reported healthy": NOT a broken cluster, the
  # unroutable-IP problem surfacing as a start failure. Believing it would abort a healthy boot; the
  # repoint below is the actual fix.
  minikube start --driver=docker --cpus=4 --memory=8g \
    || echo "    (start reported an error; repointing kubeconfig before believing it)"
  STEP="repointing kubeconfig"
  repoint_kubeconfig
  apiserver_answers || { echo "apiserver still unreachable after repointing kubeconfig" >&2; exit 1; }
fi

# --- 3b. the registry, and the trust that makes it usable --------------------------------------
# Before the workloads: a Deployment whose image lives in the registry cannot start until the node can
# pull from it. Idempotent — on an ordinary reboot this is a few seconds of "already up". It runs on
# EVERY boot because two of the three things it installs (the CA in the colima VM's /etc and in the
# node container's /etc) survive a `stop` but a `delete` destroys — after which every pull fails
# `x509: certificate signed by unknown authority` and nothing says why. See k8s/registry.sh.
STEP="the registry and its CA trust"
"${REPO}/k8s/registry.sh"

# --- 4. the workloads -------------------------------------------------------------------------
# Kubernetes restarts these on its own; this doesn't make them come back, it refuses to report success
# until they have — so `systemctl --user status platform` tells the truth.
STEP="waiting for the workloads"
echo "==> waiting for deployments"
kubectl -n platform wait --for=condition=available --timeout=600s deploy --all

# --- 5. verify the site actually serves --------------------------------------------------------
# "Available" means the containers are healthy, not that the public front door works — cloudflared can
# be up while the tunnel is not. Check the thing the user actually visits.
STEP="verifying the public site"
echo "==> verifying $SITE"
SITE_REPORT=""
DEGRADED=0
for path in / /cloud-developer-quiz/ /vmcp/ /resume.pdf; do
  code="$(curl -sL -o /dev/null -w '%{http_code}' --max-time 25 "${SITE}${path}" 2>/dev/null || echo 000)"
  [[ "$code" == "200" ]] || DEGRADED=1
  mark=$([[ "$code" == "200" ]] && echo "✅" || echo "⚠️")
  SITE_REPORT+="${mark} \`${path}\` — ${code}"$'\n'
  echo "    ${path} -> ${code}"
done

# --- done -------------------------------------------------------------------------------------
ELAPSED=$(( $(date +%s) - STARTED_AT ))
PODS="$(kubectl -n platform get pods --no-headers 2>/dev/null | grep -c Running || echo '?')"

if (( DEGRADED )); then
  discord_notify "⚠️ Platform up, site DEGRADED" \
    "**$(hostname)** — cluster back in ${ELAPSED}s, ${PODS} pods running, but not every route serves:
${SITE_REPORT}" 16098851  # amber
  desktop_notify "Platform up — site degraded" "Cluster back in ${ELAPSED}s (${PODS} pods), but some routes are not serving." critical 15
else
  discord_notify "✅ Platform up" \
    "**$(hostname)** — reboot complete in ${ELAPSED}s. ${PODS} pods running, every route serving.
${SITE_REPORT}<${SITE}>" 3066993  # green
  desktop_notify "Platform up" "Reboot complete in ${ELAPSED}s — ${PODS} pods running, ${SITE} is serving." normal 15
fi

wait  # let the backgrounded opening notification finish before the unit's cgroup is torn down
echo "==> platform is up (${ELAPSED}s)"
