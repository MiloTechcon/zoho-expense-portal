# Engineer Deployment Guide

> **Audience:** Experienced ops / devops engineer who needs to know what the app actually is, how it's wired, and how to keep it healthy in production.
> **Companion document:** `docs/ONSITE_DEPLOYMENT.md` — step-by-step playbook for the actual install. This document is the reference manual you turn to when something needs investigation, tuning, or recovery.

---

## 1. Architecture

### 1.1 Components

```
┌────────────────────────────────────────────────────────────────────┐
│                       customer's host                              │
│                                                                    │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────────┐  │
│  │  web (8000)  │  │   worker     │  │ db (postgres-16-alpine)  │  │
│  │  uvicorn +   │  │  asyncio     │  │  pgdata volume           │  │
│  │  fastapi     │  │  tick loop   │  │                          │  │
│  └──────┬───────┘  └──────┬───────┘  └─────────┬────────────────┘  │
│         │                 │                    │                   │
│         │ http://         │                    │ pg://             │
│         │ host.docker     │                    │                   │
│         │ .internal:11434 │                    │                   │
│         ▼                 ▼                    │                   │
│  ┌──────────────────────────────┐              │                   │
│  │  Ollama (host install)        │              │                   │
│  │  qwen3-vl:8b vision model    │              │                   │
│  └──────────────────────────────┘              │                   │
│                                                │                   │
└────────────────────────────────────────────────┼───────────────────┘
                                                 │
              ┌──────────────────────────────────┼──────────────────┐
              │ optional                        │                  │
              │ cloudflared (tunnel container)  │                  │
              └────────────┬─────────────────────┼──────────────────┘
                           │                     │
              outbound HTTPS                outbound HTTPS
                           │                     │
                           ▼                     ▼
                   ┌──────────────┐    ┌────────────────────────┐
                   │ Cloudflare   │    │ Zoho Books API         │
                   │ Tunnel       │    │ www.zohoapis.com/books/│
                   └──────────────┘    │ accounts.zoho.com      │
                                       └────────────────────────┘
```

### 1.2 Request flow — Receipt upload

1. Operator opens `/upload`, selects file, chooses tab (`receipt` / `dn` / `vendor_invoice`), POSTs `/receipts/upload` with `multipart/form-data` and `doc_type=<tab>`
2. Web computes SHA-256, inserts a `Receipt` row + a corresponding pipeline row (`Expense`, `DeliveryNote`, or `VendorInvoice`) in status `pending`
3. Worker tick (every 5s) picks up pending rows in that pipeline, sets status `processing`
4. Worker reads the file bytes, downscales the image to 1280px long edge, base64-encodes, POSTs to Ollama `/api/generate` with the relevant prompt
5. Ollama returns JSON; worker validates fields, matches against Zoho (PO lookup for vendor invoice, invoice lookup for DN, ref-number lookup for expense dedup)
6. Worker calls Zoho Books API endpoints (`POST /expenses`, `POST /invoices/{id}/attachment`, `POST /bills`) over HTTPS
7. Worker writes status `completed` / `failed` / `review_required` / `billed` to the pipeline row
8. Browser polls `/history` every 10s; renders the updated row

### 1.3 What stays inside the customer's network

- Receipt images, after upload, live as `bytea` in the `pgdata` Postgres volume
- OCR happens entirely on the customer's host (Ollama)
- The only outbound traffic is to `*.zoho.com` and `*.zohoapis.com` (Zoho Books API + OAuth) and `ghcr.io` (image pull)

---

## 2. System requirements

| Resource | Minimum | Recommended | Notes |
|---|---|---|---|
| CPU | 4 cores | 8 cores | Ollama vision OCR is CPU-bound without a GPU |
| RAM | 8 GB | 16 GB | qwen3-vl:8b uses ~6-8 GB; Postgres + web + worker add another 1-2 GB |
| Disk | 20 GB free | 50 GB free | Receipt blobs in Postgres grow ~50-200 KB per scan; 1000 scans/month = ~100 MB/year per customer |
| GPU | None | NVIDIA with current driver | Ollama auto-uses CUDA when available. Cuts OCR from 1-2 min to 5-15s per image |
| Network | 100 Mbit | 1 Gbit | Image pull is one-time (~500 MB); Zoho calls are small |

### 2.1 Ollama performance bands

| Hardware | Time per image (qwen3-vl:8b) | Acceptable for batch? |
|---|---|---|
| RTX 3060 12 GB | 5-10 s | Yes — auto-scan ingest happily keeps up |
| Apple Silicon M2 | 15-25 s | Yes |
| CPU-only, modern Xeon / Ryzen 7+ | 60-120 s | Yes for small daily volume; queue builds up under burst |
| CPU-only, older or low-power | 3-5 min | Marginal — recommend off-hours batching |

If the customer's hardware is in the "marginal" band, drop `OLLAMA_MODEL` to `qwen2.5vl:7b` and accept slightly lower OCR accuracy. Edit `.env` and `bash install.sh --update`.

---

## 3. Deployment topologies

### 3.1 Single-host (default, recommended)

Everything on one box. Postgres, web, worker, Ollama all share the same machine. The `docker-compose.yml` we ship is configured for this.

Use when: <10 active users, <10k receipts/month, small office.

### 3.2 Web on app server, DB on a separate Postgres instance

If the customer already runs a managed Postgres or wants to keep data on a dedicated DB host:

1. In `.env`, set `DATABASE_URL=postgresql://<user>:<pass>@<db-host>:5432/expenses`
2. Comment out the `db` service in `docker-compose.yml`
3. Run migrations manually once — the worker container does this automatically on first boot; if the external DB is fresh, the first boot will populate it

Use when: shared DBA team manages Postgres, or customer wants point-in-time recovery on the DB only.

### 3.3 Reverse proxy in front (Caddy / Nginx / Traefik)

The container binds to `8000`. For real-world traffic, put a TLS-terminating proxy in front. Example Caddyfile:

```caddy
expense.customer.example {
    reverse_proxy localhost:8000
}
```

Caddy auto-issues a Let's Encrypt cert. Update `docker-compose.yml` to bind on `127.0.0.1:8000` only so the app isn't directly reachable.

### 3.4 Cloudflare Tunnel (no public IP needed)

The compose has a `cloudflared` service under the `cloudflare` profile:

```bash
echo "CLOUDFLARE_TUNNEL_TOKEN=<from cloudflare zero trust>" >> .env
docker compose --profile cloudflare up -d
```

Set the tunnel's public hostname to forward to `http://web:8000` in the Cloudflare dashboard. Customer accesses the portal via the Cloudflare hostname over HTTPS without exposing any port on their network.

Use when: customer has no static IP / no port-forwarding capability.

### 3.5 Multi-tenant on one box (NOT supported by EULA)

The EULA forbids running the Image as a multi-tenant service. One deployment = one Zoho org = one set of users. Don't try to share an Image between two Zoho orgs by toggling env vars.

---

## 4. Networking

### 4.1 Ports

| Port | Service | Who needs to reach it |
|---|---|---|
| `8000/tcp` | web | Operators on the LAN (or reverse proxy) |
| `11434/tcp` | Ollama on host | Containers via `host.docker.internal` (no external access) |
| `5432/tcp` | Postgres | Only the worker + web containers — don't expose externally |

### 4.2 `host.docker.internal` mechanics

The compose file sets `extra_hosts: ["host.docker.internal:host-gateway"]` so the worker can reach Ollama on the host without hardcoding the host's IP. This works on Linux Docker 20.10+, Docker Desktop, and Windows / macOS.

If Ollama is on a different host (e.g. customer has a dedicated GPU box), set `OLLAMA_HOST=<gpu-host-ip>:11434` in `.env` and ensure the GPU host's firewall allows the app server's IP on port 11434.

### 4.3 Firewall rules

Outbound (must be allowed):
- `ghcr.io:443` — image pull (one-time per update)
- `*.zoho.com:443` and `*.zohoapis.com:443` — OAuth + API
- (If using Cloudflare tunnel) `*.cloudflare.com:443`

Inbound (only what the customer needs):
- `8000/tcp` from operator devices, optionally via reverse proxy on 443

### 4.4 TLS

The portal serves plain HTTP on 8000. **Do not expose port 8000 directly to the public internet.** Either:

- Put it behind a reverse proxy with a real cert
- Use Cloudflare Tunnel (TLS terminates at Cloudflare, encrypted to your cloudflared container over Cloudflare's network)
- Keep it LAN-only

The license check, JWT auth, and Zoho integration all assume the channel is private. If you must expose without a proxy, at minimum set `JWT_SECRET` to a strong 48-byte random value and use IP allowlisting.

---

## 5. Storage

### 5.1 What lives where

| Data | Location | Size profile |
|---|---|---|
| Receipt + DN + VI image blobs | Postgres `receipts` table, `file_data` column (bytea) | ~50-200 KB per scan |
| Expense / DN / VendorInvoice rows | Postgres tables of the same name | ~1 KB each |
| User accounts + JWT-issued tokens (in-memory only) | `users` table | ~200 bytes per user |
| Application logs | stdout, captured by Docker → `journald` or Docker's JSON file driver | ~10-50 MB / day |

### 5.2 `pgdata` volume

The `db` service uses a named Docker volume `pgdata`. To inspect:

```bash
docker volume inspect <project>_pgdata
# Mountpoint is typically /var/lib/docker/volumes/<project>_pgdata/_data
```

Receipt-blob growth dominates volume size. Estimate: `(scans per month) × (~150 KB) × (12 months)` per year.

### 5.3 Expected DB size after 1 year of moderate use

| Receipts / month | After 12 months | After 24 months |
|---|---|---|
| 100 | ~180 MB | ~360 MB |
| 1000 | ~1.8 GB | ~3.6 GB |
| 5000 | ~9 GB | ~18 GB |

### 5.4 Pruning old receipts (optional)

The app does not auto-delete old receipts. If a customer wants to prune, two patterns:

**Soft prune (keep DB rows, drop blobs):**

```sql
UPDATE receipts
SET file_data = NULL, content_type = 'application/octet-stream'
WHERE created_at < NOW() - INTERVAL '3 years';
```

**Hard prune (delete row + cascade):** the `delete_expense` endpoint already cascades — operators can manually clean from `/history`. Don't write a cron job that deletes en masse without the customer's signoff.

---

## 6. Backups

### 6.1 What to back up

**Required:** the `pgdata` volume (contains everything — users, expenses, receipt blobs).

**Don't bother backing up:** the Docker image (re-pullable from GHCR), the `.env` file (you'd re-issue licence + PAT anyway).

### 6.2 Backup command

```bash
docker compose exec -T db pg_dump -U postgres expenses | gzip > backup-$(date +%Y%m%d-%H%M).sql.gz
```

A daily cron entry (Linux):

```cron
0 2 * * *  cd /opt/zoho-expense-portal && docker compose exec -T db pg_dump -U postgres expenses | gzip > /backups/db-$(date +\%Y\%m\%d).sql.gz
0 3 * * 0  find /backups -name 'db-*.sql.gz' -mtime +30 -delete
```

### 6.3 Restore

```bash
gunzip -c backup-20260520-0200.sql.gz | docker compose exec -T db psql -U postgres expenses
```

If restoring into a fresh deployment:
1. Bring up the stack with `bash install.sh`
2. Wait for healthy
3. `docker compose exec db psql -U postgres -c "DROP DATABASE expenses;"` (destructive, only when re-installing!)
4. `docker compose exec db psql -U postgres -c "CREATE DATABASE expenses;"`
5. Run the restore command above
6. `docker compose restart web worker`

### 6.4 Offsite

The customer is responsible for getting `/backups/` offsite (e.g. rsync to a NAS, sync to S3 with `restic`, etc.). Recommend at least one offsite copy.

---

## 7. Observability

### 7.1 Health endpoint

```bash
curl -s http://localhost:8000/health
# {"status":"ok"}
```

Use this in monitoring (Uptime Kuma, Pingdom, Cloudflare healthchecks, etc.).

### 7.2 License status

Logged once at boot for both web and worker:

```bash
docker compose logs --since 1h web | grep '\[license\]'
# [license] valid for 'Customer Co Ltd', exp=1810771200
```

Track licence expiry: `exp` is a Unix timestamp.

### 7.3 Worker tick

The worker prints per-tick if any pipeline had work:

```
Processed 3 expense(s), 1 scan(s) ingested
Processed 1 delivery note(s)
Processed 2 vendor invoice(s)
```

A silent worker is healthy when there's nothing to do; only worry if the customer reports an upload but the worker log shows nothing related to it.

### 7.4 Useful Postgres queries

Connect:

```bash
docker compose exec db psql -U postgres expenses
```

Count by status:

```sql
SELECT status, COUNT(*) FROM expenses GROUP BY status;
SELECT status, COUNT(*) FROM delivery_notes GROUP BY status;
SELECT status, COUNT(*) FROM vendor_invoices GROUP BY status;
```

Oldest pending:

```sql
SELECT id, created_at, status FROM expenses
WHERE status IN ('pending','processing')
ORDER BY created_at LIMIT 10;
```

Total receipt blob size:

```sql
SELECT pg_size_pretty(SUM(LENGTH(file_data))::bigint) AS total
FROM receipts;
```

### 7.5 Logs to keep an eye on

| Pattern | What it means |
|---|---|
| `[license] FATAL` | Licence rejected at boot — container will keep restarting until fixed |
| `Failed to extract data from receipt` | OCR returned unparseable output; row goes to `failed` |
| `parse_llm_response: empty response from model` | Ollama returned empty; check Ollama health |
| `Zoho ... -> 4xx` | Customer's Zoho creds are wrong, scope insufficient, or rate-limited |
| `Zoho POST /bills -> 400: {'code': 1048` | Bill payload malformed — usually a vendor-invoice flow issue, not customer-facing |

---

## 8. Performance tuning

### 8.1 Ollama knobs

In `worker/ollama_client.py` (compiled — only change via app release):

| Setting | Default | When to tune |
|---|---|---|
| `num_ctx` | 8192 | If OOM on a low-RAM host, drop to 6144. Be aware truncation kicks in. |
| `num_predict` | 1024 | Truncated JSON output on multi-page → bump to 2048. |
| `format: "json"` | enabled | Don't disable; structured-output gating is load-bearing. |
| `think: false` | disabled-thinking | Don't enable; qwen3-vl thinking mode consumes the entire output budget. |
| Image long-edge downscale | 1280 px | Drop to 1024 on weak GPUs / low RAM; bump to 1600 if reading tiny printed numbers fails consistently. |

### 8.2 Worker tick rate

`WORKER_POLL_INTERVAL` defaults to 5 seconds. Set via env if you want faster cycling (lower latency) or slower (less CPU). Don't go below 1 second.

### 8.3 Scan ingest

| Setting | Default | When to tune |
|---|---|---|
| `SCAN_STABILITY_SECONDS` | 3 | Increase if the scanner writes files slowly (the worker waits N seconds of no size change before reading). |
| `SCAN_MAX_PER_TICK` | 10 | Increase if there's a large historical backlog to drain. Be aware of Ollama concurrency limits (default 1 model instance). |

---

## 9. Security

### 9.1 Trust boundaries

| Boundary | What crosses it | Threats |
|---|---|---|
| Operator browser ↔ web | JWT in Authorization header | Token theft (LAN sniffing) — use TLS via reverse proxy |
| web ↔ worker (none direct) | Postgres only | None — they don't talk directly |
| web ↔ Postgres | DB credentials in env | Bind Postgres to compose network only; never publish port externally |
| web/worker ↔ Ollama | Local network call | Trust the host; Ollama has no auth |
| worker ↔ Zoho Books | OAuth refresh token in env | Treat refresh token like a password |
| Image at rest in GHCR | Tag + manifest | PAT-gated; revoke PATs on customer offboarding |
| Licence key in `.env` | RSA-signed JWT | Validate signature; expiry enforced by boot check |

### 9.2 Secrets in `.env`

The install script writes `.env` with `chmod 600`. The Postgres password (`postgres`) is the default and shared inside the compose network — that's fine because the port isn't exposed. The customer-visible secrets are:

- `LICENSE_KEY` — public-by-design (it's the licence we issued; only useful with the matching deployment)
- `JWT_SECRET` — privacy of operator sessions depends on this. Rotate by editing `.env` and `bash install.sh --update`; all logged-in users will need to log in again.
- `ZOHO_REFRESH_TOKEN` — full read/write to the customer's Zoho Books org. Rotate via Zoho's API console if leaked.
- `GHCR_PAT` — read-only access to pull images. Revokable in GitHub's developer settings.

### 9.3 No source code on disk

Verify after deploy:

```bash
docker compose exec web sh -c "find /app/app /app/worker -name '*.py'"
# should print only run_web.py / run_worker.py — never any other .py
```

If the customer sees source files in `/app/app` or `/app/worker`, that's a release-pipeline bug — report it to Techcon. The compiled image is verified to be source-free at CI time.

### 9.4 License expiry behaviour

A container with an expired licence cannot start. The healthcheck-aware restart policy means it tries forever. To avoid waking up to a dead deployment: mint the renewal at least 30 days before expiry and have the customer apply it before the old one expires.

---

## 10. Updates and rollback

### 10.1 Standard update

```bash
# Edit .env: APP_VERSION_TAG=v1.5
bash install.sh --update
```

The script: docker compose pull → docker compose up -d → /health wait. Idempotent migrations in `app/database.py::run_migrations()` run automatically on container start.

### 10.2 Rollback

```bash
# Edit .env: APP_VERSION_TAG=v1.4 (or whichever earlier tag)
bash install.sh --update
```

Postgres state survives. Caveat: a forward migration cannot be reverted by re-running an old image — old code doesn't know how to handle new columns. In practice our migrations are additive (`ADD COLUMN IF NOT EXISTS`), so old code ignores new columns and continues to work. If we ever ship a destructive migration, we'll flag it explicitly in the release notes.

### 10.3 Blue-green

Out of scope for the SaaS image. The compose model doesn't support it natively. If you need zero-downtime, sit a reverse proxy in front of two side-by-side compose stacks on different ports and flip the upstream.

---

## 11. Disaster recovery

### 11.1 Lost license key

You issued the customer a licence, but their `.env` is gone (host wiped, etc.):
1. Re-mint from Techcon's stored private key with the SAME expiry date as the original
2. The customer pastes it into a freshly populated `.env`
3. `bash install.sh --update`

### 11.2 Lost private key (Techcon-side disaster)

If Techcon's `private.pem` is unrecoverably lost:
1. Generate a new keypair (`bash build/generate_keypair.sh`)
2. Paste the new public key into `app/license.py`
3. Tag a new release (`vX.Y.Z`)
4. Re-mint **every customer's** licence against the new private key
5. Email customers a new `LICENSE_KEY` + new `APP_VERSION_TAG`
6. Customer-side: edit `.env`, `bash install.sh --update`

This is operationally painful — keep the private key in two password managers + an offline copy.

### 11.3 Lost Postgres data

If the `pgdata` volume is gone and there's no backup:
1. All historical receipts are lost — there's no way to reconstruct them.
2. The customer's Zoho Books data is intact (it lives in Zoho, not us).
3. Bring up a fresh deployment, create users again, and resume operations.

### 11.4 GHCR outage

If GHCR is down at the moment a customer needs to pull a new tag, their existing deployment keeps running. Updates are deferred. Once GHCR is back, normal `docker compose pull` resumes.

### 11.5 Ollama corruption

If a model file gets corrupted on the host:
```bash
ollama rm qwen3-vl:8b
ollama pull qwen3-vl:8b
```

---

## 12. Multi-customer ops (Techcon-internal)

When supporting more than one customer:

### 12.1 Customer registry

Maintain a spreadsheet (or a small DB) with one row per customer:

| Field | Notes |
|---|---|
| Customer name | As on the EULA signature line |
| Licence subject (`sub`) | Should match customer name exactly |
| Licence expiry | Track + alert 30 days before |
| GHCR PAT name | Naming convention: `<customer>-<region>-<purpose>` |
| Image tag deployed | For tracking who's on which version |
| Host OS | For triage |
| Last update applied | Date of last `install.sh --update` |
| Support tier | From EULA / SOW |
| Primary contact | Email + phone |

Store offline (e.g. Notion private workspace, Airtable).

### 12.2 Licence rotation

Each year, ~30 days before expiry:
1. Mint the new licence: `python -m app.license_tools mint --private-key <path> --customer "X" --expires <date+1yr>`
2. Email customer: "Your renewal licence is attached. Please:
   - Update `LICENSE_KEY` in `.env` to the new value
   - Run `bash install.sh --update` at your convenience before <expiry-date>
   - Confirm by replying with the output of `docker compose logs web | grep license` showing `valid for X, exp=<new-timestamp>`"
3. Schedule a calendar reminder for 14 days before expiry to chase non-responders

### 12.3 Coordinated upgrades

When we publish a new image tag:
1. Bench-test on Techcon's own deployment first (Pilot Co or a dedicated staging customer)
2. Email customers: "Version X.Y is available. Changes: [release notes link]. Critical security? yes/no. To apply: edit `APP_VERSION_TAG=X.Y` in `.env` and `bash install.sh --update`."
3. Provide a 14-30 day window for non-critical updates; faster for security patches.

### 12.4 GHCR PAT lifecycle

PATs default to 30 days. **Set them to expire 30 days after the licence expires** so the customer can pull updates throughout their term. Rotate by reissuing a new PAT and revoking the old one.

---

## 13. Troubleshooting matrix

| Symptom | Likely cause | First action | If that fails |
|---|---|---|---|
| `docker compose pull` fails: "denied" | PAT expired or scoped wrong | Re-issue PAT, `docker login ghcr.io` again | Check the package exists at GHCR + visibility settings |
| `[license] FATAL: missing` | `LICENSE_KEY` not in `.env` or container not picking it up | `grep ^LICENSE_KEY= .env` and `docker compose config \| grep LICENSE_KEY` | Re-run `bash install.sh --update` |
| `[license] FATAL: signature invalid` | Public key in image doesn't match private key that signed the licence | Confirm image tag matches the one minted against | Reissue licence with current private key |
| `[license] FATAL: expired` | Customer past their term | Mint renewal, update `.env`, `install.sh --update` | — |
| Web boots but routes return 500 | Migration mismatch, Postgres unreachable, JWT secret rotated | `docker compose logs web --tail 50` | `docker compose restart web` |
| Worker silent on receipt upload | Worker container dead, or worker can't reach DB | `docker compose ps` and `docker compose logs worker --tail 50` | `docker compose restart worker` |
| OCR returns wrong amount (e.g. Octopus card balance) | Receipt class our prompt hasn't seen before | Note the receipt, fix in Zoho manually, send sample to Techcon for prompt tuning | — |
| OCR consistently failing for one customer | Ollama returning empty / OOM | Check `docker compose logs worker \| grep ollama:` for `meta=` details | Bump RAM, drop `num_ctx`, drop `OLLAMA_MODEL` to smaller variant |
| `Zoho POST /expenses -> 401` | Refresh token revoked / wrong | Walk through Zoho Self Client step again | Confirm `ZOHO_ORGANIZATION_ID` matches |
| `Zoho POST /bills -> 400 code 1048` | Vendor invoice payload malformed | Worker log shows the exact field; check the matched PO has `vendor_id` set | Open a bug to Techcon |
| Cloudflare tunnel container down | Token rotated, network issue | `docker compose logs cloudflared` | Re-issue tunnel token, update `.env` |
| `docker compose up -d` times out on healthcheck | Postgres not coming up | `docker compose logs db` — usually disk full or volume mount mis-permissioned | `docker compose down` then bring up fresh after fixing |
| Disk usage growing > expected | Receipt blobs accumulating | `SELECT pg_size_pretty(pg_database_size('expenses'));` and the per-receipt query in §7.4 | Negotiate pruning policy with customer |

---

## 14. Where to file what

- **Customer-reported bugs / feature requests** → Techcon's private repo issues, labelled with the customer name
- **Sample receipts that broke OCR** → email to Techcon engineering with the receipt image + the `parse_llm_response` log line; we'll patch the prompt in a follow-up release
- **Suspected security issue** → Techcon's security disclosure address; do NOT file as a public GitHub issue
- **Licence questions / renewals** → Techcon's accounts mailbox
- **EULA disputes** → escalate to Techcon's authorised signatory

---

## 15. Appendix — file inventory

What lives where inside the running container:

| Path | What |
|---|---|
| `/app/app.cpython-*-linux-gnu.so` | Compiled `app` package (all of the FastAPI app) |
| `/app/worker.cpython-*-linux-gnu.so` | Compiled `worker` package |
| `/app/app/templates/*.html` | Jinja templates (verbatim) |
| `/app/app/static/*` | Static assets — logo, favicon, manifest |
| `/app/app/static/custom/` | Customer brand override (bind-mounted from `./logo-overrides`) |
| `/app/run_web.py` | uvicorn launcher (stays as `.py`) |
| `/app/run_worker.py` | Worker launcher (stays as `.py`) |
| `/opt/venv/` | Runtime virtualenv (FastAPI, SQLAlchemy, uvicorn, etc.) |
| `/scans/` | Bind-mount target for auto-scan ingest (only if `SCAN_HOST_DIR` set) |

---

*This document targets a customer's engineer or Techcon's own field engineer. For the operator-facing day-to-day, see the public `INSTALL.md`. For the install playbook, see `docs/ONSITE_DEPLOYMENT.md`.*
