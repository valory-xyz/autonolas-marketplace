# Mech Analytics ETL Service — Spec

Phase 1 sub-phase 2 of the off-chain marketplace migration. This document covers the Analytics ETL, the Metrics Postgres, and the Wildcard API. It pairs with `docs/marketplace_api_spec.md`, which owns the on-chain and HTTP marketplace surface that produces the rows this ETL consumes.

Written for any reviewer (engineer, PM, ops). Assumes you have read at most the TL;DR of `marketplace_api_spec.md`.

---

## 1. TL;DR

Today three different consumers (olas-website, townhall-kpis, mech-predict) each pull raw data from IPFS and subgraphs and compute their own metrics on the fly. That work is duplicated, slow, fragile (IPFS hangs, fuzzy title matches), and breaks the moment we stop publishing content to IPFS in Phase 2.

We replace that with one Python service that reads the predict-api data lake, joins market resolutions from Omen + Polymarket subgraphs, computes every metric once, and stores the answers in a small dedicated Postgres. A public FastAPI in front of that Postgres serves three read endpoints (agent economy, tool quality, instance distribution) that every consumer reads from.

Net effect: one place computes metrics, every consumer just reads the answer.

---

## 2. Why this exists

### The before picture

```
                       Omen subgraph
                            │
                            │ + IPFS gateway + marketplace subgraph
                            ▼
  olas-website  ─────────►  Browser-side computation (TS), cached 12h
                            │
                            ▼
                       User sees Brier / ROI / tool accuracy


                       Omen subgraph + Polymarket subgraph
                            │
                            ▼
  townhall-kpis ─────────►  Next.js API route computation (TS)
                            │
                            ▼
                       Internal KPI dashboard


                       Marketplace subgraph + IPFS gateway +
                       Omen subgraph + Polymarket Gamma
                            │
                            ▼
  mech-predict  ─────────►  scorer.py in nightly CI (Python)
                            │
                            ▼
                       Daily report markdown + scores.json
```

Three pipelines. Each rebuilds the same wheel. Each is slow (IPFS gateway latency dominates). Each does a fuzzy `questionTitle` join because the data sources do not carry market_id consistently.

Worse, once Phase 2 of the migration flips the default to offchain, the marketplace subgraph stops populating `ParsedRequest.prompt`, `ParsedRequest.tool`, and the IPFS content fields. All three pipelines break.

### The after picture

```
  predict-api Postgres (data lake)
     mech_requests, mech_responses
     predictions (pearl-mini)
                │
                │ read-only role
                ▼
  ┌──────────────────────────────┐        Omen subgraph
  │                              │ ◄──── fixedProductMarketMaker resolutions
  │   Analytics ETL service      │
  │   (Python, APScheduler)      │ ◄──── Polymarket subgraph + Gamma API
  │                              │
  │   1. score new rows  (5min)  │ ◄──── Omen FPMM trades
  │   2. roll up         (15min) │ ◄──── Polymarket FPMM trades
  │   3. late resolution (15min) │
  └──────────────────────────────┘
                │
                │ writes
                ▼
  Metrics Postgres (small, dedicated)
     per_request_scores
     tool_aggregates
     agent_aggregates
     mech_aggregates
     chain_aggregates
     cursor_state
                │
                │ read-only via DB connection
                ▼
  Wildcard API (FastAPI, Cloudflare in front)
     GET /metrics/ai-agent/{ai_agent_name}
     GET /metrics/tool/{tool_name}
     GET /metrics/ai-agent/{ai_agent_name}/instances
                │
                ├──► olas-website   (replaces 3 metric files)
                ├──► townhall-kpis  (replaces NewMechFees + LegacyMechFees + PredictTrades joins)
                └──► mech-predict   (daily report thin client; recompute path still goes direct SQL)
```

One pipeline. Each consumer reads pre-computed JSON. No subgraph or IPFS calls at consumer time.

---

## 3. The three consumers, before vs after

### Consumer 1: olas-website

Files today:
- `common-util/api/predict/tool-accuracy.ts`
- `common-util/api/predict/omenstrat-roi.ts`
- `common-util/api/predict/polystrat-roi.ts`

Today's flow:
1. GraphQL the marketplace subgraph for mech deliveries in the window.
2. For each delivery, hit IPFS for `p_yes`.
3. GraphQL Omen for resolved `currentAnswer`.
4. Fuzzy-match by `questionTitle` to FPMM trades.
5. Compute Brier and ROI in TypeScript. Cache in browser 12h.

After:
1. `fetch(WILDCARD_API + '/metrics/ai-agent/omenstrat')` returns a JSON with `tool_accuracy`, `roi`, `brier`, fully formed.
2. Pick the fields, render. Done.

The fuzzy title join is gone because the ETL joins on `market_id` from `mech_requests.raw_content.extras.market_id` (request schema v2.0+ already carries it).

### Consumer 2: townhall-kpis

Today:
- `NewMechFeesQuery` + `LegacyMechFeesQuery` on the autonolas-subgraph for fee totals per chain.
- `PredictTradesQuery` for FPMM trades.
- Fuzzy `questionTitle` join in `roi.ts:54-56`.
- ROI math in `roi.ts`.

After:
- One call to `GET /metrics/ai-agent/{agent}` returns mech fees per chain (legacy snapshot + live ETL, merged) and per-agent ROI in the same response.
- Live fee totals come from `chain_aggregates` rows with `source='etl_live'`. Legacy fee totals come from `chain_aggregates` rows with `source='legacy_snapshot'`, loaded once at legacy-subgraph decommission and never updated again.
- Per-agent ROI comes from `agent_aggregates`.

Legacy snapshot: since all legacy mechs are down, `LegacyMechFeesQuery` is not ported to the ETL. At decommission date T we run the query one last time, store the raw response plus a SHA-256 hash of it alongside the resulting `chain_aggregates` rows for audit, and shut the legacy subgraph down. Rolling windows (24h / 7d / 30d) drop the legacy contribution naturally as the window slides past `T + window_size`; the `all` window always includes it. See `docs/mech_analytics_etl_schema.md` §7 for the merge semantics and the `source` column.

### Consumer 3: mech-predict

Two paths.

**Daily report (normal scoring path)**: today reads from marketplace subgraph + IPFS + Omen subgraph + Polymarket Gamma. After: reads precomputed scores from `GET /metrics/ai-agent/{agent}` and renders a markdown report.

**Recompute path (prompt sweeps, `--code-change`)**: today reads from subgraph + IPFS. After: direct read-only SQL against the predict-api data lake (no Wildcard API hop because this is internal and needs raw rows, not aggregates). The ETL does not own this path; mech-predict reads `mech_requests JOIN mech_responses` directly.

---

## 4. Inputs

Five input sources. Three are queried live every cycle. Two are queried in batch during backfill or roll-up.

### 4.1 predict-api data lake (Postgres, read-only)

Already merged in PRs #160, #161, #162. Tables:

| Table | Used for |
|-------|----------|
| `mech_requests` | Pull tool, requester, priority_mech, market_id (from `raw_content`), requested_at |
| `mech_responses` | Pull p_yes/p_no/confidence (from `raw_content.result`), status, delivered_at |
| `predictions` (pearl-mini) | Cross-reference pearl-mini rows by request_id for joint metrics |

Connection: a new read-only Postgres role `mech_analytics_reader` (see §11) with `SELECT` on the three tables above. No write access ever.

### 4.2 Omen subgraph (GraphQL, live per cycle)

Entity: `fixedProductMarketMaker`.

Fields the ETL reads:

| Field | Type | Use |
|-------|------|-----|
| `id` | bytes | market address; key for joining to mech requests' `market_id` |
| `currentAnswer` | bytes | resolved outcome (hex). `null` if unresolved. `int(currentAnswer, 16)` gives 0 or 1 for binary markets |
| `currentAnswerTimestamp` | BigInt | resolution time |
| `outcomes` | string[] | `["Yes", "No"]` for binary |
| `title` | string | market question |
| `outcomeTokenMarginalPrices` | string[] | per-outcome prices; element [0] is the implied probability of outcome 0 (the "Yes" market prob at the time of the snapshot) |
| `creationTimestamp`, `openingTimestamp` | BigInt | for category windowing |
| `category` | string | often empty in practice; not load-bearing |
| `outcomeSlotCount` | int | filter to 2 (binary only for now) |

Resolution decoding: `outcome = int(currentAnswer, 16)`. For binary markets, 0 means outcome index 0 won, 1 means outcome index 1 won. The ETL stores `resolved_outcome` as 1.0 if the "Yes" outcome won and 0.0 otherwise. (Outcomes array convention: index 0 is always "Yes" in Omen by the bot's contract.)

### 4.3 Polymarket subgraph + Gamma API (GraphQL + REST, live per cycle)

Two sources, matching mech-predict's existing logic. Subgraph is primary, Gamma is fallback.

Subgraph entity: `questions`.

| Field | Type | Use |
|-------|------|-----|
| `id` | string | condition_id; key for joining |
| `metadata.title` | string | market question |
| `metadata.outcomes` | string[] | `["Yes", "No"]` |
| `resolution.winningIndex` | int | direct 0/1 outcome; null if unresolved |
| `resolution.blockTimestamp` | BigInt | resolution time |

Gamma fallback: `GET https://gamma-api.polymarket.com/markets?condition_ids={id}&closed=true`. Used when the subgraph returns no resolution but the Gamma `resolved` flag is true. Read `outcomes` array index where `prices[i] >= 0.99` to get the winning outcome.

The ETL maps both to a unified `resolved_outcome` (1.0 = Yes won, 0.0 = No won).

### 4.4 FPMM trades for ROI (GraphQL, live per cycle)

Required because ROI is computed against actual bets placed by omenstrat/polystrat agents, not against mech requests.

**Omen FPMM trades** (autonolas-subgraph, `fpmmTrades` entity):

| Field | Use |
|-------|-----|
| `id` | trade id |
| `creator` | trader address; matched against agent's Safe |
| `fpmm.id` | market id; joins to mech requests' `market_id` |
| `fpmm.currentAnswer` | resolution at trade time |
| `outcomeIndex` | which outcome the trader bought |
| `collateralAmount` | USDC spent (wei, 18 decimals) |
| `outcomeTokensTraded` | conditional tokens received |
| `feeAmount` | fee paid |
| `creationTimestamp` | when the trade happened |

**Polymarket FPMM trades** (similar shape on Polymarket's subgraph; mirrors `Activity` / `Trade` entities). Same fields conceptually.

Per-trade ROI math is in §7.9.

### 4.5 Per-tool / per-mech metadata (manifest CID, one-shot cache)

Tool category (`prediction-request`, `prediction-online`, etc.) and per-mech metadata come from the IPFS-published manifest. Read once per mech on service start, cache for 24h. Used to enrich tool aggregates with `platform` and `category` fields.

---

## 5. Outputs (Metrics Postgres tables)

Small, dedicated Postgres instance. One database. Six tables. Migrations land in the ETL repo via alembic.

### 5.1 `per_request_scores`

One row per delivered prediction request. The fine-grained table that gives us slicing flexibility later (e.g. "Brier for high-confidence only", "edge by market category").

Partitioned monthly by `requested_at` once row count exceeds ~10M.

```sql
CREATE TABLE per_request_scores (
    request_id              TEXT        PRIMARY KEY,
    tool                    TEXT        NOT NULL,
    mech_address            TEXT        NOT NULL,
    requester               TEXT        NOT NULL,
    chain_id                INTEGER     NOT NULL,
    market_id               TEXT,
    platform                TEXT,                      -- 'omen' | 'polymarket' | NULL if unmatched
    p_yes                   DOUBLE PRECISION,
    p_no                    DOUBLE PRECISION,
    confidence              DOUBLE PRECISION,
    market_prob_at_prediction DOUBLE PRECISION,        -- from mech request raw_content if present
    resolved_outcome        DOUBLE PRECISION,          -- 1.0 = Yes won, 0.0 = No won, NULL if unresolved
    resolved_at             TIMESTAMPTZ,               -- when market resolved on-chain
    brier                   DOUBLE PRECISION,          -- NULL until resolved
    log_loss                DOUBLE PRECISION,          -- NULL until resolved
    edge                    DOUBLE PRECISION,          -- NULL until resolved
    directional_correct     BOOLEAN,                   -- NULL until resolved
    calibration_bin         INTEGER,                   -- 0..9 by p_yes, NULL if p_yes is NULL
    no_signal_flag          BOOLEAN     NOT NULL,      -- TRUE if p_yes == 0.5 exactly
    prediction_parse_status TEXT        NOT NULL,      -- 'valid' | 'malformed' | 'missing_fields' | 'error'
    requested_at            TIMESTAMPTZ NOT NULL,
    delivered_at            TIMESTAMPTZ NOT NULL,
    computed_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_resolution_check_at TIMESTAMPTZ
);

CREATE INDEX prs_tool_requested_at_idx ON per_request_scores (tool, requested_at DESC);
CREATE INDEX prs_requester_requested_at_idx ON per_request_scores (requester, requested_at DESC);
CREATE INDEX prs_market_idx ON per_request_scores (market_id) WHERE market_id IS NOT NULL;
CREATE INDEX prs_unresolved_idx ON per_request_scores (last_resolution_check_at)
    WHERE resolved_outcome IS NULL;
CREATE INDEX prs_platform_resolved_idx ON per_request_scores (platform, resolved_at DESC)
    WHERE resolved_outcome IS NOT NULL;
```

### 5.2 `tool_aggregates`

Rolled-up per (tool, platform, window).

```sql
CREATE TABLE tool_aggregates (
    id                  BIGSERIAL   PRIMARY KEY,
    tool                TEXT        NOT NULL,
    platform            TEXT        NOT NULL,           -- 'omen' | 'polymarket' | 'all'
    window_kind         TEXT        NOT NULL,           -- '7d' | '30d' | 'all'
    window_start        TIMESTAMPTZ NOT NULL,
    window_end          TIMESTAMPTZ NOT NULL,
    n_predictions       INTEGER     NOT NULL,
    n_resolved          INTEGER     NOT NULL,
    mean_brier          DOUBLE PRECISION,
    mean_log_loss       DOUBLE PRECISION,
    mean_edge           DOUBLE PRECISION,
    edge_positive_count INTEGER,
    directional_accuracy DOUBLE PRECISION,
    ece                 DOUBLE PRECISION,
    bss                 DOUBLE PRECISION,
    calibration_curve   JSONB,                          -- array of {bin, lo, hi, count, avg_predicted, realized_rate, gap}
    no_signal_rate      DOUBLE PRECISION,
    computed_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tool, platform, window_kind, window_end)
);
```

### 5.3 `agent_aggregates`

Rolled-up per (agent, window).

```sql
CREATE TABLE agent_aggregates (
    id                      BIGSERIAL   PRIMARY KEY,
    agent_address           TEXT        NOT NULL,       -- the Safe address
    agent_name              TEXT,                       -- 'optimus' | 'omenstrat' | 'polystrat' | ...
    window_kind             TEXT        NOT NULL,
    window_start            TIMESTAMPTZ NOT NULL,
    window_end              TIMESTAMPTZ NOT NULL,
    n_mech_requests         INTEGER     NOT NULL,
    mech_fee_usd            DOUBLE PRECISION,
    n_mech_requests_settled INTEGER,                    -- subset of n_mech_requests whose joined market has resolved
    mech_fee_usd_settled    DOUBLE PRECISION,           -- fees for that settled subset
    n_bets_omen             INTEGER,
    n_bets_polymarket       INTEGER,
    roi_omen                DOUBLE PRECISION,           -- (payout - cost) / cost, aggregated
    roi_polymarket          DOUBLE PRECISION,
    tool_accuracy_omen      DOUBLE PRECISION,           -- mean directional accuracy on Omen
    tool_accuracy_polymarket DOUBLE PRECISION,
    computed_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (agent_address, window_kind, window_end)
);
```

The `agent_name` column is what the Wildcard API uses to resolve human-readable agent names. Populated from a small static mapping (Safe address to agent name) maintained in the ETL repo.

`n_mech_requests` and `mech_fee_usd` are computed over **all** `mech_requests` rows for the Safe, not just rows that produced a `per_request_scores` entry. A requester that never makes prediction requests (e.g. optimus) still gets counts and fees; its ROI and tool-accuracy columns are simply NULL. The `_settled` variants count only requests whose joined market has resolved (`resolved_outcome IS NOT NULL` on the corresponding `per_request_scores` row); requests with no market join are excluded from the settled variants. See §7.13 for why the settled split exists.

### 5.4 `mech_aggregates`

Rolled-up per (mech, window).

```sql
CREATE TABLE mech_aggregates (
    id                      BIGSERIAL   PRIMARY KEY,
    mech_address            TEXT        NOT NULL,
    window_kind             TEXT        NOT NULL,
    window_start            TIMESTAMPTZ NOT NULL,
    window_end              TIMESTAMPTZ NOT NULL,
    n_deliveries_received   INTEGER     NOT NULL,
    n_self_delivered        INTEGER     NOT NULL,
    mech_fee_usd_earned     DOUBLE PRECISION,
    computed_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (mech_address, window_kind, window_end)
);
```

### 5.5 `chain_aggregates`

Rolled-up per (chain_id, window).

```sql
CREATE TABLE chain_aggregates (
    id                      BIGSERIAL   PRIMARY KEY,
    chain_id                INTEGER     NOT NULL,
    window_kind             TEXT        NOT NULL,
    window_start            TIMESTAMPTZ NOT NULL,
    window_end              TIMESTAMPTZ NOT NULL,
    total_mech_fees_usd     DOUBLE PRECISION,
    total_requests          INTEGER,
    total_deliveries        INTEGER,
    computed_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (chain_id, window_kind, window_end)
);
```

### 5.6 `cursor_state`

One row per ETL job. Atomic with the data writes in the same transaction.

```sql
CREATE TABLE cursor_state (
    job_name                    TEXT        PRIMARY KEY,
    last_processed_request_id   TEXT,
    last_processed_at           TIMESTAMPTZ,
    last_run_at                 TIMESTAMPTZ,
    last_run_status             TEXT,                   -- 'ok' | 'failed' | 'partial'
    last_error                  TEXT,
    rows_processed_last_run     INTEGER
);
```

Jobs that take cursor rows:
- `score_new_rows` (advances per request_id)
- `rollup_tool_aggregates`, `rollup_agent_aggregates`, `rollup_mech_aggregates`, `rollup_chain_aggregates` (each tracks its own last_run_at)
- `late_resolution_sweep`
- `fpmm_trades_ingest_omen`, `fpmm_trades_ingest_polymarket`

---

## 6. Pipeline shape

Three jobs, each on a fixed interval. APScheduler runs them in-process.

### 6.1 Score new rows (every 5 minutes)

```
1. Read cursor_state.last_processed_request_id for job_name='score_new_rows'.
2. SELECT request_id, ... FROM mech_requests r JOIN mech_responses resp
       WHERE r.requested_at > cursor.last_processed_at
       ORDER BY r.requested_at ASC
       LIMIT 5000;
3. For each row:
     a. Parse p_yes/p_no/confidence from resp.raw_content.result (JSON).
     b. Extract market_id from r.raw_content.extras.market_id (request schema v2.0+).
     c. If market_id present:
          - Determine platform (omen vs polymarket) from market_id format.
          - Query the matching subgraph for currentAnswer / winningIndex.
          - If resolved: set resolved_outcome, resolved_at; compute brier / log_loss / edge /
            directional_correct / calibration_bin.
        Else:
          - Insert with NULL resolved_outcome (late resolution sweep picks it up later).
     d. Set no_signal_flag = (p_yes == 0.5).
     e. INSERT INTO per_request_scores ... ON CONFLICT (request_id) DO UPDATE
            SET (resolved fields) = EXCLUDED.(resolved fields) WHERE resolved_outcome was NULL.
4. UPDATE cursor_state SET last_processed_request_id = last_id, last_processed_at = max_ts.
5. All in one transaction so a crash mid-batch does not desync.
```

### 6.2 Late resolution sweep (every 15 minutes)

```
1. SELECT * FROM per_request_scores
       WHERE resolved_outcome IS NULL
         AND requested_at > now() - INTERVAL '90 days'
         AND (last_resolution_check_at IS NULL
              OR last_resolution_check_at < now() - INTERVAL '15 minutes')
       LIMIT 5000;
2. Batch-query each market_id against its platform's subgraph.
3. For markets that resolved since last check:
     UPDATE per_request_scores SET resolved_outcome = ..., brier = ..., log_loss = ...,
            directional_correct = ..., edge = ..., resolved_at = ...,
            last_resolution_check_at = now()
            WHERE request_id = ...;
4. For markets still unresolved:
     UPDATE per_request_scores SET last_resolution_check_at = now()
            WHERE request_id = ...;
```

After 90 days an unresolved market is considered dead (Omen MAY have UMA disputes that drag on, Polymarket similar). Configurable.

### 6.3 Roll-up aggregates (every 15 minutes per family)

For each aggregate family (tool, agent, mech, chain) and each window (7d, 30d, all):

```
1. Read per_request_scores filtered by window.
2. GROUP BY the family key.
3. Compute summary metrics (mean Brier, ECE, BSS, etc.) using the formulas in §7.
4. UPSERT into the family's aggregate table using the (key, window_kind, window_end) unique constraint.
```

Roll-ups are cheap because per_request_scores already has the per-row scores. The aggregates are simple SQL `AVG`, `SUM`, `COUNT` queries plus a Python-side ECE / BSS step.

### 6.4 FPMM trades ingest (every 15 minutes, separate job per platform)

Lives outside per_request_scores because trades are a different entity than predictions.

```
1. Cursor by creationTimestamp.
2. GraphQL fpmmTrades since cursor on each chain.
3. Compute per-trade ROI = (payout - collateral) / collateral.
   (Payout requires the matching FPMM to be resolved; see §7.9.)
4. Group by creator (agent Safe address), window. Roll up into agent_aggregates.roi_omen / .roi_polymarket.
```

---

## 7. Metric math

Every formula below is ported from `mech-predict/benchmark/scorer.py`. The line references are the source of truth; if there is ever a discrepancy between this doc and scorer.py, scorer.py wins (it is the production benchmark).

For each metric, I include:
- the formula in plain symbols
- a worked example with numbers
- the scorer.py line reference

### 7.1 Brier score (per row)

Formula: `brier = (p_yes - outcome)²`. Binary form only. Outcome is 1.0 if Yes won, 0.0 if No won.

Example: tool predicts `p_yes = 0.72`, market resolves Yes (outcome = 1.0). `brier = (0.72 - 1.0)² = 0.0784`.

Range [0, 1]. Lower is better. Perfect = 0.

Source: scorer.py:209-211 `brier_score()`.

### 7.2 Log loss (per row)

Formula:
- If outcome = 1.0: `log_loss = -log(p_yes_clipped)`
- If outcome = 0.0: `log_loss = -log(1 - p_yes_clipped)`

`p_yes_clipped = max(1e-15, min(1 - 1e-15, p_yes))`. Clipping prevents `log(0)` blowing up.

Example: tool predicts `p_yes = 0.72`, market resolves Yes. `log_loss = -log(0.72) = 0.328`.

Source: scorer.py:234-244 `log_loss_score()`.

### 7.3 Directional accuracy (per row)

Rule:
- If `p_yes > 0.5` and outcome = 1.0 → correct
- If `p_yes < 0.5` and outcome = 0.0 → correct
- Otherwise → incorrect
- If `p_yes == 0.5` exactly → excluded (no-signal, counted separately)

Example: `p_yes = 0.72`, outcome = 1.0 → correct. `p_yes = 0.40`, outcome = 1.0 → incorrect. `p_yes = 0.5`, outcome = 1.0 → no-signal, not counted.

Stored as `directional_correct BOOLEAN` per row. Aggregated as `mean(directional_correct)` over rows with `no_signal_flag = FALSE`.

Source: scorer.py:485-496.

### 7.4 No-signal flag (per row)

Rule: `no_signal_flag = (p_yes == 0.5)`. Exact equality, not a band.

Why exact and not a band: matches mech-predict's existing definition so historical numbers stay comparable. We can widen later if needed without re-backfilling (it is a derived flag from p_yes which is stored).

Source: scorer.py:486-488.

### 7.5 Calibration bin (per row)

Ten equal-width bins on p_yes:

| Bin | Range |
|-----|-------|
| 0   | [0.0, 0.1) |
| 1   | [0.1, 0.2) |
| 2   | [0.2, 0.3) |
| 3   | [0.3, 0.4) |
| 4   | [0.4, 0.5) |
| 5   | [0.5, 0.6) |
| 6   | [0.6, 0.7) |
| 7   | [0.7, 0.8) |
| 8   | [0.8, 0.9) |
| 9   | [0.9, 1.01) |

The top bin is `[0.9, 1.01)` so that `p_yes == 1.0` lands in bin 9. Lower-inclusive, upper-exclusive everywhere else.

Stored as `calibration_bin INTEGER` per row. The full calibration curve is reconstructed at roll-up time by grouping per_request_scores by `calibration_bin`.

Source: scorer.py:631-642 `CALIBRATION_BINS`, scorer.py:680 assignment.

### 7.6 Calibration curve (aggregate)

For each bin in a (tool, platform, window) group:

```
count          = number of rows in this bin
avg_predicted  = mean(p_yes) over rows in this bin
realized_rate  = mean(outcome) over rows in this bin
gap            = avg_predicted - realized_rate          (positive = overconfident)
```

Stored as JSONB in `tool_aggregates.calibration_curve`:

```json
[
  {"bin": 0, "lo": 0.0, "hi": 0.1, "count": 12, "avg_predicted": 0.07, "realized_rate": 0.08, "gap": -0.01},
  {"bin": 1, ...},
  ...
]
```

Source: scorer.py:651-703 `compute_calibration()`.

### 7.7 ECE (Expected Calibration Error)

Aggregate metric. Weighted sum of absolute calibration gaps across bins that have at least 20 samples (MIN_CALIBRATION_BIN_SIZE). Bins with fewer samples are excluded entirely.

Formula:
```
N = sum of counts across qualifying bins
ECE = sum over qualifying bins of (count_i / N) * |gap_i|
```

Example: three qualifying bins. Bin 4 has 100 samples with gap 0.05. Bin 7 has 50 samples with gap -0.10. Bin 9 has 30 samples with gap 0.02. N = 180.

`ECE = (100/180)*0.05 + (50/180)*0.10 + (30/180)*0.02 = 0.0278 + 0.0278 + 0.0033 = 0.0589`.

Range [0, 1]. Lower is better. Perfect calibration = 0.

Source: scorer.py:706-726 `compute_ece()`. Constant scorer.py:143 `MIN_CALIBRATION_BIN_SIZE = 20`.

### 7.8 BSS (Brier Skill Score)

Aggregate metric. Compares the group's mean Brier to a baseline.

Baseline: climatology, computed from the group itself. If 60% of markets in the group resolved Yes, the baseline predictor always guesses 0.60, which has Brier = `outcome_yes_rate * (1 - outcome_yes_rate) = 0.60 * 0.40 = 0.24`.

Formula:
```
outcome_yes_rate = mean(outcome) over the group        # fraction of rows where outcome == 1.0
baseline_brier   = outcome_yes_rate * (1 - outcome_yes_rate)
BSS              = 1 - tool_brier / baseline_brier     # NULL if baseline_brier == 0
```

Example: tool has mean Brier 0.18 over 500 rows where 60% resolved Yes. Baseline = 0.24. `BSS = 1 - 0.18/0.24 = 0.25` (25% better than always guessing the base rate).

`BSS = 0` means the tool ties climatology. Negative means worse than climatology.

Returns NULL when `baseline_brier = 0` (happens when all outcomes are identical, e.g. every market resolved Yes). Same convention as scorer.py.

Source: scorer.py:504-509 in `compute_group_stats()`.

### 7.9 Edge (per row, and aggregate)

Per-row formula: `edge = market_brier - tool_brier` where both use the same outcome.

```
market_brier = (market_prob_at_prediction - outcome)²
tool_brier   = (p_yes                      - outcome)²
edge         = market_brier - tool_brier
```

`market_prob_at_prediction` is the market's implied probability of Yes at the moment the tool was asked. Stored in `mech_requests.raw_content.extras.market_prob_at_prediction` for rows written live by the mech, onchain or offchain (request schema v2.0+ writes it). For historical IPFS-backfilled rows, the value may be missing; in that case `edge` stays NULL.

Positive edge: the tool beat the market.

Example: tool says `p_yes = 0.72`, market said `0.65` at request time, outcome = 1.0.
- `market_brier = (0.65 - 1.0)² = 0.1225`
- `tool_brier   = (0.72 - 1.0)² = 0.0784`
- `edge = 0.1225 - 0.0784 = +0.0441`. Tool beat the market by 4.4 Brier points.

Aggregate: `mean_edge = avg(edge)` over rows where all four of (p_yes, market_prob_at_prediction, outcome, prediction_parse_status='valid') are present. `edge_positive_count = count(rows where edge > 0)`.

Source: scorer.py:214-228 `edge_score()`, scorer.py:247-254 eligibility check.

### 7.10 ROI (per agent, per window)

Computed from FPMM trades, not from mech requests. The metric answers "did this agent make money on the bets it placed?"

Per trade (Omen):
- `cost = collateralAmount + feeAmount` (in USDC, scaled by 1e18)
- If `outcomeIndex == int(fpmm.currentAnswer, 16)`:
    - `payout = outcomeTokensTraded` (each winning token = 1 USDC at resolution)
  else:
    - `payout = 0`
- `trade_pnl = payout - cost`

Polymarket: same shape, but `winningIndex` instead of `currentAnswer`, and Gamma API may be used to confirm resolution.

Per-agent aggregate over a window:
```
total_cost   = sum of cost across the agent's trades in the window
total_payout = sum of payout across the agent's trades in the window
roi          = (total_payout - total_cost) / total_cost                 # NULL if total_cost == 0
```

Example: agent placed 10 trades. Total cost $1000. Total payout $1150. `roi = 0.15` (15% return).

Trades for a window are only counted if their FPMM is resolved within that window. Unresolved trades sit aside and join in once the late-resolution sweep picks them up.

Where the trade-to-mech-request join happens: by `fpmm.id == market_id` from the mech request's raw_content. This is the join that replaces the fuzzy `questionTitle` match olas-website and townhall-kpis do today.

**Boundary: trading ROI only.** This metric is bet cost vs bet payout. It deliberately excludes mech fees (reported separately as `mech_fee_usd`), OLAS staking rewards, and any token price conversion of rewards. Consumers that display a rewards-inclusive ROI (olas-website's `finalRoi`, trader's in-agent `final_roi`) compose it on their side: trading components and mech costs from this API, staking rewards from the staking subgraph, and an OLAS/USD price from their own source. Staking data is deliberately out of ETL scope (§16); a precomputed ratio cannot have rewards added to its numerator afterwards, which is why the API also exposes the underlying components rather than only the ratio.

### 7.11 Tool accuracy (per agent, per window)

Mean directional accuracy across the mech requests this agent made, restricted to predictions on the relevant platform.

```
tool_accuracy_omen = mean(directional_correct) over per_request_scores rows
                     WHERE requester = agent_address
                       AND platform = 'omen'
                       AND no_signal_flag = FALSE
                       AND resolved_outcome IS NOT NULL
                       AND requested_at BETWEEN window_start AND window_end
```

Same shape for `tool_accuracy_polymarket`.

This is the field that today's olas-website `tool-accuracy.ts` recomputes from IPFS on every page load. Replaced by a column read.

### 7.12 Mech fees (per chain, per window)

Sum of `delivery_rate` (in the chain's native currency unit) across `mech_requests.delivered_at` in the window, converted to USD using the chain's stable conversion rate (USDC = $1 for USDC payments, etc.).

```
total_mech_fees_usd = sum(delivery_rate_usd) over mech_requests delivered in window
total_requests      = count of mech_requests with requested_at in window
total_deliveries    = count of mech_responses with delivered_at in window
```

USD conversion: today only USDC is used for prediction tools, so the conversion is the identity. If we add other payment tokens later, a small `payment_type_to_usd_rate` table in the ETL handles it.

### 7.13 Settled mech costs (per agent, per window)

```
n_mech_requests         = count of mech_requests rows with requester = agent_address and requested_at in window
mech_fee_usd            = sum(delivery_rate_usd) over those rows that were delivered
n_mech_requests_settled = subset of the above whose joined market has resolved (resolved_outcome IS NOT NULL)
mech_fee_usd_settled    = sum(delivery_rate_usd) over the settled subset
```

Why the settled split exists: trader's performance summary accounts mech costs on market resolution. Today it computes "settled = total - open" by fuzzy-matching its recent requests' `questionTitle` against open Omen markets, which stops working once request content is no longer published to IPFS. The `_settled` fields keep the same accounting semantics through the `market_id` join instead, so trader reads them directly and drops the open-market machinery.

Semantics choice, stated explicitly: costs on unresolved markets stay invisible until the market resolves. That matches trader's numbers today (continuity), at the price of slightly deferring cost recognition. If we ever want immediate recognition, consumers switch to the unsuffixed totals; both variants are served.

Requests are path-agnostic by construction: onchain and offchain rows both land in `mech_requests` (see §15, resolved), so these fields are correct for deployments running either request path, or switching between them.

---

## 8. Wildcard API

Three endpoints. FastAPI in front of the metrics Postgres. No auth on the read side; Cloudflare in front. They match the three natural axes of analysis: one agent's economy, one tool's quality, one service's instance distribution. Each is extensible by adding keys to its JSON, never by adding new routes. Today's olas-website "verify" links become curl invocations of these endpoints, preserving the verifiability pattern.

### `GET /metrics/ai-agent/{ai_agent_name}`

One JSON containing the agent's mech-request counts and fees (totals and settled-only variants), ROI per platform, tool accuracy per platform, the per-tool metric breakdown, and per-chain totals. Rolling windows (7d / 30d / all) plus per-day snapshots for ROI and tool accuracy.

```json
{
  "agent_name": "omenstrat",
  "agent_address": "0xabc...",
  "as_of": "2026-06-24T10:00:00Z",
  "windows": {
    "7d":  { "n_mech_requests": 487, "mech_fee_usd": 23.40,
             "n_mech_requests_settled": 412, "mech_fee_usd_settled": 19.80,
             "roi_omen": 0.12, "roi_polymarket": null,
             "tool_accuracy_omen": 0.62, "tool_accuracy_polymarket": null,
             "n_bets_omen": 142, "n_bets_polymarket": 0 },
    "30d": { ... },
    "all": { ... }
  },
  "tools": [
    { "tool": "prediction-request-reasoning", "platform": "omen", "window": "7d",
      "n_predictions": 487, "n_resolved": 412, "mean_brier": 0.18, "mean_log_loss": 0.42,
      "mean_edge": 0.04, "ece": 0.05, "bss": 0.21, "directional_accuracy": 0.62,
      "no_signal_rate": 0.08,
      "calibration_curve": [ {"bin": 0, ...}, ... ] },
    ...
  ],
  "chain": {
    "gnosis":  { "total_mech_fees_usd": 12450, "total_requests": 8421, "total_deliveries": 8410 },
    "base":    { ... },
    "polygon": { ... }
  }
}
```

Composite call. Internally the route does three reads (agent_aggregates, tool_aggregates, chain_aggregates) and assembles. All cached in-process for 60s.

### `GET /metrics/tool/{tool_name}`

One JSON for a single tool with quality metrics that don't depend on the requester: Brier, calibration curve, ECE, BSS, edge, log loss, directional accuracy, no-signal rate. Same windows. Straight read of `tool_aggregates`.

### `GET /metrics/ai-agent/{ai_agent_name}/instances`

An array, one entry per agent instance (Safe) of that service: the same shape as the agent-level response but flattened, so consumers can bin into ROI distribution charts or other cross-instance views client-side. Each entry is keyed by the instance's Safe address, and an optional `safe_address` query param filters the array down to that single entry. This is how a running agent fetches its own numbers, since the Safe address is the only identity an agent knows about itself. Instance entries carry the same fields as the agent-level response, including the `all` window and the settled-only mech cost fields. Trader's Pearl performance summary reads `n_mech_requests_settled` and `mech_fee_usd_settled` from here and keeps composing ROI locally; its trade totals still come from the trader subgraph and staking rewards stay agent-side (§7.10 boundary note).

### Windows and freshness

"Window" means rolling (7d = the last 7 days from now), not a calendar date. The daily snapshots are a separate per-day time series alongside the rolling values.

Values are as fresh as the last ETL cycle plus the mech's write lag, and settled fields additionally lag by market resolution plus the late-resolution sweep. Agents consuming these endpoints should cache the last good response and tolerate staleness of at least one cycle interval.

Extensibility rule: new fields are added as new keys; never remove or rename. Consumers ignore unknown keys.

---

## 9. Language choice — Python, not Node

Could this be Node? Mechanically yes; Postgres + GraphQL + FastAPI-equivalent all exist in Node. But the case for Python is strong:

1. **scorer.py exists.** Brier, ECE, calibration bins, BSS, edge, directional are already implemented and battle-tested in `mech-predict/benchmark/scorer.py`. Porting Python to Python is a copy. Porting Python to Node is a re-implementation with the same risk of subtle numerical differences (log clipping, bin boundaries, NaN handling).
2. **Every other Olas backend service is Python.** mech, mech-interact, predict-api, mech-predict. Operators do not have a separate Node toolchain.
3. **Scientific computing libraries.** numpy / scipy if we ever want bootstrapping confidence intervals on Brier. Cleaner in Python.
4. **APScheduler** + **psycopg** + **httpx** + **FastAPI** is a tight, well-trodden stack for this exact shape.

Recommendation: Python 3.11. Stick with the same dependency set as predict-api so ops surface stays uniform.

---

## 10. Service architecture

### 10.1 Repo and layout

New repo: `mech-analytics-etl`. Single container.

```
mech-analytics-etl/
├── etl/
│   ├── readers/
│   │   ├── data_lake.py           # SELECT from predict-api Postgres
│   │   ├── omen_subgraph.py       # GraphQL client (httpx + gql or raw POST)
│   │   ├── polymarket_subgraph.py
│   │   ├── polymarket_gamma.py    # REST fallback
│   │   ├── omen_fpmm_trades.py
│   │   └── polymarket_fpmm_trades.py
│   ├── scoring/
│   │   ├── brier.py               # ports of scorer.py functions
│   │   ├── log_loss.py
│   │   ├── calibration.py         # bins, ECE
│   │   ├── edge.py
│   │   ├── bss.py
│   │   ├── directional.py
│   │   ├── no_signal.py
│   │   └── prediction_parser.py   # parses raw_content.result for p_yes/p_no/confidence
│   ├── aggregates/
│   │   ├── tool.py
│   │   ├── agent.py
│   │   ├── mech.py
│   │   └── chain.py
│   ├── jobs/
│   │   ├── score_new_rows.py
│   │   ├── late_resolution_sweep.py
│   │   ├── rollup_tool.py
│   │   ├── rollup_agent.py
│   │   ├── rollup_mech.py
│   │   ├── rollup_chain.py
│   │   └── ingest_fpmm_trades.py
│   ├── writers/
│   │   └── metrics_db.py          # connection pool, upsert helpers
│   ├── api/
│   │   ├── main.py                # FastAPI app
│   │   └── routes/
│   │       └── agent_economy.py
│   ├── cursor.py
│   ├── config.py
│   └── scheduler.py               # APScheduler entry point
├── alembic/
│   └── versions/
│       └── 001_initial_schema.py  # the six tables above
├── tests/
│   ├── unit/
│   │   ├── test_brier.py          # mirrors mech-predict/benchmark/tests
│   │   ├── test_ece.py
│   │   ├── test_bss.py
│   │   └── test_edge.py
│   └── integration/
│       ├── test_score_new_rows.py # seeded test DB
│       └── test_api.py
├── Dockerfile
├── pyproject.toml
└── README.md
```

Two entry points:
- `scheduler.py` runs the ETL (no HTTP).
- `api/main.py` runs the Wildcard API (FastAPI on uvicorn).

Same container image, different start commands. Operationally one image, two deployments.

### 10.2 Scheduling

APScheduler in-process cron. Job definitions in `scheduler.py`:

```python
sched.add_job(score_new_rows.run,            "interval", minutes=5)
sched.add_job(late_resolution_sweep.run,     "interval", minutes=15)
sched.add_job(rollup_tool.run,               "interval", minutes=15)
sched.add_job(rollup_agent.run,              "interval", minutes=15)
sched.add_job(rollup_mech.run,               "interval", minutes=15)
sched.add_job(rollup_chain.run,              "interval", minutes=15)
sched.add_job(ingest_fpmm_trades.run_omen,   "interval", minutes=15)
sched.add_job(ingest_fpmm_trades.run_poly,   "interval", minutes=15)
```

Each job acquires an advisory lock keyed by `job_name` so two scheduler instances cannot overlap a job. (We deploy one instance; the lock is defense.)

### 10.3 Deployment

Same cluster as predict-api. Two containers:
- `mech-analytics-etl-scheduler` (1 replica, the ETL)
- `mech-analytics-etl-api` (2+ replicas behind a load balancer + Cloudflare)

Both connect to the new metrics Postgres. The ETL also connects to the predict-api Postgres with the read-only role.

### 10.4 Observability

Standard Olas observability: Prometheus metrics on rows processed per minute, lag (now() - max(requested_at) in per_request_scores), job failure counts, API request latency. Alert on lag > 30 minutes for `score_new_rows`.

---

## 11. Read-only DB role on predict-api

Small, in-scope of the predict-api repo (not this one). Coordination call-out.

New alembic migration in `wildcard/server/alembic/versions/008_mech_analytics_reader.py`:

```sql
CREATE ROLE mech_analytics_reader LOGIN PASSWORD '<from secrets manager>';
GRANT CONNECT ON DATABASE wildcard TO mech_analytics_reader;
GRANT USAGE ON SCHEMA public TO mech_analytics_reader;
GRANT SELECT ON mech_requests, mech_responses, predictions TO mech_analytics_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO mech_analytics_reader;
```

Why: least-privilege. The ETL must never accidentally write to the data lake. Without this role, the ETL would use predict-api's full read/write credentials and one buggy `executemany` could corrupt `mech_requests`.

The password goes in the same secrets manager the predict-api uses. ETL deployment mounts it via env var.

---

## 12. Backfill mode

After the historical IPFS ETL (see the historical-backfill section of `docs/marketplace_api_spec.md`) finishes loading `mech_requests` + `mech_responses` with `source='ipfs_historical'`, the analytics ETL runs in backfill mode:

```
1. Reset cursor_state.score_new_rows.last_processed_at to NULL.
2. Bump the batch size from 5000 to 50000.
3. Run score_new_rows in a loop until cursor catches up to now().
4. Run all roll-up jobs once.
5. Switch back to normal interval scheduling.
```

Backfill is single-threaded. Expected duration: 10-20 hours for a 10M-row dataset based on a steady ~150 scored rows/sec (dominated by subgraph round-trips, not DB writes). Subgraph batching (50 markets per query) is the main lever.

---

## 13. Failure modes

| Failure | Behavior | Recovery |
|---------|----------|----------|
| Omen subgraph 5xx | Skip resolution for this batch; log to metrics; per_request_scores rows inserted with NULL resolved_outcome | Late resolution sweep retries next cycle |
| Polymarket subgraph + Gamma both down | Same as Omen failure | Same |
| Predict-api Postgres unreachable | Scheduler logs and skips the cycle; alert fires after 3 consecutive failures | Reconnect on next cycle |
| Metrics Postgres unreachable | Same as above. Wildcard API serves stale data from in-process cache for up to 60s, then 503 | Reconnect on next cycle |
| Malformed `raw_content.result` (cannot parse p_yes) | Row inserted with `prediction_parse_status='malformed'`, p_yes NULL | Visible in per_request_scores; flagged in tool-aggregate `parse_failure_rate` (TODO) |
| Cursor advances past a row that arrives late | Theoretically possible if a settlement is inserted with a `requested_at` that pre-dates the cursor. Mitigation: cursor is on `created_at`, not `requested_at`. | Late rows are always picked up because we sort by `created_at` |
| Two scheduler instances running by mistake | Advisory lock per job_name prevents double-execution; the second one no-ops the cycle | Visible in logs |

---

## 14. Tasks at a glance

- [ ] Stand up the metrics Postgres instance (small RDS / managed Postgres, single-AZ to start)
- [ ] New repo `mech-analytics-etl` with the layout in §10
- [ ] Alembic migration `001_initial_schema.py` for the six tables in §5
- [ ] Read-only DB role migration in the predict-api repo (§11)
- [ ] Port scorer.py metric functions into `etl/scoring/` with line-for-line equivalence tests
- [ ] Subgraph readers for Omen, Polymarket, FPMM trades
- [ ] `score_new_rows` job + tests against a seeded data lake
- [ ] `late_resolution_sweep` job + tests
- [ ] Roll-up jobs for tool, agent, mech, chain
- [ ] FPMM trades ingest job
- [ ] APScheduler wire-up
- [ ] FastAPI app + `/metrics/ai-agent/{ai_agent_name}`, `/metrics/tool/{tool_name}`, `/metrics/ai-agent/{ai_agent_name}/instances` endpoints
- [ ] Static `agent_name → agent_address` mapping in the ETL repo
- [ ] Dockerfile + deployment manifests (scheduler container + API container)
- [ ] Observability: Prometheus metrics, lag alert, parse failure rate
- [ ] Backfill mode runbook
- [ ] Per-metric correctness tests against a known fixture (re-use mech-predict's test fixtures so the numbers are guaranteed to match)
- [ ] End-to-end test: seed predict-api Postgres + mock subgraph + run ETL + assert per_request_scores

### Effort estimate

- ~1500-2000 lines of Python in the ETL service
- ~300 lines of alembic migrations
- ~500 lines of tests
- ~150 lines for the FastAPI app
- 3-5 weeks once someone picks it up, assuming the metrics Postgres instance, the read-only DB role on predict-api, and the data lake (#160 + #161 + #162) are in place

---

## 15. Open questions

Small list. All non-blocking for starting code.

1. Metrics Postgres infrastructure home. Same cluster as predict-api with a separate instance, or different cluster? Recommendation: same cluster, separate instance, separate backup policy.
2. `agent_name → agent_address` mapping ownership. Static file in the ETL repo (recommended) vs a config table.
3. Window definitions. Default 7d / 30d / all. Add 24h for ops visibility?
4. FPMM trades subgraph endpoints and rate limits across Omen + Polymarket. Need to confirm we are within the public-tier quotas at our query rate.
5. Onchain request data — where does it enter the pipeline? **Resolved: Option B.** The mech writes onchain requests to the predict-api Postgres alongside offchain ones, so the data lake is the unified source for both request paths and the ETL never reads the marketplace subgraph. This is what makes every per-agent metric in this spec path-agnostic: a deployment running onchain, offchain, or switching between them produces the same rows. Onchain requests made before the mech started dual-writing enter via the historical backfill (item I).
   - Option A (rejected): ETL pulls onchain requests from the marketplace subgraph periodically and normalizes them into the same shape. Kept the data lake offchain-only and left a permanent live subgraph dependency inside the ETL.

---

## 16. What this spec deliberately does NOT cover

- Item H (olas-website rewrites) — that is a separate workstream, driven by this ETL but lives in olas-website repo.
- Item I (historical IPFS ETL) — separate workstream. The analytics ETL consumes its output but does not own the IPFS scraping.
- Item K (consumer migrations of townhall-kpis, mech-predict daily report, market-resolver) — separate per-consumer workstreams, sequenced after this ETL is stable.
- Auth on `POST /mech/events` — owned by the predict-api repo (see `docs/marketplace_api_spec.md` for the write-path contract). The ETL only reads, no auth concerns on the write side.
- Staking rewards and OLAS price feeds — rewards-inclusive ROI (olas-website's `finalRoi`, trader's `final_roi`) is composed consumer-side from this API's components plus the consumer's own staking-subgraph and price reads. The ETL never touches staking data (§7.10 boundary note).
- Portfolio-based ROI for non-predict agents (optimus) — that is a balance computation inside the agent (including its unspent BalanceTracker balance), not a metrics-pipeline concern. Such agents can still read their mech spend from `/instances?safe_address=` for reporting.
