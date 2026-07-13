#!/usr/bin/env python3
"""
logins.py — list the identities registered with platform-auth.

Reads the `identities` table out of platform-db and marks which usernames are admins by
cross-referencing the live AUTH_ADMINS secret. Helps answer "which username did I sign up as, and
which one is my admin?" — the account overview, not the credential.

WHAT IT CANNOT DO, BY DESIGN: show you a code. The code is stored only as HMAC-SHA256(pepper, code)
in `code_lookup`; it is never kept in a form anyone can read back — not for a regular user, not for an
admin (AUTH_ADMINS is a list of usernames, not codes). A forgotten code cannot be recovered, only
reset. This tool is deliberately read-only and shows no credential material.

Usage:
    python3 logins.py            # a table, newest login first
    python3 logins.py --json     # machine-readable

Errors are printed as `ERROR: ...` for the caller to parse.
"""

import argparse
import base64
import json
import subprocess
import sys

NS = "platform"


def die(msg: str) -> "NoReturn":  # type: ignore[name-defined]
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def run(args: list[str], **kw) -> str:
    """Run a command, return stdout, die with a labelled error on failure."""
    try:
        p = subprocess.run(args, capture_output=True, text=True, **kw)
    except FileNotFoundError:
        die(f"command not found: {args[0]}")
    if p.returncode != 0:
        die(f"command failed (exit {p.returncode}): {' '.join(args)}\n{p.stderr.strip()}")
    return p.stdout


def repoint_kubeconfig() -> None:
    """Same Colima/minikube fix as deploy.sh — the forwarded apiserver port moves every restart."""
    names = subprocess.run(["docker", "ps", "--format", "{{.Names}}"], capture_output=True, text=True)
    if names.returncode != 0 or "minikube" not in names.stdout.split():
        return  # not a minikube-in-colima setup, or cluster down — let the next call report it
    port = subprocess.run(["docker", "port", "minikube", "8443"], capture_output=True, text=True)
    line = port.stdout.strip().splitlines()
    if line:
        p = line[0].rsplit(":", 1)[-1]
        subprocess.run(
            ["kubectl", "config", "set-cluster", "minikube", f"--server=https://127.0.0.1:{p}"],
            capture_output=True, text=True,
        )


def admin_usernames() -> set[str]:
    """The live AUTH_ADMINS list — lowercased usernames, matching how platform-auth compares them."""
    out = run(["kubectl", "-n", NS, "get", "secret", "platform-auth",
               "-o", "jsonpath={.data.AUTH_ADMINS}"])
    if not out.strip():
        return set()
    raw = base64.b64decode(out).decode("utf-8", "replace")
    return {u.strip().lower() for u in raw.split(",") if u.strip()}


def identities() -> list[dict]:
    """Read the identities table via psql inside the platform-db pod, using the pod's own DB user."""
    sql = ("SELECT username, id, to_char(created_at, 'YYYY-MM-DD'), "
           "to_char(last_seen, 'YYYY-MM-DD HH24:MI') FROM identities ORDER BY last_seen DESC;")
    out = run(["kubectl", "-n", NS, "exec", "deploy/platform-db", "--",
               "sh", "-c", f'psql -U "$POSTGRES_USER" -d auth -tA -F "|" -c "{sql}"'])
    rows = []
    for line in out.splitlines():
        if not line.strip():
            continue
        parts = line.split("|")
        if len(parts) < 4:
            continue
        rows.append({"username": parts[0], "id": parts[1], "created": parts[2], "last_seen": parts[3]})
    return rows


def main() -> None:
    ap = argparse.ArgumentParser(description="List platform-auth identities (no codes — see header).")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    args = ap.parse_args()

    repoint_kubeconfig()
    admins = admin_usernames()
    rows = identities()
    for r in rows:
        r["admin"] = r["username"].lower() in admins

    if args.json:
        print(json.dumps(rows, indent=2))
        return

    if not rows:
        print("No identities registered yet.")
        return

    uw = max(8, max(len(r["username"]) for r in rows))
    print(f"{'USERNAME'.ljust(uw)}  ADMIN  {'CREATED'.ljust(10)}  {'LAST SEEN'.ljust(16)}  ID")
    print("-" * (uw + 2 + 5 + 2 + 10 + 2 + 16 + 2 + 36))
    for r in rows:
        badge = " ★  " if r["admin"] else "    "
        print(f"{r['username'].ljust(uw)}  {badge}  {r['created'].ljust(10)}  {r['last_seen'].ljust(16)}  {r['id']}")
    print(f"\n{len(rows)} account(s); {sum(1 for r in rows if r['admin'])} admin. "
          "Codes are not shown — they are stored one-way and cannot be recovered, only reset.")


if __name__ == "__main__":
    main()
