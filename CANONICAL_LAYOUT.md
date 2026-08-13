# The Canonical Layout — How XEQM Nodes Should Run

## Why canonical layout?

The old installer layout (one OS user per node, binary in ~/bin, data in ~/.xeqmlabs) worked
for single-node deployments but does not scale safely or efficiently to multi-node hosts.

The canonical layout fixes five concrete problems:

| Dimension | Installer layout | Canonical layout |
|-----------|-----------------|-----------------|
| **Security** | Each snodeN user has sudo privileges and a full home directory. A compromised snode1 process can read snode2's key files. | Single `xeqm` system user with no shell, no home, and `ReadWritePaths` scoped per unit. A compromised snode1 process cannot reach snode2's data directory. |
| **Disk efficiency** | Binary duplicated in every user's ~/bin. 28 nodes = 28 copies of xeqm-d on disk, 28× page-cache pressure. | One binary at `/opt/xeqm/bin/xeqm-d`. The OS page-caches it once, shared across all snodes. Rollback is one `ln -sf` call. |
| **Operational simplicity** | Per-user xeqm-node.sh wrappers, per-user install.conf, per-user sudoers entries, per-user blockchain copies. | All nodes managed identically via `systemctl`. One binary, one user, consistent paths. No per-node scripts. |
| **FHS compliance** | State scattered across /home, binaries in user home dirs — not discoverable by standard tooling. | Binaries in `/opt`, state in `/var/lib`, config embedded in the unit `ExecStart`. Compatible with journalctl aggregation, logrotate, audit frameworks out of the box. |
| **systemd hardening** | No sandboxing. The daemon runs with the snodeN user's full capabilities. | `NoNewPrivileges`, `ProtectSystem=strict`, `PrivateTmp`, `CapabilityBoundingSet=`, `RestrictAddressFamilies` — enforced by the kernel regardless of what the daemon code does. |

---

## Directory structure

```
/opt/xeqm/
└── bin/
    ├── xeqm-d             -> xeqm-d-core-v1.0.7   (symlink, updated on upgrade)
    └── xeqm-d-core-v1.0.7  (versioned binary)

/var/lib/xeqm/
├── snode1/
│   ├── key_bls            (BLS private key — BACK THIS UP)
│   ├── key_ed25519        (Ed25519 private key — BACK THIS UP)
│   ├── p2pstate.bin
│   └── lmdb/
│       └── data.mdb
├── snode2/
│   └── ...
└── snodeN/
    └── ...

/etc/systemd/system/
├── xeqmnode_snode1.service
├── xeqmnode_snode2.service
└── xeqmnode_snodeN.service
```

---

## User model

All service nodes share a single system user `xeqm` (uid 999, no home directory, shell
`/usr/sbin/nologin`). This user cannot log in interactively.

Each unit's `ReadWritePaths` is scoped to its own data directory
(`/var/lib/xeqm/snodeN`). Combined with `ProtectSystem=strict`, a running daemon
can only write to its own directory — it cannot touch another node's state, /opt, /etc,
or any other filesystem path.

---

## Binary installation

Binaries are stored versioned to enable instant rollback:

```
/opt/xeqm/bin/xeqm-d-core-v1.0.7    # versioned copy
/opt/xeqm/bin/xeqm-d                 # symlink -> above
```

To upgrade: place new binary, update symlink, restart services.
To roll back: point symlink at previous versioned binary, restart services.

---

## Port convention

For each node, ports are derived from the base p2p port:

| Port       | Use                                 | Firewall |
|------------|-------------------------------------|----------|
| p2p        | Peer-to-peer (e.g. 9230)            | TCP inbound open |
| p2p + 1    | rpc-admin (e.g. 9231)               | 127.0.0.1 only, never open |
| p2p + 2    | Quorumnet (e.g. 9232)               | TCP+UDP inbound open |

Default first node: 9230/9231/9232. Additional nodes increment by 100:
9330/9331/9332, 9430/9431/9432, etc.

---

## Systemd unit structure

Annotated example for snode1 with p2p=9230:

```ini
[Unit]
Description=XEQMLabs Service Node (snode1)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=xeqm                            # shared system user, no shell
Group=xeqm
StateDirectory=xeqm/snode1           # systemd creates /var/lib/xeqm/snode1 if absent
StateDirectoryMode=0700              # only xeqm user can read it
WorkingDirectory=/var/lib/xeqm/snode1
ExecStart=/opt/xeqm/bin/xeqm-d \
  --non-interactive \
  --data-dir=/var/lib/xeqm/snode1 \
  --service-node \
  --p2p-bind-ip=0.0.0.0 \
  --p2p-bind-port=9230 \
  --rpc-admin=127.0.0.1:9231 \       # admin RPC is loopback-only
  --quorumnet-port=9232 \
  --service-node-public-ip=<public-ip> \
  --seed-node=seeds.xeqmlabs.com:9230 \
  --add-priority-node=seeds.xeqmlabs.com:9230
Restart=on-failure
RestartSec=15s
TimeoutStartSec=300s
TimeoutStopSec=60s
LimitNOFILE=65536

# Hardening
NoNewPrivileges=true                 # daemon cannot gain new capabilities via setuid/setcap
ReadWritePaths=/var/lib/xeqm/snode1 # only this path is writable; everything else is read-only
ProtectSystem=strict                 # /usr, /boot, /etc are read-only to the daemon
PrivateTmp=true                      # /tmp is private; no cross-process /tmp snooping
CapabilityBoundingSet=               # empty set — daemon cannot use any Linux capabilities
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK  # no raw sockets, no packet sockets

[Install]
WantedBy=multi-user.target
```

Note: the actual unit file uses a single-line ExecStart (no line continuations).
The annotated form above is for readability only.

---

## Hardening details

| Directive | Effect |
|-----------|--------|
| `NoNewPrivileges=true` | Prevents the daemon from gaining elevated capabilities via setuid binaries or file capabilities. |
| `ProtectSystem=strict` | Mounts /usr, /boot, /etc as read-only inside the service's namespace. The daemon cannot modify system files even if it wanted to. |
| `ReadWritePaths=/var/lib/xeqm/snodeN` | Explicitly whitelists the one directory the daemon needs to write. Everything else is read-only. |
| `PrivateTmp=true` | Gives the service a private, empty /tmp. Cross-service /tmp attacks are not possible. |
| `CapabilityBoundingSet=` | Drops all Linux capabilities. The daemon cannot open raw sockets, bind privileged ports, or modify kernel parameters. |
| `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK` | Prevents the daemon from creating raw or packet sockets. TCP/UDP, Unix domain, and Netlink sockets are permitted. (Netlink is required by ZMQ for network interface enumeration.) |

---

## Real-world impact

Numbers from an actual migration of a 13-node installer-layout host running v1.0.7:

**Surf migration (13 nodes, v1.0.7):**

Binary disk usage dropped from 13 separate copies (13 × 284 MB = 3.7 GB) to one shared
binary (284 MB) — saving 3.4 GB of disk. LMDB compaction via `mdb_copy -c` brought each
node's database from 902 MB to 891 MB, a modest ~1.2% reduction consistent with a young
chain that hasn't accumulated much fragmentation yet.

The RAM story is more significant. The old layout had 13 separate xeqm-d inodes, so the
OS could not share the ~200 MB text segment between them — each process held its own
private copy in page cache. After migration to the canonical shared binary, the kernel
pages that segment once across all 13 instances. Total RSS before migration: ~4–5 GB for
the 13 installer-layout processes. After migration: 1,685 MB for all 14 processes (13
snodes + seed daemon), averaging 120 MB each. Available RAM on the 11 GB host went from
~6–7 GB to 9.8 GB — nearly 3 GB freed by the layout change alone.

**Lemon migration (55 nodes, v1.0.6):**

Before migration: 55 installer-layout nodes with full blockchains consumed **31,509 MB total RSS**
(572 MB average per node), with 37 GB available RAM on the 62 GB host.

After migration to canonical layout: **6,448 MB total RSS** across all 55 nodes — an 80% reduction
in resident memory. Average per node dropped from 572 MB to 117 MB. Available RAM rose from
37 GB to 46 GB — nearly 9 GB freed by the layout change alone.

The single shared binary at `/opt/xeqm/bin/xeqm-d` (24 MB) replaced 55 separate binary copies
held in per-user home directories. The OS maps the text segment into physical memory once and
shares it across all 55 processes; in the installer layout each process held its own private copy.
For a 55-node host this eliminates roughly 55 × (binary text segment size) of redundant RAM
pressure — the dominant factor in the measured reduction.

---

## Adding a node manually

Replace `<ver>`, `<N>`, `<p2p>`, `<rpc>`, `<qnet>`, and `<public-ip>` with real values.

```bash
# 1. Ensure xeqm user exists
sudo useradd --system --no-create-home --shell /usr/sbin/nologin xeqm

# 2. Install binary (if not already done)
sudo mkdir -p /opt/xeqm/bin
sudo cp xeqm-d /opt/xeqm/bin/xeqm-d-<ver>
sudo chmod 755 /opt/xeqm/bin/xeqm-d-<ver>
sudo ln -sf /opt/xeqm/bin/xeqm-d-<ver> /opt/xeqm/bin/xeqm-d

# 3. Create data directory
sudo mkdir -p /var/lib/xeqm/snode<N>
sudo chown xeqm:xeqm /var/lib/xeqm/snode<N>
sudo chmod 0700 /var/lib/xeqm/snode<N>

# 4. Write unit file — see example above
sudo tee /etc/systemd/system/xeqmnode_snode<N>.service > /dev/null <<EOF
... (unit content) ...
EOF

# 5. Enable and start
sudo systemctl daemon-reload
sudo systemctl enable --now xeqmnode_snode<N>

# 6. Open firewall
sudo ufw allow <p2p>/tcp
sudo ufw allow <qnet>         # TCP+UDP
```

---

## Removing a node manually

```bash
sudo systemctl stop xeqmnode_snode<N>
sudo systemctl disable xeqmnode_snode<N>
sudo rm /etc/systemd/system/xeqmnode_snode<N>.service
sudo systemctl daemon-reload
sudo rm -rf /var/lib/xeqm/snode<N>
```

The xeqm user and /opt/xeqm/bin are shared — only remove them when no nodes remain.

---

## Upgrading the binary

```bash
# 1. Download new binary
wget -O /tmp/xeqm-d-new <github-release-url>
chmod +x /tmp/xeqm-d-new

# 2. Install versioned copy
sudo cp /tmp/xeqm-d-new /opt/xeqm/bin/xeqm-d-<new-ver>
sudo chmod 755 /opt/xeqm/bin/xeqm-d-<new-ver>

# 3. Update symlink (atomic)
sudo ln -sf /opt/xeqm/bin/xeqm-d-<new-ver> /opt/xeqm/bin/xeqm-d

# 4. Rolling restart — one at a time to avoid quorum disruption
for unit in /etc/systemd/system/xeqmnode_snode*.service; do
  name=$(basename "${unit}")
  sudo systemctl stop "${name}"
  sleep 2
  sudo systemctl start "${name}"
done
```

To roll back, point the symlink at the previous versioned binary and restart.

---

## Key file location

The service node keys are stored at:

```
/var/lib/xeqm/snodeN/key_bls
/var/lib/xeqm/snodeN/key_ed25519
```

Back up both files immediately after registration. Losing either one means losing the node —
there is no recovery path if the keys are gone and the node is still registered.

```bash
# Copy keys to a backup location
sudo cp /var/lib/xeqm/snode<N>/key_bls    /secure/backup/snode<N>.key_bls
sudo cp /var/lib/xeqm/snode<N>/key_ed25519 /secure/backup/snode<N>.key_ed25519
sudo chmod 600 /secure/backup/snode<N>.key_bls /secure/backup/snode<N>.key_ed25519
```

---

## Contrast with old installer layout

| Aspect | Installer layout | Canonical layout |
|--------|-----------------|-----------------|
| OS users | One per node (snode1, snode2 …) | One shared system user (xeqm) |
| Binary location | /home/snodeN/bin/xeqm-d | /opt/xeqm/bin/xeqm-d (symlink) |
| Data location | /home/snodeN/.xeqmlabs/ | /var/lib/xeqm/snodeN/ |
| Configuration | install.conf file | Embedded in unit ExecStart |
| Node wrapper | xeqm-node.sh per user | None — use systemctl directly |
| systemd hardening | None | Full (NoNewPrivileges, ProtectSystem, etc.) |
| Upgrade mechanism | Copy binary per user, restart per user | Swap symlink, restart all units |
| Suitable for | Single-node, first-time operators | Multi-node fleets, community deployments |

---

Run `sudo bash install.sh` — it detects your existing setup and does the right thing.
