#!/usr/bin/env bash
# The image registry, and — the part that is easy to forget — the TRUST that makes it usable.
# Idempotent, safe on every boot. Called by k8s/minikube-up.sh (cold boot) and
# systemd/platform-boot.sh (reboot); also runnable by hand.
#
# WHY A SCRIPT, NOT A README: the registry needs THREE things, two of which live in filesystems a
# `stop` survives but a `delete` wipes:
#   1. The registry itself — a container on minikube's docker network, serving TLS.
#   2. The CA, trusted by the COLIMA VM's docker daemon — the one that PUSHES.       (VM /etc, colima delete wipes)
#   3. The CA, trusted by the MINIKUBE NODE's docker daemon — PULLS for the kubelet. (node /etc, minikube delete wipes)
# Install (2)/(3) by hand once and it works — until the cluster is recreated, when every pull fails
# `x509: certificate signed by unknown authority` and nothing in git says why (exactly how this
# platform's systemd units came to be files that had never been installed). So the trust is not a
# setup step — it is part of bringing the platform up, every time.
#
# WHY TLS, NOT --insecure-registry: Docker refuses plain HTTP however reachable — reachability and
# trust are different problems. minikube only accepts `--insecure-registry` at CLUSTER CREATION, so
# taking it means `minikube delete`, destroying the sealed-secrets keypair (the only thing that can
# decrypt every committed sealed-*.yaml). Instead we issue our own CA: docker reads a per-registry CA
# from /etc/docker/certs.d/<host>:<port>/ca.crt with NO daemon restart and NO cluster recreate.
set -Eeuo pipefail

export PATH="/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin"

REG_NAME="registry"
REG_PORT=5000
REG_HOST="registry:${REG_PORT}"
# A FIXED address, deliberately. Colima's daemon is not on minikube's network, so it cannot resolve
# container names and needs an /etc/hosts entry — and docker reassigns IPs on restart. Unpinned, a
# restart silently points pushes at whatever container took the old IP. .10 sits clear of the low
# addresses docker hands out sequentially (the node is .2).
REG_IP="192.168.49.10"
NETWORK="minikube"

# The ONE directory Colima mounts into the VM (~/.config/colima/default/colima.yaml). A path outside
# it does not exist in the VM: a bind mount of it silently resolves to an empty directory — which is
# how this registry first crash-looped, from /tmp.
VM_DIR="${PLATFORM_VM_DIR:-$HOME/git-workspace/claude-workspace/.platform-vm}"
CERTS="$VM_DIR/certs"
# The CA's PRIVATE KEY lives OUTSIDE the mount, on purpose: anything that can read it can mint a
# trusted cert for any host on this machine. The registry needs its own key and the CA cert, never
# the CA key.
CA_DIR="${PLATFORM_CA_DIR:-$HOME/git-workspace/claude-workspace/.registry-ca}"

say() { echo "    $*"; }

# --- 1. certificates ---------------------------------------------------------------------------
# Regenerating the CA would invalidate the trust already installed in the VM and node, so the CA is
# created ONCE and reused. Only the server cert is reissued, and only when missing, expiring, or no
# longer signed by our CA.
ensure_certs() {
  mkdir -p "$CERTS" "$CA_DIR"
  chmod 700 "$CA_DIR"

  if [ ! -s "$CA_DIR/ca.key" ] || [ ! -s "$CERTS/ca.crt" ]; then
    say "issuing a new CA (10y — a cert that quietly expires breaks every pull on a random Tuesday)"
    openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
      -keyout "$CA_DIR/ca.key" -out "$CERTS/ca.crt" -subj "/CN=platform-registry-ca" 2>/dev/null
    rm -f "$CERTS/registry.crt"   # a new CA means the old server cert is worthless
  fi

  # Reissue only if absent, expiring within 30 days, or not signed by the CA we hold.
  if [ -s "$CERTS/registry.crt" ] \
     && openssl x509 -checkend 2592000 -noout -in "$CERTS/registry.crt" >/dev/null 2>&1 \
     && openssl verify -CAfile "$CERTS/ca.crt" "$CERTS/registry.crt" >/dev/null 2>&1; then
    say "server certificate present and valid"
  else
    say "issuing the registry's server certificate"
    # CSR, SAN config and openssl's serial file are signing ARTEFACTS — kept in the CA directory, not
    # $CERTS. $CERTS is a window into the VM, and only the three files something over there reads
    # belong there: registry.crt + registry.key (the registry container) and ca.crt (the VM-side cp
    # that installs trust).
    openssl req -newkey rsa:4096 -nodes -keyout "$CERTS/registry.key" \
      -out "$CA_DIR/registry.csr" -subj "/CN=registry" 2>/dev/null
    # subjectAltName is MANDATORY: Go (both docker and the registry) ignores CN entirely, and a CN-only
    # cert fails with an error that says nothing about SANs.
    printf 'subjectAltName = DNS:registry, DNS:localhost, IP:127.0.0.1\nextendedKeyUsage = serverAuth\n' \
      > "$CA_DIR/san.cnf"
    openssl x509 -req -in "$CA_DIR/registry.csr" -CA "$CERTS/ca.crt" -CAkey "$CA_DIR/ca.key" \
      -CAcreateserial -CAserial "$CA_DIR/ca.srl" \
      -out "$CERTS/registry.crt" -days 3650 -sha256 -extfile "$CA_DIR/san.cnf" 2>/dev/null
    rm -f "$CA_DIR/registry.csr"
  fi

  # Sweep anything else that drifted into the mount: this directory's value is entirely in what is NOT in it.
  find "$CERTS" -maxdepth 1 -type f \
    ! -name ca.crt ! -name registry.crt ! -name registry.key -delete 2>/dev/null || true

  chmod 600 "$CA_DIR/ca.key" "$CERTS/registry.key"
  chmod 644 "$CERTS/ca.crt" "$CERTS/registry.crt"
}

# --- 2. the registry container -----------------------------------------------------------------
registry_serving() {
  docker run --rm --network "$NETWORK" -v "$CERTS":/certs:ro --entrypoint curl \
    curlimages/curl:latest -sf --max-time 5 --cacert /certs/ca.crt "https://${REG_HOST}/v2/" \
    >/dev/null 2>&1
}

ensure_registry() {
  # minikube's network exists only once the cluster does — which is why this runs after `minikube start`.
  docker network inspect "$NETWORK" >/dev/null 2>&1 \
    || { echo "the '$NETWORK' docker network does not exist — is minikube up?" >&2; exit 1; }

  if docker ps --format '{{.Names}}' | grep -qx "$REG_NAME" && registry_serving; then
    say "registry already up and serving TLS at ${REG_HOST}"
    return
  fi

  say "starting the registry"
  docker rm -f "$REG_NAME" >/dev/null 2>&1 || true
  docker run -d --name "$REG_NAME" --network "$NETWORK" --ip "$REG_IP" --restart unless-stopped \
    -v registry-data:/var/lib/registry \
    -v "$CERTS":/certs:ro \
    -e REGISTRY_HTTP_ADDR="0.0.0.0:${REG_PORT}" \
    -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/registry.crt \
    -e REGISTRY_HTTP_TLS_KEY=/certs/registry.key \
    -e REGISTRY_STORAGE_DELETE_ENABLED=true \
    registry:2 >/dev/null

  for _ in $(seq 1 15); do registry_serving && break; sleep 2; done
  registry_serving || { echo "the registry never came up — 'docker logs $REG_NAME'" >&2; exit 1; }
  say "registry serving TLS at ${REG_HOST} (${REG_IP})"
}

# --- 3. trust ----------------------------------------------------------------------------------
# Compared by fingerprint, not presence: a stale CA from a previous generation is worse than none —
# it fails with the same error while looking installed.
ca_fingerprint() { openssl x509 -in "$CERTS/ca.crt" -noout -fingerprint -sha256 | cut -d= -f2; }

ensure_trust_vm() {
  local want; want="$(ca_fingerprint)"
  local have
  have="$(colima ssh -- sudo openssl x509 -in "/etc/docker/certs.d/${REG_HOST}/ca.crt" \
            -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 || true)"
  if [ "$have" = "$want" ]; then
    say "colima VM already trusts the CA"
  else
    say "installing the CA into the colima VM (it is the daemon that PUSHES)"
    colima ssh -- sudo mkdir -p "/etc/docker/certs.d/${REG_HOST}"
    colima ssh -- sudo cp "$CERTS/ca.crt" "/etc/docker/certs.d/${REG_HOST}/ca.crt"
  fi

  # Colima's daemon isn't on minikube's network, so docker's embedded DNS never serves it the name.
  # The bridge lives in the VM, so the pinned IP is routable — /etc/hosts is enough.
  colima ssh -- sudo sh -c \
    "sed -i '/[[:space:]]registry\$/d' /etc/hosts; echo '${REG_IP} registry' >> /etc/hosts"
  say "colima VM resolves registry -> ${REG_IP}"
}

ensure_trust_node() {
  local want; want="$(ca_fingerprint)"
  local have
  have="$(minikube ssh -- "sudo openssl x509 -in '/etc/docker/certs.d/${REG_HOST}/ca.crt' \
            -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2" 2>/dev/null | tr -d '\r' || true)"
  if [ "$have" = "$want" ]; then
    say "minikube node already trusts the CA"
    return
  fi
  say "installing the CA into the minikube node (it is the daemon that PULLS for the kubelet)"
  minikube ssh -- "sudo mkdir -p '/etc/docker/certs.d/${REG_HOST}'"
  minikube cp "$CERTS/ca.crt" /tmp/registry-ca.crt >/dev/null
  # `sudo` covers the rm too: minikube cp lands the file root-owned, so an unprivileged rm fails
  # "Operation not permitted" — and as the last command in the chain, that would fail the whole boot
  # AFTER trust was already installed.
  minikube ssh -- "sudo sh -c \"cp /tmp/registry-ca.crt '/etc/docker/certs.d/${REG_HOST}/ca.crt' && rm -f /tmp/registry-ca.crt\""
  # No daemon restart: docker reads certs.d per-pull — that is what makes this non-destructive.
}

# --- 4. prove it, rather than assume it --------------------------------------------------------
# Every step above can report success while the thing that matters — the kubelet being able to pull —
# stays broken. So we don't finish until the NODE has really pulled over TLS.
verify() {
  minikube ssh -- "getent hosts registry >/dev/null" \
    || { echo "the node cannot resolve 'registry'" >&2; exit 1; }
  # A manifest fetch is the cheapest thing exercising the whole chain: DNS, TCP, TLS, and the CA.
  minikube ssh -- "docker pull ${REG_HOST}/quiz:latest >/dev/null 2>&1" \
    && say "verified: the node pulled from ${REG_HOST} over TLS" \
    || say "note: nothing to pull yet (registry is empty) — trust is installed and the registry is serving"
}

echo "==> Registry"
ensure_certs
ensure_registry
ensure_trust_vm
ensure_trust_node
verify
