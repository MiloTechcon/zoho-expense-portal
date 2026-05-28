# Changelog

Customer-facing release notes for the Zoho Expense Portal Docker image.

The pinned image version is whichever tag you set in `APP_VERSION_TAG` in your `.env`. Never use `:latest` — version pinning is required for licensing, reproducibility, and rollback.

---

## v1.4.4-saas — 2026-05-28  *(current — recommended to pin)*

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
