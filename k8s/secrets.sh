#!/usr/bin/env bash
# Seal, inspect, and recover the platform's secrets.
#
# ---------------------------------------------------------------------------------------------
# READ THIS FIRST, because it is the thing people get wrong about Sealed Secrets:
#
# There is no "fetch the secret and inject it into a Secret object" step, and this script does not
# provide one. The sealed-secrets controller ALREADY materialises a real Kubernetes Secret from each
# committed SealedSecret at apply time. `kubectl -n platform get secrets` lists them today.
#
# So a Helm chart that needs a credential does NOT need anything fetched. It references the Secret
# that already exists, by name — nearly every chart exposes this as `existingSecret` /
# `existingSecretName` / `envFrom`. Point it at one of ours, or seal a new one for it with
# `seal` below. (That is the difference from HashiCorp Vault, where an agent or CSI driver pulls
# secrets at RUNTIME. Sealed Secrets pushes them in at APPLY time.)
#
# THE SCOPING TRAP. Our SealedSecrets are strict-scoped, meaning each is cryptographically bound to
# BOTH its namespace and its name. Applying k8s/bootstrap/sealed-vmcp-db.yaml into a namespace other than
# `platform` does not fail with a permissions error you can grant your way out of — the controller
# simply cannot decrypt it, because the namespace is part of what was encrypted. A chart installed
# into a new namespace needs its OWN seal:
#
#     ./k8s/secrets.sh seal grafana-admin -n monitoring \
#         -o charts/grafana/sealed-grafana-admin.yaml \
#         admin-user=admin admin-password=@GRAFANA_PASSWORD
#
# ---------------------------------------------------------------------------------------------
# Usage
#
#   seal <name> [-n NS] [-o FILE] KEY=VALUE | KEY=@ENV_VAR ...
#       Seals a new SealedSecret. KEY=@ENV_VAR reads the value from .env instead of the command
#       line, so credentials never land in your shell history. Defaults: -n platform,
#       -o k8s/bootstrap/sealed-<name>.yaml.
#
#   show <name> [-n NS]
#       Prints the LIVE Secret's decoded values. This reads the cluster, not the sealed file — and
#       it is the only way to recover the Postgres password, which by design has no plaintext copy
#       on disk (it was generated, rotated with ALTER USER, and sealed). Values go to stdout only.
#
#   recover <sealed-file> [--key FILE]
#       Disaster recovery: decrypts a committed sealed file using the backed-up MASTER KEY, with no
#       cluster involved. This is what you use when minikube is gone. It reads your master private
#       key, so do not run it casually or on a shared machine.
#
#   list
#       Shows every SealedSecret and the Secret it produced.
set -euo pipefail

cd "$(dirname "$0")/.."
NS=platform
CONTROLLER_NS=kube-system
ENV_FILE=".env"
# Where the master key backup lives by default. NOT in this repo, and not in any git repo — a
# private key next to a git remote is one `git add -A` away from being published.
DEFAULT_KEY="$HOME/git-workspace/claude-workspace/sealed-secrets-master.key.yaml"

die() { echo "error: $*" >&2; exit 1; }

cmd_seal() {
  local name="" out="" args=()
  name="${1:?usage: seal <name> [-n NS] [-o FILE] KEY=VALUE|KEY=@ENV_VAR ...}"; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      -n|--namespace) NS="$2"; shift 2 ;;
      -o|--out)       out="$2"; shift 2 ;;
      *=*)
        local k="${1%%=*}" v="${1#*=}"
        # KEY=@ENV_VAR — pull the value out of .env rather than argv, so it never reaches the shell
        # history or the process list.
        if [ "${v:0:1}" = "@" ]; then
          local ref="${v:1}"
          [ -f "$ENV_FILE" ] || die "$ENV_FILE not found, needed for $k=@$ref"
          v="$(grep -m1 "^${ref}=" "$ENV_FILE" | cut -d= -f2-)" \
            || die "$ref not found in $ENV_FILE"
          [ -n "$v" ] || die "$ref is empty in $ENV_FILE"
        fi
        args+=(--from-literal="$k=$v"); shift ;;
      *) die "unrecognised argument: $1" ;;
    esac
  done
  [ ${#args[@]} -gt 0 ] || die "no KEY=VALUE pairs given"
  [ -n "$out" ] || out="k8s/bootstrap/sealed-${name}.yaml"

  # --dry-run: the plaintext Secret is only ever a stream on a pipe. It is never applied, and never
  # written to disk — the only artefact is the encrypted output.
  kubectl create secret generic "$name" -n "$NS" --dry-run=client -o yaml "${args[@]}" \
    | kubeseal --format yaml --controller-namespace "$CONTROLLER_NS" --scope strict \
    > "$out"

  echo "sealed $NS/$name -> $out  (strict scope: locked to this namespace AND name)"
  echo "then apply it: kubectl apply -f k8s/bootstrap/"
}

cmd_show() {
  local name="${1:?usage: show <name> [-n NS]}"; shift
  while [ $# -gt 0 ]; do case "$1" in -n|--namespace) NS="$2"; shift 2 ;; *) die "unrecognised: $1" ;; esac; done
  # Decoded in python rather than `base64 -d` in a shell loop: a secret value can legitimately
  # contain newlines (a PEM key, a JSON blob), which a line-oriented shell loop would mangle.
  kubectl -n "$NS" get secret "$name" -o json \
    | python3 -c '
import base64, json, sys
data = json.load(sys.stdin).get("data", {})
if not data:
    sys.exit("(no data in this secret)")
for k, v in sorted(data.items()):
    value = base64.b64decode(v).decode("utf-8", "replace")
    sys.stdout.write(k + "=" + value + "\n")'
}

cmd_recover() {
  local file="${1:?usage: recover <sealed-file> [--key FILE]}"; shift
  local key="$DEFAULT_KEY"
  while [ $# -gt 0 ]; do case "$1" in --key) key="$2"; shift 2 ;; *) die "unrecognised: $1" ;; esac; done
  [ -f "$file" ] || die "$file not found"
  [ -f "$key" ]  || die "master key not found at $key — restore it from your password manager"
  echo "# decrypting $file with the master key (no cluster involved)" >&2
  kubeseal --recovery-unseal --recovery-private-key "$key" -o yaml < "$file"
}

cmd_list() {
  printf "%-22s %-12s %s\n" "SEALEDSECRET" "NAMESPACE" "PRODUCES SECRET"
  kubectl get sealedsecrets -A --no-headers 2>/dev/null \
    | awk '{printf "%-22s %-12s %s\n", $2, $1, $2}'
}

case "${1:-}" in
  seal)    shift; cmd_seal "$@" ;;
  show)    shift; cmd_show "$@" ;;
  recover) shift; cmd_recover "$@" ;;
  list)    shift; cmd_list "$@" ;;
  *) sed -n '28,50p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
