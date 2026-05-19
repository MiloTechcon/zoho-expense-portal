# Onsite Deployment Playbook

> **Audience:** Engineer deploying the Zoho Expense Portal at a new customer's site, with the customer present.
> **Time budget:** ~90 minutes from arrival to handoff.
> **Output:** A working install, one portal user, a smoke-tested receipt upload, the customer trained on day-to-day use.

Follow each step in order. Each step has a **check** that proves it worked before you move on.

---

## 0. Before you go onsite (Techcon side, before the call)

Five things to have in hand:

| Item | How to get it |
|---|---|
| Customer's signed EULA | Email exchange or DocuSign |
| Customer's annual fee invoiced & paid | Finance |
| **Licence key** for this customer | `cd ~/Git/zoho-expense && venv/bin/python -m app.license_tools mint --private-key <path-to-restored-private.pem> --customer "Customer Co Ltd" --expires 2027-05-20 > /tmp/customer-licence.txt` |
| **GHCR Personal Access Token** for this customer | github.com → profile → Developer settings → PATs → Generate (classic), scope `read:packages` only, expiry = licence expiry + 30 days, name = `customer-co-zoho-expense` |
| This playbook open | Bookmark it on your laptop |

Store the licence key + PAT in your password manager **before** going onsite. Don't leave them in a `/tmp/` file you might forget about.

**Check:** You have one file (licence) and one string (PAT) saved to your password manager.

---

## 1. Arrive and confirm the target host (5 min)

The customer's host is whichever machine will run the portal. Confirm:

- It's reachable on the local network (you can ping it from the customer's laptop).
- The customer can `sudo` on it (or, on Windows, has admin rights).
- It has at least **8 GB RAM** (16 GB strongly preferred — Ollama is hungry).
- It has at least **20 GB free disk** (image + Postgres growth + Ollama models).
- It can reach the internet — `curl https://ghcr.io` works (this is where the image comes from).

```bash
# On the target host:
free -h          # Linux: free -h shows RAM. macOS: system_profiler SPHardwareDataType. Windows: systeminfo
df -h /
curl -sI https://ghcr.io | head -1     # expect: HTTP/2 200 or similar
```

**Check:** All four boxes ticked. If not, get a different host before continuing.

---

## 2. Install Docker (10-15 min, varies by OS)

| OS | Instructions |
|---|---|
| **Ubuntu / Debian** | `curl -fsSL https://get.docker.com \| sh` then `sudo usermod -aG docker $USER`, log out and back in |
| **Windows 10/11** | Download Docker Desktop installer, run it, enable "Use WSL2", reboot |
| **macOS** | Download Docker Desktop for Mac, install, launch |

Verify:

```bash
docker --version            # >= 24.x
docker compose version      # >= v2.20
docker run --rm hello-world # confirms Docker daemon is up
```

**Check:** All three commands succeed.

---

## 3. Install Ollama (5-10 min)

Ollama runs natively on the host (NOT in a container) so the portal can reach it via `host.docker.internal:11434`.

| OS | Command |
|---|---|
| **Linux** | `curl -fsSL https://ollama.com/install.sh \| sh` |
| **Windows** | Download from <https://ollama.com/download/windows>, install, it starts as a service |
| **macOS** | Download from <https://ollama.com/download/macos> or `brew install ollama` |

Pull the vision model (this is the slow step — ~5 GB download):

```bash
ollama pull qwen3-vl:8b
ollama list                 # confirm qwen3-vl:8b appears
```

Verify reachability from the container network you'll use later:

```bash
curl -s http://localhost:11434/api/tags | head -50
```

You should see a JSON list of installed models including `qwen3-vl:8b`.

**Check:** `ollama list` shows the model and `curl localhost:11434/api/tags` returns JSON.

---

## 4. Get Zoho Books API credentials (10-15 min)

Sit with the customer at their browser; they own the credentials.

1. Open <https://api-console.zoho.com/>
2. Click **Add Client** → choose **Self Client** → Create
3. Note down `Client ID` and `Client Secret`
4. On the **Generate Code** tab, fill in:
   - **Scope:** `ZohoBooks.fullaccess.all`
   - **Time duration:** 10 minutes
   - **Scope description:** `Initial setup for Zoho Expense Portal`
5. Click **Create** → copy the generated `code`
6. **Immediately** exchange the code for a refresh token (the code expires in 10 min):

   ```bash
   curl -X POST https://accounts.zoho.com/oauth/v2/token \
     -d "code=<CODE>" \
     -d "client_id=<CLIENT_ID>" \
     -d "client_secret=<CLIENT_SECRET>" \
     -d "grant_type=authorization_code"
   ```

7. Save `refresh_token` from the response. **This is what goes into `.env` as `ZOHO_REFRESH_TOKEN`** — the code itself is single-use.
8. Get the **Organization ID**: Zoho Books → Settings → Organization Profile → "Organization ID" near the top.

You now have four values:
- `ZOHO_CLIENT_ID`
- `ZOHO_CLIENT_SECRET`
- `ZOHO_REFRESH_TOKEN`
- `ZOHO_ORGANIZATION_ID`

**Check:** Refresh token request returned `200 OK` with a non-empty `refresh_token`.

---

## 5. Clone the customer-facing repo (2 min)

```bash
git clone https://github.com/MiloTechcon/zoho-expense-portal.git
cd zoho-expense-portal
ls
```

You should see: `README.md`, `INSTALL.md`, `CHANGELOG.md`, `EULA.md`, `docker-compose.yml`, `.env.example`, `install.sh`.

**Check:** The directory listing matches.

---

## 6. Run the install script (10 min)

```bash
bash install.sh
```

The script prompts for each value. Have these from your password manager / earlier steps:

| Prompt | What to paste |
|---|---|
| `LICENSE_KEY` | The token from `/tmp/customer-licence.txt` |
| Image tag | `v1.4-saas` (or the current production tag — check `customer/.env.example`) |
| GitHub username | `MiloTechcon` |
| GitHub PAT | The customer-specific PAT you generated in step 0 |
| `ZOHO_CLIENT_ID` | From step 4 |
| `ZOHO_CLIENT_SECRET` | From step 4 |
| `ZOHO_REFRESH_TOKEN` | From step 4 |
| `ZOHO_ORGANIZATION_ID` | From step 4 |
| Paid-through account | E.g. `HSBC HK` — the customer's default Zoho bank account name |
| Ollama host | Press Enter for default `host.docker.internal:11434` |
| Ollama model | Press Enter for default `qwen3-vl:8b` |

The script will:
- ✅ Validate prerequisites
- ✅ Write `.env` (mode 600)
- ✅ `docker login ghcr.io`
- ✅ `docker compose pull`
- ✅ `docker compose up -d`
- ✅ Wait for `/health` to respond

You'll see `[license] valid for 'Customer Co Ltd', exp=…` near the end.

**Check:** Final line says `✓ Deployment complete.` If you see `[license] FATAL` in the logs, the licence key is wrong — re-mint it.

---

## 7. Create the first user (2 min)

```bash
docker compose exec web python -m app.manage create-user director1
# Prompts for a password (min 8 chars). The customer types it; you don't see it.
```

Repeat for each director / staff member who will use the portal.

**Check:** `docker compose exec web python -m app.manage list-users` shows the new users.

---

## 8. Open the portal and validate (5 min)

```bash
curl -s http://localhost:8000/health
# {"status":"ok"}
```

In a browser on the customer's laptop, open `http://<host-ip>:8000` (or `http://localhost:8000` if running on the same machine). Log in with the user you just created.

You should see the upload page with the customer's brand (if you set `BRAND_NAME` in `.env`).

**Check:** Login succeeds and `/upload` renders with three tabs (Receipt / Delivery Note / Vendor Invoice).

---

## 9. End-to-end smoke test (10 min)

The customer photographs a real receipt and uploads it. Watch the worker log live:

```bash
docker compose logs -f worker
```

Expected sequence within ~30 seconds (faster with GPU):

```
ollama: receipt extract, content_type=image/jpeg prepared_image_bytes=...
Processed 1 expense(s), 0 scan(s) ingested
```

Open Zoho Books → Purchases → Expenses. The new expense should appear with:
- ✅ Correct vendor name
- ✅ Correct amount and currency
- ✅ Correct date
- ✅ The receipt image attached

**Check:** The expense is in Zoho Books with the receipt visible.

If anything looks wrong:
- Status `failed` in `/history` → click the row to see the OCR'd values and error message
- Wrong account picked → train the customer to pick the right expense-account in Zoho directly after; we can tune the prompt later
- Wrong amount (especially $X for Octopus-style "Remaining Value" trap) → flag it; this case is already in our prompt but unusual receipts can still trip up

---

## 10. Configure auto-scan ingest (optional, 10 min)

If the customer has a Kodak S2080W or any scanner that outputs to a folder:

1. Decide the folder path. Defaults to the Kodak Smart Touch output:

   ```text
   Windows: C:\Users\<user>\Documents\Smart Touch\s2080w\Output
   Linux:   /home/<user>/scans
   ```

2. Edit `.env`:

   ```env
   SCAN_HOST_DIR="<path>"
   SCAN_DEFAULT_USERNAME="scanner"
   ```

3. Create the scanner user:

   ```bash
   docker compose exec web python -m app.manage create-user scanner
   ```

4. Apply the change:

   ```bash
   bash install.sh --update
   ```

5. Configure scanner buttons. Each Kodak Smart Touch button writes a file with one of these prefixes:
   - `expense_*.pdf` → Receipt
   - `expense_milo_*.pdf` → Receipt attributed to `milo` (must be a portal user)
   - `dn_*.pdf` → Delivery Note
   - `bill_*.pdf` → Vendor Invoice

6. Drop a sample `expense_test.pdf` into the folder, watch `docker compose logs -f worker` for `scan: ingested expense …` within ~10 seconds.

**Check:** Sample file moves from `Output/` to `Output/_processed/` and appears in `/history`.

---

## 11. Hand off to the customer (10 min)

Walk the customer through:

1. **Their portal URL** — `http://<host-ip>:8000` (or whatever they prefer)
2. **How to upload** — the three tabs; demonstrate one of each
3. **How to read `/history`** — status badges, retry button on failures
4. **Where to find the dashboard strip** — overdue invoices + unpaid bills
5. **How to send overdue reminders** — click the reminder button
6. **What to do if a row is `failed`** — copy the error message, email Techcon
7. **Backup expectations** — your team or theirs?
8. **Update channel** — Techcon will email when a new version is available; customer (or you) runs `bash install.sh --update`

Hand over:
- The customer's copy of the EULA (signed by both)
- The `INSTALL.md` and `README.md` URLs (public repo) for self-service reference
- Techcon's support email + response SLA from the EULA

**Check:** Customer can demonstrate uploading a receipt and seeing it in Zoho without your help.

---

## 12. Post-install Techcon hygiene (5 min, back at your desk)

- Update your customer tracker spreadsheet (or whatever you use) with: customer name, licence expiry date, image tag deployed, GHCR PAT name + expiry, host OS, support contact.
- Schedule a 30-day check-in (calendar invite to yourself).
- Schedule a 60-day-before-expiry reminder to mint the next year's licence.
- File any quirks you noticed (unusual receipts, custom paid-through accounts, requested features) in the private repo's issues for follow-up.

---

## Troubleshooting fast-paths

| Symptom | First thing to check |
|---|---|
| `bash install.sh` fails at "Logging in to ghcr.io" | PAT scope (`read:packages`) and not expired |
| `[license] FATAL: signature invalid` | Licence was minted with a key that doesn't match the deployed image. Re-mint with the current private key. |
| `[license] FATAL: license expired` | Customer is past their term. Mint a renewal, update `.env`, `bash install.sh --update`. |
| Worker logs `Failed to extract data from receipt` | `docker compose logs worker --tail 50` — usually Ollama is unreachable or returned empty. Restart Ollama on the host. |
| Web `/health` doesn't respond | `docker compose ps` to see if web container restarted. Usually Postgres healthcheck not yet green. Wait 30 more seconds. |
| Customer can't reach portal from another machine | `docker compose.yml` ports default to `127.0.0.1:8000`. Add a `docker-compose.override.yml` with `0.0.0.0:8000:8000` and re-up. |
| Zoho API calls fail with 401 | Refresh token rotated or revoked. Walk through step 4 again. |

For deeper issues, see `docs/DEPLOYMENT_GUIDE_ENGINEERS.md` in the private Techcon repo.

---

## Time budget reference

| Phase | Target |
|---|---|
| 0. Pre-arrival prep | 15 min (your desk, before the call) |
| 1. Host check | 5 min |
| 2. Docker install | 10-15 min |
| 3. Ollama install + model pull | 5-10 min (download depends on bandwidth) |
| 4. Zoho credentials | 10-15 min |
| 5. Clone repo | 2 min |
| 6. `install.sh` | 10 min |
| 7. First user | 2 min |
| 8. Open + validate | 5 min |
| 9. End-to-end smoke | 10 min |
| 10. Auto-scan setup (optional) | 10 min |
| 11. Handoff | 10 min |
| 12. Techcon hygiene | 5 min (back at desk) |
| **Total onsite** | **~75-90 min** (longer if Ollama download is slow) |

Plan for half a day in the calendar to absorb traffic, lunch, and questions.
