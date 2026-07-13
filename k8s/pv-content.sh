#!/usr/bin/env bash
# pv-content.sh — replace files on the `platform-content` PersistentVolume (the résumé, the card
# decks) without an image rebuild.
#
# WHY A THROWAWAY POD. The volume is mounted into the running pods READ-ONLY and by subPath, so you
# cannot write to it through them. This brings up a short-lived pod that mounts the SAME PVC
# read-write at /content, copies your file in, then tears the pod down.
#
# WHY THE RESTART. A subPath single-file mount (home's /resume.pdf) is a bind mount to the file's
# inode. Replacing the file gives it a NEW inode, and the old bind mount would keep serving the old
# one — so after writing, the consumer is rolled so its mount re-resolves. (Cards are a directory
# mount and would pick up new files on their own, but the server reads decks once at startup, so it
# is restarted too.)
#
# Usage:
#   pv-content.sh ls
#   pv-content.sh set-resume <local.pdf>
#   pv-content.sh set-cards  <local-dir | one.yaml>
set -euo pipefail

NS=platform
PVC=platform-content
WRITER=pv-writer
cd "$(dirname "$0")"

die() { echo "ERROR: $*" >&2; exit 1; }
command -v kubectl >/dev/null || die "kubectl not found"

# Repoint kubeconfig at the forwarded apiserver port — same Colima/minikube reason as deploy.sh.
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx minikube; then
  P="$(docker port minikube 8443 2>/dev/null | head -1 | sed 's/.*://')"
  [ -n "${P:-}" ] && kubectl config set-cluster minikube --server="https://127.0.0.1:${P}" >/dev/null 2>&1 || true
fi
kubectl -n "$NS" get pvc "$PVC" >/dev/null 2>&1 || die "PVC '$PVC' not found in namespace '$NS' — is the cluster up?"

writer_down() { kubectl -n "$NS" delete pod "$WRITER" --ignore-not-found --now >/dev/null 2>&1 || true; }
writer_up() {
  writer_down
  kubectl -n "$NS" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: { name: $WRITER, namespace: $NS, labels: { app: pv-writer } }
spec:
  restartPolicy: Never
  terminationGracePeriodSeconds: 0
  containers:
    - name: w
      image: busybox:1.36
      command: ["sh", "-c", "sleep 3600"]
      volumeMounts: [{ name: content, mountPath: /content }]
  volumes:
    - name: content
      persistentVolumeClaim: { claimName: $PVC }
YAML
  kubectl -n "$NS" wait --for=condition=Ready "pod/$WRITER" --timeout=90s >/dev/null
}
roll() { # $1 = deploy name
  echo "==> restarting $1 so the change takes effect"
  kubectl -n "$NS" rollout restart "deploy/$1" >/dev/null
  kubectl -n "$NS" rollout status "deploy/$1" --timeout=150s
}

cmd="${1:-}"; arg="${2:-}"
case "$cmd" in
  ls)
    writer_up; trap writer_down EXIT
    echo "== platform-content =="
    kubectl -n "$NS" exec "$WRITER" -- sh -c 'ls -lh /content 2>/dev/null; echo; echo "cards/:"; ls /content/cards 2>/dev/null | sed "s/^/  /" || echo "  (none)"'
    ;;

  set-resume)
    [ -n "$arg" ] || die "usage: pv-content.sh set-resume <local.pdf>"
    [ -f "$arg" ] || die "file not found: $arg"
    case "$arg" in *.pdf) ;; *) die "the résumé must be a .pdf" ;; esac
    writer_up; trap writer_down EXIT
    kubectl -n "$NS" cp "$arg" "$NS/$WRITER:/content/resume.pdf"
    kubectl -n "$NS" exec "$WRITER" -- ls -lh /content/resume.pdf
    writer_down; trap - EXIT
    roll home
    echo "done — /resume.pdf now serves $(basename "$arg")"
    ;;

  set-cards)
    [ -n "$arg" ] || die "usage: pv-content.sh set-cards <local-dir | one.yaml>"
    [ -e "$arg" ] || die "path not found: $arg"
    writer_up; trap writer_down EXIT
    kubectl -n "$NS" exec "$WRITER" -- mkdir -p /content/cards
    if [ -d "$arg" ]; then
      kubectl -n "$NS" cp "$arg/." "$NS/$WRITER:/content/cards"
    else
      kubectl -n "$NS" cp "$arg" "$NS/$WRITER:/content/cards/$(basename "$arg")"
    fi
    kubectl -n "$NS" exec "$WRITER" -- sh -c 'ls /content/cards | wc -l | xargs echo "cards on the volume:"'
    writer_down; trap - EXIT
    roll quiz
    echo "done"
    ;;

  *)
    echo "usage: pv-content.sh {ls | set-resume <file.pdf> | set-cards <dir|file.yaml>}" >&2
    exit 2
    ;;
esac
