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
6. [Migrating from Docker](#6-migrating-from-docker)
7. [Completing Setup — Staking Your Node](#7-completing-setup--staking-your-node)
8. [Daily Node Management](#8-daily-node-management)
9. [Upgrading Your Nodes](#9-upgrading-your-nodes)
10. [Health Checks and Auto-Repair](#10-health-checks-and-auto-repair)
11. [Moving a Node to Another Server](#11-moving-a-node-to-another-server)
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
| Operating System | Ubuntu 20.04 or 22.04 | Ubuntu 22.04 LTS |
| RAM | 2 GB | 4 GB |
| Disk Space | 50 GB free | 100 GB+ SSD |
| Network | Stable broadband | Dedicated connection |

> **Each additional node** on the same server needs roughly **800 MB more RAM** and
> **2 GB more disk space** for the software itself, plus additional space as the
> blockchain grows over time.

### Ports That Must Be Open

Your server's firewall (or router if you use one) must allow traffic on these ports
for **each node**:

| Port | Purpose |
|---|---|
| **9230** | Peer-to-peer — how your node finds others |
| **9232** | Quorumnet — service node consensus |

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
git clone https://github.com/vellitas/xeqm-node-installer-script.git

# Move into the folder
cd xeqm-node-installer-script
```

You only need to do this once. To get future updates:

```bash
cd ~/xeqm-node-installer-script && git pull
```

---

## 4. Installing Your First Node

### Step 1 — Run the installer

From inside the `xeqm-node-installer-script` folder, run:

```bash
sudo bash install.sh
```

The installer displays a welcome screen, then launches an **interactive wizard** — a
series of graphical dialog boxes where you navigate with the arrow keys and Tab, and
press Enter to confirm each choice. You can press **Back** on any screen to go back
and change a previous answer.

> **No wizard?** If whiptail is not available on your system, the same questions are
> asked as plain text prompts. The answers and defaults are identical.

---

### Step 2 — How many nodes?

A dialog asks how many service nodes to install on this server. Type a number or leave
blank to default to 1. The installer calculates the maximum your server can support
based on available RAM and disk space and shows it in the prompt.

For your first install, **leave blank and press Enter** to install 1 node.

---

### Step 3 — Shared password (multi-node installs)

A Yes/Skip dialog appears asking whether to set a shared password for all node accounts.

If you are installing more than one node, choosing **Yes** lets you type one password
in the terminal that is used for all node user accounts — so you are not prompted once
per node. Recommended for multi-node installs.

For a single-node install, choose **Skip**.

---

### Step 4 — Choose how to get the binaries

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

### Step 5 — Choose how to get the blockchain

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

### Step 6 — Public IP address

A dialog shows the auto-detected public IPv4 address of your server. Press Enter to
accept it. If your server is behind a load balancer or NAT and has a different public
IP, clear the field and type the correct address.

---

### Step 7 — Firewall

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
| **Oracle Cloud (OCI)** | Oracle Cloud free-tier or paid instances. OCI ships a raw iptables REJECT rule that silently blocks ports even when UFW allows them; this option fixes it automatically. |
| **External firewall** | Your server sits behind OPNsense, pfSense, or a cloud security group. The installer prints the exact ports to open rather than touching the server's firewall. |

**Select UFW** for most VPS providers. Select **Oracle Cloud** if you are on OCI.

---

### Step 8 — Review and confirm

The wizard auto-detects free ports and usernames, fetches the latest XEQM version, and
shows a scrollable summary of the full configuration. Review it, then advance to the
**Confirm Installation** dialog and select **Install** to begin.

---

### Step 9 — Wait for the installer to finish

The installer will:

1. Install required system packages
2. Download the XEQM software
3. Set up a dedicated user account for your node
4. Create a system service (so the node restarts automatically after reboots)
5. Start the node and download the blockchain

The blockchain download takes about 15 minutes with the bootstrap option.

---

## 5. Installing Multiple Nodes on One Server

You can run several nodes on one server as long as it has enough RAM and disk space.

### Install multiple nodes at once

```bash
sudo bash install.sh --nodes 5
```

### Install nodes with usernames you choose

```bash
sudo bash install.sh --nodes 3 --user snode1,snode2,snode3
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
| Node 1 | 9230 | 9231 | 9232 |
| Node 2 | 9330 | 9331 | 9332 |
| Node 3 | 9430 | 9431 | 9432 |

Open ports **9230 and 9232** (and the equivalent pair for each extra node) in your firewall.
The RPC port (9231) must stay closed to the internet.

---

## 6. Migrating from Docker

If your nodes are currently running in Docker containers, `migrate.sh` moves them to
native systemd services without losing your node identity or blockchain data.

**What it does:**
- Auto-detects all running XEQM Docker containers on this host
- Copies blockchain data and service node keys out of each container
- Creates a dedicated system user per node and installs a systemd service on the same ports
- Offers a dry-run mode so you can review the plan before anything changes
- Prints Docker cleanup commands once migration is complete

### Before you start

Optionally set up a shared password first to avoid being prompted once per node:

```bash
sudo bash install.sh --one-passwd-file
```

### Run the migration

Make sure your Docker containers are running, then:

```bash
sudo bash migrate.sh
```

The script walks you through everything interactively:

1. Lists all detected containers with their ports, blockchain height, and data locations
2. Lets you select which containers to migrate (all or a subset)
3. Offers a dry run to preview the migration plan
4. Prompts for the public IP of this server
5. Asks how to handle firewall rules
6. Migrates each selected node
7. Prints Docker cleanup commands at the end

After migration, each node runs as a systemd service and starts automatically on boot.
Proceed to [Section 7](#7-completing-setup--staking-your-node) if you need to re-register any nodes.

---

## 7. Completing Setup — Staking Your Node

Installation sets up the software, but your node is **not active on the network yet**.
You need to register it by staking XEQM from your wallet.

### Step 1 — Run the prepare command

Replace `snode1` with your node's username (shown at the end of installation):

```bash
sudo -H -u snode1 bash -c 'cd ~/xeqm-installer/ && bash xeqm-node.sh prepare_sn'
```

The script will ask you three questions:

**Solo or pool node?**
```
  [1] Solo node  — stake the full 200,000 XEQM yourself
  [2] Pool node  — stake a portion and open to contributors (minimum 100,000 XEQM)
```

- **Solo**: You provide all 200,000 XEQM. Rewards go entirely to you.
- **Pool**: You contribute 100,000–200,000 XEQM and other wallets can fill the rest.

**If pool — your contribution amount and operator fee**

You will be asked how much XEQM you are contributing (100,000–200,000) and what
percentage of rewards you keep as operator before splitting with contributors (0–10%).

**Your XEQM wallet address**

Paste in the wallet address you want rewards sent to.

---

### Step 2 — Submit the registration command

The script generates a registration command and displays it on screen. Copy it exactly
and submit it from your XEQM wallet to complete registration.

---

### Step 3 — Confirm your node is registered

After staking, wait a few minutes then check your node's status:

```bash
sudo -H -u snode1 bash -c 'cd ~/xeqm-installer/ && bash xeqm-node.sh print_sn_status'
```

When registration is confirmed you will see your node listed as active.

> **Important:** Your node must be fully synced with the network before staking.
> Run the `status` command to confirm the block height matches the network before proceeding.

---

## 8. Daily Node Management

All management commands follow this pattern — replace `snode1` with your node's username:

```bash
sudo -H -u snode1 bash -c 'cd ~/xeqm-installer/ && bash xeqm-node.sh COMMAND'
```

### Check if your node is running

```bash
sudo -H -u snode1 bash -c 'cd ~/xeqm-installer/ && bash xeqm-node.sh status'
```

You will see something like:

```
Height: 1234567/1234567 (100.0%) on mainnet, not mining, net hash ...
```

The number before the `/` is your node's current block. The number after is the
network's latest block. When they match (100%), your node is fully synced.

---

### Start your node

```bash
sudo -H -u snode1 bash -c 'cd ~/xeqm-installer/ && bash xeqm-node.sh start'
```

> Nodes start automatically when the server boots. You only need this command
> if you manually stopped the node or after a crash.

---

### Stop your node

```bash
sudo -H -u snode1 bash -c 'cd ~/xeqm-installer/ && bash xeqm-node.sh stop'
```

> **Warning:** Stopping a registered node means it won't earn rewards while stopped.
> If stopped for too long the network may deregister it.

---

### View live logs

```bash
sudo -H -u snode1 bash -c 'cd ~/xeqm-installer/ && bash xeqm-node.sh log'
```

This shows a live stream of what your node is doing. Press **Ctrl+C** to stop watching.

---

### Get your node's public key

Your public key is your node's unique identity on the network. You may need it for
staking pools or to verify your node is registered.

```bash
sudo -H -u snode1 bash -c 'cd ~/xeqm-installer/ && bash xeqm-node.sh print_sn_key'
```

---

### Check network registration status

```bash
sudo -H -u snode1 bash -c 'cd ~/xeqm-installer/ && bash xeqm-node.sh print_sn_status'
```

---

### Managing multiple nodes

If you have several nodes, repeat the command for each username:

```bash
sudo -H -u snode1 bash -c 'cd ~/xeqm-installer/ && bash xeqm-node.sh status'
sudo -H -u snode2 bash -c 'cd ~/xeqm-installer/ && bash xeqm-node.sh status'
```

Or use [doctor.sh](#10-health-checks-and-auto-repair) to check all nodes at once.

---

## 9. Upgrading Your Nodes

When a new XEQM version is released, run the upgrade script. It automatically
backs up your node keys before making any changes.

### Upgrade one node

```bash
bash upgrade.sh --user snode1
```

### Upgrade multiple nodes at once

```bash
bash upgrade.sh --user snode1,snode2,snode3
```

The first node downloads the new software. The rest copy from it,
so the process is much faster for node 2, 3, etc.

### Upgrade to a specific version

```bash
bash upgrade.sh --user snode1 --version v1.0.2
```

> **Before upgrading:** Check the XEQM community channels for any special upgrade
> instructions for the new version. Some releases require additional steps.

---

## 10. Health Checks and Auto-Repair

The `doctor.sh` script checks all your nodes at once and can fix common problems
automatically.

### Run a health check

```bash
bash doctor.sh
```

The doctor will check every active node on your server and report on:

| Check | What It Means |
|---|---|
| ✅ NTP synchronized | Your server clock is accurate (required for consensus) |
| ✅ Disk space | Enough space for the blockchain to grow |
| ✅ Service active | The node's system service is running |
| ✅ Public key readable | The node can identify itself on the network |
| ✅ Blockchain healthy | Your node's blockchain matches the network |

---

### What the results mean

**HEALTHY** — Your node is working correctly. Nothing to do.

**SYNCING** — Your node is downloading the blockchain. This is normal after a fresh
install or restart. Wait for it to reach 100%.

**CORRUPT / STUCK** — Your node's blockchain data is damaged or frozen. The doctor
will offer to fix it automatically.

---

### Auto-repair

If a problem is found, the doctor will offer to fix it:

```
Corrupt/stuck blockchains found. Auto-fix from healthy donor? [Y/N]:
```

**If you have another healthy node on the same server:** Type `Y` and press Enter.
The doctor copies the good blockchain to the broken node — takes a few minutes.

**If you have no other healthy nodes on this server:**

```
How would you like to fix the corrupt node(s)?

  [1] Download bootstrap from https://bootstrap.xeqmlabs.com  (~15 min)
  [2] Skip — I will fix manually later
```

Choose **1** to download a fresh blockchain automatically.

---

### Auto-fix without prompts

```bash
bash doctor.sh --auto-fix
```

---

### Remediation plan

When the doctor finds problems it can't fix automatically, it prints a
**Remediation Plan** — a numbered list of commands you can run yourself to resolve
each issue. Copy and paste them one at a time.

---

## 11. Moving a Node to Another Server

If you need to move a service node to a new server — for maintenance or to consolidate
servers — use `transfer.sh`.

> **Why does moving matter?** Your node has a unique key that identifies it on the
> network. Moving the key means the new server takes over as that node, keeping your
> stake and registration intact.

### See all your nodes and their keys

```bash
bash transfer.sh --list
```

---

### Step 1 — Export the key from the old server

Run this on your **old server**:

```bash
bash transfer.sh --export --user snode1
```

This creates a file like `xeqm-key-snode1-20260513120000.tar.gz` in your current
folder. This file **is your node's identity** — keep it safe.

> **Warning:** Anyone with this file can take over your service node. Do not share it
> or store it in a public location.

---

### Step 2 — Copy the file to the new server

One common way (run from your local computer):

```bash
scp xeqm-key-snode1-20260513120000.tar.gz youruser@new-server-ip:/home/youruser/
```

---

### Step 3 — Install a fresh node on the new server

On the **new server**, run the installer as normal (see [Section 4](#4-installing-your-first-node)).
The new node will get a fresh key — you will replace it in the next step.

---

### Step 4 — Import the key on the new server

```bash
bash transfer.sh --import --user snode1 --key-file xeqm-key-snode1-20260513120000.tar.gz
```

The script will stop the node, install your original key, and restart the node.
Your node is now running on the new server with its original identity.

---

### Moving a key between users on the same server

```bash
bash transfer.sh --transfer --from snode1 --to snode2
```

---

## 12. Firewall Configuration

### Automatic configuration (recommended)

When you run `sudo bash install.sh`, the installer asks how your firewall is managed:

```
How is the firewall managed on this server?

  [1] UFW  — configure automatically  (recommended for most VPS)
  [2] iptables  — configure automatically
  [3] OPNsense, pfSense, or other external firewall  — show required ports
  [4] No firewall / I will handle it manually
```

Choosing **1** or **2** configures the firewall for you automatically.

---

### Manual configuration (OPNsense, pfSense, or hardware firewalls)

Choose option **3** during install and the installer will print the exact ports to open.
For reference:

**For each service node**, allow **inbound TCP** on:

| Service | Port | Notes |
|---|---|---|
| P2P | 9230 | Required — peer discovery |
| Quorumnet | 9232 | Required — service node consensus |

For a second node on the same server, add 100 to each port (9330, 9332).
For a third node, add 200 (9430, 9432), and so on.

> **Do not open port 9231 (RPC) publicly.** This port is for internal use only
> and should remain closed to the internet.

---

### After changing firewall rules

After opening ports, verify your node is reachable using an online port checker or
by asking in the XEQM community. A node that is not reachable on its P2P and Quorumnet
ports will not earn rewards and may be deregistered.

---

## 13. Quiet Mode (Unattended Installs)

If you want to install without answering any questions, use `--quiet` combined with
all required options.

### Example: fully unattended install

```bash
sudo bash install.sh \
  --quiet \
  --nodes 1 \
  --user snode1 \
  --copy-blockchain bootstrap \
  --open-firewall
```

### Example: unattended multi-node install

```bash
sudo bash install.sh \
  --quiet \
  --nodes 2 \
  --user snode1,snode2 \
  --copy-blockchain no,auto \
  --open-firewall
```

### Example: unattended upgrade

```bash
bash upgrade.sh --user snode1,snode2
```

> **Quiet mode defaults:** When `--copy-blockchain` is not specified in quiet mode,
> the installer uses `bootstrap` automatically.

---

## 14. Quick Reference Card

### Installation

| Goal | Command |
|---|---|
| Install one node | `sudo bash install.sh` |
| Install with bootstrap | `sudo bash install.sh --copy-blockchain bootstrap` |
| Install 3 nodes | `sudo bash install.sh --nodes 3` |
| Preview settings before install | `sudo bash install.sh --inspect-auto-magic` |
| Set a shared password for all node users | `sudo bash install.sh --one-passwd-file` |
| Migrate Docker nodes to systemd | `sudo bash migrate.sh` |
| Push script updates to all nodes | `sudo bash xeqm-node.sh sync_scripts` |

### Node Management (replace `snode1` with your username)

| Goal | Command |
|---|---|
| Check sync status | `sudo -H -u snode1 bash -c 'cd ~/xeqm-installer/ && bash xeqm-node.sh status'` |
| Start node | `sudo -H -u snode1 bash -c 'cd ~/xeqm-installer/ && bash xeqm-node.sh start'` |
| Stop node | `sudo -H -u snode1 bash -c 'cd ~/xeqm-installer/ && bash xeqm-node.sh stop'` |
| View live logs | `sudo -H -u snode1 bash -c 'cd ~/xeqm-installer/ && bash xeqm-node.sh log'` |
| Stake / register node | `sudo -H -u snode1 bash -c 'cd ~/xeqm-installer/ && bash xeqm-node.sh prepare_sn'` |
| Show public key | `sudo -H -u snode1 bash -c 'cd ~/xeqm-installer/ && bash xeqm-node.sh print_sn_key'` |
| Check registration status | `sudo -H -u snode1 bash -c 'cd ~/xeqm-installer/ && bash xeqm-node.sh print_sn_status'` |

### Health & Repair

| Goal | Command |
|---|---|
| Check all nodes | `bash doctor.sh` |
| Check and auto-fix without prompts | `bash doctor.sh --auto-fix` |

### Upgrade

| Goal | Command |
|---|---|
| Upgrade one node | `bash upgrade.sh --user snode1` |
| Upgrade multiple nodes | `bash upgrade.sh --user snode1,snode2` |

### Key Transfer

| Goal | Command |
|---|---|
| List all nodes and keys | `bash transfer.sh --list` |
| Export a node key | `bash transfer.sh --export --user snode1` |
| Import a node key | `bash transfer.sh --import --user snode1 --key-file xeqm-key-snode1-*.tar.gz` |
| Move key between users (same server) | `bash transfer.sh --transfer --from snode1 --to snode2` |

---

## 15. Troubleshooting

### "My node shows 0/0 for block height"

The daemon may still be starting up. Wait 30–60 seconds and try the status command again.
If it persists, check the logs:

```bash
sudo -H -u snode1 bash -c 'cd ~/xeqm-installer/ && bash xeqm-node.sh log'
```

Look for error messages near the bottom.

---

### "My node is stuck and won't sync past a certain block"

Run the doctor:

```bash
bash doctor.sh
```

If it reports CORRUPT/STUCK, choose the bootstrap option to download a fresh blockchain.

---

### "I get 'Permission denied' when running commands"

Make sure you are logged in as the same user who downloaded the scripts
(not as a node user like snode1). Run commands from your main user account using `sudo`.

---

### "I forgot which username my node runs under"

```bash
bash transfer.sh --list
```

This shows all active node usernames and their keys.

Alternatively:

```bash
sudo ps aux | grep xeqm-d
```

The first column shows the username for each running node process.

---

### "The node service won't start"

Check if the service exists:

```bash
sudo systemctl status xeqmnode_snode1.service
```

If it says "not found", re-run the service setup:

```bash
sudo -H -u snode1 bash -c 'cd ~/xeqm-installer/ && bash xeqm-node.sh setup_service'
sudo -H -u snode1 bash -c 'cd ~/xeqm-installer/ && bash xeqm-node.sh start'
```

---

### "I'm running out of disk space"

Check disk usage:

```bash
df -h /home
```

Check how much space the blockchain is using:

```bash
sudo du -sh /home/snode1/.xeqmlabs
```

If multiple nodes share the same server, each has its own copy of the blockchain.
The doctor will warn you when free space drops below 20 GB.

---

### "My server's clock is wrong and I'm seeing NTP warnings"

```bash
sudo timedatectl set-ntp true
sudo systemctl restart systemd-timesyncd
sudo timedatectl
```

The output should show `NTP synchronized: yes`.

---

### "I need help"

If you're stuck, please reach out in the XEQM Labs community channels.
When asking for help, run the doctor and share the output — it gives helpers
the information they need quickly:

```bash
bash doctor.sh 2>&1 | tee doctor-output.txt
cat doctor-output.txt
```
