# AP Invoices Cortex Agent: Design

- **Target data:** `COCO_WORKSHOP.PIPELINE_LAB.SILVER_AP_INVOICES` (session has no schema set; this is the only copy)
- **Proposed semantic view:** `COCO_WORKSHOP.PIPELINE_LAB.SV_AP_INVOICES` (not yet created)
- **Status:** design only. No semantic view or agent exists yet; searches for AP invoices returned none.
- **Date:** 2026-10-20

## Data profile (what limits the design)

| Fact | Value | Impact |
|---|---|---|
| Size | 50 invoices, 28 vendors, 4 source systems | Small; fine for a demo |
| Currencies | USD, EUR, GBP; no FX in Silver (BR-002) | Never add amounts across currencies |
| Payment data | No paid date or payment status columns | Can't answer "paid" or "overdue" questions |
| Date coverage | Invoice dates 2025-01-10 → 2025-06-01; due dates 2025-02-09 → 2025-07-09 | Relative periods ("this month") return nothing today |
| Vendors | `vendor_id` unique only within a source system | No cross-system vendor totals |
| GL / cost center | Raw source codes; no unified chart of accounts (BR-006) | Present as raw codes; never translate between systems |
| High-value | 0 invoices over 500,000 in local currency; max 125,000 | >$500K flag needs FX, so it belongs in the data quality check (DMF), not the agent |

## Primary audience

**The AP and Finance Operations team**: AP specialists, the AP manager, and controllers (e.g. Tom Walsh). They need invoice lookup, approval backlog, due-date review, and vendor exposure across SAP, Oracle, Baan and Workday.

Not a good fit for:
- **Treasury and FP&A**, who need FX-converted totals (Gold layer).
- **Cash-flow reporting**, which needs payment data.

## Top five business questions

1. **Approval backlog:** "How many invoices are pending approval, and for how much, by source system and currency?" (`approval_status`)
2. **Upcoming due dates:** "Which invoices are due in the next N days, or before a given date, by vendor?" (`due_date`; only about due dates, not payment status)
3. **Vendor exposure:** "Who are the top vendors by invoice amount, per currency?"
4. **Invoice lookup:** "Show me invoice BN-2025-1003: status, amount, PO, GL account and cost center." (`invoice_number`, `po_number`)
5. **Source mix and trend:** "Monthly invoice count and amount by source system and region." (`source_system`, `invoice_date`, `currency_code`)

## Guardrails

**Data scope**
- The only tool is Cortex Analyst over `SV_AP_INVOICES`. No web search, no Bronze tables.

**Currency**
- Never add amounts across currencies. Always group by `currency_code`. If asked for a single "total", explain that FX conversion lives in Gold and isn't available yet.
- No guessing exchange rates. Point >$500K review questions to the DMF.

**What the table can't answer**
- Payments: no "paid", "overdue payment" or days-to-pay answers. Say plainly that there's no payment data.
- Cross-system vendor totals: `vendor_id` is per source system; don't merge vendors by name.
- No unified chart of accounts: `source_gl_account` and `source_cost_center` are raw codes. Never translate them between systems.

**Answer style**
- **Dates:** if a relative period returns no rows, state the date range the data actually covers.
- **Status values:** use the normalized `approval_status` (APPROVED / PENDING). Mention `source_status` only when the user asks about the raw value.
- **Show the basis:** every numeric answer states its filters, currency and row count, and shows the SQL it ran.
- **Read-only:** the agent never approves, changes or writes anything.

## Semantic view descriptions

| Element | Description / synonyms |
|---|---|
| Table | One row per AP invoice from SAP, Oracle, Baan (EMEA) and Workday (Americas + London). Amounts in the original currency. Current state only; no payment data. |
| `invoice_key` | Primary key, `<SOURCE>\|<id>`. Unique across systems. |
| `invoice_number` | Business-facing invoice number. Synonyms: invoice #, invoice ref, document number. |
| `source_system` | SAP, ORACLE, BAAN, WORKDAY. Synonyms: ERP, source, system. Region hint: BAAN = EMEA, WORKDAY = Americas + UK. |
| `vendor_id` / `vendor_name` | Synonyms: supplier, payee. IDs are only unique within one source system. |
| `invoice_amount` | Gross invoice amount in `currency_code`. Not FX-converted; never sum across currencies. |
| `currency_code` | ISO 4217 code (USD, EUR, GBP). |
| `approval_status` | APPROVED or PENDING. Synonyms: approved, posted, validated → APPROVED; in review, awaiting approval → PENDING. |
| `payment_terms` | NET30 / NET60, normalized across sources. Synonyms: terms, net days. |
| `due_date` | When payment is due. Doesn't mean the invoice is unpaid or overdue. |
| `invoice_date` | Date on the invoice. Default time dimension. |
| `source_gl_account`, `source_cost_center` | Raw source codes; formats differ by system (GL-NNN, LA-NNNN). Not mapped across systems. |
| `po_number` | Purchase order reference; may be NULL for service invoices. |
| `source_company_code`, `sap_document_type`, `oracle_entry_source` | Specific to one source system. Hide from the agent or mark as SAP/Oracle-only. |

**Metrics**
- `invoice_count`
- `total_invoice_amount` (always grouped by `currency_code`)
- `pending_invoice_count` / `pending_amount`
- `avg_invoice_amount`

**Saved example queries:** one per top-five question to start.

**Filter:** `due_next_30_days` = `due_date BETWEEN CURRENT_DATE AND CURRENT_DATE + 30`. With the 2025 data it currently returns nothing; that's where the date-coverage rule applies.

## Suggested agent instructions (short version)

> You answer AP invoice questions using only the AP invoices semantic view. Group money by currency. State the date range and filters behind every answer. If a question needs payment status, FX conversion or matching vendors across systems, say that the data doesn't support it.

## Next steps

1. Build `COCO_WORKSHOP.PIPELINE_LAB.SV_AP_INVOICES` with these descriptions, metrics and saved example queries; validate it.
2. Create the agent with these instructions and the Cortex Analyst tool.
3. Test with the five questions plus edge cases: a cross-currency total, "overdue", "this month".
