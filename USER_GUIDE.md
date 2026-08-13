# XEQM Labs — Service Node User Guide

Welcome! This guide will walk you through everything you need to run an XEQM service node —
from first installation to day-to-day management. No deep technical knowledge required.
Take it one step at a time and you'll be up and running in under an hour.

---

## Table of Contents

1. [What Is a Service Node?](#1-what-is-a-service-node)
2. [What You Need Before You Start](#2-what-you-need-before-you-start)
3. [Getting the Scripts](#3-getting-the-scripts)
4. [Installing Your First Node](#4-installing-your-first-node)
5. [Installing Multiple Nodes on One Server](#5-installing-multiple-nodes-on-one-server)
6. [Registering and Staking Your Node](#6-registering-and-staking-your-node)
7. [Daily Node Management](#7-daily-node-management)
8. [Upgrading Your Nodes](#8-upgrading-your-nodes)
9. [Health Checks and Auto-Repair](#9-health-checks-and-auto-repair)
10. [Moving a Node to Another Server](#10-moving-a-node-to-another-server)
11. [Unlocking a Node (Stake Release)](#11-unlocking-a-node-stake-release)
12. [Firewall Configuration](#12-firewall-configuration)
13. [Quiet Mode (Unattended Installs)](#13-quiet-mode-unattended-installs)
14. [Quick Reference Card](#14-quick-reference-card)
15. [Troubleshooting](#15-troubleshooting)

---

## 1. What Is a Service Node?

A service node is a computer (usually a rented server) that helps run the XEQM network.
Think of it like volunteering a server to keep the network healthy. In return, the owner
earns XEQM rewards.

To activate a node you must **stake** — temporarily lock up a set amount of XEQM as a
guarantee that your node will behave correctly. Your staked XEQM is never spent; it is
returned when you stop operating the node.

These scripts handle all the technical work of setting up and managing your node. Your
job is to answer a few questions during installation, then stake from your wallet.

---

## 2. What You Need Before You Start

### Server Requirements

| Requirement | Minimum | Recommended |
|---|---|---|
| Operating System | Ubuntu 22.04 LTS | Ubuntu 24.04 LTS |
| RAM | 2 GB | 4 GB |
| Disk Space | 50 GB free | 100 GB+ SSD |
| Network | Stable broadband | Dedicated connection |

> **Each additional node** on the same server needs roughly **800 MB more RAM** and
> **2 GB more disk space** for the software itself, plus additional space as the
> blockchain grows over time.

### Ports That Must Be Open

Your server's firewall (or router if you use one) must allow traffic on these ports
for **each node**:

| Port | Protocol | Purpose |
|---|---|---|
| **9230** | TCP | Peer-to-peer — how your node finds others |
| **9232** | TCP + UDP | Quorumnet — service node consensus |

> **Quorumnet requires both TCP and UDP.** Opening only TCP causes
> "Unreachable for Timestamp Check" deregistrations.
> Port 9231 (RPC) is for **internal use only** and must not be opened externally.

If you are on a VPS (rented cloud server), these ports are usually easy to open in your
provider's control panel. If you run your own hardware behind a router, you will need
to set up port forwarding. See [Section 12](#12-firewall-configuration) for details.

### Things to Have Ready

- SSH access to your server (or be sitting at it)
- Your XEQM wallet, for staking after installation
- About 30–60 minutes of time

---

## 3. Getting the Scripts

Log in to your server and run the following commands. Copy and paste them exactly.

```bash
# Install git if it is not already present
sudo apt -y install git

# Download the scripts
sudo git clone https://github.com/vellitas/xeqm-node-installer-script /opt/xeqm-node-installer-script

# Move into the folder
cd /opt/xeqm-node-installer-script
```

You only need to do this once. To get future updates:

```bash
cd /opt/xeqm-node-installer-script && sudo git pull
```

---

## 4. Installing Your First Node

### Step 1 — Launch the menu

From inside the `xeqm-node-installer-script` folder, run:

```bash
sudo bash xeqm-manager.sh
```

This opens a full-screen interactive menu. Select **Install** and press Enter.

The installer launches an **interactive wizard** — a series of dialog boxes where you
navigate with the arrow keys and Tab, and press Enter to confirm each choice. You can
press **Back** on any screen to change a previous answer.

> **No dialog boxes?** If whiptail is not available, the same questions are asked as
> plain text prompts. The answers and defaults are identical.

---

### Step 2 — How many nodes?

A dialog asks how many service nodes to install on this server. The installer calculates
the maximum your server can support based on available RAM and disk space and shows it
in the prompt.

For your first install, **leave blank and press Enter** to install 1 node.

---

### Step 3 — Choose how to get the binaries

```
┌──────────────────────── XEQM Binaries ────────────────────────┐
│ How would you like to get the XEQM node binaries?             │
│                                                                │
│   ( ) Download pre-built binaries from GitHub  (fastest)      │
│   ( ) Compile from source  (~1 hour)                          │
└────────────────────────────────────────────────────────────────┘
```

**Select "Download pre-built binaries from GitHub"** (the default). Compiling from
source takes about an hour and is only needed if no pre-built release is available
for your CPU architecture.

---

### Step 4 — Choose how to get the blockchain

The blockchain is the complete history of all XEQM transactions. Your node needs a
full copy before it can participate in the network.

```
┌─────────────────────────── Blockchain ────────────────────────┐
│ How should the node(s) get their blockchain?                  │
│                                                               │
│   ( ) Download bootstrap  (fastest, ~15 min)                 │
│   ( ) Copy from an existing active node on this server       │
│   ( ) Sync from the network  (slowest, may take many hours)  │
└───────────────────────────────────────────────────────────────┘
```

| Option | When to use it |
|---|---|
| **Download bootstrap** | First node on a new server. Fast, ~15 minutes. |
| **Copy from existing node** | You already have a synced node running on this server. |
| **Sync from network** | Only if bootstrap is unavailable and no existing node. |

For almost everyone, **select "Download bootstrap" and press Enter**.

---

### Step 5 — Public IP address

A dialog shows the auto-detected public IPv4 address of your server. Press Enter to
accept it. If your server is behind a load balancer or NAT and has a different public
IP, clear the field and type the correct address.

---

### Step 6 — Firewall

```
┌──────────────────────────── Firewall ─────────────────────────┐
│ How is the firewall managed on this server?                   │
│                                                               │
│   ( ) UFW — configure automatically  (recommended)           │
│   ( ) iptables — configure automatically                      │
│   ( ) Oracle Cloud (OCI) — UFW + remove raw iptables REJECT  │
│   ( ) OPNsense / pfSense / other external firewall           │
└───────────────────────────────────────────────────────────────┘
```

| Option | When to use it |
|---|---|
| **UFW** | Standard VPS on Contabo, Hetzner, OVH, DigitalOcean, etc. |
| **iptables** | Server without UFW installed. |
| **Oracle Cloud (OCI)** | Oracle Cloud instances. OCI ships a raw iptables REJECT rule that silently blocks ports even when UFW allows them; this option fixes it automatically. |
| **External firewall** | Your server sits behind OPNsense, pfSense, or a cloud security group. The installer prints the exact ports to open rather than touching the server's firewall. |

**Select UFW** for most VPS providers. Select **Oracle Cloud** if you are on OCI.

---

### Step 7 — Review and confirm

The wizard shows a scrollable summary of your full configuration — node names, ports,
binary version, and blockchain source. Review it, then advance to **Confirm Installation**
and select **Install** to begin.

---

### Step 8 — Operator Dashboard Agent (optional)

After installation completes, the wizard offers to install the **XEQM Operator Dashboard
Agent**. This connects your server to an operator dashboard for remote monitoring and
management from a web browser.

If you have a dashboard URL and agent token, enter them here. If not, select **Skip** —
you can add the agent later by re-running the installer.

---

### Step 9 — Wait for the installer to finish

The installer will:

1. Install required system packages
2. Download the XEQM software
3. Create the node state directory and shared system user
4. Install a systemd service (so the node restarts automatically after reboots)
5. Open firewall ports
6. Start the node and download the blockchain

The blockchain download takes about 15 minutes with the bootstrap option. When complete,
a summary and next-steps checklist are shown.

---

## 5. Installing Multiple Nodes on One Server

You can run several nodes on one server as long as it has enough RAM and disk space.

### Install multiple nodes at once

```bash
sudo bash install.sh --nodes 5
```

### Install 2 nodes — first downloads bootstrap, second copies from first

```bash
sudo bash install.sh --nodes 2 --copy-blockchain no,auto
```

> **Tip:** `no,auto` is the fastest way to install multiple nodes — only the
> first node downloads the bootstrap, and the rest copy from it in minutes.

### What happens with ports?

Each node automatically gets its own set of ports. With default settings:

| Node | P2P | RPC (internal only) | Quorumnet |
|---|---|---|---|
| snode1 | 9230 | 9231 | 9232 |
| snode2 | 9330 | 9331 | 9332 |
| snode3 | 9430 | 9431 | 9432 |

Open the **P2P port (TCP)** and **Quorumnet port (TCP + UDP)** for each node in your
firewall. The RPC port must stay closed to the internet.

---

## 6. Registering and Staking Your Node

Installation sets up the software, but your node is **not active on the network yet**.
You need to register it by staking XEQM from your wallet.

### Step 1 — Wait for your node to sync

Your node must be fully synced before you can register it. Check its status:

```bash
sudo systemctl status xeqmnode_snode1
```

Or run the Health Check from the menu — it shows the sync progress for all nodes at once.

---

### Step 2 — Generate the registration command

From the menu select **Register**, or run directly:

```bash
sudo bash register.sh
```

The script auto-discovers all installed nodes, checks each against the chain, and shows
only nodes that are not yet registered. For each unregistered node it asks:

**Solo or pool node?**
- **Solo**: you stake the full 200,000 XEQM yourself. Rewards go entirely to you.
- **Pool**: you stake 100,000–200,000 XEQM and open the remainder to contributors.

**Operator fee** (pool nodes only): 0–10% of rewards kept by you before splitting
with contributors.

**Your XEQM wallet address.** Must start with `XEQM`.

---

### Step 3 — Submit the command from your wallet

The script prints a `register_service_node` command. Copy it exactly and submit it
from your XEQM wallet CLI to complete registration.

---

### Step 4 — Back up your node keys

Each node has a unique private key. **Losing this key means losing the node.** Back
it up immediately after install.

List all node keys:

```bash
sudo find /var/lib/xeqm -name 'key_ed25519' 2>/dev/null
```

Copy a key off the server (example for snode1):

```bash
sudo cat /var/lib/xeqm/snode1/key_ed25519
```

Store the output securely (password manager, encrypted backup). To move a node to a new
server without losing its identity, use `server-migrate.sh` —
see [Section 10](#10-moving-a-node-to-another-server).

---

## 7. Daily Node Management

Nodes run as systemd services under the shared `xeqm` user. All standard systemd
commands work directly.

### Check if your node is running

```bash
sudo systemctl status xeqmnode_snode1
```

### View live logs

```bash
sudo journalctl -u xeqmnode_snode1 -f
```

Press **Ctrl+C** to stop watching.

### Start / stop / restart

```bash
sudo systemctl start   xeqmnode_snode1
sudo systemctl stop    xeqmnode_snode1
sudo systemctl stop    xeqmnode_snode1 && sleep 3 && sudo systemctl start xeqmnode_snode1
```

> **Warning:** Stopping a registered node means it won't earn rewards while stopped.
> If stopped for too long the network may deregister it.

### Managing all nodes at once

```bash
sudo systemctl stop   'xeqmnode_snode*'
sudo systemctl start  'xeqmnode_snode*'
sudo systemctl status 'xeqmnode_snode*'
```

### Check sync height

```bash
curl -s http://127.0.0.1:9231/json_rpc \
  -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":"0","method":"get_info"}' \
  | python3 -m json.tool | grep -E 'height|status'
```

When `height` matches `target_height`, your node is fully synced.

> **Tip:** Use the **Health Check** from the menu — it shows sync status, peers, RAM,
> registration state, and firewall rules for all nodes at once without needing to run
> individual commands.

---

## 8. Upgrading Your Nodes

When a new XEQM version is released, run the upgrade script from the menu or directly:

```bash
sudo bash upgrade.sh
```

All installed nodes are upgraded automatically. The binary is downloaded once and
reused for each node.

### Upgrade to a specific version

```bash
sudo bash upgrade.sh --version v1.0.7
```

> **Before upgrading:** Check the XEQM community channels for any special upgrade
> instructions for the new version. Some releases require additional steps.

---

## 9. Health Checks and Auto-Repair

The Health Check scans all your nodes at once and can fix common problems automatically.
Run it from the menu or directly:

```bash
sudo bash doctor.sh
```

### Reading the output

The doctor prints one row per node:

| Column | What it shows |
|---|---|
| **Node** | Node name (snode1, snode2, …) |
| **Svc** | systemd service state — `active` (green) / `inactive` / `failed` |
| **Chain** | Sync progress — height vs network tip, or `stuck` / `no data` |
| **Peers** | Inbound + outbound peer count — green ≥ 3, amber 1–2, red 0 |
| **Uptime** | How long the daemon process has been running |
| **RAM** | Current memory usage of the daemon process |
| **Reg** | Registration state — `reg'd`, `unreg`, `unlock` (14-day lock), `sync` |
| **FW** | Firewall check — p2p TCP, quorumnet TCP + UDP; flags missing rules |
| **SN Key** | First 16 characters of the node's ed25519 public key |

### What the results mean

**active / reg'd** — Your node is working correctly. Nothing to do.

**sync** — Your node is downloading the blockchain. Normal after a fresh install or
restart. Wait for it to reach network height.

**stuck** — Your node has stopped advancing. The doctor will offer to restart it, and
if that doesn't help, to replace the blockchain data automatically.

### Auto-repair

If a stuck or corrupt node is detected, the doctor offers to restart it and — if still
stuck — to replace its blockchain data:

- **If you have another healthy node on this server:** the doctor copies its blockchain
  to the broken node (takes a few minutes).
- **If not:** the doctor downloads a fresh bootstrap automatically (~15 minutes).

---

## 10. Moving a Node to Another Server

If you need to move a service node — for maintenance or to consolidate servers — use
`server-migrate.sh`. This copies the node's keys and blockchain state from a remote
server to this one over SSH, preserving the node's identity and registration.

> **Why does this matter?** Your node has a unique key. Moving the key means the new
> server takes over as that node, keeping your stake and registration intact with no
> lock period.

### Requirements

- Passwordless SSH key access from this server to the source server
- The source server must still be running the node

### Run the migration

```bash
sudo bash server-migrate.sh
```

The tool will:

1. Prompt for the source server's hostname or IP and SSH user
2. Test connectivity and auto-discover all nodes on the source server
3. Let you select which node to migrate
4. Copy the keys and blockchain data via rsync
5. Install the node on this server and start it

After migration, the source node is still running — stop it once the new server has
synced to avoid duplicate signing.

---

## 11. Unlocking a Node (Stake Release)

When you are ready to stop running a node and reclaim your staked XEQM, use the
**Unlock** tool. This starts a 14-day unlock period during which your node continues
to earn rewards. Your stake is returned at the end of the unlock period.

From the menu select **Unlock**, or run directly:

```bash
sudo bash decommission.sh
```

The tool shows all commissioned nodes on this server, lets you select one, confirms
the estimated unlock date, and prints the wallet command:

```
request_stake_unlock <your-node-pubkey>
```

Submit this command from your XEQM wallet to begin the unlock period.

> **Do not deregister a node just to move it to new hardware.** Use
> [server-migrate.sh](#10-moving-a-node-to-another-server) instead — it carries the
> key and state across with no lock period and no gap in rewards.

---

## 12. Firewall Configuration

### Automatic configuration (recommended)

When you run the installer, it asks how your firewall is managed and opens the correct
ports automatically. For most VPS providers, selecting **UFW** is sufficient.

---

### Manual configuration (OPNsense, pfSense, or hardware firewalls)

Choose **External firewall** during install and the installer will print the exact ports
to open. For reference:

**For each service node**, allow **inbound** on:

| Service | Port | Protocol | Notes |
|---|---|---|---|
| P2P | 9230 | TCP | Required — peer discovery |
| Quorumnet | 9232 | TCP + UDP | Required — service node consensus |

For a second node on the same server, add 100 to each port (9330/9332).
For a third node, add 200 (9430/9432), and so on.

> **Do not open port 9231 (RPC) publicly.** This port is for internal use only.

---

### Oracle Cloud (OCI)

OCI has two independent firewall layers. The installer's **Oracle Cloud** option handles
the VM-level iptables REJECT removal, but you must also open ports in the **VCN Security
List** in the OCI Console:

OCI Console → Networking → Virtual Cloud Networks → your VCN → Security Lists → Add ingress rules for each port.

---

### After changing firewall rules

After opening ports, run the Health Check — the **FW** column confirms each node's
required ports are open. A node that is unreachable on its P2P and Quorumnet ports
will not earn rewards and may be deregistered.

---

## 13. Quiet Mode (Unattended Installs)

If you want to install without answering any questions, use `--quiet` combined with
all required options.

### Example: fully unattended install

```bash
sudo bash install.sh \
  --quiet \
  --nodes 1 \
  --copy-blockchain bootstrap \
  --open-firewall
```

### Example: unattended multi-node install

```bash
sudo bash install.sh \
  --quiet \
  --nodes 2 \
  --copy-blockchain no,auto \
  --open-firewall
```

### Example: unattended upgrade

```bash
sudo bash upgrade.sh
```

### Example: unattended install with dashboard agent

```bash
sudo bash install.sh \
  --quiet \
  --nodes 1 \
  --copy-blockchain bootstrap \
  --open-firewall \
  --agent-url https://dashboard.example.com \
  --agent-token YOUR_TOKEN_HERE
```

> **Quiet mode defaults:** When `--copy-blockchain` is not specified in quiet mode,
> the installer uses `bootstrap` automatically.

---

## 14. Quick Reference Card

### Menu

```bash
sudo bash xeqm-manager.sh
```

### Installation

| Goal | Command |
|---|---|
| Open the menu | `sudo bash xeqm-manager.sh` |
| Install (interactive) | `sudo bash install.sh` |
| Install 1 node, bootstrap, open firewall | `sudo bash install.sh --nodes 1 --copy-blockchain bootstrap --open-firewall` |
| Install 3 nodes | `sudo bash install.sh --nodes 3` |
| Upgrade all nodes | `sudo bash upgrade.sh` |
| Upgrade to specific version | `sudo bash upgrade.sh --version v1.0.7` |

### Node Management (replace `snode1` with your node name)

| Goal | Command |
|---|---|
| Check status | `sudo systemctl status xeqmnode_snode1` |
| View live logs | `sudo journalctl -u xeqmnode_snode1 -f` |
| Start node | `sudo systemctl start xeqmnode_snode1` |
| Stop node | `sudo systemctl stop xeqmnode_snode1` |
| Start all nodes | `sudo systemctl start 'xeqmnode_snode*'` |
| Stop all nodes | `sudo systemctl stop 'xeqmnode_snode*'` |

### Registration & Keys

| Goal | Command |
|---|---|
| Generate registration commands | `sudo bash register.sh` |
| List all node keys | `sudo find /var/lib/xeqm -name 'key_ed25519'` |
| View a node's key | `sudo cat /var/lib/xeqm/snode1/key_ed25519` |

### Health & Repair

| Goal | Command |
|---|---|
| Check all nodes | `sudo bash doctor.sh` |

### Moving & Unlocking

| Goal | Command |
|---|---|
| Move a node from another server | `sudo bash server-migrate.sh` |
| Begin 14-day stake unlock | `sudo bash decommission.sh` |
| Permanently remove all nodes | `sudo bash wipe.sh` |

---

## 15. Troubleshooting

### "My node shows height 0 or isn't syncing"

The daemon may still be starting up. Wait 30–60 seconds, then check the logs:

```bash
sudo journalctl -u xeqmnode_snode1 -f
```

Look for error messages near the bottom. If no peers are listed, ensure the P2P port
(9230) is open in your firewall.

---

### "My node is stuck and won't sync past a certain block"

Run the Health Check:

```bash
sudo bash doctor.sh
```

If it shows `stuck`, the doctor will offer to restart the node and, if that fails,
replace the blockchain data with a fresh bootstrap automatically.

---

### "The node service won't start"

Check the service status for an error message:

```bash
sudo systemctl status xeqmnode_snode1
sudo journalctl -u xeqmnode_snode1 --no-pager | tail -30
```

If the service is missing entirely, re-run the installer — it is safe to run on a
server that already has nodes installed.

---

### "I get 'Permission denied' when running commands"

All installer scripts must be run with `sudo`. Make sure you are on your main user
account and prefixing commands with `sudo bash`.

---

### "My node won't earn rewards / keeps getting deregistered"

The most common cause is a firewall blocking the Quorumnet port. Run the Health Check
and check the **FW** column — it will show exactly which ports are missing.

Quorumnet requires **both TCP and UDP** on port 9232 (and the equivalent port for each
additional node). Opening TCP only is a common mistake.

---

### "I'm running out of disk space"

Check disk usage:

```bash
df -h /var/lib/xeqm
```

Check how much space each node's blockchain is using:

```bash
sudo du -sh /var/lib/xeqm/snode*
```

The Health Check will warn when free space is running low.

---

### "My server's clock is wrong and I'm seeing sync warnings"

```bash
sudo timedatectl set-ntp true
sudo systemctl restart systemd-timesyncd
sudo timedatectl
```

The output should show `NTP synchronized: yes`.

---

### "I need help"

If you're stuck, please reach out in the XEQM Labs community channels. When asking for
help, run the Health Check and share the output — it gives helpers the information they
need quickly:

```bash
sudo bash doctor.sh 2>&1 | tee doctor-output.txt
cat doctor-output.txt
```
