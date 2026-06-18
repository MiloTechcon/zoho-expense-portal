# Changelog

Customer-facing release notes for the Zoho Expense Portal Docker image.

The pinned image version is whichever tag you set in `APP_VERSION_TAG` in your `.env`. Never use `:latest` — version pinning is required for licensing, reproducibility, and rollback.

---

## v1.4.17-saas — 2026-06-18  *(current — recommended to pin)*

Email notifications for items that need your attention.

When a receipt fails to process, or is flagged for review (empty/unreadable scan, possible duplicate, an unusual amount, or an out-of-range date), the portal now **emails the responsible director** with a link straight to the history page to verify-and-complete or cancel it — so nothing waits unnoticed. Exactly one email is sent per item (no repeats on every poll), via the Resend email service.

Emails go to the **owner** of the item (the director who uploaded it), with a fallback address for scanner-ingested items. Set each director's email with the admin CLI.

New env vars:

```
RESEND_API_KEY=re_...                       # from your Resend account
EMAIL_FROM=alerts@your-domain.com           # a Resend-verified sender
APP_BASE_URL=https://your-portal-url        # used for the link in the email
REVIEW_NOTIFY_EMAIL=fallback@your-domain.com  # optional; for items with no owner
```

After upgrading, set the directors' email addresses:

```bash
docker compose exec zoho-expense-web python /app/run_manage.py set-email <username> <email>
```

If `RESEND_API_KEY` is left blank, the feature is simply off — existing deployments are unaffected.

Apply with:

```bash
# In .env:  APP_VERSION_TAG=v1.4.17-saas
bash install.sh --update
```

---

## v1.4.16-saas — 2026-06-16

Future-dated receipts are flagged for review (with a timezone-safe grace).

A follow-up to v1.4.15's date checks. Receipts whose OCR-read date lands in the future (typically a wrong-year mis-read) are flagged for verification instead of being booked. Because "today" is measured in UTC and you operate in UTC+8, a small grace (`EXPENSE_FUTURE_GRACE_DAYS`, default 1 day) prevents a legitimate same-day receipt scanned in the early morning from being wrongly flagged, while genuine far-future mis-reads still get caught.

New env var (optional):

```
EXPENSE_FUTURE_GRACE_DAYS=1     # days past today allowed before flagging a future date
```

Apply with:

```bash
# In .env:  APP_VERSION_TAG=v1.4.16-saas
bash install.sh --update
```

---

## v1.4.15-saas — 2026-06-16

Extraction plausibility checks — catch OCR mis-reads before they reach Zoho.

Two new safeguards flag a receipt for **Needs review** (instead of booking a wrong figure), and a **Cancel** button to drop anything you don't want:

- **Learned amount check.** For each vendor, the system learns the normal range from *your own* past expenses. If a new receipt's amount falls well outside that vendor's usual range — too high *or* too low (a dropped or added digit) — it's flagged. It's deliberately lenient at first and gets more precise the more times it has seen a vendor (it needs at least a handful of past expenses before it judges anything; brand-new vendors are never flagged on amount).
- **Date floor.** A receipt dated before your company start date is flagged. Set it with `EXPENSE_MIN_DATE` (e.g. `2024-08-15`); leave blank to disable.
- **Cancel on review cards.** Every Needs-review item (receipt, delivery note, vendor invoice) now has a **Cancel** button that drops it and deletes the scan — which also clears the duplicate lock, so you can re-scan and re-submit it cleanly later.

New env vars (all optional, sensible defaults):

```
EXPENSE_MIN_DATE=2024-08-15            # date floor; blank = off
AMOUNT_OUTLIER_ENABLED=true
AMOUNT_OUTLIER_MIN_SAMPLES=5           # past expenses needed before judging a vendor
AMOUNT_OUTLIER_IQR_FACTOR=2.5          # higher = more tolerant
AMOUNT_OUTLIER_MIN_TOLERANCE_PCT=40
```

Flagged amounts show the learned range, e.g. *"This vendor's past expenses were $230–$310; this reads $520. Please verify the amount."* Confirm with **Create new anyway**, or **Cancel** to drop it.

Apply with:

```bash
# In .env:  APP_VERSION_TAG=v1.4.15-saas
bash install.sh --update
```

---

## v1.4.14-saas — 2026-06-09

History view: scrollable, fixed-height list.

The history page used to be one long, ever-growing page — to reach the footer (and the app version shown there) you had to scroll past every record, which was awkward on mobile. The list now sits in a **fixed-height box that scrolls on its own**, loading more cards as you scroll to the bottom. The page itself stays short, so the footer and version are always one glance away.

Filter changes jump back to the top; the auto-refresh of in-progress items keeps your scroll position. No data or settings change — purely a view improvement.

Apply with:

```bash
# In .env:  APP_VERSION_TAG=v1.4.14-saas
bash install.sh --update
```

---

## v1.4.13-saas — 2026-06-08

Fix: receipts with itemised line items no longer fail.

Some receipts (e.g. restaurant bills with a list of dishes) made the model return line items as structured objects rather than plain text, which crashed expense creation with an internal "expected str instance, dict found" error and left the card `failed`. Line items are now normalised to readable text (`item name (price)`) before the expense is built.

Line items remain **best-effort**: they're included in the Zoho description when they read cleanly, but can never crash or bloat an expense — the vendor, amount and date are what matter, and the original receipt image is always attached to the Zoho expense for full detail. (The 500-character description cap from v1.4.8 still applies.)

**Operator action after upgrade — retry the affected records:**

```sql
UPDATE expenses
SET status = 'pending', error_message = NULL
WHERE status = 'failed'
  AND error_message LIKE '%expected str instance%';
```

Apply with:

```bash
# In .env:  APP_VERSION_TAG=v1.4.13-saas
bash install.sh --update
```

---

## v1.4.12-saas — 2026-06-08

Receipt OCR: automatically retry an empty read once.

A follow-up to v1.4.11. On CPU-only Ollama hosts the model occasionally returns a blank read for a perfectly legible receipt — observed as 1 of 4 identical-format telephone bills landing as "Unknown – $0.00 / Needs review". When OCR returns no vendor **and** no amount, the worker now **re-runs the extraction once** before flagging the card; the second pass almost always succeeds.

Genuinely blank or unreadable scans stay empty on the retry and still go to **Needs review** as before, so nothing wrong gets auto-created. Operator-forced "create anyway" retries skip the extra pass.

> Still the durable fix for OCR speed and reliability: run Ollama on a host with a supported GPU. The retry is a safety net over slow CPU inference, not a substitute for it.

**Operator action after upgrade — retry the affected records:**

```sql
UPDATE expenses
SET status = 'pending', error_message = NULL
WHERE status IN ('failed', 'review_required')
  AND (vendor IS NULL OR amount IS NULL OR amount = 0);
```

Apply with:

```bash
# In .env:  APP_VERSION_TAG=v1.4.12-saas
bash install.sh --update
```

---

## v1.4.11-saas — 2026-06-08

Receipt OCR: render page 1 only, and raise the output budget.

On CPU-only Ollama hosts (no supported GPU), a 2-page receipt PDF took several minutes per document, and the scanner's usually-blank second page could crowd the model's context and blank out the extraction — leaving "Unknown – $0.00" cards. Receipts now send **only the first page** to the model (halving inference time and freeing context), and the output token budget is raised so receipts with long line-item lists no longer get their JSON cut off mid-output (which previously produced an empty extraction).

Delivery notes and vendor invoices are unchanged — they still process up to two pages, since those documents are legitimately multi-page.

> Tip: for acceptable OCR speed, run Ollama on a host with a supported GPU. Stock Ollama accelerates NVIDIA (CUDA), AMD (ROCm), and Apple (Metal); pure-CPU inference of a 7–8B vision model is slow regardless of this change.

**Operator action after upgrade — retry the affected records:**

```sql
UPDATE expenses
SET status = 'pending', error_message = NULL
WHERE status IN ('failed', 'review_required')
  AND (vendor IS NULL OR amount IS NULL OR amount = 0);
```

The worker re-OCRs them on the next poll tick. Or click **Retry** on each card.

Apply with:

```bash
# In .env:  APP_VERSION_TAG=v1.4.11-saas
bash install.sh --update
```

---

## v1.4.10-saas — 2026-06-08

In-app license import & renewal — no more `.env` editing to renew.

Renew your license straight from the web UI. A new **License** page (🔑 in the top bar) shows who the license is issued to, the expiry date, and days remaining, and lets you **paste a renewed key and import it** — it's stored in the database and takes effect automatically, with no `.env` edit and no manual restart.

An **expiry warning banner** now appears on every page within 14 days of expiry (turning red in the final 3 days), so renewals never lapse silently.

At startup the app uses whichever **valid license lasts longest** between the stored (imported) key and the `LICENSE_KEY` in your `.env`, so coverage never moves backwards. Import only accepts a key that extends your current coverage.

New env var (optional):

```
LICENSE_WARN_DAYS=14     # days before expiry to start showing the banner
```

No compose change — the imported license persists in the existing Postgres volume. Your existing `.env` `LICENSE_KEY` keeps working as the bootstrap license; future renewals can go through the UI.

> Renew **before** expiry. If a license fully lapses the app stops (as before) and the import page is unreachable — the banner is there to prevent that.

Apply with:

```bash
# In .env:  APP_VERSION_TAG=v1.4.10-saas
bash install.sh --update
```

---

## v1.4.9-saas — 2026-06-08

Accept TIFF scans.

`.tif` / `.tiff` images are now accepted for both manual upload and scan-folder ingestion, alongside the existing PDF / JPEG / PNG formats — useful for multi-function scanners that output TIFF by default.

Apply with:

```bash
# In .env:  APP_VERSION_TAG=v1.4.9-saas
bash install.sh --update
```

---

## v1.4.8-saas — 2026-05-29

Hotfix: truncate Zoho's `description` field to its 500-character cap before submission.

OCR-extracted line-item lists on long receipts (typically supermarket / parts-list scans) can push the constructed description past Zoho's limit, causing Zoho to reject the POST with HTTP 400 and the expense to land as `failed`. The worker now truncates to 499 characters and appends an ellipsis (`…`) so the cut is visible in Zoho.

**Operator action after upgrade — retry the failed records:**

```sql
UPDATE expenses
SET status = 'pending', error_message = NULL
WHERE status = 'failed'
  AND error_message LIKE '%Description%has less than 500 characters%';
```

The worker will pick them up on the next poll tick (default 5 s), re-OCR, truncate, and submit successfully. Or click **Retry** on each failed card individually.

Apply with:

```bash
# In .env:  APP_VERSION_TAG=v1.4.8-saas
bash install.sh --update
```

---

## v1.4.7-saas — 2026-05-29

Empty-extraction guard. Three layers of protection against blank or unreadable scans polluting history by auto-linking to wrong Zoho expenses.

**Layer 1 — scanner pre-OCR size guard.** Files smaller than `MIN_RECEIPT_SIZE_BYTES` (default 5 KB) move to the source folder's `_failed/` archive with a clear log message. No DB row is created.

**Layer 2 — upload endpoint size guard.** `POST /receipts/upload` rejects too-small files with HTTP 400 naming the file. Mirrors layer 1 for manual uploads.

**Layer 3 — worker post-OCR guard.** When OCR returns no vendor AND no amount, the worker now sets the expense to `review_required` with `review_reason=extraction_empty` and **skips dedup + Zoho**. Previously a blank extraction could match an existing Zoho expense by reference number and auto-link to it, creating ghost "Completed" cards.

Affected setup: multi-function scanners (e.g. Kodak S2080W) that produce multi-page batches including blank pages. The size guard catches those at ingest; the worker guard is a safety net for non-blank-but-unreadable scans that slip through.

New env var (optional):

```
MIN_RECEIPT_SIZE_BYTES=5120     # default; set higher/lower to tune
                                # set to 0 to disable the size guards entirely
```

New i18n entry shows "OCR couldn't read vendor or amount. Delete or re-upload." on flagged cards.

**Operator action required after upgrade:** delete any pre-existing ghost expense rows (status=completed, vendor=NULL, amount=NULL, review_reason=linked_to_existing). They were created by the bug this release fixes. Sample cleanup SQL:

```sql
DELETE FROM expenses
WHERE vendor IS NULL AND amount IS NULL
  AND review_reason = 'linked_to_existing';
DELETE FROM receipts
WHERE id NOT IN (SELECT receipt_id FROM expenses WHERE receipt_id IS NOT NULL)
  AND id NOT IN (SELECT receipt_id FROM delivery_notes WHERE receipt_id IS NOT NULL)
  AND id NOT IN (SELECT receipt_id FROM vendor_invoices WHERE receipt_id IS NOT NULL);
```

Apply with:

```bash
# In .env:  APP_VERSION_TAG=v1.4.7-saas
bash install.sh --update
```

---

## v1.4.6-saas — 2026-05-28

History cards now show the original source filename below the status pill, so operators can identify which uploaded file produced any record — especially flagged-for-review ones.

```
📄 ✅ Completed
📎 invoice-acme-2026-05-28.pdf       ← NEW
Acme Co — $1,234.56
...
```

Apply with:

```bash
# In .env:  APP_VERSION_TAG=v1.4.6-saas
bash install.sh --update
```

---

## v1.4.5-saas — 2026-05-28

Auto-scan ingest now supports per-folder paid-through routing. Each subfolder of `SCAN_ROOT` declared in the new `SCAN_FOLDER_ACCOUNT_MAP` env var maps to a specific `(user, paid_through_account)` tuple. Files dropped there become receipts stamped with that account — no filename prefix required.

```
SCAN_FOLDER_ACCOUNT_MAP=Milo=milo,Director C/A-Mr Yung;Milo_P=milo,Director C/A-Mr Yung (P);Kobe=kobe,Director C/A-Mr Lau;Kobe_P=kobe,Director C/A-Mr Lau (P)
```

Use case: a multi-function scanner (e.g. Kodak S2080W) is configured with one scan function per (director, account), depositing into the matching subfolder.

- Mapped subfolders are **receipt-only** (DN/VI keep using filename prefixes at root)
- Each mapped subfolder gets its own `_processed/` and `_failed/` archive
- Root-level behaviour and existing `expense_*` / `dn_*` / `bill_*` filename routing are unchanged
- Unmapped subfolders are silently skipped (no recursion)

Apply with:

```bash
# In .env:  APP_VERSION_TAG=v1.4.5-saas
# Add SCAN_FOLDER_ACCOUNT_MAP=...
# Create the matching directories under SCAN_ROOT
bash install.sh --update
```

---

## v1.4.4-saas — 2026-05-28

*(superseded by v1.4.5+ — same multi-account mapping carries forward.)*

Multi-account-per-user paid-through mapping. Directors who manage two business accounts (e.g. `Director C/A-Mr Yung` and `Director C/A-Mr Yung (P)`) can now declare both in `PAID_THROUGH_ACCOUNT_MAP` and pick between them per upload.

New env-var syntax (semicolon between users, comma between a user's accounts):

```
PAID_THROUGH_ACCOUNT_MAP=milo=Director C/A-Mr Yung (P),Director C/A-Mr Yung;kobe=Director C/A-Mr Lau (P),Director C/A-Mr Lau
DEFAULT_PAID_THROUGH_ACCOUNT=HSBC HK
```

First mapped account is the dropdown's default selection (operator controls ordering via the env var). Auto-scan ingest also uses the first mapped account.

**Backward compatibility:** the legacy comma-only format (one account per user) still works without `.env` changes — the parser auto-detects which delimiter scheme is in use.

**Cosmetic:** dropdown labels now show the bare account name. The "Personal —" / "Company —" prefix from v1.4.3 was dropped — it scaled awkwardly past two options.

Apply with:

```bash
# In .env:  APP_VERSION_TAG=v1.4.4-saas
bash install.sh --update
```

---

## v1.4.3-saas — 2026-05-22

First per-upload "Paid through" override. Adds a dropdown above the file input on the Receipt tab so a director who pays a receipt on the company card can route it to `HSBC HK` instead of their personal account at upload time.

- New nullable column `receipts.paid_through_account_name` (idempotent migration on container start)
- New endpoint `GET /receipts/paid-through-options` returning the user's allowed choices
- `POST /receipts/upload` accepts `paid_through` form field, validates server-side against the allow-list
- Worker honours the override when present; falls back to per-user mapping otherwise

Superseded by `v1.4.4-saas` (multi-account-per-user mapping + label cleanup). New deployments should pin `v1.4.4-saas` instead.

---

## v1.4.2-saas — 2026-05-21

Admin CLI is now reachable inside the compiled image. Previous tags required a Python one-liner workaround because Nuitka-compiled modules don't support `python -m`. A small `run_manage.py` launcher fixes this.

User management now works as documented:

```bash
docker compose exec web python /app/run_manage.py create-user <name>
docker compose exec web python /app/run_manage.py list-users
docker compose exec web python /app/run_manage.py set-password <name>
docker compose exec web python /app/run_manage.py delete-user <name>
```

Apply with:

```bash
# In .env:  APP_VERSION_TAG=v1.4.2-saas
bash install.sh --update
```

---

## v1.4.1-saas — 2026-05-20

Footer version label now correctly shows `v1.4` (the previous build had `v1.2` baked in by accident). No other changes — same features, same security posture, same multi-arch image as `v1.4-saas`.

**Known issue (resolved in v1.4.2-saas):** `docker compose exec web python -m app.manage ...` fails with `AttributeError: type object 'nuitka_module_loader' has no attribute 'get_code'`. Workaround:

```bash
docker compose exec web python -c "import sys; from app.manage import main; sys.exit(main(['manage','create-user','<name>']))"
```

New deployments should pin `v1.4.2-saas` instead.

---

## v1.4-saas — 2026-05-20

**First production SaaS release.** Superseded by `v1.4.2-saas`. New deployments should pin `v1.4.2-saas` instead.

- Multi-arch image (linux/amd64 + linux/arm64); native pulls on Apple Silicon and ARM cloud hosts
- Licence-key enforcement at boot (web + worker); no phone-home
- Customer install script `install.sh` with `--update` / `--check` modes
- Brand customisation via `BRAND_NAME` / `BRAND_LOGO_URL` env vars
- Image source is compiled — no readable Python from `app/` or `worker/` ships in the image

For deployment engineers: see [ONSITE_DEPLOYMENT.md](ONSITE_DEPLOYMENT.md) for the step-by-step playbook and [DEPLOYMENT_GUIDE_ENGINEERS.md](DEPLOYMENT_GUIDE_ENGINEERS.md) for the operational reference.

---

## Pilot iterations *(no longer available)*

Tags `v1.4-saas-pilot`, `v1.4-saas-pilot.1`, and `v1.4-saas-pilot.2` were internal pilot iterations that produced the production builds above. Their images and git tags have been removed; they are not pullable.

## What's inside, feature-wise (carried forward from prior releases)

- Receipt → Zoho Expense pipeline with vision OCR for HK receipts including waybills, parking slips, stored-value card slips
- Delivery Note → invoice attach + auto-email
- Vendor Invoice → PO → Bill with partial-billing support (subset line matching, attaches to both Bill and PO)
- Auto-scan folder ingest (Kodak S2080W) with filename-prefix routing
- Dashboard summary on `/history` for overdue invoices + unpaid vendor bills (multi-currency split)
- One-click payment reminder via Zoho's built-in template
- Bilingual EN / 繁體中文 UI
- 24-hour JWT sessions with auto-redirect on expiry
- Idempotent Postgres migrations on container start

## Upgrade procedure

1. Edit `.env`: bump `APP_VERSION_TAG` to the new version.
2. Run `bash install.sh --update`.

Postgres volume persists across upgrades.

## Rollback procedure

1. Edit `.env`: set `APP_VERSION_TAG` back to the previous version.
2. Run `bash install.sh --update`.
