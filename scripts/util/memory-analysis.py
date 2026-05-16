#!/usr/bin/env python3
# Analyze Kubernetes node memory allocation across all pods.
#
# Usage:
#   ./scripts/util/memory-analysis.py
#   ./scripts/util/memory-analysis.py --pending        # show scheduling failure events
#   ./scripts/util/memory-analysis.py --top 30         # show top N consumers (default: 20)
#   ./scripts/util/memory-analysis.py --app            # skip openshift-* / kube-* / system namespaces

import argparse
import json
import shutil
import subprocess
import sys


SYSTEM_NS_PREFIXES = ("openshift-", "kube-", "kube-system")
SYSTEM_NS_EXACT = {"default", "kube-system", "kube-public", "kube-node-lease"}


def main():
    parser = argparse.ArgumentParser(description="Kubernetes memory allocation analysis")
    parser.add_argument("--pending", action="store_true", help="show scheduling failure events for pending pods")
    parser.add_argument("--top", type=int, default=20, metavar="N", help="show top N pods by request (default: 20)")
    parser.add_argument("--app", action="store_true", help="hide openshift-*, kube-*, and other system namespaces")
    args = parser.parse_args()

    if not shutil.which("kubectl"):
        sys.exit("kubectl not found")

    def run(*cmd):
        return subprocess.check_output(list(cmd), text=True)

    def skip_ns(ns):
        if not args.app:
            return False
        return ns in SYSTEM_NS_EXACT or any(ns.startswith(p) for p in SYSTEM_NS_PREFIXES)

    # ── Node capacity ──────────────────────────────────────────────────────────
    nodes = json.loads(run("kubectl", "get", "nodes", "-o", "json"))
    total_alloc = sum(
        parse_mem(n["status"].get("allocatable", {}).get("memory", "0"))
        for n in nodes["items"]
    )

    # ── Pod requests ───────────────────────────────────────────────────────────
    pods = json.loads(run("kubectl", "get", "pods", "-A", "-o", "json"))

    by_ns   = {}  # {namespace: total_mib}  — filtered when --app
    entries = []  # [(total_mib, ns, name, phase, [per-container])]  — filtered
    pending = []  # pending pods  — filtered
    total_req_all = 0  # always includes system namespaces (for the bar)

    for pod in pods["items"]:
        phase = pod.get("status", {}).get("phase", "Unknown")
        ns    = pod["metadata"]["namespace"]
        name  = pod["metadata"]["name"]

        if phase in ("Succeeded", "Failed"):
            continue

        per_c = []
        pod_total = 0
        for c in pod["spec"].get("containers", []):
            mem = c.get("resources", {}).get("requests", {}).get("memory", "0")
            mib = parse_mem(mem)
            per_c.append((c["name"], mib))
            pod_total += mib

        total_req_all += pod_total

        if skip_ns(ns):
            continue

        entries.append((pod_total, ns, name, phase, per_c))
        by_ns[ns] = by_ns.get(ns, 0) + pod_total

        if phase == "Pending":
            pending.append((pod_total, ns, name))

    # ── Output ─────────────────────────────────────────────────────────────────
    W = 72
    print("─" * W)
    label = "MEMORY ALLOCATION ANALYSIS" + (" (listings: app namespaces only)" if args.app else "")
    print(f"  {label}")
    print("─" * W)
    total_req_app = sum(e[0] for e in entries)

    print(f"  Node allocatable : {fmt(total_alloc)}")
    print(f"  Total requested  : {fmt(total_req_all)}")
    if args.app:
        print(f"  App namespaces   : {fmt(total_req_app)}")
    print(f"  Available        : {fmt(total_alloc - total_req_all)}")
    print(f"  {bar(total_req_all, total_alloc)}")
    print()

    print("  BY NAMESPACE")
    print("  " + "─" * (W - 2))
    for ns, mib in sorted(by_ns.items(), key=lambda x: -x[1]):
        pct = mib / max(total_alloc, 1) * 100
        print(f"  {ns:<45} {fmt(mib):>8}  ({pct:.1f}%)")
    print()

    print(f"  TOP {args.top} PODS BY REQUEST")
    print("  " + "─" * (W - 2))
    for total, ns, name, phase, per_c in sorted(entries, reverse=True)[: args.top]:
        flag = " [PENDING]" if phase == "Pending" else ""
        print(f"  {fmt(total):>8}  {ns}/{name}{flag}")
        if len(per_c) > 1:
            for cname, mib in per_c:
                print(f"           {cname}: {fmt(mib)}")
    print()

    if pending:
        print(f"  PENDING PODS ({len(pending)})")
        print("  " + "─" * (W - 2))
        for mib, ns, name in sorted(pending, reverse=True):
            print(f"  {fmt(mib):>8}  {ns}/{name}")
        print()

    if args.pending and pending:
        print("  PENDING POD SCHEDULING EVENTS")
        print("  " + "─" * (W - 2))
        for _, ns, name in sorted(pending, reverse=True):
            try:
                raw = run(
                    "kubectl", "get", "events", "-n", ns,
                    "--field-selector", f"involvedObject.name={name}",
                    "--sort-by=.lastTimestamp", "-o", "json",
                )
                evts = json.loads(raw)["items"]
                last = [e for e in evts if e.get("reason") == "FailedScheduling"]
                if last:
                    msg = last[-1].get("message", "")[:80]
                    print(f"  {ns}/{name}")
                    print(f"    {msg}")
            except Exception:
                pass
        print()

    print("─" * W)


def parse_mem(s):
    """Parse a Kubernetes memory quantity string to MiB."""
    if not s:
        return 0
    s = s.strip()
    if s.endswith("Gi"):
        return int(float(s[:-2]) * 1024)
    if s.endswith("Mi"):
        return int(s[:-2])
    if s.endswith("Ki"):
        return max(1, int(s[:-2]) // 1024)
    if s.endswith("G"):
        return int(float(s[:-1]) * 1024)
    if s.endswith("M"):
        return int(s[:-1])
    if s.endswith("k"):
        return max(1, int(s[:-1]) // 1024)
    return max(1, int(s) // (1024 * 1024))


def fmt(mib):
    if mib >= 1024:
        return f"{mib / 1024:.1f}Gi"
    return f"{mib}Mi"


def bar(used, capacity, width=30):
    pct = min(used / max(capacity, 1), 1.0)
    filled = int(pct * width)
    color = "\033[32m"
    if pct > 0.85:
        color = "\033[33m"
    if pct > 0.95:
        color = "\033[31m"
    return f"{color}[{'█' * filled}{'░' * (width - filled)}]\033[0m {pct * 100:.1f}%"


if __name__ == "__main__":
    main()
