# PRD-Driven Update: Review Artifacts

Change: add **Baan IV** and **Workday** as AP invoice sources to
`COCO_WORKSHOP.PIPELINE_LAB.SILVER_AP_INVOICES` (applied and validated 2026-10-20).

> ⚠️ None of these files are committed yet (`git status`: all untracked). Commit them together so the review has one consistent snapshot.

## 1. Inputs (the PRD)

| Artifact | Purpose | Status |
|---|---|---|
| `sample_business_requirements_source_onboarding.csv` | Which new sources, regions, ingestion timing, blockers (SRC-2025-003/004) | ✅ in repo |
| `sample_business_requirements_business_rules.csv` | BR-001 … BR-010 (status mapping, no FX, dedup, drops, lag) | ✅ in repo |
| `sample_business_requirements_column_mapping.csv` | Column-level Bronze → Silver mapping for Baan and Workday | ✅ in repo |

## 2. Review the change

| Artifact | Purpose | Status |
|---|---|---|
| `notes/02_prd_change_plan.md` | The plan: summary, mapping table, open questions Q1–Q9, assumptions, DDL delta, results after the change | ✅ in repo |
| `sql/03_silver_ap_invoices_prd_update.sql` | DDL that can be rerun (`CREATE OR ALTER`) plus validation queries V1–V5, with the assumptions in the header | ✅ in repo |
| `.cortex/plans/plan_2026-10-20_0745.md` | The earlier plan that created the original SAP + Oracle version (baseline before this change) | ✅ in repo, but auto-generated; keep it for history or move it to `notes/01_initial_silver_plan.md` |
| Baseline DDL before the change (SAP + Oracle only) | Lets a reviewer diff before and after, or roll back | ❌ **missing**. Save it as `sql/01_silver_ap_invoices_baseline.sql`. The definition is in the plan above; it isn't in `GET_DDL` anymore. |
| Bronze table DDL for `SOURCE_DATA.BRONZE_{SAP,ORACLE,BAAN,WORKDAY}_AP_INVOICES` | Reviewers can check the column names in the mapping against the real tables | ❌ **missing**. Optional: `sql/00_bronze_ddl.sql` via `GET_DDL('TABLE', ...)` |

## 3. Rerun the checks

| Artifact | Purpose | Status |
|---|---|---|
| `sql/03_silver_ap_invoices_prd_update.sql`, "VALIDATION QUERIES" section | V1 reconciliation, uniqueness, amounts · V2 mapping spot-check · V3 required fields · V4 dropped columns are NULL · V5 refresh health | ✅ |
| Expected results | BAAN 10/10, ORACLE 15/15, SAP 15/15, WORKDAY 10/10; all diff/unmapped/dup/amount values = 0; refresh mode INCREMENTAL | ✅ in `notes/02_prd_change_plan.md` §6 and the V1 comment |
| Connection prerequisites | Role ACCOUNTADMIN (owner), warehouse COMPUTE_WH, no default schema, so every name is fully qualified | ⚠️ only implicit. Add a line to `README.md` |

How to rerun: open `sql/03_silver_ap_invoices_prd_update.sql`, skip the `CREATE OR ALTER` (it's already applied), and run V1–V5. Compare the results with §6 of the change plan.

## 4. Reuse the PRD Evaluator skill

| Artifact | Purpose | Status |
|---|---|---|
| `.cortex/skills/prd-to-dynamic-table-plan/SKILL.md` | Project skill: inputs `prd_path`, `target_dynamic_table`; 8-section output; rules for open questions and assumptions; review gate before DDL | ✅ in repo, shows up in `cortex skill list` |
| Example invocation | `Use prd-to-dynamic-table-plan with prd_path=<file> and target_dynamic_table=<FQN>` | ✅ in SKILL.md |
| XLSX sample PRD | The skill officially supports **XLSX only**; this run used the CSV fallback | ❌ **missing**. Combine the 3 CSVs into `prd/ap_invoices_phase2.xlsx` (one sheet each) so the skill's main path can be tested |

### Skill updates suggested by this run
- **Name:** it's registered as `prd-to-dynamic-table-plan`. Users asked for `prd-to-silver` / "PRD Evaluator". Add those names as trigger phrases in the `description`.
- **Column order:** add a note that `CREATE OR ALTER` can't reorder DT columns, so new columns must go last.
- **Already-applied changes:** add a check that the target already reflects the PRD (compare the live DDL with the plan) before applying again.
- **CSV input:** make CSV a supported input (one file per sheet), since that's what the real PRDs arrived as.

## 5. Decisions still open (track outside the repo)

| Item | Owner |
|---|---|
| Sign-off on defaults Q1 (payment terms at Silver), Q2 (keep company columns), Q3 (`approval_status`) | Sarah Chen / David Kim |
| Workday legal agreement DPA-2025-0041 signed? | Jennifer Okafor / Legal |
| TARGET_LAG 1 hour vs DOWNSTREAM (BR-009) | Engineering |

## Suggested final layout

```
.cortex/skills/prd-to-dynamic-table-plan/SKILL.md   # reusable skill
prd/ap_invoices_phase2.xlsx                         # TODO: XLSX version of the PRD
sample_business_requirements_*.csv                  # PRD inputs used for this run
notes/01_initial_silver_plan.md                     # TODO: moved from .cortex/plans/
notes/02_prd_change_plan.md                         # change plan + results
notes/04_prd_update_artifacts.md                    # this file
sql/01_silver_ap_invoices_baseline.sql              # TODO: before-state DDL
sql/03_silver_ap_invoices_prd_update.sql            # applied DDL + validations
```
