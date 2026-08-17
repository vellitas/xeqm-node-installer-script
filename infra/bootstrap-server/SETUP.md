# Bootstrap Server Setup

The bootstrap server provides an hourly-updated chain snapshot that the installer downloads instead of syncing from peers. This reduces post-install sync time from 40+ minutes to under 2 minutes.

## Current host

**pn-2** (217.77.5.231) — serves `bootstrap.xeqmlabs.com` via nginx behind Cloudflare.

The generator sources chain data from the co-located pubnode daemon at `127.0.0.1:9231`.

## Tarball contents

| File | Purpose |
|---|---|
| `lmdb/` | Raw blockchain (LMDB) — consistent snapshot via `xeqm-mdb_copy -c` |
| `sqlite.db` | Service node list + ONS state — eliminates post-bootstrap rescan |
| `p2pstate.bin` | Peer address cache — gives new nodes immediate peers |

## Prerequisites

```bash
# nginx
sudo apt-get install -y nginx

# sqlite3 >= 3.27.0 (for VACUUM INTO — clean WAL-merged snapshot)
sudo apt-get install -y sqlite3

# xeqm-mdb_copy — ships with xeqm-core; copy from any synced node
sudo cp /opt/xeqm/bin/xeqm-mdb_copy /usr/local/bin/xeqm-mdb_copy
sudo chmod 755 /usr/local/bin/xeqm-mdb_copy
```

## Directory setup

```bash
sudo mkdir -p /var/www/bootstrap
sudo cp infra/bootstrap-server/index.html /var/www/bootstrap/index.html
# index.html stats (height, size, sha256, timestamp) are updated in-place each run
```

## Install the generator script

```bash
sudo cp infra/bootstrap-server/xeqm-bootstrap-sync.sh /usr/local/bin/xeqm-bootstrap-sync.sh
sudo chmod 755 /usr/local/bin/xeqm-bootstrap-sync.sh
```

## Cron

```bash
sudo tee /etc/cron.d/xeqm-bootstrap > /dev/null << 'EOF'
# Generate xeqm chain bootstrap tarball every hour
0 * * * * root /usr/local/bin/xeqm-bootstrap-sync.sh >> /var/log/xeqm-bootstrap-sync.log 2>&1
EOF
```

## nginx

```bash
sudo cp infra/bootstrap-server/nginx-bootstrap.conf \
     /etc/nginx/sites-available/bootstrap.xeqmlabs.com
sudo ln -s /etc/nginx/sites-available/bootstrap.xeqmlabs.com \
           /etc/nginx/sites-enabled/
```

### TLS — Cloudflare origin certificates

The config uses Cloudflare origin pull verification so direct connections (bypassing Cloudflare) are rejected.

1. **Origin certificate** (`/etc/nginx/certs/origin.pem` + `origin.key`):
   Cloudflare Dashboard → SSL/TLS → Origin Server → Create Certificate.
   Save the cert and key to `/etc/nginx/certs/`.

2. **Origin pull CA** (`/etc/nginx/certs/cloudflare-origin-pull-ca.pem`):
   Download from `https://developers.cloudflare.com/ssl/static/authenticated_origin_pull_ca.pem`.

3. **Snippets** — create `/etc/nginx/snippets/cloudflare-auth-pull.conf`:
   ```nginx
   ssl_client_certificate /etc/nginx/certs/cloudflare-origin-pull-ca.pem;
   ssl_verify_client on;
   ```
   And `/etc/nginx/snippets/cloudflare-real-ip.conf` — Cloudflare publishes its IP
   ranges at `https://www.cloudflare.com/ips-v4`. Example:
   ```nginx
   set_real_ip_from 103.21.244.0/22;
   # ... (full list from cloudflare.com/ips-v4 and /ips-v6)
   real_ip_header CF-Connecting-IP;
   ```

4. Reload nginx:
   ```bash
   sudo nginx -t && sudo systemctl reload nginx
   ```

## DNS

Add a CNAME (or A) record in Cloudflare DNS for `bootstrap.xeqmlabs.com` pointing to the server IP. Enable **proxied** mode so the Cloudflare origin pull cert requirement is enforced.

## Run the first snapshot manually

```bash
sudo /usr/local/bin/xeqm-bootstrap-sync.sh
tail -f /var/log/xeqm-bootstrap-sync.log
```

A successful run ends with:
```
INFO  published height=XXXXXX size=XXXM sha256=...
```

If `VACUUM INTO` succeeds (look for `INFO  sqlite.db snapshot OK`), the bootstrap will include fully checkpointed ONS state and new installs will not need to rescan from block 6.

If you see `WARN  VACUUM INTO failed` check that `sqlite3 --version` returns 3.27.0 or higher.

## Monitoring

Check the last run:
```bash
tail -20 /var/log/xeqm-bootstrap-sync.log
```

Check the published manifest:
```bash
curl -s https://bootstrap.xeqmlabs.com/manifest.json | python3 -m json.tool
```

## Moving to a new host

1. Provision the new host with the prerequisites above.
2. Ensure a fully-synced xeqm pubnode or snode daemon is running and its RPC responds on `127.0.0.1:9231`.
3. Copy `xeqm-mdb_copy` from the node binary directory.
4. Follow this guide from **Directory setup** onward.
5. Update the `LMDB_PATH` and `DATA_DIR` variables in the script if the daemon's data directory differs from `/opt/xeqm/data/`.
6. Update DNS to point `bootstrap.xeqmlabs.com` at the new host.
