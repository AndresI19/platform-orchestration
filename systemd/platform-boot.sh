#!/usr/bin/env bash
# Brings the whole platform up after a reboot, and announces both ends of the trip.
#
# This is the single entry point for boot: Colima (the Docker runtime VM) -> minikube -> kubeconfig
# repoint -> wait for the workloads -> verify the public site actually serves. Invoked by
# platform.service; every step is idempotent, so it is equally safe to run by hand after a crash.
#
# It deliberately does NOT build or load images. The minikube node is a container whose Docker daemon
# keeps its images across a stop/start, so a reboot only needs the cluster STARTED, not repopulated.
# Rebuilding five images on every boot would add minutes to the site's recovery time for nothing.
# Use k8s/minikube-up.sh when the images themselves need to change.
set -Eeuo pipefail   # -E so the ERR trap below still fires for a failure inside a function

# A systemd unit's PATH does not include Homebrew, where colima/minikube/kubectl live.
export PATH="/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SITE="${PLATFORM_SITE_URL:-https://project-platform.me}"
STARTED_AT="$(date +%s)"
STEP="startup"

# ---------------------------------------------------------------------------------------------
# Notifications
#
# Two channels, and they are NOT equally reliable at boot — the script leans on that difference:
#
#   Discord  — reachable as soon as the network is, which is before anything else here runs. This is
#              the channel that will actually deliver a boot message, so it is the one that matters.
#   Desktop  — notify-send needs org.freedesktop.Notifications, which is owned by gnome-shell. Under
#              `loginctl enable-linger` this script runs at BOOT, before any graphical session exists,
#              so at the moment the "booting" message is sent there is usually nobody listening.
#              desktop_notify therefore WAITS for the daemon to show up, and the opening message is
#              sent in the background so that wait never delays the platform coming back.
#
# Neither channel may ever fail the boot: every call is best-effort and swallows its own errors.
# ---------------------------------------------------------------------------------------------

# The webhook is a credential, so it is read from the gitignored .env rather than committed here.
# PLATFORM_BOOT_WEBHOOK_URL lets boot alerts go somewhere other than the home page's greeting channel;
# unset, they share it.
webhook_url() {
  local url="${PLATFORM_BOOT_WEBHOOK_URL:-}"
  if [[ -z "$url" && -r "$REPO/.env" ]]; then
    url="$(sed -n 's/^PLATFORM_BOOT_WEBHOOK_URL=//p' "$REPO/.env" | head -1)"
    [[ -z "$url" ]] && url="$(sed -n 's/^DISCORD_WEBHOOK_URL=//p' "$REPO/.env" | head -1)"
  fi
  printf '%s' "$url"
}

# Discord takes JSON, so anything interpolated into it has to be escaped. jq is not guaranteed to be
# on a boot PATH; this handles the three characters that can actually appear in these messages.
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
  # A systemd user unit gets no DBUS_SESSION_BUS_ADDRESS in its environment, but the user bus socket
  # is always at /run/user/$UID/bus once `systemd --user` is running — which linger guarantees.
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
# Backgrounded: it may sit for up to two minutes waiting for GNOME to appear, and the platform must
# not wait with it. The bring-up below takes minutes, so this child always finishes first.
desktop_notify "Platform booting" "$(hostname) rebooted — bringing the cluster back up." normal 120 &

discord_notify "🔄 Platform booting" \
  "**$(hostname)** rebooted (up $(cut -d. -f1 /proc/uptime)s) — starting Colima, then minikube, then the stack.
Expect the site back in ~5 minutes." 3447003  # blue

# --- 1. Colima: the Docker runtime ------------------------------------------------------------
# Docker on this box is not a system daemon — it is a QEMU VM that does not start itself, and the
# minikube node is a container INSIDE it. Nothing below can work until this is up. platform.service
# also pulls in colima.service; this call is the idempotent fast path (and what makes the script
# runnable standalone).
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
# THE STEP THAT IS EASY TO FORGET, and the one everything else depends on.
#
# minikube writes the node's bridge IP (192.168.49.2:8443) into kubeconfig. That address exists only
# inside Colima's VM network namespace, so from the host every kubectl call hangs. Colima forwards the
# node's published port out to the host — and Docker REASSIGNS that port on every container start, so
# it has to be re-read each boot rather than hard-coded. See k8s/README.md.
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
# `minikube status` is USELESS as a gate here, and gating on it (as this script used to) is expensive:
# it probes the apiserver at that same unroutable 192.168.49.2 and so reports the cluster unhealthy
# even when the site is serving perfectly. That means `minikube start` runs on EVERY boot — and
# against an already-healthy cluster, that start sits through a SIX-MINUTE "apiserver healthz never
# reported healthy" timeout before giving up. So gate on what is actually true instead: is the node
# container up, and does the apiserver answer once kubeconfig points at the forwarded port?
if node_running && repoint_kubeconfig && apiserver_answers; then
  echo "    already running"
else
  # Expect this to exit non-zero with "apiserver healthz never reported healthy". It is NOT a broken
  # cluster — it is the unroutable-IP problem again, surfacing as a start failure. Believing it would
  # abort a perfectly healthy boot; the repoint immediately below is what actually fixes it.
  minikube start --driver=docker --cpus=4 --memory=8g \
    || echo "    (start reported an error; repointing kubeconfig before believing it)"
  STEP="repointing kubeconfig"
  repoint_kubeconfig
  apiserver_answers || { echo "apiserver still unreachable after repointing kubeconfig" >&2; exit 1; }
fi

# --- 4. the workloads -------------------------------------------------------------------------
# Kubernetes restarts these on its own; this does not make them come back, it refuses to report
# success until they actually have — so `systemctl --user status platform` tells the truth.
STEP="waiting for the workloads"
echo "==> waiting for deployments"
kubectl -n platform wait --for=condition=available --timeout=600s deploy --all

# --- 5. verify the site actually serves --------------------------------------------------------
# Deployments being "available" means the containers are healthy, not that the public front door
# works — cloudflared could be up while the tunnel is not. Check the thing the user actually visits.
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
