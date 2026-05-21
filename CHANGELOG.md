# Changelog

Customer-facing release notes for the Zoho Expense Portal Docker image.

The pinned image version is whichever tag you set in `APP_VERSION_TAG` in your `.env`. Never use `:latest` — version pinning is required for licensing, reproducibility, and rollback.

---

## v1.4.1-saas — 2026-05-20  *(current — recommended to pin)*

Footer version label now correctly shows `v1.4` (the previous build had `v1.2` baked in by accident). No other changes — same features, same security posture, same multi-arch image as `v1.4-saas`.

Apply with:

```bash
# In .env:  APP_VERSION_TAG=v1.4.1-saas
bash install.sh --update
```

---

## v1.4-saas — 2026-05-20

**First production SaaS release.** Superseded by `v1.4.1-saas` (cosmetic version-label fix). New deployments should pin `v1.4.1-saas` instead.

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
