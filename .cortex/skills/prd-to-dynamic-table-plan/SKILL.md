---
name: prd-to-dynamic-table-plan
description: "Turn PRD-style business requirements workbooks (XLSX) into an implementation plan for a target Snowflake Dynamic Table such as SILVER_AP_INVOICES. Use when: a PRD, requirements spreadsheet, source onboarding sheet, business rules sheet, or column mapping must be translated into Dynamic Table changes; onboarding a new source system into a Silver/Gold DT; reviewing requirements for gaps before implementation. Triggers: PRD to dynamic table, requirements to plan, onboard new source, business rules for silver layer, plan DT changes from spreadsheet, SILVER_AP_INVOICES update."
---

# PRD → Dynamic Table Plan

Converts requirement workbooks into a reviewable change plan for ONE target Dynamic Table.
This skill **plans only** — it never alters Snowflake objects. Implementation is handed to
the bundled `dynamic-tables` skill after the user approves the plan.

## When to Use

- A requirements workbook (sheets like *Source Onboarding*, *Business Rules*, *Column Mapping*) describes changes to a pipeline that lands in a Dynamic Table.
- You need to know *what changes, what is decided, and what is still open* before writing DDL.

Do NOT use for: building a DT from scratch with no requirements doc, DT refresh debugging
(use `dynamic-tables`), or Gold/BI metric design.

## Inputs

| Input | Required | Example | Notes |
|---|---|---|---|
| `prd_path` | yes | `./prd/ap_invoices_q3.xlsx` | XLSX only (v1). Absolute or repo-relative. |
| `target_dynamic_table` | yes | `DEMO.SILVER.SILVER_AP_INVOICES` | Fully qualified preferred; if only a name is given, resolve it and confirm. |
| `sheets` | no | `["Source Onboarding","Business Rules"]` | Default: all sheets. |
| `layer_scope` | no | `silver` | Rules owned by other layers are listed but not planned. |

If `prd_path` is not `.xlsx`, stop and say only XLSX is supported in this version
(CSV exports may be read as a fallback only if the user explicitly agrees).

## Workflow

### Step 1: Load the PRD
- Use the `read` tool on `prd_path` (it parses XLSX natively). If sheet list is unknown, read once, then read each sheet by `sheet_name` with `read_tabular` for structured access.
- Record per sheet: name, row count, column headers. Identify sheet role (onboarding / rules / mapping / other) from headers, not sheet names alone.
- Keep every requirement's own ID (e.g. `SRC-2025-003`, `BR-005`) — all outputs must cite it.

### Step 2: Inspect the current target DT (read-only)
Run with `sql_execute`:
```sql
SHOW DYNAMIC TABLES LIKE '<NAME>' IN SCHEMA <DB>.<SCHEMA>;
SELECT GET_DDL('TABLE', '<DB>.<SCHEMA>.<NAME>');
DESCRIBE TABLE <DB>.<SCHEMA>.<NAME>;
```
Capture: current SELECT/UNION branches, columns + types, TARGET_LAG, refresh mode, upstream Bronze tables (`cortex lineage <FQN> --direction upstream`).
If the DT does not exist or access fails, say so and continue as a **greenfield plan**, labelled as such — do not invent the current definition.

### Step 3: Classify each requirement
For every row, assign exactly one:
- **IN SCOPE – DECIDED**: affects the target DT and has a confirmed owner/decision.
- **IN SCOPE – OPEN**: affects the target DT but is undecided, conflicting, or underspecified.
- **OUT OF SCOPE**: owned by another layer/object (e.g. "implement in Gold", "implement as DMF"). Still list it, with where it goes.
- **INFO**: context only (timing, contacts).

Signals of OPEN: phrases like "OPEN QUESTION", "NEEDS DECISION", "pending", "TBD", "may", "should we", legal/approval blockers, or a rule referencing columns not in the mapping.

### Step 4: Cross-check for gaps
Check every in-scope item against the DT and the other sheets:
- Column referenced by a rule but absent from the mapping or Bronze source.
- Value mappings (status, codes) that don't enumerate all source values — ask about the unmapped ones.
- Dedup/partition keys that collide across UNION ALL branches (should they include `SOURCE_SYSTEM`?).
- Rules that need data the layer is told not to have (e.g. USD thresholds when no FX at this layer).
- Dropped columns whose loss removes a needed grain (entity, tenant, region).
- Format changes over time (old vs new code patterns in history).
- Dates/deadlines already past relative to today; blockers (legal, tickets) with unknown status.
- Case/whitespace sensitivity in literal mappings.

### Step 5: Produce the plan (exact output below)

**⚠️ MANDATORY STOPPING POINT**: Present the plan and the open questions. Do NOT write DDL,
`CREATE OR REPLACE DYNAMIC TABLE`, or any file beyond the plan until the user approves and
answers (or explicitly accepts the stated assumptions for) blocking questions.

### Step 6 (only after approval): Hand off
Optionally save the plan to `plans/<target_name>_<yyyymmdd>.md`. For implementation,
load the `dynamic-tables` skill with the approved plan; run `EXPLAIN CHANGES` / compile-only
before any replace.

## Surfacing Assumptions — Rules

1. **Never fill a gap silently.** If a value, mapping, column, or decision is not in the PRD or the live DT, it is an open question or a labelled assumption — never a fact.
2. **Cite everything.** Each plan item references its requirement ID and sheet; each assumption says what evidence it's based on.
3. **Separate "PRD says" from "I infer".** Use an explicit `Assumption:` prefix for inferences.
4. **Rank questions by impact**: `BLOCKING` (wrong answer = wrong data or rework), `NON-BLOCKING` (can default safely), each with a proposed default and owner (from the PRD's owner column when present).
5. **Plan around open items, don't stall.** Plan everything that's decided; mark dependent steps `⏸ waiting on Q#`.
6. **Flag conflicts, don't resolve them.** When two rows disagree, quote both and ask.
7. **Respect layer boundaries stated in the PRD** — don't pull Gold/DMF work into the Silver DT because it's convenient.

## Output (always, in this order)

```
## PRD → DT Plan: <target_dynamic_table>
Source: <prd_path> (sheets: …) | Target state: existing | greenfield

### 1. Summary
2–4 sentences: what changes and overall readiness (Ready / Ready with assumptions / Blocked).

### 2. New source systems
| Req ID | Source | Platform | Region | Ingestion/arrival | Status/blockers | SOURCE_SYSTEM literal |

### 3. Planned DT changes (in scope – decided)
| # | Req ID | Change | Type (column/branch/CASE/filter/dedup/lag) | SQL sketch |

### 4. Column impact
| Column | Change (add/modify/drop/none) | Source mapping per system | Type | Req ID |

### 5. Out of scope (owned elsewhere)
| Req ID | Item | Owner layer/object |

### 6. Assumptions
A# — statement — evidence — risk if wrong

### 7. Open questions
Q# — BLOCKING|NON-BLOCKING — question — why it matters — proposed default — owner

### 8. Implementation sequence
Ordered steps, with ⏸ markers for steps waiting on Q#; ends with validation steps
(compile-only, EXPLAIN CHANGES, row-count/dup checks per SOURCE_SYSTEM).
```

Empty sections stay in the output with "None identified" — never drop a section.

## Example Usage

User:
> Use prd-to-dynamic-table-plan with prd_path=./prd/ap_invoices_phase2.xlsx and
> target_dynamic_table=DEMO.SILVER.SILVER_AP_INVOICES

Expected shape of the result (abridged):

- **New sources**: `SRC-2025-003` Baan IV (EMEA, nightly CSV → S3 ~02:00 UTC, `'BAAN'`); `SRC-2025-004` Workday (Americas + London tenant WD-T2, hourly, blocked on DPA-2025-0041, `'WORKDAY'`).
- **Planned changes**: add BAAN and WORKDAY `UNION ALL` branches (BR-007); extend status CASE: `POSTED→APPROVED`, `Approved→APPROVED`, `In Review→PENDING` (BR-001); Baan-branch dedup `QUALIFY ROW_NUMBER() OVER (PARTITION BY INVOICE_NUMBER ORDER BY CREATED_AT DESC)=1` (BR-003); drop `BAN_COMPANY`, `WD_TENANT_ID` (BR-008); keep original currency and GL codes (BR-002, BR-006); TARGET_LAG stays DOWNSTREAM (BR-009).
- **Out of scope**: >$500K flag → Guardrails DMF (BR-004); FX → Gold (BR-002); CoA mapping → Phase 2 (BR-006).
- **Open questions**:
  - Q1 BLOCKING — Payment terms normalize at Silver or Gold? (BR-005; default: as-is at Silver; owner Sarah Chen / David Kim)
  - Q2 BLOCKING — Dedup partition: Baan branch only, or include SOURCE_SYSTEM? Confirm BAN_INVOICE_REF→INVOICE_NUMBER (BR-003)
  - Q3 BLOCKING — Unmapped statuses (rejected/cancelled/draft) in Baan & Workday? (BR-001)
  - Q4 NON-BLOCKING — Keep entity/tenant grain if WD_TENANT_ID is dropped? (BR-008, SRC-2025-004)
  - Q5 NON-BLOCKING — BC-XX vs BC-XXX cost centers: store as-is? (SRC-2025-003)
- **Sequence**: Baan branch first (approved) → Workday branch ⏸ Q-legal → validate per-source counts and duplicate check.

## Stopping Points
- ✋ After Step 1 if the file isn't XLSX or the target DT can't be resolved to one object.
- ✋ After Step 5 — plan review; no DDL until approved.
