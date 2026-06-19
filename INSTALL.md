# Installation Guide

This document walks through deploying the Zoho Expense Portal on your hardware. Plan ~30 minutes for the first install; updates take ~2 minutes.

## 1. Prerequisites

Install the following on the host that will run the portal:

| Software | Where to get it |
|---|---|
| Docker Desktop (Windows / macOS) or Docker Engine + Compose v2 (Linux) | <https://www.docker.com/products/docker-desktop> |
| Ollama | <https://ollama.com/download> |
| Git (optional, for cloning this repo) | <https://git-scm.com/downloads> |

After installing Docker, confirm:

```bash
docker --version          # 24+ recommended
docker compose version    # v2
```

After installing Ollama, pull the vision model (~5 GB):

```bash
ollama pull qwen3-vl:8b
ollama list               # confirm qwen3-vl:8b appears
```

Ollama runs as a host service. The portal containers reach it via `host.docker.internal:11434` automatically.

## 2. Get the install artefacts

```bash
git clone https://github.com/MiloTechcon/zoho-expense-portal.git
cd zoho-expense-portal
```

Or download a release tarball if you don't want to use git.

## 3. Get your credentials from Techcon Solution

You'll receive three things from Techcon:

1. **LICENSE_KEY** — a signed JWT, ~600 characters. Goes into `.env`.
2. **GitHub PAT** — a Personal Access Token with `read:packages` scope, scoped to pull the container image.
3. **GHCR username** — `MiloTechcon` (the publisher).

Keep all three in a password manager. Treat the PAT like a password — anyone with it can pull (but not modify) the image.

## 4. Get Zoho Books API credentials

Follow Zoho's "Self Client" flow once per organisation:

1. Go to <https://api-console.zoho.com/>
2. Create a **Self Client**
3. Generate a code with scope `ZohoBooks.fullaccess.all`
4. Exchange the code for a refresh token (one-time):

   ```bash
   curl -X POST https://accounts.zoho.com/oauth/v2/token \
     -d "code=<code>" \
     -d "client_id=<client_id>" \
     -d "client_secret=<client_secret>" \
     -d "grant_type=authorization_code"
   ```

5. Save the `refresh_token` from the response.
6. Note your **Organization ID** from Zoho Books → Settings → Organization Profile.

You now have: `ZOHO_CLIENT_ID`, `ZOHO_CLIENT_SECRET`, `ZOHO_REFRESH_TOKEN`, `ZOHO_ORGANIZATION_ID`.

## 5. Run the install script

```bash
bash install.sh
```

The script will:

1. Check that Docker, Compose, curl, and Ollama are reachable
2. Prompt you for each missing value (LICENSE_KEY, Zoho creds, Ollama settings, etc.)
3. Generate a fresh `JWT_SECRET` if missing
4. Write `.env` with 600 permissions
5. Log in to `ghcr.io` with your GitHub username + PAT
6. Pull the pinned image version
7. Start the containers (`web`, `worker`, `db`)
8. Wait up to 60 seconds for `/health` to respond

On success you'll see:

```
✓ Deployment complete.

Next steps:
  • Web UI:          http://localhost:8000
  • Create a user:   docker compose exec web python /app/run_manage.py create-user <name>
  • Tail worker:     docker compose logs -f worker
  • Update later:    bash install.sh --update
```

## 6. Create your first user

```bash
docker compose exec web python /app/run_manage.py create-user director1
# Prompts for a password (min 8 chars)
```

Open `http://localhost:8000` and log in.

## 7. Make the portal accessible to other devices

By default the portal binds to `localhost:8000` on the host. To open it on your LAN, either:

- Edit `docker-compose.yml` and change `ports: "8000:8000"` to `ports: "0.0.0.0:8000:8000"`, then `docker compose up -d`
- Or use Cloudflare Tunnel: set `CLOUDFLARE_TUNNEL_TOKEN` in `.env` and run `docker compose --profile cloudflare up -d`

## 8. Auto-scan folder ingest (optional)

If you have a Kodak S2080W or similar scanner, configure it to drop files into one folder. The worker watches that folder and routes files by filename prefix.

In `.env`:

```env
SCAN_HOST_DIR="/path/to/Scanner Output Folder"
SCAN_DEFAULT_USERNAME="scanner"   # create this portal user first
```

Filename conventions:

| Pattern | Pipeline |
|---|---|
| `expense_<rest>.pdf` | Receipt → Expense (uploaded as SCAN_DEFAULT_USERNAME) |
| `expense_<director>_<rest>.pdf` | Receipt → Expense uploaded as `<director>` (must be a portal user) |
| `dn_<rest>.pdf` | Delivery Note |
| `bill_<rest>.pdf` | Vendor Invoice |
| anything else | Ignored, left in place |

Restart after editing `.env`: `bash install.sh --update`.

## 9. Email notifications (optional)

The portal can email the responsible director whenever an item lands in **Needs review** or **Failed** — an unreadable/blank scan, a possible duplicate, an unusual amount, an out-of-range date, or a processing error — with a link straight to the history page so nothing waits unnoticed. It sends through [Resend](https://resend.com).

1. Create a Resend account, **verify a sending domain** (e.g. `techcon-solution.com`), and create an API key.
2. In `.env`:

   ```env
   RESEND_API_KEY=re_xxxxxxxx
   EMAIL_FROM=alerts@techcon-solution.com       # an address on your verified domain
   APP_BASE_URL=https://your-portal-url          # used for the link in the email
   # REVIEW_NOTIFY_EMAIL=ops@techcon-solution.com  # optional fallback for scanner items with no owner
   ```

3. Apply, then set each director's email address:

   ```bash
   bash install.sh --update
   docker compose exec web python /app/run_manage.py set-email <username> <email>
   ```

   Confirm with `docker compose exec web python /app/run_manage.py list-users` — the email column should show.

One email is sent per item (no repeats on every poll). Emails go to the item's **owner** (the director who uploaded it); scanner-ingested items with no owner fall back to `REVIEW_NOTIFY_EMAIL`. Leaving `RESEND_API_KEY` blank keeps notifications off.

> Until your domain is verified in Resend you can test with `EMAIL_FROM=onboarding@resend.dev`.

## 10. Updates

```bash
# 1. Edit .env: change APP_VERSION_TAG to the new version
# 2. Run:
bash install.sh --update
```

Database state (the `pgdata` volume) is preserved across upgrades. Idempotent migrations run on container start.

To roll back, change the tag back to the previous version and run the same command.

## 11. Backup

The only persistent state is the `pgdata` Docker volume. Receipt images are stored as bytea inside Postgres, so a SQL dump includes them.

```bash
docker compose exec db pg_dump -U postgres expenses > backup-$(date +%Y%m%d).sql
```

To restore:

```bash
cat backup-YYYYMMDD.sql | docker compose exec -T db psql -U postgres expenses
```

## 12. Common issues

### Login to ghcr.io fails

- Check that the PAT has `read:packages` scope
- Check that the PAT hasn't expired (PATs default to 30 days unless extended)
- Test manually: `echo <PAT> | docker login ghcr.io -u <username> --password-stdin`

### `[license] FATAL: license expired` in worker / web logs

Your license has reached its `exp` date. Contact Techcon for a renewed license; replace `LICENSE_KEY` in `.env` and run `bash install.sh --update`.

### `[license] FATAL: license signature invalid`

The `LICENSE_KEY` does not match the public key baked into the image. Either:
- You're using a license from a different deployment
- The image version is older than your license (rare; reach out to Techcon)

### Ollama not responding

Confirm `ollama serve` is running on the host (`ollama list` should work). The portal calls `host.docker.internal:11434` from inside the container; ensure the host firewall isn't blocking loopback.

### Worker keeps logging "Failed to extract data from receipt"

Usually an Ollama issue. Check `docker compose logs worker` for the upstream error from Ollama (image too large, OOM, etc.). The portal logs the raw model output when parsing fails so you can see what went wrong.

### Notification emails not arriving

- Confirm `RESEND_API_KEY` and `EMAIL_FROM` are set in `.env` and the containers were restarted (`bash install.sh --update`).
- `EMAIL_FROM` must be on a **Resend-verified domain** — an unverified sender is rejected. Test with `EMAIL_FROM=onboarding@resend.dev` first.
- Set the recipient: `docker compose exec web python /app/run_manage.py set-email <username> <email>` (check with `list-users`). Items with no owner need `REVIEW_NOTIFY_EMAIL` set.
- Check `docker compose logs worker | grep notify` for send errors (the worker logs the Resend response on failure).

## Uninstall

```bash
docker compose down -v       # stops containers AND deletes pgdata volume (irreversible)
```

Or without `-v` to keep your data for a future re-install.
