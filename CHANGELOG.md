# Changelog

Customer-facing release notes for the Zoho Expense Portal Docker image.

The pinned image version is whichever tag you set in `APP_VERSION_TAG` in your `.env`. Never use `:latest` — version pinning is required for licensing, reproducibility, and rollback.

---

## v1.4.8-saas — 2026-05-29  *(current — recommended to pin)*

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
