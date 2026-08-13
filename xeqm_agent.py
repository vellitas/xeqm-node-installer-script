#!/usr/bin/env python3
"""
XEQM Operator Dashboard — Remote Agent

Collects host metrics and service node info, then POSTs to a central dashboard.
Requires only Python 3.8+ stdlib + psutil. No dashboard package needed.

Quick start (one-shot, for systemd timer):
  python3 xeqm_agent.py --url http://DASHBOARD:8080 --token YOUR_TOKEN

Daemon mode (built-in loop):
  python3 xeqm_agent.py --url http://DASHBOARD:8080 --token YOUR_TOKEN --daemon

Dry run (print payload, don't send):
  python3 xeqm_agent.py --url http://DASHBOARD:8080 --token YOUR_TOKEN --dry-run

Config file (/etc/xeqm-agent.conf or ~/.xeqm-agent.conf):
  [agent]
  url   = http://192.168.50.11:8080
  token = YOUR_TOKEN
  interval = 60

Token env var alternative: XEQM_AGENT_TOKEN
"""
from __future__ import annotations

import argparse
import configparser
import glob
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

try:
    import psutil
    HAS_PSUTIL = True
except ImportError:
    HAS_PSUTIL = False

# Bump on any change to the wire contract or agent behaviour. The dashboard advertises
# the version it serves; a self-updating agent (auto_update, default on) pulls /agent.py
# when the dashboard offers a newer one. SemVer-ish "MAJOR.MINOR.PATCH".
AGENT_VERSION = "1.2.5"
AGENT_API_VERSION = "v1"   # path prefix the agent posts under (/api/v1/agent/*)

DEFAULT_RPC_PORT = 9231
DEFAULT_INTERVAL = 60
_CONF_PATHS = ["/etc/xeqm-agent.conf", os.path.expanduser("~/.xeqm-agent.conf")]

# Identify as XEQM-Agent rather than the default "Python-urllib" UA: Cloudflare's
# Browser Integrity Check (error 1010) bans that signature, which blocks reports to a
# Cloudflare-proxied dashboard (the missoula migration, 2026-06-23). A custom UA passes.
_opener = urllib.request.build_opener()
_opener.addheaders = [("User-Agent", f"XEQM-Agent/{AGENT_VERSION}")]
urllib.request.install_opener(_opener)


def _version_tuple(v: str) -> tuple:
    """Parse 'A.B.C' into a comparable int tuple; non-numeric parts sort low.
    Tolerant of junk so a malformed advertised version can't crash the agent."""
    out = []
    for part in str(v or "").split("."):
        m = re.match(r"\d+", part)
        out.append(int(m.group()) if m else -1)
    return tuple(out)


# ── RPC helpers ────────────────────────────────────────────────────────────────

def _rpc(base_url: str, method: str, timeout: float = 5.0) -> dict:
    payload = json.dumps({"jsonrpc": "2.0", "id": "0", "method": method, "params": {}}).encode()
    req = urllib.request.Request(
        f"{base_url.rstrip('/')}/json_rpc",
        data=payload,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = json.loads(resp.read())
    if "error" in data:
        raise RuntimeError(data["error"])
    return data.get("result", {})


def get_pubkey(rpc_url: str, timeout: float = 5.0) -> str | None:
    try:
        return _rpc(rpc_url, "get_service_node_key", timeout).get("service_node_pubkey") or None
    except Exception:
        return None


def check_ntp_sync() -> bool | None:
    """Return whether this host's clock is reported as NTP-synchronized.

    Uses timedatectl (covers systemd-timesyncd and chrony). Returns None
    if timedatectl is unavailable (non-systemd host) so the dashboard can
    distinguish "drifting" from "unknown".
    """
    try:
        r = subprocess.run(
            ["timedatectl", "show", "-p", "NTPSynchronized", "--value"],
            capture_output=True, text=True, timeout=5,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None
    if r.returncode != 0:
        return None
    return r.stdout.strip() == "yes"


def get_info(rpc_url: str, timeout: float = 5.0) -> dict:
    try:
        return _rpc(rpc_url, "get_info", timeout)
    except Exception:
        return {}


# ── Host metrics ───────────────────────────────────────────────────────────────

def collect_host_metrics() -> dict:
    m: dict = {}
    if HAS_PSUTIL:
        try:
            m["cpu_percent"] = psutil.cpu_percent(interval=1)
        except Exception:
            pass
        try:
            mem = psutil.virtual_memory()
            m["memory_percent"] = mem.percent
            m["memory_used_bytes"] = mem.used
            m["memory_total_bytes"] = mem.total
        except Exception:
            pass
        try:
            disk = psutil.disk_usage("/")
            m["disk_root_percent"] = disk.percent
            m["disk_root_free_bytes"] = disk.free
        except Exception:
            pass
        try:
            la = psutil.getloadavg()
            m["load_1"], m["load_5"], m["load_15"] = la
        except Exception:
            pass
        try:
            m["uptime_seconds"] = int(time.time() - psutil.boot_time())
        except Exception:
            pass
    else:
        # /proc fallback (Linux only)
        try:
            with open("/proc/loadavg") as f:
                p = f.read().split()
                m["load_1"], m["load_5"], m["load_15"] = float(p[0]), float(p[1]), float(p[2])
        except Exception:
            pass
        try:
            with open("/proc/meminfo") as f:
                mem: dict = {}
                for line in f:
                    k, v = line.split(":")
                    mem[k.strip()] = int(v.strip().split()[0]) * 1024
            total = mem.get("MemTotal", 0)
            avail = mem.get("MemAvailable", 0)
            if total:
                m["memory_total_bytes"] = total
                m["memory_used_bytes"] = total - avail
                m["memory_percent"] = round((total - avail) / total * 100, 1)
        except Exception:
            pass
        try:
            st = os.statvfs("/")
            total_b = st.f_blocks * st.f_frsize
            free_b = st.f_bavail * st.f_frsize
            m["disk_root_free_bytes"] = free_b
            if total_b:
                m["disk_root_percent"] = round((total_b - free_b) / total_b * 100, 1)
        except Exception:
            pass
    return m


# ── Systemd discovery ─────────────────────────────────────────────────────────

def discover_systemd_rpc_urls(
    pattern: str = "xeqmnode_snode*.service",
    unit_dir: str = "/etc/systemd/system",
) -> list[str]:
    """Parse --rpc-admin ports from matching systemd unit ExecStart lines.

    Kept for backwards compatibility — returns URLs only. New code should
    prefer ``discover_systemd_units`` which returns (unit_name, url) pairs
    so the dashboard can attribute each pubkey to its specific unit.
    """
    return [url for _name, url in discover_systemd_units(pattern, unit_dir)]


def _read_fd_stats_via_helper(pid: int) -> tuple[int | None, int | None]:
    """Use the privileged helper to read fd stats when direct
    /proc reads come up short (the common case: the daemon runs as
    a different UID than the agent, and /proc/<pid>/fd is only
    readable by the daemon's UID).

    Returns (None, None) on any failure — same shape as the direct
    read, so the caller doesn't need to know which path produced
    the answer.
    """
    if not os.path.exists(PRIVILEGED_CAPTURE_HELPER):
        return (None, None)
    try:
        r = subprocess.run(
            ["sudo", "-n", PRIVILEGED_CAPTURE_HELPER, "--fd-stats", str(pid)],
            capture_output=True, text=True, timeout=5,
        )
    except Exception:
        return (None, None)
    if r.returncode != 0 or not r.stdout:
        return (None, None)
    try:
        parts = r.stdout.strip().split()
        return int(parts[0]), int(parts[1])
    except (ValueError, IndexError):
        return (None, None)


def read_fd_stats_for_pid(pid: int) -> tuple[int | None, int | None]:
    """Read (soft NOFILE limit, currently-open fd count) for `pid`.

    Tries direct /proc read first (works when daemon runs under the
    same UID as the agent). When `/proc/<pid>/fd` is unreadable
    (typical: agent is xeqm-agent uid, daemon is snodeN uid), falls
    back to the privileged helper via sudo NOPASSWD. The dashboard's
    seed coloring uses None as the "no data, use legacy thresholds"
    signal so partial returns never crash.
    """
    soft_limit: int | None = None
    try:
        with open(f"/proc/{pid}/limits") as f:
            for line in f:
                if line.startswith("Max open files"):
                    parts = line.split()
                    # Format: "Max open files     <soft>  <hard>  files"
                    if len(parts) >= 5:
                        try:
                            soft_limit = int(parts[3])
                        except ValueError:
                            pass
                    break
    except OSError:
        pass
    used: int | None
    try:
        used = len(os.listdir(f"/proc/{pid}/fd"))
    except OSError:
        used = None

    # If either piece is missing (almost always `used` on cross-UID
    # hosts), ask the privileged helper for both. Cheap (<50ms) and
    # the answer is more authoritative than a partial direct read.
    if soft_limit is None or used is None:
        helper_limit, helper_used = _read_fd_stats_via_helper(pid)
        if helper_limit is not None:
            soft_limit = helper_limit
        if helper_used is not None:
            used = helper_used
    return soft_limit, used


def read_fd_stats_for_unit(unit_name: str) -> tuple[int | None, int | None]:
    """Resolve a systemd unit (with or without .service suffix) to its
    MainPID and read fd stats for that pid. (None, None) on any miss."""
    unit = unit_name if unit_name.endswith(".service") else f"{unit_name}.service"
    try:
        r = subprocess.run(
            ["systemctl", "show", "-p", "MainPID", "--value", unit],
            capture_output=True, text=True, timeout=5,
        )
        pid = int((r.stdout or "0").strip())
    except Exception:
        return (None, None)
    if pid <= 1:
        return (None, None)
    return read_fd_stats_for_pid(pid)


def find_single_xeqm_d_pid() -> int | None:
    """Best-effort fallback to locate xeqm-d on a host where the agent
    didn't discover a matching systemd unit. Walks /proc/*/comm for
    processes named "xeqm-d" and returns the lone pid if exactly one
    is running.

    Returns None on a multi-snode host (ambiguous — the systemd path
    handles those per-unit) or when no xeqm-d is found. This means
    seeds and pn-* hosts (single daemon, often not under the
    xeqmnode_snode* naming pattern) get fd stats too, without
    misattributing on hosts with multiple xeqm-d's.
    """
    pids: list[int] = []
    try:
        for entry in os.listdir("/proc"):
            if not entry.isdigit():
                continue
            try:
                with open(f"/proc/{entry}/comm") as f:
                    if f.read().strip() == "xeqm-d":
                        pids.append(int(entry))
            except OSError:
                continue
    except OSError:
        return None
    if len(pids) == 1:
        return pids[0]
    return None


def count_omq_self_ping_failures(
    units_with_pubkeys: list[tuple[str, str | None]],
    minutes: int = 30,
) -> dict[str, int]:
    """Per-pubkey count of OMQ `Unable to ping configured service node
    address` warnings in the last `minutes` minutes from systemd
    journals.

    Returns {pubkey: count}. Pubkeys with zero warnings are omitted.

    The 2026-06-08 forensics across Fernando/Lemon found this warning
    fires reliably 30-60 minutes before a daemon enters the silent-
    wedge state that the chain then decommissions with "Missed Uptime
    Proofs". Counting them lets the watchdog preempt the wedge with a
    restart while the daemon is still active, never bleeding credit.

    Best-effort: if `journalctl` isn't on PATH or the agent user can't
    read the journal (not in systemd-journal group), the function
    silently returns {}. The watchdog still has its other triggers as
    fallbacks; this just adds a faster path.
    """
    if not shutil.which("journalctl"):
        return {}
    counts: dict[str, int] = {}
    for unit_name, pubkey in units_with_pubkeys:
        if not pubkey:
            continue
        try:
            r = subprocess.run(
                ["journalctl",
                 "-u", f"{unit_name}.service",
                 f"--since={minutes} minutes ago",
                 "-o", "cat", "-q", "--no-pager"],
                capture_output=True, text=True, timeout=8,
            )
        except (subprocess.TimeoutExpired, FileNotFoundError):
            continue
        if r.returncode != 0:
            continue
        n = sum(
            1 for line in r.stdout.splitlines()
            if "Unable to ping configured service node address" in line
        )
        if n > 0:
            counts[pubkey] = n
    return counts


def check_listen_queue_overflows(
    unit_rpc_pairs: list[tuple[str, str]],
    url_to_pubkey: dict[str, str],
    unit_dir: str = "/etc/systemd/system",
) -> dict[str, int]:
    """Check TCP listen-queue overflow on quorumnet ports.

    Recv-Q > 0 on a LISTEN socket means new SYN packets are queued ahead
    of accept() — the daemon has stopped calling accept(), which is the
    direct signature of the OMQ ABBA deadlock wedge. This fires at wedge
    onset; the journal-based omq_self_ping_failing signal lags 30-60 min.

    Returns {pubkey: recv_q} for units whose quorumnet port has Recv-Q > 0.
    Healthy ports are omitted. Best-effort: returns {} on any error.
    """
    import re as _re
    if not shutil.which("ss"):
        return {}

    # Parse --quorumnet-port from each unit file (same backslash-collapse
    # trick used in discover_systemd_units for multi-line ExecStart).
    unit_to_port: dict[str, int] = {}
    for unit_name, _rpc_url in unit_rpc_pairs:
        path = os.path.join(unit_dir, unit_name + ".service")
        try:
            with open(path) as f:
                content = _re.sub(r"\\\n\s*", " ", f.read())
        except OSError:
            continue
        for line in content.splitlines():
            if not line.strip().startswith("ExecStart="):
                continue
            m = _re.search(r"--quorumnet-port[= ](\d+)", line)
            if m:
                unit_to_port[unit_name] = int(m.group(1))
                break

    if not unit_to_port:
        return {}

    # Snapshot all listening TCP sockets once.
    try:
        r = subprocess.run(["ss", "-tlnH"], capture_output=True, text=True, timeout=5)
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return {}

    # Parse: state recv-q send-q local-addr:port peer-addr:port
    port_recv_q: dict[int, int] = {}
    for line in r.stdout.splitlines():
        parts = line.split()
        if len(parts) < 4:
            continue
        try:
            recv_q = int(parts[1])
            port = int(parts[3].rsplit(":", 1)[-1])
            if recv_q > 0:
                port_recv_q[port] = recv_q
        except (ValueError, IndexError):
            continue

    result: dict[str, int] = {}
    for unit_name, rpc_url in unit_rpc_pairs:
        port = unit_to_port.get(unit_name)
        if port is None or port not in port_recv_q:
            continue
        pubkey = url_to_pubkey.get(rpc_url)
        if pubkey:
            result[pubkey] = port_recv_q[port]
    return result


def check_and_heal_firewall_ports(
    unit_rpc_pairs: list[tuple[str, str]],
    url_to_pubkey: dict[str, str],
    unit_dir: str = "/etc/systemd/system",
) -> tuple[dict[str, list[str]], dict[str, list[str]]]:
    """Check UFW for required ports per node role and auto-add missing ones.

    Service nodes need p2p + quorumnet (tcp+udp each).
    Public/seed nodes need p2p only.
    Best-effort: returns ({}, {}) if UFW is unavailable or not active.

    Returns:
        (healed, still_missing)
        healed       — {pubkey: ["port/proto", ...]} added this cycle
        still_missing — {pubkey: ["port/proto", ...]} still blocked after heal
    """
    import re as _re

    ufw_bin = shutil.which("ufw") or "/usr/sbin/ufw"

    try:
        r = subprocess.run(
            ["sudo", "-n", ufw_bin, "status"],
            capture_output=True, text=True, timeout=10,
        )
        if r.returncode != 0 or "Status: active" not in r.stdout:
            return {}, {}
        ufw_output = r.stdout
    except (subprocess.TimeoutExpired, FileNotFoundError, PermissionError):
        return {}, {}

    open_rules: set[str] = set()
    for line in ufw_output.splitlines():
        m = _re.match(r"\s*(\d+)/(tcp|udp)\s+ALLOW", line)
        if m:
            open_rules.add(f"{m.group(1)}/{m.group(2)}")

    unit_required_ports: dict[str, list[str]] = {}
    for unit_name, _rpc_url in unit_rpc_pairs:
        path = os.path.join(unit_dir, unit_name + ".service")
        try:
            with open(path) as f:
                content = _re.sub(r"\\\n\s*", " ", f.read())
        except OSError:
            continue
        for line in content.splitlines():
            if not line.strip().startswith("ExecStart="):
                continue
            ports: list[str] = []
            p2p_m = _re.search(r"--p2p-bind-port[= ](\d+)", line)
            if p2p_m:
                p = p2p_m.group(1)
                ports += [f"{p}/tcp", f"{p}/udp"]
            if _re.search(r"--service-node\b", line):
                qnet_m = _re.search(r"--quorumnet-port[= ](\d+)", line)
                if qnet_m:
                    q = qnet_m.group(1)
                    ports += [f"{q}/tcp", f"{q}/udp"]
            if ports:
                unit_required_ports[unit_name] = ports
            break

    healed: dict[str, list[str]] = {}
    still_missing: dict[str, list[str]] = {}

    for unit_name, rpc_url in unit_rpc_pairs:
        required = unit_required_ports.get(unit_name)
        if not required:
            continue
        pubkey = url_to_pubkey.get(rpc_url)
        if not pubkey:
            continue
        missing = [p for p in required if p not in open_rules]
        if not missing:
            continue
        unit_healed: list[str] = []
        unit_failed: list[str] = []
        for port_proto in missing:
            try:
                add = subprocess.run(
                    ["sudo", "-n", ufw_bin, "allow", port_proto],
                    capture_output=True, text=True, timeout=10,
                )
                if add.returncode == 0:
                    unit_healed.append(port_proto)
                    open_rules.add(port_proto)
                else:
                    unit_failed.append(port_proto)
            except (subprocess.TimeoutExpired, FileNotFoundError, PermissionError):
                unit_failed.append(port_proto)
        if unit_healed:
            healed[pubkey] = unit_healed
        if unit_failed:
            still_missing[pubkey] = unit_failed

    return healed, still_missing


def discover_systemd_units(
    pattern: str = "xeqmnode_snode*.service",
    unit_dir: str = "/etc/systemd/system",
) -> list[tuple[str, str]]:
    """Return [(unit_name_without_.service, rpc_url), ...] for each matching unit.

    Pre-collapses backslash line continuations in the unit file before
    parsing so multi-line ExecStart directives (the explorer-1/2 wedge
    case from 2026-06-06) don't drop their --rpc-admin flag.
    """
    import fnmatch, re as _re
    out: list[tuple[str, str]] = []
    try:
        for fname in sorted(os.listdir(unit_dir)):
            if not fnmatch.fnmatch(fname, pattern):
                continue
            try:
                with open(os.path.join(unit_dir, fname)) as f:
                    content = f.read()
                # Collapse `\<newline><whitespace>` so multi-line ExecStart
                # directives are visible to the regex (see explorer-1/2
                # silent-wedge bug, 2026-06-06).
                content = _re.sub(r"\\\n\s*", " ", content)
            except OSError:
                continue
            url: str | None = None
            for line in content.splitlines():
                if not line.strip().startswith("ExecStart="):
                    continue
                m = _re.search(r"--rpc-admin[= ]\S*:(\d+)", line)
                if not m:
                    m = _re.search(r"--rpc-bind-port[= ](\d+)", line)
                if m:
                    url = f"http://127.0.0.1:{m.group(1)}"
                    break
            if url is None:
                continue
            name = fname[:-8] if fname.endswith(".service") else fname
            out.append((name, url))
    except OSError:
        pass
    return out


# ── Payload assembly ───────────────────────────────────────────────────────────

def build_payload(rpc_urls: list[str],
                  systemd_pattern: str = "xeqmnode_snode*.service",
                  systemd_unit_dir: str = "/etc/systemd/system",
                  rpc_timeout: float = 5.0) -> dict:
    metrics = collect_host_metrics()
    containers: list[dict] = []

    # systemd-discovered units carry both a name AND a URL so the
    # dashboard can attribute each pubkey to its specific unit. Returns
    # [(unit_name, rpc_url), ...]. Empty on hosts without matching
    # units (seeds, pn-*); the caller's explicit rpc_urls cover those.
    systemd_units = discover_systemd_units(systemd_pattern, systemd_unit_dir)
    url_to_unit = {url: name for name, url in systemd_units}
    rpc_urls = list(rpc_urls) + [url for _name, url in systemd_units]

    # Build (url, known_pubkey_or_None) probes from explicit URLs.
    # Pubkey is resolved per URL via get_pubkey on the snode's admin RPC.
    probes: list[tuple[str, str | None]] = []
    seen_urls: set[str] = set()
    for url in rpc_urls:
        if url in seen_urls:
            continue
        probes.append((url, get_pubkey(url, rpc_timeout)))
        seen_urls.add(url)

    # Single get_info pass per URL: collect per-snode peer counts + version,
    # and pick the first responding daemon for local_height + a host-wide
    # daemon_version fallback. pubkey_versions is what the dashboard uses
    # to decide whether to offer the Upgrade button — host-wide
    # daemon_version is only kept for the host metrics view.
    peer_counts: dict[str, int] = {}
    pubkey_versions: dict[str, str] = {}
    pubkey_heights: dict[str, int] = {}
    local_height = None
    daemon_version = None
    # Host-wide in/out from the first responding daemon. For SN hosts the
    # per-pubkey counts above are richer; for seed hosts (no pubkey) the
    # per-pubkey branch never fires and the dashboard's Seed Health panel
    # falls back to these so it can show real in/out instead of "—".
    host_incoming = None
    host_outgoing = None
    # 2026-06-09: capture the host's daemon fd capacity alongside the
    # connection counts so the dashboard's Seed Health panel can color
    # by (used/limit) ratio instead of a hardcoded 40/80 conn count.
    # The fd ceiling actually bounds how many peers a seed can serve;
    # a 65k-limit seed with 256 conns is healthy, a 1k-limit seed
    # with 256 conns is critical — same number, very different
    # headroom. Same first-responder pattern as host_incoming.
    host_fd_limit: int | None = None
    host_fd_used: int | None = None
    for url, pk in probes:
        info = get_info(url, rpc_timeout)
        if not info:
            continue
        # Accept only semver-shaped strings (must contain a dot).
        # get_info on some daemon modes returns version as a protocol
        # integer (e.g. 1) rather than a semver string; reject those.
        _v_raw = info.get("version_string") or info.get("version")
        _v_s = str(_v_raw) if _v_raw is not None else ""
        v_str = _v_s if "." in _v_s else None
        if pk:
            inc = info.get("incoming_connections_count") or 0
            out = info.get("outgoing_connections_count") or 0
            peer_counts[pk] = inc + out
            if v_str:
                pubkey_versions[pk] = v_str
            h = info.get("height")
            if h is not None:
                pubkey_heights[pk] = h
        if local_height is None and info.get("height"):
            local_height = info["height"]
            daemon_version = v_str
            host_incoming = info.get("incoming_connections_count")
            host_outgoing = info.get("outgoing_connections_count")
            # The url_to_unit mapping was built earlier for systemd
            # discoveries. On hosts where the daemon isn't a
            # xeqmnode_snode*.service unit (seeds, pn-*), the lookup
            # misses — so we fall back to finding the lone xeqm-d
            # process directly. find_single_xeqm_d_pid() only returns a
            # pid when exactly one is running, which keeps multi-snode
            # hosts on the systemd path (where each daemon's stats are
            # attributed to its specific unit).
            unit_name = url_to_unit.get(url)
            if unit_name:
                host_fd_limit, host_fd_used = read_fd_stats_for_unit(unit_name)
            else:
                fallback_pid = find_single_xeqm_d_pid()
                if fallback_pid:
                    host_fd_limit, host_fd_used = read_fd_stats_for_pid(fallback_pid)

    # If no probe returned a semver daemon_version (e.g. companion daemons
    # whose get_info returns a protocol integer), fall back to reading the
    # binary version directly from the companion unit's executable.
    if daemon_version is None:
        for companion in ("xeqm-pubnode", "xeqm-seed"):
            exec_dir = _get_unit_exec_dir(f"{companion}.service")
            if exec_dir:
                try:
                    daemon_version = _xeqm_d_version(os.path.join(exec_dir, "xeqm-d"))
                except RuntimeError:
                    pass
                if daemon_version:
                    break

    pubkeys: list[str] = []
    seen_pks: set[str] = set()
    for _, pk in probes:
        if pk and pk not in seen_pks:
            pubkeys.append(pk)
            seen_pks.add(pk)

    # Surface systemd-discovered units in the containers list so the
    # dashboard can populate `nodes.container_name`. The field name
    # `containers_json` is historical; everything in it is a systemd unit.
    units_with_pubkeys: list[tuple[str, str | None]] = []
    for url, pk in probes:
        unit_name = url_to_unit.get(url)
        if not unit_name:
            continue
        containers.append({
            "name": unit_name,
            "pubkey": pk,
            "status": "active",  # systemd lists it; the dashboard treats this as the unit-running signal
            "image": "systemd",
        })
        units_with_pubkeys.append((unit_name, pk))

    # 2026-06-08 early-warning signal: scan the journal for the OMQ
    # self-ping warning, count per pubkey. Dashboard's watchdog gets a
    # 30-60 minute head start on the wedge vs waiting for chain decom.
    omq_warn_counts = count_omq_self_ping_failures(units_with_pubkeys)

    # 2026-07-04 direct wedge detection: Recv-Q > 0 on a quorumnet LISTEN
    # socket fires at wedge onset, complementing the journal-based signal.
    url_to_pubkey = {url: pk for url, pk in probes if pk}
    listen_q_overflows = check_listen_queue_overflows(
        systemd_units, url_to_pubkey, systemd_unit_dir
    )

    # 2026-07-18 firewall port validation + auto-heal: checks UFW rules
    # against required ports per node role (service node needs p2p+quorumnet,
    # others p2p only). Adds missing rules automatically via sudo ufw allow.
    # Returns ports healed this cycle and any that still couldn't be opened.
    fw_healed, fw_still_missing = check_and_heal_firewall_ports(
        systemd_units, url_to_pubkey, systemd_unit_dir
    )

    return {
        "agent_version": AGENT_VERSION,
        "agent_api_version": AGENT_API_VERSION,
        "hostname": socket.gethostname(),
        "pubkeys": pubkeys,
        "pubkey_versions": pubkey_versions,
        "pubkey_heights": pubkey_heights,
        "pubkey_omq_warn_counts": omq_warn_counts,
        "pubkey_listen_queue_overflows": listen_q_overflows,
        "pubkey_firewall_healed": fw_healed,
        "pubkey_firewall_missing": fw_still_missing,
        "containers": containers,
        "local_height": local_height,
        "daemon_version": daemon_version,
        "host_incoming_connections": host_incoming,
        "host_outgoing_connections": host_outgoing,
        "host_fd_limit": host_fd_limit,
        "host_fd_used": host_fd_used,
        "ntp_synchronized": check_ntp_sync(),
        "peer_counts": peer_counts,
        **metrics,
    }


# ── Reporting ──────────────────────────────────────────────────────────────────

def _agent_post(dashboard_url: str, suffix: str, token: str, payload: dict,
                timeout: float = 15) -> dict | None:
    """POST JSON to /api/v1/agent/<suffix>, falling back to the legacy unversioned
    /api/agent/<suffix> on a 404 (talking to an older dashboard). Returns the parsed
    JSON dict, or None on HTTP/connection error. One chokepoint for auth + API-version
    negotiation so every agent endpoint speaks the same dialect."""
    base = dashboard_url.rstrip("/")
    data = json.dumps(payload).encode()
    candidates = [f"{base}/api/{AGENT_API_VERSION}/agent/{suffix}",
                  f"{base}/api/agent/{suffix}"]
    for i, url in enumerate(candidates):
        req = urllib.request.Request(
            url, data=data,
            headers={"Content-Type": "application/json", "Authorization": f"Bearer {token}"},
        )
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return json.loads(resp.read())
        except urllib.error.HTTPError as e:
            if e.code == 404 and i == 0:
                continue  # versioned route absent on an old dashboard → try legacy
            print(f"[agent] HTTP {e.code} ({url}): {e.read().decode(errors='replace')}", file=sys.stderr)
            return None
        except urllib.error.URLError as e:
            print(f"[agent] Connection failed ({url}): {e.reason}", file=sys.stderr)
            return None
    return None


def send_report(dashboard_url: str, token: str, payload: dict) -> dict | None:
    """POST a report. Returns the parsed response (commands array for the SUDS
    executor + agent_latest_version/sha256 for self-update) or None on failure."""
    result = _agent_post(dashboard_url, "report", token, payload)
    return result if (result and result.get("ok")) else None


def post_upgrade_status(dashboard_url: str, token: str, command_id: int,
                        status: str, **fields) -> bool:
    """SUDS: report progress on an upgrade command. ``fields`` accepts
    'message', 'prior_version', 'backup_path', 'error'."""
    result = _agent_post(dashboard_url, "upgrade_status", token,
                         {"command_id": command_id, "status": status, **fields})
    return bool(result and result.get("ok"))


def post_registration_result(dashboard_url: str, token: str, command_id: int,
                             status: str, registration_cmd: str | None = None,
                             error: str | None = None) -> bool:
    """Phase 2G: post the result of a registration_command back to the
    dashboard. status must be 'ready' (with registration_cmd) or 'failed'
    (with error)."""
    payload: dict = {"command_id": command_id, "status": status}
    if registration_cmd is not None:
        payload["registration_cmd"] = registration_cmd
    if error is not None:
        payload["error"] = error
    result = _agent_post(dashboard_url, "registration_result", token, payload)
    return bool(result and result.get("ok"))


def post_restart_result(dashboard_url: str, token: str, command_id: int,
                        status: str, error: str | None = None,
                        stack_dump_path: str | None = None) -> bool:
    """2026-06-08: post the outcome of a restart_command back to the
    dashboard. status must be 'ok' or 'failed'. stack_dump_path is the
    on-host path to the wedge-state capture (if any) so the dashboard
    can fire a dev-attention alarm naming the file."""
    payload: dict = {"command_id": command_id, "status": status}
    if error is not None:
        payload["error"] = error
    if stack_dump_path is not None:
        payload["stack_dump_path"] = stack_dump_path
    result = _agent_post(dashboard_url, "restart_result", token, payload)
    return bool(result and result.get("ok"))


def self_update(dashboard_url: str, latest_version: str, latest_sha256: str | None) -> bool:
    """Replace this agent file with the dashboard's bundled /agent.py when it advertises
    a newer version. Returns True if an update was applied (caller may exit so the next
    run uses it). Conservative + fail-safe — any doubt and it leaves the agent untouched:

      * only upgrades (advertised version strictly greater than ours)
      * verifies the download's sha256 against the advertised digest (if given)
      * compiles the new source and confirms its AGENT_VERSION matches what was advertised
      * writes atomically (temp in the same dir + os.replace), so a partial download or a
        crash mid-write can never leave a corrupt agent on disk.
    """
    if not latest_version or _version_tuple(latest_version) <= _version_tuple(AGENT_VERSION):
        return False
    try:
        target = os.path.realpath(__file__)
        url = f"{dashboard_url.rstrip('/')}/agent.py"
        with urllib.request.urlopen(url, timeout=30) as resp:
            new_src = resp.read()
        if latest_sha256:
            import hashlib
            got = hashlib.sha256(new_src).hexdigest()
            if got != latest_sha256:
                print(f"[update] sha256 mismatch (want {latest_sha256[:12]}…, got {got[:12]}…) — skipping", file=sys.stderr)
                return False
        # Compile + confirm the new file declares the version we were promised.
        compile(new_src, target, "exec")
        m = re.search(rb'^AGENT_VERSION\s*=\s*["\']([^"\']+)["\']', new_src, re.M)
        if not m or m.group(1).decode() != latest_version:
            print("[update] downloaded agent version doesn't match advertised — skipping", file=sys.stderr)
            return False
        # Prefer atomic temp+replace; fall back to in-place write when the
        # agent's directory is root-owned (xeqm-agent owns the file but not
        # the dir, so it can overwrite the existing inode but not create new).
        tmp = target + ".new"
        try:
            with open(tmp, "wb") as f:
                f.write(new_src)
            os.chmod(tmp, os.stat(target).st_mode & 0o777)
            os.replace(tmp, target)
        except PermissionError:
            with open(target, "wb") as f:
                f.write(new_src)
        print(f"[update] agent self-updated {AGENT_VERSION} → {latest_version}; next run uses it")
        return True
    except Exception as e:
        print(f"[update] self-update skipped: {e}", file=sys.stderr)
        return False


PRIVILEGED_CAPTURE_HELPER = "/opt/xeqm-agent/capture-stack"

# Where wedge-state captures get written. /var/log lives on disk, not
# tmpfs, so files survive a reboot — important because a wedge often
# precedes a reboot if the operator escalates from restart → reboot.
# Falls back to /tmp/xeqm-stack-dumps/ at runtime if /var/log/xeqm-agent
# doesn't exist or isn't writable (e.g. on a host that hasn't had the
# 2026-06-09 deploy applied yet). The fallback exists so forensics
# always lands somewhere even if a host is mid-migration.
STACK_DUMP_DIR_PERSISTENT = "/var/log/xeqm-agent/stack-dumps"
STACK_DUMP_DIR_FALLBACK = "/tmp/xeqm-stack-dumps"

# Keep at most this many capture files per host — deletes the oldest
# when the count exceeds. 200 captures × ~12 KB each ≈ 2.4 MB ceiling,
# so disk use stays trivial. 200 also means ~6 wedges/day × 30 days
# of history if a host is consistently buggy, which is more than
# enough to spot patterns.
STACK_DUMP_KEEP = 200


def _resolve_stack_dump_dir() -> str:
    """Pick the persistent dir if writable, else fall back to /tmp."""
    for d in (STACK_DUMP_DIR_PERSISTENT, STACK_DUMP_DIR_FALLBACK):
        try:
            os.makedirs(d, exist_ok=True)
        except Exception:
            continue
        if os.access(d, os.W_OK):
            return d
    return "/tmp"


def _rotate_stack_dumps(dir_path: str, keep: int = STACK_DUMP_KEEP) -> None:
    """Delete oldest *.txt captures so the count stays under `keep`.

    Best effort — never raises. We don't want a transient FS error to
    block the actual wedge capture from being written.
    """
    try:
        entries = []
        for name in os.listdir(dir_path):
            if not name.endswith(".txt"):
                continue
            full = os.path.join(dir_path, name)
            try:
                entries.append((os.path.getmtime(full), full))
            except OSError:
                continue
        if len(entries) <= keep:
            return
        entries.sort(key=lambda e: e[0])
        for _mtime, full in entries[: len(entries) - keep]:
            try:
                os.unlink(full)
            except OSError:
                pass
    except OSError:
        pass


def capture_daemon_state(unit: str) -> str | None:
    """Best-effort snapshot of a wedged daemon's thread state, written
    to /tmp before we stop it.

    Tries two levels in sequence:

    1. **Privileged path** via the sudo-wrapped helper at
       PRIVILEGED_CAPTURE_HELPER. Reads every per-thread wchan AND
       per-thread kernel stack from /proc (which require root because
       the daemon runs under a different user than the agent), AND
       runs `gdb -batch -p <pid> 'thread apply all bt'` for full
       userspace backtraces. This is the data the dev team actually
       needs to identify an OMQ deadlock or stuck event loop — kernel
       wchan alone often resolves to a generic futex_wait that doesn't
       name the offending mutex.

    2. **Unprivileged fallback** if the helper isn't installed or
       sudoers doesn't grant access. Same set as the original capture:
       /proc/<pid>/status, /proc/<pid>/wchan, per-thread wchan + comm,
       ps -Lf. Under user-mismatch these all return 0 or blank — but
       the thread count and ps output still give shape, which is
       better than nothing.

    Never raises — the watchdog flow must never break because forensic
    capture failed. Returns the file path on success, or None if no
    output could be written.
    """
    try:
        r = subprocess.run(
            ["systemctl", "show", "-p", "MainPID", "--value", unit],
            capture_output=True, text=True, timeout=5,
        )
        pid = int((r.stdout or "0").strip())
    except Exception:
        return None
    if pid <= 1:
        return None

    out_dir = _resolve_stack_dump_dir()
    _rotate_stack_dumps(out_dir)
    ts = int(time.time())
    unit_short = unit.replace(".service", "")
    path = f"{out_dir}/{unit_short}-{ts}.txt"

    def _slurp(p: str) -> str:
        try:
            with open(p) as f:
                return f.read()
        except Exception as e:
            return f"<error: {e}>"

    chunks: list[str] = [
        f"=== xeqm-d wedge capture — {unit} pid={pid} ts={ts} ===\n",
        f"# Captured by xeqm-agent before stop+start. Pass to dev team\n",
        f"# along with daemon version (look for 'Ragnarok' in journal).\n\n",
    ]

    # Privileged path first. sudo -n = non-interactive (fail rather
    # than prompt). 90s timeout absorbs the gdb attach.
    used_privileged = False
    if os.path.exists(PRIVILEGED_CAPTURE_HELPER):
        try:
            r = subprocess.run(
                ["sudo", "-n", PRIVILEGED_CAPTURE_HELPER, str(pid)],
                capture_output=True, text=True, timeout=90,
            )
            if r.returncode == 0 and r.stdout:
                chunks.append(r.stdout)
                used_privileged = True
            else:
                err = (r.stderr or "").strip()[:300]
                chunks.append(
                    f"<privileged helper exited {r.returncode}: {err}>\n"
                    f"<falling back to unprivileged capture>\n\n"
                )
        except Exception as e:
            chunks.append(f"<privileged helper raised: {e}>\n\n")

    if not used_privileged:
        chunks.append(
            f"--- /proc/{pid}/status ---\n{_slurp(f'/proc/{pid}/status')}\n"
        )
        chunks.append(
            f"--- /proc/{pid}/wchan ---\n{_slurp(f'/proc/{pid}/wchan')}\n\n"
        )
        try:
            tids = sorted(os.listdir(f"/proc/{pid}/task"), key=int)
            chunks.append(f"--- per-thread wchan ({len(tids)} threads) ---\n")
            for tid in tids:
                wchan = _slurp(f"/proc/{pid}/task/{tid}/wchan").strip()
                comm = _slurp(f"/proc/{pid}/task/{tid}/comm").strip()
                chunks.append(f"tid {tid:>7} [{comm:<15}]: {wchan}\n")
        except Exception as e:
            chunks.append(f"<failed to list threads: {e}>\n")
        chunks.append("\n")
        try:
            r = subprocess.run(["ps", "-Lf", "-p", str(pid)],
                               capture_output=True, text=True, timeout=5)
            chunks.append(f"--- ps -Lf -p {pid} ---\n{r.stdout}\n")
        except Exception:
            pass

    try:
        with open(path, "w") as f:
            f.writelines(chunks)
    except Exception:
        return None
    return path


def execute_restart_command(cmd: dict, dashboard_url: str, token: str) -> None:
    """Cycle a snode unit for a watchdog-queued remote restart, then POST
    the outcome back. Validates the unit name to prevent command
    injection from a compromised dashboard.

    Uses sudo `systemctl stop` + brief settle + `systemctl start`
    instead of a single `restart`, because the existing operator
    sudoers policy (set up for the SUDS upgrade flow) whitelists
    those two verbs but not `restart`. Asking the operator to update
    sudoers on every agent host would block the 2026-06-08 self-heal
    deploy on a config chore — stop+start gets the same effect with
    the policy as-is. The 2-second settle gives the daemon time to
    release the p2p/RPC/quorumnet ports before we re-bind.
    """
    import re as _re
    unit = cmd.get("unit") or ""
    cid = cmd["id"]
    # Defensive: only allow the unit-name shapes we manage — snode units
    # (xeqmnode_snodeN.service) plus the seed and public-node units
    # (xeqm-seed.service / xeqm-pubnode.service). The old pattern matched
    # only xeqmnode_* and silently refused xeqm-seed / xeqm-pubnode, which
    # defeated the watchdog pn/seed daemon-wedge self-heal entirely: every
    # remote restart of a seed or pubnode was rejected here before it ran.
    if not _re.fullmatch(
        r"(xeqmnode_[A-Za-z0-9_-]+|xeqm-seed|xeqm-pubnode)\.service", unit):
        post_restart_result(
            dashboard_url, token, cid, "failed",
            error=f"refusing to restart unsafe unit name: {unit!r}",
        )
        return

    def _ctl(verb: str, timeout: int) -> tuple[bool, str]:
        try:
            r = subprocess.run(
                ["sudo", "/bin/systemctl", verb, unit],
                capture_output=True, text=True, timeout=timeout,
            )
        except subprocess.TimeoutExpired:
            return False, f"systemctl {verb} timed out after {timeout}s"
        if r.returncode == 0:
            return True, ""
        return False, ((r.stderr or "").strip() or f"exit code {r.returncode}")[:1000]

    # 2026-06-08: capture wedge-state forensics BEFORE the stop. Best
    # effort — if it fails or returns None, restart proceeds normally.
    # The path is reported back so the dashboard can fire an alarm
    # naming the file the operator forwards to dev.
    stack_dump = capture_daemon_state(unit)

    ok, err = _ctl("stop", 180)
    if not ok:
        post_restart_result(dashboard_url, token, cid, "failed",
                            error=f"stop failed: {err}",
                            stack_dump_path=stack_dump)
        return
    time.sleep(2)
    ok, err = _ctl("start", 60)
    if not ok:
        post_restart_result(dashboard_url, token, cid, "failed",
                            error=f"start failed: {err}",
                            stack_dump_path=stack_dump)
        return
    post_restart_result(dashboard_url, token, cid, "ok",
                        stack_dump_path=stack_dump)


def execute_registration_command(cmd: dict, dashboard_url: str, token: str,
                                 systemd_pattern: str, systemd_unit_dir: str,
                                 rpc_timeout: float = 5.0) -> None:
    """Phase 2G: handle one registration_command by calling the snode
    daemon's get_service_node_registration_cmd RPC and posting the blob
    (or error) back to the dashboard."""
    cid = cmd["id"]
    pubkey = cmd["pubkey"]
    operator_address = cmd["operator_address"]
    contribution_amount = cmd["contribution_amount"]
    operator_cut = cmd.get("operator_cut", 0)

    target = _resolve_upgrade_target(
        pubkey, systemd_pattern, systemd_unit_dir, rpc_timeout,
    )
    if not target:
        post_registration_result(
            dashboard_url, token, cid, "failed",
            error=f"no daemon found for pubkey {pubkey[:12]}…",
        )
        return

    # Re-discover the matching RPC URL from the snode's systemd unit.
    rpc_url = None
    _, unit_name, _ = target
    try:
        with open(os.path.join(systemd_unit_dir, unit_name)) as f:
            for line in f:
                if not line.strip().startswith("ExecStart="):
                    continue
                m = re.search(r"--rpc-admin[= ]\S*:(\d+)", line)
                if m:
                    rpc_url = f"http://127.0.0.1:{m.group(1)}"
                    break
                m = re.search(r"--rpc-bind-port[= ](\d+)", line)
                if m:
                    rpc_url = f"http://127.0.0.1:{m.group(1)}"
                    break
    except OSError:
        pass
    if not rpc_url:
        post_registration_result(
            dashboard_url, token, cid, "failed",
            error="could not resolve daemon RPC URL for registration call",
        )
        return

    print(f"[agent] generating registration blob for {pubkey[:12]}… via {rpc_url}")
    payload = {
        "jsonrpc": "2.0", "id": "0",
        "method": "get_service_node_registration_cmd",
        "params": {
            "operator_cut": str(operator_cut),
            "contributor_addresses": [operator_address],
            "contributor_amounts": [contribution_amount],
            "staking_requirement": contribution_amount,
        },
    }
    try:
        req = urllib.request.Request(
            rpc_url + "/json_rpc", data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            result = json.loads(resp.read())
    except Exception as e:
        post_registration_result(
            dashboard_url, token, cid, "failed",
            error=f"daemon RPC failed: {e}",
        )
        return

    if "error" in result:
        post_registration_result(
            dashboard_url, token, cid, "failed",
            error=f"daemon RPC error: {result['error']}",
        )
        return

    blob = (result.get("result") or {}).get("registration_cmd")
    if not blob:
        post_registration_result(
            dashboard_url, token, cid, "failed",
            error="daemon returned no registration_cmd field",
        )
        return

    post_registration_result(dashboard_url, token, cid, "ready", registration_cmd=blob)


# ── SUDS Phase 2: native-systemd upgrade executor ─────────────────────────────

# Binaries we expect to swap together — keep in sync with the release tarball
# contents. Any extra files in the tarball that don't appear here are ignored.
SUDS_BINARIES = ("xeqm-d", "xeqm-rpc", "xeqm-wallet", "xeqm-mdb_copy", "xeqm-mdb_stat")

# How many .bak.* sets to keep per binary after each upgrade or rollback.
SUDS_BACKUP_KEEP = 2

# How long we wait for `systemctl is-active` to report 'active' after start.
SUDS_STARTUP_TIMEOUT_S = 90
# How long between polls of `systemctl is-active`.
SUDS_STARTUP_POLL_S = 2


def _run(cmd: list[str], timeout: float = 60.0) -> subprocess.CompletedProcess:
    """Thin wrapper that captures both streams and decodes to text."""
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def _get_unit_exec_dir(unit_name: str) -> str | None:
    """Parse ExecStart= from `systemctl cat <unit>` and return its dirname,
    e.g. '/home/snode1/bin'. Returns None if the unit can't be inspected."""
    # `systemctl cat` reads world-readable unit files; no privilege needed.
    # Mirrors the dashboard-side fix (suds_executor.py:_get_unit_exec_dir):
    # routing through sudo creates an unnecessary dependency on the sudoers
    # grant covering this verb, and silently fails if it doesn't.
    r = _run(["/bin/systemctl", "cat", unit_name], timeout=10)
    if r.returncode != 0:
        return None
    for line in r.stdout.splitlines():
        line = line.strip()
        if line.startswith("ExecStart="):
            tokens = line[len("ExecStart="):].split()
            if tokens:
                return os.path.dirname(tokens[0])
    return None


def _resolve_upgrade_target(pubkey: str, systemd_pattern: str,
                            systemd_unit_dir: str,
                            rpc_timeout: float) -> tuple[str, str, str] | None:
    """Locate the pubkey's daemon and report how to upgrade it.

    Returns ('systemd', unit_name, exec_dir) on success, or None if the
    pubkey isn't reported by any local systemd-managed xeqm-d.
    """
    unit_name = _find_unit_for_pubkey(pubkey, systemd_pattern, systemd_unit_dir, rpc_timeout)
    if unit_name:
        exec_dir = _get_unit_exec_dir(unit_name)
        if exec_dir:
            return ("systemd", unit_name, exec_dir)
    return None


def _find_unit_for_pubkey(pubkey: str, systemd_pattern: str,
                          systemd_unit_dir: str, rpc_timeout: float) -> str | None:
    """Discover which systemd unit's local RPC is currently reporting the
    given pubkey. Returns the unit name (e.g. 'xeqmnode_snode1.service') or
    None if not found."""
    import glob
    for path in glob.glob(os.path.join(systemd_unit_dir, systemd_pattern)):
        unit_name = os.path.basename(path)
        # Walk the unit file for an --rpc-admin=127.0.0.1:PORT or
        # rpc-admin= line in its config-file reference. Simplest path: ask
        # systemd for ExecStart and pull --rpc-admin out of the command line.
        # `systemctl cat` is world-readable; no sudo needed (mirrors the
        # dashboard-side suds_executor.py fix).
        r = _run(["/bin/systemctl", "cat", unit_name], timeout=10)
        if r.returncode != 0:
            continue
        m = re.search(r"--rpc-admin=([0-9.]+):(\d+)", r.stdout)
        if not m:
            continue
        rpc_url = f"http://127.0.0.1:{m.group(2)}"
        if get_pubkey(rpc_url, rpc_timeout) == pubkey:
            return unit_name
    return None


def _xeqm_d_version(binary_path: str) -> str | None:
    """Run `<binary_path> --version` and parse the version string.
    Tries without sudo first (canonical layout puts binaries in
    /opt/xeqm/bin/ which is world-executable); falls back to sudo
    for old restricted-home layouts. Returns e.g. '1.0.7-release-dev',
    or None if the binary cannot be executed."""
    _VER_RE = re.compile(r"v?(\d+\.\d+\.\d+(?:-[A-Za-z0-9_.-]+)?)")
    last_output = ""
    for cmd in ([binary_path, "--version"], ["sudo", binary_path, "--version"]):
        try:
            r = _run(cmd, timeout=10)
        except OSError:
            continue
        output = (r.stdout + r.stderr) or ""
        last_output = output
        m = _VER_RE.search(output)
        if m:
            return m.group(1)
    # Binary ran but produced no parseable version — return the raw output
    # so callers surface the real error (e.g. missing shared lib) rather
    # than the opaque "got ''" message.
    stripped = last_output.strip()
    if stripped:
        return f"exec-error: {stripped[:200]}"
    return None


def _parse_semver(s: str | None) -> tuple[int, ...] | None:
    """'1.0.7' or '1.0.7-release-dev' or '1.0.7-qa1' -> (1, 0, 7).
    Strips pre-release suffixes so QA/debug builds compare equal to
    their base version. Returns None for unparseable input."""
    if not s:
        return None
    parts: list[int] = []
    for chunk in s.split("."):
        digits = ""
        for c in chunk:
            if c.isdigit():
                digits += c
            else:
                break
        if not digits:
            break
        parts.append(int(digits))
    return tuple(parts) if parts else None


def _download_tarball(url: str, dest_path: str, timeout: float = 60.0) -> None:
    """Pull the asset from GitHub to dest_path. Raises on failure."""
    req = urllib.request.Request(url, headers={"User-Agent": "xeqm-agent-suds"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        with open(dest_path, "wb") as f:
            while True:
                chunk = resp.read(64 * 1024)
                if not chunk:
                    break
                f.write(chunk)


def _extract_tarball(tarball_path: str, dest_dir: str) -> str:
    """Extract `tarball_path` into `dest_dir`, returning the path of the
    extracted root that contains the binaries. Handles single-top-dir
    archives (which is the XEQM release convention)."""
    os.makedirs(dest_dir, exist_ok=True)
    import tarfile
    with tarfile.open(tarball_path) as tf:
        tf.extractall(dest_dir)
        members = tf.getmembers()
    # Identify the directory that actually contains the binaries.
    candidates = set()
    for m in members:
        parts = m.name.split("/", 1)
        if parts[0]:
            candidates.add(parts[0])
    if len(candidates) == 1:
        return os.path.join(dest_dir, candidates.pop())
    return dest_dir


def _prune_suds_backups(exec_dir: str) -> None:
    """Delete old .bak.* files in exec_dir, keeping SUDS_BACKUP_KEEP most-recent
    sets per binary. Failures are logged but never propagate."""
    import re
    bak_pat = re.compile(r'^(.+?)\.bak\.(\d{8}-\d{6})$')
    r = _run(["sudo", "/bin/ls", exec_dir], timeout=10)
    if r.returncode != 0:
        print(f"[suds] prune: could not list {exec_dir}: {(r.stderr or '').strip()}")
        return
    by_base: dict[str, list[str]] = {}
    for name in (r.stdout or "").splitlines():
        name = name.strip()
        m = bak_pat.match(name)
        if m:
            by_base.setdefault(m.group(1), []).append(name)
    for base, baks in by_base.items():
        baks.sort(reverse=True)  # YYYYMMDD-HHMMSS is lexicographically ordered
        for old in baks[SUDS_BACKUP_KEEP:]:
            full = os.path.join(exec_dir, old)
            d = _run(["sudo", "/bin/rm", full], timeout=10)
            if d.returncode == 0:
                print(f"[suds] prune: removed {old}")
            else:
                print(f"[suds] prune: warning: could not remove {old}: {(d.stderr or '').strip()}")


COMPANION_PUBKEY_SENTINEL = "__companion__"
COMPANION_DAEMONS = ("xeqm-seed", "xeqm-pubnode")


def _restart_companion_daemons(unit_name: str) -> None:
    """After installing new binaries, restart any companion daemons that share
    the same binary so they pick up the new version.  Failures are logged but
    never propagate — the snode is the upgrade target, not the companion."""
    for companion in COMPANION_DAEMONS:
        c_unit = f"{companion}.service"
        if unit_name == c_unit:
            continue
        chk = _run(["/bin/systemctl", "is-active", c_unit], timeout=5)
        if (chk.stdout or "").strip() != "active":
            continue
        print(f"[suds] restarting companion {c_unit} to pick up new binary")
        r = _run(["sudo", "/bin/systemctl", "stop", c_unit], timeout=120)
        if r.returncode != 0:
            print(f"[suds] warning: stop {c_unit} failed: {r.stderr.strip()}")
            continue
        r = _run(["sudo", "/bin/systemctl", "start", c_unit], timeout=30)
        if r.returncode != 0:
            print(f"[suds] warning: start {c_unit} failed: {r.stderr.strip()}")
            continue
        print(f"[suds] {c_unit} restarted OK")


def _execute_companion_upgrade(cmd: dict, dashboard_url: str, token: str) -> None:
    """Upgrade path for companion-daemon-only hosts (seed-3, future isolated
    pubnode hosts).  These hosts run xeqm-seed / xeqm-pubnode but have no
    registered snodes, so the normal pubkey-targeted path has no entry point.

    Flow: download tarball → back up → stop companions → install → start →
    verify active → committed.  No observation phase (no snode proof-age to
    watch).  Rolls back on any failure."""
    cid = cmd["id"]
    asset_url = cmd["asset_url"]
    target_version = cmd["target_version"]

    def status(s: str, **kw) -> None:
        post_upgrade_status(dashboard_url, token, cid, s, **kw)

    # Find companion units that are loaded (exist) on this host, whether active or not.
    # An interrupted previous upgrade may have left a companion stopped; we still need
    # to be able to install and restart it.
    active_units: list[str] = []    # units to stop before install + start after
    exec_dir: str | None = None
    for companion in COMPANION_DAEMONS:
        c_unit = f"{companion}.service"
        show = _run(["/bin/systemctl", "show", c_unit,
                     "--property=LoadState,ActiveState"], timeout=5)
        out = show.stdout or ""
        if "LoadState=loaded" not in out:
            continue  # unit does not exist on this host
        if exec_dir is None:
            exec_dir = _get_unit_exec_dir(c_unit)
        # Include regardless of active/inactive: we always want it running after upgrade.
        active_units.append(c_unit)

    if not active_units or exec_dir is None:
        status("failed", error="no companion daemon units found on this host")
        return

    print(f"[suds] companion upgrade {cid}: units={active_units} exec_dir={exec_dir}")

    binary_path = os.path.join(exec_dir, "xeqm-d")
    prior_version = _xeqm_d_version(binary_path) or ""

    status("downloading", message=f"companions={','.join(active_units)}", prior_version=prior_version)
    work_root = f"/tmp/xeqm-suds-{cid}"
    tarball = work_root + os.path.splitext(asset_url)[1]
    extracted = None
    try:
        if os.path.exists(work_root):
            shutil.rmtree(work_root)
        _download_tarball(asset_url, tarball)
        extracted = _extract_tarball(tarball, work_root)
    except Exception as e:
        shutil.rmtree(work_root, ignore_errors=True)
        status("failed", error=f"download/extract failed: {e}")
        return

    missing = [b for b in SUDS_BINARIES if not os.path.isfile(os.path.join(extracted, b))]
    if missing:
        shutil.rmtree(work_root, ignore_errors=True)
        status("failed", error=f"release tarball missing binaries: {', '.join(missing)}")
        return

    ts_str = time.strftime("%Y%m%d-%H%M%S")
    backup_paths: list[tuple[str, str]] = []
    binaries_with_backup: list[str] = []
    try:
        for b in SUDS_BINARIES:
            cur = os.path.join(exec_dir, b)
            bak = f"{cur}.bak.{ts_str}"
            r = _run(["sudo", "/bin/cp", "-a", cur, bak])
            if r.returncode == 0:
                backup_paths.append((cur, bak))
                binaries_with_backup.append(b)
                continue
            stderr_l = (r.stderr or "").lower()
            if "no such file" in stderr_l or "cannot stat" in stderr_l:
                continue
            raise RuntimeError(f"backup failed for {b}: {r.stderr.strip()}")
    except Exception as e:
        shutil.rmtree(work_root, ignore_errors=True)
        status("failed", error=f"backup failed: {e}", prior_version=prior_version)
        return
    if "xeqm-d" not in binaries_with_backup:
        shutil.rmtree(work_root, ignore_errors=True)
        status("failed", error=f"no xeqm-d backup made in {exec_dir}",
               prior_version=prior_version)
        return

    status("staging", message=f"backups *.bak.{ts_str}", prior_version=prior_version,
           backup_path=ts_str)

    rollback_reason: str | None = None
    status("restarting")
    try:
        for c_unit in active_units:
            # Only stop if currently running; it may already be stopped from a previous
            # interrupted upgrade attempt.
            chk = _run(["/bin/systemctl", "is-active", c_unit], timeout=5)
            if (chk.stdout or "").strip() == "active":
                r = _run(["sudo", "/bin/systemctl", "stop", c_unit], timeout=120)
                if r.returncode != 0:
                    raise RuntimeError(f"stop {c_unit} failed: {r.stderr.strip()}")
        for b in SUDS_BINARIES:
            src = os.path.join(extracted, b)
            dst = os.path.join(exec_dir, b)
            r = _run(["sudo", "/usr/bin/install", "-o", "root", "-g", "root",
                      "-m", "0755", src, dst])
            if r.returncode != 0:
                raise RuntimeError(f"install of {b} failed: {r.stderr.strip()}")
        for c_unit in active_units:
            r = _run(["sudo", "/bin/systemctl", "start", c_unit], timeout=30)
            if r.returncode != 0:
                raise RuntimeError(f"start {c_unit} failed: {r.stderr.strip()}")
    except Exception as e:
        rollback_reason = str(e)

    # Wait for all companions to become active.
    if rollback_reason is None:
        deadline = time.time() + SUDS_STARTUP_TIMEOUT_S
        while time.time() < deadline:
            states = []
            for c_unit in active_units:
                r = _run(["/bin/systemctl", "is-active", c_unit], timeout=5)
                states.append((r.stdout or "").strip())
            if all(s == "active" for s in states):
                break
            time.sleep(SUDS_STARTUP_POLL_S)
        else:
            rollback_reason = f"companion(s) did not become active within {SUDS_STARTUP_TIMEOUT_S}s"

    if rollback_reason is not None:
        status("rolling_back", error=rollback_reason)
        try:
            for c_unit in active_units:
                _run(["sudo", "/bin/systemctl", "stop", c_unit], timeout=120)
            for cur, bak in backup_paths:
                r = _run(["sudo", "/usr/bin/install", "-o", "root", "-g", "root",
                          "-m", "0755", bak, cur])
                if r.returncode != 0:
                    raise RuntimeError(f"restore of {cur} failed: {r.stderr.strip()}")
            for c_unit in active_units:
                _run(["sudo", "/bin/systemctl", "start", c_unit], timeout=30)
            status("rolled_back_ok", error=rollback_reason, prior_version=prior_version,
                   backup_path=ts_str)
        except Exception as re:
            status("rolled_back_failed", error=f"rollback failed: {re}", prior_version=prior_version,
                   backup_path=ts_str)
        shutil.rmtree(work_root, ignore_errors=True)
        return

    # Companion upgrades go straight to committed — no snode proof-age to observe.
    seen_version = _xeqm_d_version(binary_path) or ""
    if seen_version and seen_version == prior_version:
        rollback_reason = (
            f"binary unchanged after install: still '{seen_version}' "
            f"(tarball may contain a different build of the same semver)"
        )
        status("rolling_back", error=rollback_reason)
        try:
            for c_unit in active_units:
                _run(["sudo", "/bin/systemctl", "stop", c_unit], timeout=120)
            for cur, bak in backup_paths:
                r = _run(["sudo", "/usr/bin/install", "-o", "root", "-g", "root",
                          "-m", "0755", bak, cur])
                if r.returncode != 0:
                    raise RuntimeError(f"restore of {cur} failed: {r.stderr.strip()}")
            for c_unit in active_units:
                _run(["sudo", "/bin/systemctl", "start", c_unit], timeout=30)
            status("rolled_back_ok", error=rollback_reason, prior_version=prior_version,
                   backup_path=ts_str)
        except Exception as re:
            status("rolled_back_failed", error=f"rollback failed: {re}", prior_version=prior_version,
                   backup_path=ts_str)
        shutil.rmtree(work_root, ignore_errors=True)
        return
    shutil.rmtree(work_root, ignore_errors=True)
    _prune_suds_backups(exec_dir)
    status("committed", message=f"companions={','.join(active_units)} version={seen_version}",
           prior_version=prior_version, backup_path=ts_str)


def execute_upgrade_command(cmd: dict, dashboard_url: str, token: str,
                            systemd_pattern: str, systemd_unit_dir: str,
                            rpc_timeout: float = 5.0) -> None:
    """Run one upgrade-or-rollback cycle for ``cmd`` (a dict matching the
    payload the dashboard sends in /api/agent/report's 'commands' array).

    Posts status updates back to the dashboard at each stage; on any hard
    failure (download / install / startup / version mismatch) the binaries
    are restored from backup and the unit is restarted before reporting
    rolled_back_ok (or rolled_back_failed if the restore itself fails)."""

    cid = cmd["id"]
    pubkey = cmd["pubkey"]
    target_version = cmd["target_version"]
    asset_url = cmd["asset_url"]

    if pubkey.startswith(COMPANION_PUBKEY_SENTINEL + ":"):
        _execute_companion_upgrade(cmd, dashboard_url, token)
        return

    def status(s: str, **kw) -> None:
        post_upgrade_status(dashboard_url, token, cid, s, **kw)

    target = _resolve_upgrade_target(
        pubkey, systemd_pattern, systemd_unit_dir, rpc_timeout,
    )
    if not target:
        status("failed", error=f"no upgrade target found for pubkey {pubkey[:12]}…")
        return
    _, unit_name, exec_dir = target
    binary_path = os.path.join(exec_dir, "xeqm-d")
    prior_version = _xeqm_d_version(binary_path) or ""
    print(f"[suds] command {cid}: mode=systemd unit={unit_name} exec_dir={exec_dir} prior={prior_version}")

    # 2. Download the release tarball + extract.
    status("downloading", message=f"unit={unit_name}", prior_version=prior_version)
    work_root = f"/tmp/xeqm-suds-{cid}"
    tarball = work_root + os.path.splitext(asset_url)[1]
    extracted = None
    try:
        if os.path.exists(work_root):
            shutil.rmtree(work_root)
        _download_tarball(asset_url, tarball)
        extracted = _extract_tarball(tarball, work_root)
    except Exception as e:
        shutil.rmtree(work_root, ignore_errors=True)
        status("failed", error=f"download/extract failed: {e}")
        return

    # Sanity-check that the expected binaries are present in the extracted tree.
    missing = [b for b in SUDS_BINARIES if not os.path.isfile(os.path.join(extracted, b))]
    if missing:
        shutil.rmtree(work_root, ignore_errors=True)
        status("failed", error=f"release tarball missing binaries: {', '.join(missing)}")
        return

    # 3. Backup whichever current binaries actually exist on the host.
    # The agent runs as `xeqm-agent` and cannot stat /home/snodeN/
    # (typically 0700 mode), so a plain os.path.isfile check is unsafe:
    # it returns False for every binary even when the daemon is right
    # there. Probe via `sudo cp` instead — sudoers already grants the
    # exact pattern (`/bin/cp -a /home/snode*/bin/xeqm-d* ...`). A
    # 'No such file or directory' from cp means the binary genuinely
    # isn't installed on this host (e.g. explorers' snode2/snode3 ship
    # with xeqm-d only); skip the backup but still install the new copy
    # from the tarball, normalizing the host's binary set. Any other cp
    # failure is real and fails the upgrade.
    ts_str = time.strftime("%Y%m%d-%H%M%S")
    backup_paths = []
    binaries_with_backup = []
    try:
        for b in SUDS_BINARIES:
            cur = os.path.join(exec_dir, b)
            bak = f"{cur}.bak.{ts_str}"
            r = _run(["sudo", "/bin/cp", "-a", cur, bak])
            if r.returncode == 0:
                backup_paths.append((cur, bak))
                binaries_with_backup.append(b)
                continue
            stderr_l = (r.stderr or "").lower()
            if "no such file" in stderr_l or "cannot stat" in stderr_l:
                continue   # not installed on this host — skip backup
            raise RuntimeError(f"backup failed for {b}: {r.stderr.strip()}")
    except Exception as e:
        shutil.rmtree(work_root, ignore_errors=True)
        status("failed", error=f"backup failed: {e}", prior_version=prior_version)
        return
    if "xeqm-d" not in binaries_with_backup:
        # The daemon binary must have been present to roll back to; if
        # cp couldn't find it, something is wrong with exec_dir or
        # the sudoers grant. Bail rather than risk an unrecoverable
        # install.
        shutil.rmtree(work_root, ignore_errors=True)
        status("failed",
               error=f"no xeqm-d backup made in {exec_dir} (perms or path wrong)",
               prior_version=prior_version)
        return
    status("staging",
           message=f"backups at *.bak.{ts_str} ({', '.join(binaries_with_backup)})",
           prior_version=prior_version, backup_path=ts_str)

    # 4. Stop unit, install new binaries, start unit.
    # Install ALL SUDS_BINARIES from the tarball — including any that
    # weren't on the host before — so partial-binary hosts get
    # normalized in the same step. Rollback only restores from the
    # subset we actually backed up; binaries newly added here have no
    # .bak and stay in place if rollback runs.
    status("restarting")
    rollback_reason: str | None = None
    try:
        r = _run(["sudo", "/bin/systemctl", "stop", unit_name], timeout=120)
        if r.returncode != 0:
            raise RuntimeError(f"stop failed: {r.stderr.strip()}")
        for b in SUDS_BINARIES:
            src = os.path.join(extracted, b)
            dst = os.path.join(exec_dir, b)
            r = _run(["sudo", "/usr/bin/install", "-o", "root", "-g", "root",
                      "-m", "0755", src, dst])
            if r.returncode != 0:
                raise RuntimeError(f"install of {b} failed: {r.stderr.strip()}")
        r = _run(["sudo", "/bin/systemctl", "start", unit_name], timeout=30)
        if r.returncode != 0:
            raise RuntimeError(f"start failed: {r.stderr.strip()}")
        _restart_companion_daemons(unit_name)
    except Exception as e:
        rollback_reason = str(e)

    # 5. Signal 1: wait for unit to become active.
    if rollback_reason is None:
        deadline = time.time() + SUDS_STARTUP_TIMEOUT_S
        while time.time() < deadline:
            r = _run(["/bin/systemctl", "is-active", unit_name], timeout=5)
            if (r.stdout or "").strip() == "active":
                break
            time.sleep(SUDS_STARTUP_POLL_S)
        else:
            rollback_reason = f"unit did not become active within {SUDS_STARTUP_TIMEOUT_S}s"

    # 6. Signal 2: version semver matches expected target.
    if rollback_reason is None:
        status("verifying")
        seen_version = _xeqm_d_version(binary_path) or ""
        target_v = _parse_semver(target_version)
        seen_v = _parse_semver(seen_version)
        if not (target_v and seen_v and seen_v >= target_v):
            rollback_reason = f"version mismatch: expected '{target_version}', got '{seen_version}'"
        elif seen_version and seen_version == prior_version:
            rollback_reason = (
                f"binary unchanged after install: still '{seen_version}' "
                f"(tarball may contain a different build of the same semver)"
            )

    if rollback_reason is None:
        # Phase 2C: hand off to dashboard observation instead of finishing.
        # The dashboard watches proof_age / sync_lag / RPC for the configured
        # observation window, then transitions us to 'committed' or sends
        # back a 'rollback_requested' that we pick up on the next tick.
        shutil.rmtree(work_root, ignore_errors=True)
        _prune_suds_backups(exec_dir)
        status("observing",
               message=f"unit {unit_name} on {target_version}; awaiting dashboard observation",
               prior_version=prior_version, backup_path=ts_str)
        return

    # ── Inline rollback for signals 1 + 2 (hard failures the agent saw) ──
    _perform_rollback(status, unit_name, backup_paths, rollback_reason,
                      prior_version=prior_version)
    shutil.rmtree(work_root, ignore_errors=True)


def _perform_rollback(status_fn, unit_name: str,
                      backup_paths: list[tuple[str, str]],
                      reason: str, prior_version: str = "") -> bool:
    """Shared restore path used by both inline rollback (signals 1+2 fail)
    and the dashboard-triggered rollback_requested path. Returns True on
    success (rolled_back_ok was posted) or False on hard rollback failure
    (rolled_back_failed was posted)."""
    status_fn("rolling_back", error=reason)
    try:
        _run(["sudo", "/bin/systemctl", "stop", unit_name], timeout=120)
        for cur, bak in backup_paths:
            r = _run(["sudo", "/usr/bin/install", "-o", "root", "-g", "root",
                      "-m", "0755", bak, cur])
            if r.returncode != 0:
                raise RuntimeError(f"restore of {cur} failed: {r.stderr.strip()}")
        r = _run(["sudo", "/bin/systemctl", "start", unit_name], timeout=30)
        if r.returncode != 0:
            raise RuntimeError(f"post-restore start failed: {r.stderr.strip()}")
        _restart_companion_daemons(unit_name)
        deadline = time.time() + SUDS_STARTUP_TIMEOUT_S
        while time.time() < deadline:
            r = _run(["/bin/systemctl", "is-active", unit_name], timeout=5)
            if (r.stdout or "").strip() == "active":
                break
            time.sleep(SUDS_STARTUP_POLL_S)
        else:
            raise RuntimeError(f"unit did not come back active within {SUDS_STARTUP_TIMEOUT_S}s")
    except Exception as e:
        status_fn("rolled_back_failed",
                  error=f"original failure: {reason}; rollback also failed: {e}")
        return False
    if backup_paths:
        _prune_suds_backups(os.path.dirname(backup_paths[0][0]))
    status_fn("rolled_back_ok", error=reason, prior_version=prior_version)
    return True


def execute_rollback_command(cmd: dict, dashboard_url: str, token: str,
                             systemd_pattern: str, systemd_unit_dir: str,
                             rpc_timeout: float = 5.0) -> None:
    """Phase 2C: dashboard observation failed and is asking us to restore
    from the backup taken during the original upgrade. ``cmd`` carries
    ``backup_path`` (the timestamp suffix) and ``error`` (the dashboard's
    reason)."""
    cid = cmd["id"]
    pubkey = cmd["pubkey"]
    backup_ts = cmd.get("backup_path") or ""

    def status(s: str, **kw) -> None:
        post_upgrade_status(dashboard_url, token, cid, s, **kw)

    if not backup_ts:
        status("rolled_back_failed",
               error="rollback requested but no backup_path on command — manual fix required")
        return

    target = _resolve_upgrade_target(
        pubkey, systemd_pattern, systemd_unit_dir, rpc_timeout,
    )
    if not target:
        status("rolled_back_failed", error=f"could not locate target for pubkey {pubkey[:12]}…")
        return

    reason = cmd.get("error") or "dashboard requested rollback"

    _, unit_name, exec_dir = target
    # Hosts can have a subset of SUDS_BINARIES installed; the upgrade
    # path only backs up what was already there, so the rollback must
    # only restore those — a missing .bak for a never-installed binary
    # is expected, not a failure. xeqm-d's backup IS required (the
    # daemon couldn't have been upgraded without one).
    backup_paths = []
    for b in SUDS_BINARIES:
        cur = os.path.join(exec_dir, b)
        bak = f"{cur}.bak.{backup_ts}"
        bak_exists = os.path.exists(bak)
        if not bak_exists:
            if b == "xeqm-d":
                status("rolled_back_failed",
                       error=f"backup file missing: {bak} — manual restore required")
                return
            continue
        backup_paths.append((cur, bak))
    _perform_rollback(status, unit_name, backup_paths, reason,
                      prior_version=cmd.get("prior_version") or "")


# ── Config file ────────────────────────────────────────────────────────────────

def load_conf_file() -> dict:
    for path in _CONF_PATHS:
        if not os.path.exists(path):
            continue
        p = configparser.ConfigParser()
        p.read(path)
        s = p["agent"] if "agent" in p else {}
        rpc_raw = s.get("rpc_urls", "")
        return {
            "url":      s.get("url", ""),
            "token":    s.get("token", ""),
            "interval": int(s.get("interval", DEFAULT_INTERVAL)),
            "rpc_urls": [u.strip() for u in rpc_raw.split(",") if u.strip()],
            # default ON: a community dashboard upgrade auto-propagates the agent.
            "auto_update": s.getboolean("auto_update", True),
        }
    return {}


# ── Entry point ────────────────────────────────────────────────────────────────

def main() -> None:
    fc = load_conf_file()

    ap = argparse.ArgumentParser(
        description="XEQM Remote Node Agent",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    ap.add_argument("--url",   default=fc.get("url", ""),
                    help="Dashboard base URL, e.g. http://192.168.50.11:8080")
    ap.add_argument("--token", default=fc.get("token", os.environ.get("XEQM_AGENT_TOKEN", "")),
                    help="Bearer token from dashboard config.yaml agents list")
    ap.add_argument("--rpc-urls", default=",".join(fc.get("rpc_urls", [])),
                    help="Comma-separated RPC URLs (auto-detected from systemd units if omitted)")
    ap.add_argument("--systemd-pattern",  default="xeqmnode_snode*.service",
                    help="Glob for systemd unit files to scan for RPC ports")
    ap.add_argument("--systemd-unit-dir", default="/etc/systemd/system",
                    help="Directory containing systemd unit files")
    ap.add_argument("--daemon",   action="store_true", help="Run as a loop instead of once and exit")
    ap.add_argument("--interval", type=int, default=fc.get("interval", DEFAULT_INTERVAL),
                    help=f"Seconds between reports in --daemon mode (default: {DEFAULT_INTERVAL})")
    ap.add_argument("--dry-run",  action="store_true", help="Print payload instead of sending")
    ap.add_argument("--no-auto-update", dest="auto_update", action="store_false",
                    default=fc.get("auto_update", True),
                    help="Don't self-update even when the dashboard offers a newer agent")
    args = ap.parse_args()

    rpc_urls = [u.strip() for u in args.rpc_urls.split(",") if u.strip()] if args.rpc_urls else []

    # Remove leftover SUDS work dirs from previous runs (each is ~330MB).
    for _d in glob.glob("/tmp/xeqm-suds-[0-9]*"):
        shutil.rmtree(_d, ignore_errors=True)

    if not args.dry_run:
        if not args.url:
            ap.error("--url required (or set url= in /etc/xeqm-agent.conf)")
        if not args.token:
            ap.error("--token required (or XEQM_AGENT_TOKEN env var, or token= in config file)")

    if not HAS_PSUTIL:
        print("[agent] psutil not installed — using /proc fallback. "
              "For full metrics: pip3 install psutil", file=sys.stderr)

    def run_once() -> bool:
        payload = build_payload(rpc_urls, args.systemd_pattern, args.systemd_unit_dir)
        if args.dry_run:
            print(json.dumps(payload, indent=2))
            return True
        response = send_report(args.url, args.token, payload)
        if response is None:
            return False
        n = len(payload.get("pubkeys", []))
        print(f"[agent] Reported {n} node(s) from {payload.get('hostname')}")
        # SUDS: execute any pending upgrade commands inline. We run them
        # synchronously so the systemd one-shot model gives us natural
        # mutual exclusion against the next timer tick (Type=oneshot
        # won't re-fire until this run exits).
        for cmd in response.get("commands", []):
            # Skip terminal + observing rows. The dashboard owns the
            # observation phase — we just wait for it to either commit or
            # set status='rollback_requested', which we pick up next tick.
            agent_skip = ("committed", "failed", "rolled_back_ok",
                          "rolled_back_failed", "observing")
            cs = cmd.get("status")
            if cs in agent_skip:
                continue
            try:
                if cs == "rollback_requested":
                    print(f"[suds] dashboard requested rollback for command id={cmd['id']}")
                    execute_rollback_command(
                        cmd, args.url, args.token,
                        args.systemd_pattern, args.systemd_unit_dir,
                    )
                else:
                    print(f"[suds] executing upgrade command id={cmd['id']} → v{cmd['target_version']}")
                    execute_upgrade_command(
                        cmd, args.url, args.token,
                        args.systemd_pattern, args.systemd_unit_dir,
                    )
            except Exception as e:
                # Last-resort net: report failure so the row isn't stuck.
                post_upgrade_status(args.url, args.token, cmd["id"], "failed",
                                    error=f"unexpected exception: {e}")
        # Phase 2G: process any pending registration_commands inline. Same
        # one-shot model — cheap (one RPC call to the local daemon) so we
        # run synchronously and post the result before exiting.
        for cmd in response.get("registration_commands", []):
            try:
                print(f"[reg] generating registration for command id={cmd['id']}")
                execute_registration_command(
                    cmd, args.url, args.token,
                    args.systemd_pattern, args.systemd_unit_dir,
                )
            except Exception as e:
                post_registration_result(
                    args.url, args.token, cmd["id"], "failed",
                    error=f"unexpected exception: {e}",
                )
        # 2026-06-08: process any pending restart_commands. The watchdog
        # on the dashboard host enqueues these for remote-agent snodes
        # (it can't reach our systemd from there). We run `sudo systemctl
        # restart <unit>` locally and POST the outcome.
        for cmd in response.get("restart_commands", []):
            try:
                print(f"[restart] executing restart command id={cmd['id']} unit={cmd['unit']}")
                execute_restart_command(cmd, args.url, args.token)
            except Exception as e:
                post_restart_result(
                    args.url, args.token, cmd["id"], "failed",
                    error=f"unexpected exception: {e}",
                )
        # Self-update LAST (after this tick's work), if the dashboard offers a newer
        # agent. Under the systemd oneshot+timer model the replaced file is picked up on
        # the next fire; in --daemon mode we exit so a restart loads the new code rather
        # than looping on the stale in-memory version.
        if args.auto_update and response.get("agent_latest_version"):
            if self_update(args.url, response["agent_latest_version"],
                           response.get("agent_latest_sha256")):
                if args.daemon:
                    print("[update] exiting daemon so the updated agent loads on restart")
                    sys.exit(0)
        return True

    if args.daemon:
        print(f"[agent] Daemon mode — reporting every {args.interval}s to {args.url}")
        while True:
            try:
                run_once()
            except Exception as e:
                print(f"[agent] Error: {e}", file=sys.stderr)
            time.sleep(args.interval)
    else:
        sys.exit(0 if run_once() else 1)


if __name__ == "__main__":
    main()
