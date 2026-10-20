# PRD → DT Change Plan: `COCO_WORKSHOP.PIPELINE_LAB.SILVER_AP_INVOICES`

- **Skill:** `prd-to-dynamic-table-plan` (project skill, `.cortex/skills/`)
- **Source:** `sample_business_requirements_column_mapping.csv` (CSV fallback, explicitly requested), cross-checked with `sample_business_requirements_source_onboarding.csv` and `sample_business_requirements_business_rules.csv`
- **Date:** 2026-10-20
- **Status:** **APPLIED** with default answers to Q1–Q3 (pending owner sign-off)

## 1. Summary of requested changes

The mapping adds **Baan IV** and **Workday** to the existing SAP + Oracle Silver DT. 30 of 32 mapping rows are Confirmed; only payment terms (Baan and Workday) are open. Bronze tables `SOURCE_DATA.BRONZE_BAAN_AP_INVOICES` and `SOURCE_DATA.BRONZE_WORKDAY_AP_INVOICES` already existed (10 rows each), with columns matching the mapping exactly.

Differences between the live DT and the PRD:
- **Payment terms:** the DT already normalized them at Silver (`payment_terms`, with raw `source_payment_terms`). The PRD says normalize in Gold.
- **Status:** the DT had only raw `source_status`. There was no normalized `APPROVAL_STATUS` column.
- **Company and system-specific columns:** the DT keeps `source_company_code`, `sap_document_type` and `oracle_entry_source`. BR-008 says drop them.
- **Refresh:** `TARGET_LAG = '1 hour'`, not DOWNSTREAM as BR-009 says.

## 2. Source-to-Silver mapping summary

| Silver column | BAAN | WORKDAY | Transform |
|---|---|---|---|
| source_system | `'BAAN'` | `'WORKDAY'` | literal |
| invoice_key | `'BAAN\|'‖BAN_INVOICE_ID` | `'WORKDAY\|'‖WD_INVOICE_ID` | same pattern as the existing DT |
| source_invoice_id | BAN_INVOICE_ID | WD_INVOICE_ID | direct |
| invoice_number | BAN_INVOICE_REF | WD_INVOICE_NUM | direct; Baan dedup key |
| vendor_id / vendor_name | BAN_VENDOR_CODE / BAN_VENDOR_DESC | WD_SUPPLIER_ID / WD_SUPPLIER_NAME | direct (UTF-8 is native) |
| invoice_date / due_date | BAN_INV_DATE / BAN_PAY_DATE | WD_INVOICE_DATE / WD_DUE_DATE | direct |
| invoice_amount | BAN_AMOUNT | WD_AMOUNT | cast to `NUMBER(18,2)` |
| currency_code | BAN_CURR (EUR, GBP) | WD_CURRENCY (USD, GBP, EUR) | direct, no FX |
| payment_terms | N30/N60 → NET30/NET60 | `Net 30`/`Net 60` → NET30/NET60 | follows the existing DT pattern |
| source_payment_terms | BAN_PAY_TERMS | WD_PAY_TERMS | raw |
| po_number | BAN_PO_REF | WD_PO_NUMBER | nullable |
| description | BAN_LINE_DESC | WD_MEMO | nullable |
| source_gl_account | BAN_GL_CODE | WD_LEDGER_ACCOUNT | raw, no cross-map |
| source_cost_center | BAN_COST_CTR | WD_COST_CENTER | raw |
| source_status | BAN_STATUS | WD_APPROVAL_STATUS | raw |
| source_company_code / sap_document_type / oracle_entry_source | NULL (BAN_COMPANY dropped) | NULL (WD_TENANT_ID dropped) | per mapping |
| source_created_at | BAN_CREATED (UTC) | WD_CREATED_DATE (UTC) | direct |
| **approval_status (new, last column)** | POSTED/APPROVED → APPROVED, PENDING → PENDING | Approved → APPROVED, In Review → PENDING | CASE on `UPPER(TRIM())` |

## 3. Open questions and assumptions

### Open questions

| # | Priority | Question | Default applied / owner |
|---|---|---|---|
| Q1 | BLOCKING | Payment terms: should Silver keep normalizing them? The PRD says Gold; the live DT normalizes today. | Kept the existing pattern (normalized plus raw). Owner: Sarah Chen / David Kim |
| Q2 | BLOCKING | BR-008 says drop company and system-specific columns, but the DT keeps them for SAP/Oracle. | Kept the columns and NULLed them for the new sources. Owner: David Kim |
| Q3 | BLOCKING | Should the new `approval_status` column be added? | Added. Owner: Sarah Chen |
| Q4 | NON-BLOCKING | Should TARGET_LAG change from 1 hour to DOWNSTREAM? | Left at 1 hour |
| Q5 | NON-BLOCKING | Baan cost centers in Bronze are letter codes (`BC-IT`, `BC-MFG`), not the `BC-XX`/`BC-XXX` formats in the PRD. | Stored as-is |
| Q6 | NON-BLOCKING | Status values outside the mapping? | Set to NULL; validation query flags them |
| Q7 | NON-BLOCKING | Baan amounts: "always positive" vs "credit memos are negative"? | Negatives allowed, not filtered |
| Q8 | NON-BLOCKING | Dropping WD_TENANT_ID loses the US vs London split. | Accepted; join back to Bronze if needed |
| Q9 | INFO | Is the Workday DPA (DPA-2025-0041) signed? | Confirm before go-live |

### Assumptions
- **A1:** Payment terms follow the existing DT pattern. The raw value is kept, so either Q1 answer still works.
- **A2:** Baan dedup is scoped to the Baan branch, partitioned by `BAN_INVOICE_REF`, with `BAN_INVOICE_ID DESC` as a tie-breaker. At planning time Bronze had 0 duplicates and 0 cross-source invoice-number collisions.
- **A3:** The target was resolved to `COCO_WORKSHOP.PIPELINE_LAB` (the only match in the account).
- **Out of scope:** the >$500K DMF (BR-004), FX conversion (Gold), and the chart-of-accounts mapping (Phase 2).

## 4. DDL delta (as applied)

1. Added `approval_status` with CASE mappings for all four sources (SAP direct; Oracle VALIDATED → APPROVED; Baan POSTED → APPROVED; Workday In Review → PENDING). **It's the last column**, because `CREATE OR ALTER` can't reorder DT columns (`Cannot reorder Dynamic Table columns in ALTER`). The first attempt failed and changed nothing.
2. Added the BAAN `UNION ALL` branch with dedup: `QUALIFY ROW_NUMBER() OVER (PARTITION BY BAN_INVOICE_REF ORDER BY BAN_CREATED DESC, BAN_INVOICE_ID DESC) = 1`.
3. Added the WORKDAY branch, with `UPPER(REPLACE(WD_PAY_TERMS,' ',''))` for payment terms.
4. Unchanged: lag 1 hour, INCREMENTAL refresh, COMPUTE_WH. Comment updated.

```sql
CREATE OR ALTER DYNAMIC TABLE COCO_WORKSHOP.PIPELINE_LAB.SILVER_AP_INVOICES
  COMMENT = 'Silver AP invoices: SAP + Oracle + Baan + Workday. approval_status normalized (BR-001); GL/cost center kept as raw source_* values; payment_terms normalized with raw source_payment_terms retained.'
  TARGET_LAG = '1 hour' REFRESH_MODE = INCREMENTAL INITIALIZE = ON_CREATE WAREHOUSE = COMPUTE_WH
AS
SELECT 'SAP' AS source_system, 'SAP|' || INVOICE_ID AS invoice_key, INVOICE_ID AS source_invoice_id, INVOICE_NUMBER AS invoice_number,
       VENDOR_ID AS vendor_id, VENDOR_NAME AS vendor_name, INVOICE_DATE AS invoice_date, DUE_DATE AS due_date,
       INVOICE_AMOUNT AS invoice_amount, CURRENCY_CODE AS currency_code,
       CASE PAYMENT_TERMS WHEN 'NET30' THEN 'NET30' WHEN 'NET60' THEN 'NET60' END AS payment_terms,
       PAYMENT_TERMS AS source_payment_terms, PO_NUMBER AS po_number, LINE_DESCRIPTION AS description,
       GL_ACCOUNT AS source_gl_account, COST_CENTER AS source_cost_center, APPROVAL_STATUS AS source_status,
       SAP_COMPANY_CODE AS source_company_code, SAP_DOCUMENT_TYPE AS sap_document_type,
       NULL::VARCHAR(20) AS oracle_entry_source, CREATED_AT AS source_created_at,
       CASE UPPER(TRIM(APPROVAL_STATUS)) WHEN 'APPROVED' THEN 'APPROVED' WHEN 'PENDING' THEN 'PENDING' END AS approval_status
FROM COCO_WORKSHOP.SOURCE_DATA.BRONZE_SAP_AP_INVOICES
UNION ALL
SELECT 'ORACLE', 'ORACLE|' || INV_ID, INV_ID, INV_NUM, SUPPLIER_ID, SUPPLIER_NAME, INV_DATE, PAYMENT_DUE_DATE,
       TOTAL_AMOUNT, CURRENCY,
       CASE TERMS_CODE WHEN 'N30' THEN 'NET30' WHEN 'N60' THEN 'NET60' END,
       TERMS_CODE, PURCHASE_ORDER, DESCRIPTION, ACCOUNT_CODE, DEPT_CODE, STATUS,
       ORACLE_ORG_ID, NULL::VARCHAR(10), ORACLE_SOURCE, CREATION_DATE,
       CASE UPPER(TRIM(STATUS)) WHEN 'VALIDATED' THEN 'APPROVED' WHEN 'APPROVED' THEN 'APPROVED' WHEN 'PENDING' THEN 'PENDING' END
FROM COCO_WORKSHOP.SOURCE_DATA.BRONZE_ORACLE_AP_INVOICES
UNION ALL
SELECT 'BAAN', 'BAAN|' || BAN_INVOICE_ID, BAN_INVOICE_ID, BAN_INVOICE_REF, BAN_VENDOR_CODE, BAN_VENDOR_DESC, BAN_INV_DATE, BAN_PAY_DATE,
       BAN_AMOUNT::NUMBER(18,2), BAN_CURR,
       CASE UPPER(TRIM(BAN_PAY_TERMS)) WHEN 'N30' THEN 'NET30' WHEN 'N60' THEN 'NET60' END,
       BAN_PAY_TERMS, BAN_PO_REF, BAN_LINE_DESC, BAN_GL_CODE, BAN_COST_CTR, BAN_STATUS,
       NULL::VARCHAR(10), NULL::VARCHAR(10), NULL::VARCHAR(20), BAN_CREATED,
       CASE UPPER(TRIM(BAN_STATUS)) WHEN 'POSTED' THEN 'APPROVED' WHEN 'APPROVED' THEN 'APPROVED' WHEN 'PENDING' THEN 'PENDING' END
FROM COCO_WORKSHOP.SOURCE_DATA.BRONZE_BAAN_AP_INVOICES
QUALIFY ROW_NUMBER() OVER (PARTITION BY BAN_INVOICE_REF ORDER BY BAN_CREATED DESC, BAN_INVOICE_ID DESC) = 1
UNION ALL
SELECT 'WORKDAY', 'WORKDAY|' || WD_INVOICE_ID, WD_INVOICE_ID, WD_INVOICE_NUM, WD_SUPPLIER_ID, WD_SUPPLIER_NAME, WD_INVOICE_DATE, WD_DUE_DATE,
       WD_AMOUNT::NUMBER(18,2), WD_CURRENCY,
       CASE UPPER(REPLACE(WD_PAY_TERMS, ' ', '')) WHEN 'NET30' THEN 'NET30' WHEN 'NET60' THEN 'NET60' END,
       WD_PAY_TERMS, WD_PO_NUMBER, WD_MEMO, WD_LEDGER_ACCOUNT, WD_COST_CENTER, WD_APPROVAL_STATUS,
       NULL::VARCHAR(10), NULL::VARCHAR(10), NULL::VARCHAR(20), WD_CREATED_DATE,
       CASE UPPER(TRIM(WD_APPROVAL_STATUS)) WHEN 'APPROVED' THEN 'APPROVED' WHEN 'IN REVIEW' THEN 'PENDING' END
FROM COCO_WORKSHOP.SOURCE_DATA.BRONZE_WORKDAY_AP_INVOICES;
```

## 5. Validation queries

```sql
-- V1 Row reconciliation per source (Baan expected = distinct refs)
SELECT s.source_system, s.n silver, b.n bronze, s.n - b.n diff FROM
 (SELECT source_system, COUNT(*) n FROM COCO_WORKSHOP.PIPELINE_LAB.SILVER_AP_INVOICES GROUP BY 1) s
JOIN (SELECT 'SAP' source_system, COUNT(*) n FROM COCO_WORKSHOP.SOURCE_DATA.BRONZE_SAP_AP_INVOICES
      UNION ALL SELECT 'ORACLE', COUNT(*) FROM COCO_WORKSHOP.SOURCE_DATA.BRONZE_ORACLE_AP_INVOICES
      UNION ALL SELECT 'BAAN', COUNT(DISTINCT BAN_INVOICE_REF) FROM COCO_WORKSHOP.SOURCE_DATA.BRONZE_BAAN_AP_INVOICES
      UNION ALL SELECT 'WORKDAY', COUNT(*) FROM COCO_WORKSHOP.SOURCE_DATA.BRONZE_WORKDAY_AP_INVOICES) b USING (source_system);

-- V2 Key uniqueness (expect 0 rows)
SELECT invoice_key, COUNT(*) FROM COCO_WORKSHOP.PIPELINE_LAB.SILVER_AP_INVOICES GROUP BY 1 HAVING COUNT(*) > 1;
SELECT source_system, invoice_number, COUNT(*) FROM COCO_WORKSHOP.PIPELINE_LAB.SILVER_AP_INVOICES GROUP BY 1,2 HAVING COUNT(*) > 1;

-- V3 Unmapped status / payment terms (expect 0 rows)
SELECT source_system, source_status, source_payment_terms, COUNT(*) FROM COCO_WORKSHOP.PIPELINE_LAB.SILVER_AP_INVOICES
WHERE approval_status IS NULL OR payment_terms IS NULL GROUP BY ALL;

-- V4 Required columns not null (expect all 0)
SELECT source_system, COUNT_IF(invoice_number IS NULL) inv, COUNT_IF(vendor_id IS NULL) vendor, COUNT_IF(invoice_date IS NULL) dt,
       COUNT_IF(invoice_amount IS NULL) amt, COUNT_IF(currency_code IS NULL) ccy, COUNT_IF(source_gl_account IS NULL) gl,
       COUNT_IF(source_cost_center IS NULL) cc, COUNT_IF(source_created_at IS NULL) created
FROM COCO_WORKSHOP.PIPELINE_LAB.SILVER_AP_INVOICES GROUP BY 1;

-- V5 Amount fidelity vs Bronze (expect 0)
SELECT 'BAAN', SUM(invoice_amount) - (SELECT SUM(BAN_AMOUNT) FROM COCO_WORKSHOP.SOURCE_DATA.BRONZE_BAAN_AP_INVOICES)
FROM COCO_WORKSHOP.PIPELINE_LAB.SILVER_AP_INVOICES WHERE source_system = 'BAAN'
UNION ALL SELECT 'WORKDAY', SUM(invoice_amount) - (SELECT SUM(WD_AMOUNT) FROM COCO_WORKSHOP.SOURCE_DATA.BRONZE_WORKDAY_AP_INVOICES)
FROM COCO_WORKSHOP.PIPELINE_LAB.SILVER_AP_INVOICES WHERE source_system = 'WORKDAY';

-- V6 Status distribution
SELECT source_system, approval_status, COUNT(*) FROM COCO_WORKSHOP.PIPELINE_LAB.SILVER_AP_INVOICES GROUP BY ALL ORDER BY 1,2;

-- V7 Refresh health
SHOW DYNAMIC TABLES LIKE 'SILVER_AP_INVOICES' IN SCHEMA COCO_WORKSHOP.PIPELINE_LAB;
SELECT refresh_action, state, state_message, refresh_start_time FROM TABLE(COCO_WORKSHOP.INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(NAME => 'COCO_WORKSHOP.PIPELINE_LAB.SILVER_AP_INVOICES')) ORDER BY refresh_start_time DESC LIMIT 5;
```

## 6. Results after implementation (2026-10-20)

Manual refresh: 50 rows inserted, 30 deleted. This was a one-time `REINITIALIZE` after the definition change, and it SUCCEEDED.

| Source | Silver rows | Expected | Approved | Pending | Unmapped | Duplicate keys or numbers | Missing required values | Amount difference |
|---|---|---|---|---|---|---|---|---|
| BAAN | 10 | 10 | 9 | 1 | 0 | 0 | 0 | 0.00 |
| ORACLE | 15 | 15 | 13 | 2 | 0 | 0 | 0 | 0.00 |
| SAP | 15 | 15 | 11 | 4 | 0 | 0 | 0 | 0.00 |
| WORKDAY | 10 | 10 | 8 | 2 | 0 | 0 | 0 | 0.00 |

- Refresh mode is still **INCREMENTAL** (`refresh_mode_reason` = None). The `QUALIFY` inside the Baan branch did not force a full refresh.
- The stored DT text still shows the old comment in its header, but the `comment` property is updated. Cosmetic only.

## 7. Follow-ups
- Get sign-off on the defaults applied for Q1–Q3 from Sarah Chen and David Kim.
- Confirm Workday DPA-2025-0041 is signed before treating Workday data as production.
- Consider scheduling V1–V7 (e.g. daily, after the ~02:00 UTC Baan load) as a `cortex automation`.
