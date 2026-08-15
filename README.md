# XEQM Labs — Service Node Installer

Easy setup and management of XEQM service nodes on Linux or macOS.

> Based on the original work by [misterr-labs](https://github.com/misterr-labs/eqsnode-installer-script) — extended with XEQM Labs rebranding, canonical systemd/launchd layout, and additional tooling.

---

## Requirements

### Linux
- Ubuntu 22.04 or 24.04 LTS (64-bit, x86_64 or ARM64)
- Root or `sudo` access
- ~2 GB disk space and ~800 MB RAM per node

### macOS
- Apple Silicon (ARM64) — macOS 12 Ventura or later
- [Homebrew](https://brew.sh) installed
- ~2 GB disk space and ~800 MB RAM per node
- No `sudo` required — nodes run as your user account

---

## Step 1 — Get the scripts

### Linux

```bash
sudo apt -y install git
sudo git clone https://github.com/vellitas/xeqm-node-installer-script /opt/xeqm-node-installer-script
cd /opt/xeqm-node-installer-script
```

**Already have the scripts? Pull the latest before doing anything:**

```bash
cd /opt/xeqm-node-installer-script && sudo git pull
```

### macOS

```bash
git clone https://github.com/vellitas/xeqm-node-installer-script
cd xeqm-node-installer-script
```

> If `git` is not found, run `xcode-select --install` to get the Xcode Command Line Tools.

**Already have the scripts? Pull the latest:**

```bash
cd xeqm-node-installer-script && git pull
```

---

## Step 2 — Launch the menu

### Linux

```bash
sudo bash xeqm-manager.sh
```

### macOS

```bash
bash xeqm-manager.sh
```

This opens a full-screen interactive menu with every tool:

| Tool | What it does |
|---|---|
| **Install** | Install service nodes on this server |
| **Health Check** | Check node health: sync, firewall ports, disk space |
| **Register** | Generate registration commands for all unregistered nodes |
| **Firewall** | Reconfigure firewall — switch between UFW, OCI, iptables, or external |
| **Migrate** | Move a node from a remote server to this one |
| **Upgrade** | Upgrade node binaries |
| **Unlock** | Graceful 14-day stake unlock — rewards continue during the lock period |
| **Remove Nodes** | Permanently remove node installs from this server |

> **SSH users:** If the dialog boxes draw incorrectly or appear blank, make sure you allocated a TTY:
> ```bash
> ssh -t user@yourserver
> ```

---

## Step 3 — Install service nodes

Select **Install** from the menu. The installer automatically installs its dependencies, then walks you through every decision one step at a time:

| Step | What it asks |
|---|---|
| 1 | How many nodes to install (auto-detects RAM/disk/CPU limit) |
| 2 | How to get binaries: download latest release / use existing / compile |
| 3 | How to get the blockchain: bootstrap (recommended) / copy from existing node / sync from scratch |
| 4 | Public IPv4 address (auto-detected — confirm or override) |
| 5 | Firewall mode — auto-detected if UFW is active; otherwise prompts for UFW / iptables / Oracle Cloud / external |
| 6 | Scrollable summary of ports, node names, and version |
| 7 | Final confirmation — press **Install** to begin |
| 8 | **Operator Dashboard Agent** (optional) — connects this server to an XEQM operator dashboard for remote monitoring. Skip if you are not using a dashboard. |

On **macOS**, binary download defaults to the official notarized ARM64 release and the firewall step defaults to **External** — open the required ports in your router or OPNSense/pfSense.

### Firewall mode (Linux)

| Option | When to use |
|---|---|
| UFW | Most VPS providers (Contabo, Hetzner, DigitalOcean, OVH, etc.) |
| iptables | Servers without UFW installed |
| Oracle Cloud (OCI) | OCI ships a raw iptables REJECT rule that silently blocks UFW-opened ports — this option removes it automatically |
| External firewall | OPNsense, pfSense, or any perimeter firewall — installer prints the exact ports to open |

After confirmation, the installer shows step-by-step progress as it creates the node state directories, downloads and verifies the binary, downloads the blockchain, installs services, and starts the daemons. A single node takes about 15–20 minutes (mostly blockchain download time).

---

## Step 4 — Register and stake each node

After the install finishes, a **Next Steps** checklist is shown. Each node must be registered on-chain before it starts earning rewards.

Select **Register** from the menu. The script auto-discovers all installed nodes, checks each against the chain, and shows only nodes that are **not yet registered**. For each unregistered node it asks:

1. **Solo or pool node?**
   - Solo: you stake the full 200,000 XEQM yourself
   - Pool: you stake 100,000–200,000 XEQM and open the remainder to contributors

2. **Operator fee** (pool nodes only): 0–10% of rewards kept by you before splitting with contributors.

3. **Your XEQM wallet address.** Must start with `XEQM` and be the correct length.

The script prints a registration command for each node. Submit it from your XEQM wallet to complete registration.

---

## Key backup

Each node has a unique private key stored in its state directory. **Losing this key means losing the node.** Back it up immediately after install.

### Linux

```bash
sudo find /var/lib/xeqm -name 'key_ed25519'
sudo cat /var/lib/xeqm/snode1/key_ed25519
```

### macOS

```bash
find ~/xeqm -name 'key_ed25519'
cat ~/xeqm/snode1/key_ed25519
```

Store the output securely (password manager, encrypted backup). To move a node to a new server without losing its identity, use `server-migrate.sh` — see [Migrate a node](#migrate-a-node-from-another-server-server-migratesh) below.

---

## Day-to-day node management

### Linux

Nodes run as systemd services under the shared `xeqm` user:

```bash
# Status
sudo systemctl status xeqmnode_snode1

# Logs (live)
sudo journalctl -u xeqmnode_snode1 -f

# Start / stop / restart
sudo systemctl start  xeqmnode_snode1
sudo systemctl stop   xeqmnode_snode1
sudo systemctl stop   xeqmnode_snode1 && sleep 3 && sudo systemctl start xeqmnode_snode1
```

To act on all nodes at once:

```bash
sudo systemctl stop   'xeqmnode_snode*'
sudo systemctl start  'xeqmnode_snode*'
sudo systemctl status 'xeqmnode_snode*'
```

### macOS

Nodes run as launchd agents under your user account:

```bash
# Status (all nodes)
launchctl list | grep xeqmlabs

# Logs (live)
tail -f ~/xeqm/snode1/xeqm-d.log

# Start / stop / restart
launchctl start  com.xeqmlabs.snode1
launchctl stop   com.xeqmlabs.snode1
launchctl stop   com.xeqmlabs.snode1 && sleep 3 && launchctl start com.xeqmlabs.snode1
```

---

## Operator Dashboard (optional)

The [XEQM Operator Dashboard](https://github.com/vellitas/xeqm-operator-dashboard) lets you monitor and manage your nodes from a web browser. Step 8 of the installer sets up the agent that connects your server to a dashboard.

> **Note:** The dashboard agent is Linux-only. macOS nodes can be monitored via the Health Check tool locally.

**What you need first:**
- A running operator dashboard (self-hosted or provided by a community member)
- A dashboard URL (e.g. `https://dashboard.example.com`)
- An agent token from the dashboard's **Settings → Agents** page

**If you skipped Step 8 during install**, re-run the installer — the agent step appears at the end:

```bash
sudo bash install.sh
```

**Verifying the connection:** After install, the agent runs every 60 seconds. Within a minute your server should appear as **online** in the dashboard's Remote Agents list.

---

## Upgrading nodes

Run from the menu or directly:

### Linux
```bash
sudo bash upgrade.sh
```

### macOS
```bash
bash upgrade.sh
```

All installed nodes are upgraded automatically. The binary is downloaded once, SHA256-verified, and reused for each node.

---

## Health Check (doctor.sh)

### Linux
```bash
sudo bash doctor.sh
```

### macOS
```bash
bash doctor.sh
```

The doctor prints a table with one row per node:

| Column | What it shows |
|---|---|
| **Node** | Node name (snode1, snode2, …) |
| **Svc** | Service state (`active` / `inactive` / `failed`) |
| **Chain** | Sync progress — height vs network tip, or `stuck` / `no data` |
| **Peers** | Inbound + outbound peer count (green ≥ 3, amber 1–2, red 0) |
| **Uptime** | How long the daemon process has been running |
| **RAM** | Current resident memory of the daemon process |
| **Reg** | Registration state — `reg'd`, `unreg`, `unlock` (14-day lock), `sync` |
| **FW** | Firewall check — `OK` all ports open, `EXT` external firewall, `FAIL` port not reachable, `SCAN` daemon starting up |
| **SN Key** | First 16 characters of the node's ed25519 public key |

When a stuck or corrupt node is detected the doctor offers to restart it automatically before falling back to blockchain replacement.

---

## Reconfigure Firewall (firewall.sh)

**Linux only.** Switch firewall mode for all installed nodes without reinstalling:

```bash
sudo bash firewall.sh
```

| Mode | When to use |
|---|---|
| **UFW** | Moving to a VPS or any server where the host firewall should manage ports |
| **Oracle Cloud (OCI)** | OCI VMs — UFW + removes the raw iptables REJECT rule that blocks UFW-opened ports |
| **iptables** | Servers without UFW where you want direct iptables rules |
| **External firewall** | OPNSense, pfSense, or any perimeter firewall — prints the full port list to configure manually |
| **Remove UFW rules** | Moving from a VPS (UFW) to a location with an external firewall — cleans up node-specific UFW rules |

> **Quorumnet requires both TCP and UDP.** UFW mode opens quorumnet with a combined rule covering both protocols. External firewall mode lists separate TCP and UDP entries for each node.

---

## Migrate a node from another server (server-migrate.sh)

Move a node from a remote server to this one without losing its identity or blockchain data.

### Linux
```bash
sudo bash server-migrate.sh
```

### macOS
```bash
bash server-migrate.sh
```

The tool prompts for the source server hostname/IP and SSH user, tests connectivity, then auto-discovers all nodes on the source server. Select which node to migrate; the script copies the keys and blockchain data, installs the node here, and starts the service.

> Requires passwordless SSH key access from this server to the source server.

---

## Firewall ports

Open these ports **inbound** for each node:

| Purpose | Default Port | Protocol |
|---|---|---|
| P2P (peer discovery) | 9230 | TCP |
| Quorumnet (SN consensus) | 9232 | **TCP + UDP** |

> **Quorumnet requires both TCP and UDP.** Opening only TCP causes "Unreachable for Timestamp Check" deregistrations.

Default port spacing is 100 per node: snode2 uses 9330/9332, snode3 uses 9430/9432, etc.

**UFW example (Linux, per node):**

```bash
sudo ufw allow 9230/tcp    # P2P
sudo ufw allow 9232        # Quorumnet — both TCP and UDP
```

**Oracle Cloud users:** In addition to UFW, open the equivalent ports in your VCN Security List (OCI Console → Networking → Virtual Cloud Networks → your VCN → Security Lists). The installer's **Oracle Cloud** firewall option also removes the OCI iptables REJECT rule automatically.

**macOS / external firewall users:** Open the ports in your router or OPNSense/pfSense (Firewall → NAT → Port Forward, one rule per port).

---

## Remove Nodes (wipe.sh)

Permanently remove all installed nodes from this server.

### Linux
```bash
sudo bash wipe.sh
```

### macOS
```bash
bash wipe.sh
```

This stops and disables all node services, removes all state directories, and removes the binary. **This is irreversible** — if any nodes are registered, migrate them first to avoid stake lockout.

---

## Advanced / CLI options

All installer questions can be answered up front on the command line. Anything not specified is still prompted interactively.

### Number of nodes

```bash
# Linux
sudo bash install.sh --nodes 5

# macOS
bash install.sh --nodes 5
```

### Blockchain source

```bash
bash install.sh --copy-blockchain bootstrap          # download bootstrap (recommended)
bash install.sh --copy-blockchain auto               # copy from existing node on this server
bash install.sh --copy-blockchain /path/to/snode1    # copy from specific path
bash install.sh --copy-blockchain no                 # sync fresh from network
```

### Custom ports (useful when behind NAT or sharing a public IP)

```bash
bash install.sh --nodes 2 --ports p2p:12230+12330,rpc:12231+12331
```

Quorumnet is derived automatically as P2P+2 per node.

### Specific version

```bash
bash install.sh --version core-v1.0.7
```

### Fully non-interactive install

```bash
# Linux
sudo bash install.sh --nodes 2 --copy-blockchain bootstrap --open-firewall --quiet

# macOS
bash install.sh --nodes 1 --copy-blockchain bootstrap --quiet
```

---

## Built-in help

```bash
bash install.sh --help
bash server-migrate.sh --help
bash upgrade.sh --help
bash doctor.sh --help
```
