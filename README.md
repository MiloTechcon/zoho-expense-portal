# Zoho Expense Portal

A self-hosted receipt & vendor-invoice ingestion portal that integrates with **Zoho Books**. Operators photograph receipts, delivery notes, and vendor invoices; an on-device vision model (Ollama) extracts structured data; the app posts expenses, attaches DN photos to invoices, and converts purchase orders into bills automatically.

Designed for small/medium businesses in Hong Kong who already use Zoho Books and want to eliminate manual data entry without sending receipts to a third-party cloud.

> **Distribution:** This repository hosts the customer-facing install artefacts (compose template, install script, EULA). The application binaries ship as a compiled Docker image from a private GitHub Container Registry. Source code is licensed under the EULA in this repo; see [EULA.md](EULA.md).

## Features

- **Receipts → Zoho Expenses** — photograph any receipt, the app posts an expense with the right account, paid-through, currency, and reference number.
- **Delivery Notes** — upload signed DNs, the app matches the printed invoice number against Zoho, attaches the DN to the invoice, and emails the invoice to the customer.
- **Vendor Invoices → PO → Bill** — upload vendor invoices with our PO number printed on them; the worker validates line-item amounts against the PO and creates a Bill in Zoho automatically. Supports partial billing (one PO over multiple Bills) when the OCR'd lines match a subset.
- **Auto-scan folder ingest** — drop scanned files from a Kodak S2080W or similar scanner into a watched folder; the worker picks them up by filename prefix (`expense_`, `dn_`, `bill_`) and routes them to the right pipeline.
- **Receivables / Payables dashboard** — `/history` shows overdue invoices (with one-click payment reminder via Zoho's built-in template) and unpaid vendor bills, split by currency.
- **Bilingual UI** — English / Traditional Chinese, toggle in the nav.
- **Mobile-friendly** — uploads work straight from a phone camera.

## How it works

```
            phone / desktop                          your Postgres + worker
              ┌─────────┐                                   ┌──────────┐
   receipt → │ /upload │ ──── HTTPS ────▶ portal ───────▶ │ ingestion │
              └─────────┘                                   └─────┬────┘
                                                                  │
                          ┌──────────────── Ollama ◀───────────── │
                          │  qwen3-vl:8b OCR + JSON              │
                          └───────────────── ▶ extracted          │
                                                  fields          ▼
                                                          ┌──────────────┐
                                                          │ Zoho Books   │
                                                          │  /expenses   │
                                                          │  /invoices   │
                                                          │  /bills      │
                                                          └──────────────┘
```

Everything runs on the customer's own machine. Receipt images live in the customer's Postgres. Ollama is on-host; image data never leaves the customer's network for OCR. The only outbound traffic is to Zoho Books for posting expenses/bills/invoice attachments.

## Prerequisites

| Component | Minimum |
|---|---|
| OS | Linux, Windows 10/11 with WSL2, or macOS |
| Docker | Docker Desktop 4.x or Docker Engine 24+ with Compose v2 |
| RAM | 8 GB (16 GB recommended if running Ollama locally) |
| Ollama | Installed on the host with `qwen3-vl:8b` pulled |
| Zoho Books | Active subscription with API "Self Client" credentials |

## Install

See [INSTALL.md](INSTALL.md) for the full step-by-step. Short version:

```bash
# 1. Copy the templates into a directory of your choice
git clone https://github.com/MiloTechcon/zoho-expense-portal.git
cd zoho-expense-portal

# 2. Run the install script — it prompts for missing values
bash install.sh
```

The script writes a `.env`, logs into the image registry, pulls the pinned image version, starts the stack, and waits for the health endpoint. Re-running with `--update` redeploys.

## Updates

```bash
# edit APP_VERSION_TAG in .env to the new version, then
bash install.sh --update
```

Customer data (Postgres volume) persists across upgrades. Rollback is the same flow with the previous tag.

## Pricing & licensing

Each deployment requires a signed license key issued by **Techcon Solution**. The key is included in your `.env` and validated locally — there is no phone-home requirement. Contact Techcon Solution for license terms, support tiers, and renewal.

By installing this software you agree to the [EULA](EULA.md).

## Support

- **Email**: <support@techcon-solution.example>  *(replace with real contact)*
- **Issue tracker**: GitHub Issues on this repo for installation / docs questions
- **Security disclosure**: <security@techcon-solution.example>  *(replace with real contact)*

## Releases

See [CHANGELOG.md](CHANGELOG.md) for release notes. Pin a specific `APP_VERSION_TAG` in your `.env`. Never use `:latest`.

## Built by

Techcon Solution · Hong Kong
