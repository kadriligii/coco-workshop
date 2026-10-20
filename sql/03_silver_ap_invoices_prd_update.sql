-- =============================================================================
-- 03_silver_ap_invoices_prd_update.sql
-- Adds Baan IV and Workday as AP invoice sources to SILVER_AP_INVOICES.
-- PRD inputs: sample_business_requirements_source_onboarding.csv,
--             sample_business_requirements_column_mapping.csv,
--             sample_business_requirements_business_rules.csv
-- Plan: notes/02_prd_change_plan.md
-- Status: applied to COCO_WORKSHOP.PIPELINE_LAB on 2026-10-20 (validated).
-- =============================================================================
--
-- HOW NEW SOURCES MAP INTO THE COMMON SCHEMA
-- - One UNION ALL branch per source with a hard-coded source_system literal (BR-007);
--   invoice_key = '<SOURCE>|<id>' keeps IDs from different sources from colliding.
-- - Direct renames: BAN_* and WD_* columns -> common names
--   (supplier -> vendor, WD_MEMO -> description, WD_LEDGER_ACCOUNT -> source_gl_account);
--   amounts cast to NUMBER(18,2).
-- - Normalized: approval_status (Baan POSTED / Workday Approved -> APPROVED,
--   Workday In Review -> PENDING; BR-001); payment_terms (N30 / 'Net 30' -> NET30),
--   with raw value kept in source_payment_terms.
-- - Kept as-is: currency (no FX, BR-002), GL codes and cost centers (BR-006).
-- - Dropped: BAN_COMPANY, WD_TENANT_ID (BR-008); company/system-specific columns
--   are NULL for the new sources.
-- - Baan dedup (BR-003): latest BAN_CREATED per BAN_INVOICE_REF, within the Baan branch only.
--
-- ASSUMPTIONS REQUIRING ENGINEERING REVIEW
-- 1. Payment terms are normalized at Silver (matches the existing DT); BR-005 and the
--    mapping lean toward Gold. Raw value is retained either way.
-- 2. Company/system-specific columns are kept for SAP/Oracle and NULL for Baan/Workday;
--    this conflicts with BR-008 (drop them all).
-- 3. approval_status is the LAST column: CREATE OR ALTER cannot reorder DT columns.
-- 4. Baan QUALIFY is inside a UNION branch (not top-level). Still INCREMENTAL today;
--    watch for full-refresh fallback at scale.
-- 5. TARGET_LAG stays '1 hour' (BR-009 says DOWNSTREAM).
-- 6. Status values outside the mapping become NULL (flagged by V2). Negative Baan
--    credit memos are allowed. Baan cost centers are letter codes (BC-IT), not the
--    BC-XX / BC-XXX formats the PRD describes.
-- 7. Workday go-live depends on legal sign-off for DPA-2025-0041.
-- =============================================================================

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

-- Optional: refresh immediately instead of waiting for TARGET_LAG
-- ALTER DYNAMIC TABLE COCO_WORKSHOP.PIPELINE_LAB.SILVER_AP_INVOICES REFRESH;

-- =============================================================================
-- VALIDATION QUERIES
-- =============================================================================

-- V1 Reconciliation, uniqueness, unmapped values, amounts per source
--    (expect diff / unmapped / dup_keys / dup_nums / amt_diff = 0)
--    Result on 2026-10-20: BAAN 10/10, ORACLE 15/15, SAP 15/15, WORKDAY 10/10, all zeros.
WITH s AS (SELECT source_system, COUNT(*) n, COUNT_IF(approval_status IS NULL OR payment_terms IS NULL) unmapped,
             COUNT(*)-COUNT(DISTINCT invoice_key) dup_keys, COUNT(*)-COUNT(DISTINCT invoice_number) dup_nums, SUM(invoice_amount) amt
           FROM COCO_WORKSHOP.PIPELINE_LAB.SILVER_AP_INVOICES GROUP BY 1),
b AS (SELECT 'SAP' source_system, COUNT(*) n, SUM(INVOICE_AMOUNT) amt FROM COCO_WORKSHOP.SOURCE_DATA.BRONZE_SAP_AP_INVOICES
  UNION ALL SELECT 'ORACLE', COUNT(*), SUM(TOTAL_AMOUNT) FROM COCO_WORKSHOP.SOURCE_DATA.BRONZE_ORACLE_AP_INVOICES
  UNION ALL SELECT 'BAAN', COUNT(DISTINCT BAN_INVOICE_REF), SUM(BAN_AMOUNT) FROM COCO_WORKSHOP.SOURCE_DATA.BRONZE_BAAN_AP_INVOICES
  UNION ALL SELECT 'WORKDAY', COUNT(*), SUM(WD_AMOUNT) FROM COCO_WORKSHOP.SOURCE_DATA.BRONZE_WORKDAY_AP_INVOICES)
SELECT s.source_system, s.n silver, b.n expected, s.n-b.n diff, s.unmapped, s.dup_keys, s.dup_nums, s.amt-b.amt amt_diff
FROM s JOIN b USING (source_system) ORDER BY 1;

-- V2 Status / payment terms mapping spot-check (raw -> normalized; NULL = unmapped)
SELECT source_system, source_status, approval_status, source_payment_terms, payment_terms, COUNT(*)
FROM COCO_WORKSHOP.PIPELINE_LAB.SILVER_AP_INVOICES GROUP BY ALL ORDER BY 1,2;

-- V3 Required fields populated (expect all 0)
SELECT source_system, COUNT_IF(invoice_number IS NULL OR vendor_id IS NULL OR invoice_date IS NULL OR invoice_amount IS NULL
       OR currency_code IS NULL OR source_gl_account IS NULL OR source_cost_center IS NULL OR source_created_at IS NULL) null_required
FROM COCO_WORKSHOP.PIPELINE_LAB.SILVER_AP_INVOICES GROUP BY 1;

-- V4 Dropped columns are NULL for new sources (expect 0)
SELECT COUNT(*) FROM COCO_WORKSHOP.PIPELINE_LAB.SILVER_AP_INVOICES
WHERE source_system IN ('BAAN','WORKDAY') AND (source_company_code IS NOT NULL OR sap_document_type IS NOT NULL OR oracle_entry_source IS NOT NULL);

-- V5 Refresh health: still INCREMENTAL, last refresh SUCCEEDED
SHOW DYNAMIC TABLES LIKE 'SILVER_AP_INVOICES' IN SCHEMA COCO_WORKSHOP.PIPELINE_LAB;
SELECT refresh_action, state, state_message, refresh_start_time
FROM TABLE(COCO_WORKSHOP.INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(NAME => 'COCO_WORKSHOP.PIPELINE_LAB.SILVER_AP_INVOICES'))
ORDER BY refresh_start_time DESC LIMIT 5;
