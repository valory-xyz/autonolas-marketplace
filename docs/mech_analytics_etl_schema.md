# Mech Analytics — Metrics Postgres Schema

The reference DDL for every table the analytics ETL writes, plus the consumer queries each table backs. Pairs with `docs/mech_analytics_etl_spec.md` (pipeline, jobs, metric math, service architecture).

This doc is what reviewers should look at when they want to know "what does the metrics database look like and which endpoint does each table feed" without reading the full pipeline spec.

If a column or grain disagrees between this doc and the spec, this doc wins (it reflects the latest scope decisions, including daily snapshots and the three Wildcard API endpoints).

---

## 1. Conventions

- All timestamps `TIMESTAMPTZ`, UTC.
- All money amounts stored as `DOUBLE PRECISION` for analytics ergonomics. Source rows in the data lake (`mech_requests.delivery_rate`) stay integer-unit; conversion to USD happens at ETL write time.
- Aggregate tables key on `(grain columns, window_kind, window_end)` and are upserted in place on every roll-up cycle.
- The ETL is the only writer. The Wildcard API holds read-only credentials. olas-website, townhall-kpis, and mech-predict never touch the metrics Postgres directly — they go through the API.
- `window_kind` enum: `'24h' | '7d' | '30d' | 'all' | 'day'`. Rolling windows (`24h`, `7d`, `30d`, `all`) carry their `window_end` as the current cycle time; the `'day'` rows are per-calendar-day snapshots keyed by `window_end = end-of-day UTC`.

---

## 2. Tables at a glance

| Table | Grain | Wildcard endpoint(s) it backs |
|-------|-------|-------------------------------|
| [`per_request_scores`](#3-per_request_scores) | one row per delivered prediction | source for every aggregate; not consumer-facing |
| [`tool_aggregates`](#4-tool_aggregates) | (tool, platform, window) | `GET /v1/metrics/tool/{tool_name}` |
| [`agent_aggregates`](#5-agent_aggregates) | (agent, window) and (agent, day) | `GET /v1/metrics/ai-agent/{ai_agent_name}`, `GET /v1/metrics/ai-agent/{ai_agent_name}/instances` |
| [`mech_aggregates`](#6-mech_aggregates) | (mech, window) | `GET /v1/metrics/ai-agent/{ai_agent_name}` (mech context block) |
| [`chain_aggregates`](#7-chain_aggregates) | (chain, window) | `GET /v1/metrics/ai-agent/{ai_agent_name}` (chain block) |
| [`cursor_state`](#8-cursor_state) | one row per ETL job | not consumer-facing; ETL bookmark |

---

## 3. `per_request_scores`

One row per delivered prediction request. The fine-grained source table that every aggregate rolls up from. Partitioned monthly by `requested_at` once row count exceeds ~10M (matches the predictions-table precedent in the data lake).

### DDL

```sql
CREATE TABLE per_request_scores (
    request_id                 TEXT             PRIMARY KEY,
    tool                       TEXT             NOT NULL,
    mech_address               TEXT             NOT NULL,
    requester                  TEXT             NOT NULL,
    chain_id                   INTEGER          NOT NULL,
    market_id                  TEXT,
    platform                   TEXT,                       -- 'omen' | 'polymarket' | NULL if unmatched
    p_yes                      DOUBLE PRECISION,
    p_no                       DOUBLE PRECISION,
    confidence                 DOUBLE PRECISION,
    market_prob_at_prediction  DOUBLE PRECISION,           -- from mech_requests.raw_content.extras.market_prob_at_prediction
    resolved_outcome           DOUBLE PRECISION,           -- 1.0 = Yes won, 0.0 = No won, NULL if unresolved
    resolved_at                TIMESTAMPTZ,
    brier                      DOUBLE PRECISION,           -- NULL until resolved
    log_loss                   DOUBLE PRECISION,           -- NULL until resolved
    edge                       DOUBLE PRECISION,           -- NULL until resolved or market_prob_at_prediction missing
    directional_correct        BOOLEAN,                    -- NULL until resolved or no_signal_flag = TRUE
    calibration_bin            INTEGER,                    -- 0..9 by p_yes, NULL if p_yes is NULL
    no_signal_flag             BOOLEAN          NOT NULL,  -- TRUE iff p_yes == 0.5 exactly
    prediction_parse_status    TEXT             NOT NULL,  -- 'valid' | 'malformed' | 'missing_fields' | 'error'
    requested_at               TIMESTAMPTZ      NOT NULL,
    delivered_at               TIMESTAMPTZ      NOT NULL,
    computed_at                TIMESTAMPTZ      NOT NULL DEFAULT now(),
    last_resolution_check_at   TIMESTAMPTZ
);

CREATE INDEX prs_tool_requested_at_idx
    ON per_request_scores (tool, requested_at DESC);
CREATE INDEX prs_requester_requested_at_idx
    ON per_request_scores (requester, requested_at DESC);
CREATE INDEX prs_market_idx
    ON per_request_scores (market_id) WHERE market_id IS NOT NULL;
CREATE INDEX prs_unresolved_idx
    ON per_request_scores (last_resolution_check_at) WHERE resolved_outcome IS NULL;
CREATE INDEX prs_platform_resolved_idx
    ON per_request_scores (platform, resolved_at DESC) WHERE resolved_outcome IS NOT NULL;
```

### What the columns are for

- `market_id` + `platform` is the join key the ETL uses against Omen / Polymarket subgraphs for resolutions and trades. The fuzzy `questionTitle` join that olas-website / townhall-kpis do today is replaced by an equality join on this pair.
- `market_prob_at_prediction` is the market's implied Yes probability at the moment the prediction was made. Set by the mech-side request schema v2.0. Required for `edge` to be computable; rows where it's missing get `edge = NULL`.
- `no_signal_flag` is set when `p_yes == 0.5` exactly. Excluded from `directional_correct` aggregates and counted separately as `no_signal_rate`.
- `prediction_parse_status` distinguishes malformed tool output (`'malformed'`) from valid p_yes-bearing rows (`'valid'`). Lets aggregates exclude bad rows without losing the row itself.
- `last_resolution_check_at` powers the late-resolution sweep: unresolved rows newer than ~14 days are re-checked; older ones are terminally marked unresolved.

### Which consumer queries hit it

- The ETL's roll-up jobs (`rollup_tool`, `rollup_agent`, `rollup_mech`, `rollup_chain`) read it as the source for every aggregate.
- mech-predict's recompute path (prompt sweeps, `--code-change`) reads it directly via read-only SQL when it needs raw per-row Brier / log-loss / calibration data. This is the only consumer that bypasses the Wildcard API.

---

## 4. `tool_aggregates`

Rolled up per (tool, platform, window). Backs the per-tool quality endpoint.

### DDL

```sql
CREATE TABLE tool_aggregates (
    id                    BIGSERIAL        PRIMARY KEY,
    tool                  TEXT             NOT NULL,
    platform              TEXT             NOT NULL,        -- 'omen' | 'polymarket' | 'all'
    window_kind           TEXT             NOT NULL,        -- '24h' | '7d' | '30d' | 'all'
    window_start          TIMESTAMPTZ      NOT NULL,
    window_end            TIMESTAMPTZ      NOT NULL,
    n_predictions         INTEGER          NOT NULL,
    n_resolved            INTEGER          NOT NULL,
    mean_brier            DOUBLE PRECISION,
    mean_log_loss         DOUBLE PRECISION,
    mean_edge             DOUBLE PRECISION,
    edge_positive_count   INTEGER,
    directional_accuracy  DOUBLE PRECISION,
    ece                   DOUBLE PRECISION,
    bss                   DOUBLE PRECISION,
    calibration_curve     JSONB,                            -- [{bin, lo, hi, count, avg_predicted, realized_rate, gap}, ...]
    no_signal_rate        DOUBLE PRECISION,
    computed_at           TIMESTAMPTZ      NOT NULL DEFAULT now(),
    UNIQUE (tool, platform, window_kind, window_end)
);
```

### Which consumer queries hit it

`GET /v1/metrics/tool/{tool_name}` returns the per-tool quality view. Internally the route is:

```sql
SELECT platform, window_kind, n_predictions, n_resolved,
       mean_brier, mean_log_loss, mean_edge, directional_accuracy,
       ece, bss, calibration_curve, no_signal_rate
  FROM tool_aggregates
 WHERE tool = $1
   AND window_kind IN ('24h', '7d', '30d', 'all')
   AND window_end = (SELECT MAX(window_end) FROM tool_aggregates WHERE tool = $1)
 ORDER BY platform, window_kind;
```

Each (tool, platform) gets one row per window. The endpoint pivots into a per-window JSON object.

`GET /v1/metrics/ai-agent/{ai_agent_name}` also reads this table, sliced to the tools that agent actually used in the window, for the "tools" block of the response. The slice uses `per_request_scores` to find which tools matter.

---

## 5. `agent_aggregates`

Rolled up per (agent, window). Carries both rolling windows and per-day snapshots; the rolling rows let consumers render "ROI over the last 7 days", the daily rows let consumers render a time series.

### DDL

```sql
CREATE TABLE agent_aggregates (
    id                          BIGSERIAL        PRIMARY KEY,
    agent_address               TEXT             NOT NULL,    -- the Safe address
    agent_name                  TEXT,                         -- 'omenstrat' | 'polystrat' | 'optimus' | ...
    window_kind                 TEXT             NOT NULL,    -- '24h' | '7d' | '30d' | 'all' | 'day'
    window_start                TIMESTAMPTZ      NOT NULL,
    window_end                  TIMESTAMPTZ      NOT NULL,
    n_mech_requests             INTEGER          NOT NULL,
    mech_fee_usd                DOUBLE PRECISION,
    n_mech_requests_settled     INTEGER,                      -- subset of n_mech_requests whose joined market has resolved
    mech_fee_usd_settled        DOUBLE PRECISION,             -- fees for that settled subset
    n_bets_omen                 INTEGER,
    n_bets_polymarket           INTEGER,
    roi_omen                    DOUBLE PRECISION,             -- (payout - cost) / cost, NULL if cost = 0
    roi_polymarket              DOUBLE PRECISION,
    tool_accuracy_omen          DOUBLE PRECISION,             -- mean directional accuracy on Omen
    tool_accuracy_polymarket    DOUBLE PRECISION,
    computed_at                 TIMESTAMPTZ      NOT NULL DEFAULT now(),
    UNIQUE (agent_address, window_kind, window_end)
);

CREATE INDEX aa_agent_window_idx
    ON agent_aggregates (agent_address, window_kind, window_end DESC);
CREATE INDEX aa_day_idx
    ON agent_aggregates (agent_address, window_end DESC) WHERE window_kind = 'day';
```

### Computation sources

`n_mech_requests` and `mech_fee_usd` are computed over **all** `mech_requests` rows for the Safe (any tool, any requester type), not just rows that produced a `per_request_scores` entry. A requester that never makes prediction requests (e.g. optimus) still gets counts and fees; its ROI and tool-accuracy columns are NULL. The `_settled` variants count only requests whose joined market has resolved (`per_request_scores.resolved_outcome IS NOT NULL`); requests with no market join are excluded from the settled variants. Trader's in-agent performance summary consumes the settled pair — it replaces the open-market exclusion it does against the marketplace subgraph today (see spec §7.13).

ROI and tool-accuracy columns roll up from `per_request_scores` and the FPMM trades ingest, restricted to resolved markets.

### Which consumer queries hit it

`GET /v1/metrics/ai-agent/{ai_agent_name}` resolves `agent_name → agent_address` from a static mapping, then issues two reads:

```sql
-- rolling windows for the headline numbers
SELECT window_kind, n_mech_requests, mech_fee_usd,
       n_mech_requests_settled, mech_fee_usd_settled,
       n_bets_omen, n_bets_polymarket,
       roi_omen, roi_polymarket,
       tool_accuracy_omen, tool_accuracy_polymarket
  FROM agent_aggregates
 WHERE agent_address = $1
   AND window_kind IN ('24h', '7d', '30d', 'all')
   AND window_end = (SELECT MAX(window_end) FROM agent_aggregates
                     WHERE agent_address = $1 AND window_kind = '7d');

-- per-day snapshots for the ROI / tool-accuracy time series
SELECT window_end::date AS day,
       roi_omen, roi_polymarket,
       tool_accuracy_omen, tool_accuracy_polymarket
  FROM agent_aggregates
 WHERE agent_address = $1
   AND window_kind = 'day'
   AND window_end >= now() - INTERVAL '90 days'
 ORDER BY window_end ASC;
```

`GET /v1/metrics/ai-agent/{ai_agent_name}/instances` returns an array of these objects, one per agent instance (Safe) of the service. The route maps `ai_agent_name → [agent_address, ...]` and runs the same two queries per agent. Each entry is keyed by the instance's Safe address. An optional `safe_address` query param narrows the array to that single entry — the same queries with `agent_address = $safe_address` directly, skipping the name-to-addresses fan-out. This is how a running agent fetches its own numbers, since the Safe address is the only identity an agent knows about itself.

### Daily snapshot semantics

Daily snapshots are attributed by **prediction date** (i.e. the row's `requested_at::date`), not by resolution date. Same convention as mech-predict's daily scoring. A market that resolves three days later updates the snapshot for the prediction day, not for the resolution day.

---

## 6. `mech_aggregates`

Rolled up per (mech, window). Powers the mech-context block of the ai-agent response (so a consumer rendering "agent X's most-used mech earned $Y" doesn't need a second join).

### DDL

```sql
CREATE TABLE mech_aggregates (
    id                       BIGSERIAL        PRIMARY KEY,
    mech_address             TEXT             NOT NULL,
    window_kind              TEXT             NOT NULL,
    window_start             TIMESTAMPTZ      NOT NULL,
    window_end               TIMESTAMPTZ      NOT NULL,
    n_deliveries_received    INTEGER          NOT NULL,    -- requests this mech was assigned (priority or fallback)
    n_self_delivered         INTEGER          NOT NULL,    -- subset where this mech actually delivered
    mech_fee_usd_earned      DOUBLE PRECISION,
    computed_at              TIMESTAMPTZ      NOT NULL DEFAULT now(),
    UNIQUE (mech_address, window_kind, window_end)
);
```

### Which consumer queries hit it

`GET /v1/metrics/ai-agent/{ai_agent_name}` reads it sliced to the mechs the requested agent actually used. The slice uses `per_request_scores.mech_address` filtered to the agent's `requester`.

It is not its own endpoint today. If a "mech leaderboard" endpoint is added later, that's an additive change against this table and does not need a schema migration.

---

## 7. `chain_aggregates`

Rolled up per (chain_id, window, source). Backs the chain block of the ai-agent response. `source` distinguishes the live ETL roll-up from the one-time legacy-subgraph snapshot that lands here at legacy decommission.

### DDL

```sql
CREATE TABLE chain_aggregates (
    id                       BIGSERIAL        PRIMARY KEY,
    chain_id                 INTEGER          NOT NULL,
    window_kind              TEXT             NOT NULL,    -- '24h' | '7d' | '30d' | 'all'
    window_start             TIMESTAMPTZ      NOT NULL,
    window_end               TIMESTAMPTZ      NOT NULL,
    source                   TEXT             NOT NULL,    -- 'etl_live' | 'legacy_snapshot'
    total_mech_fees_usd      DOUBLE PRECISION,
    total_requests           INTEGER,
    total_deliveries         INTEGER,
    snapshot_input_hash      TEXT,                         -- non-NULL only when source='legacy_snapshot'; SHA-256 of the raw LegacyMechFeesQuery response captured at decommission
    computed_at              TIMESTAMPTZ      NOT NULL DEFAULT now(),
    UNIQUE (chain_id, window_kind, window_end, source)
);
```

### Sources and merge semantics

Two row sources coexist:

- `source='etl_live'` — written by the `rollup_chain_aggregates` job on every interval from the live `per_request_scores` data. One row per (chain, window_kind, window_end). Constantly refreshed.
- `source='legacy_snapshot'` — written exactly once when the legacy autonolas-subgraph is decommissioned. Captures per-chain fee / request / delivery totals from the final `LegacyMechFeesQuery` run at decommission date `T`. Never updated thereafter. `snapshot_input_hash` holds the SHA-256 of the raw query response so the load can be audited.

Snapshot rows are written for:
- `window_kind='all'` — one row per chain, contributes to every `all`-window read forever.
- Rolling `window_kind` values — the roll-up job writes a snapshot row alongside the live row only while `window_end <= T + window_size_seconds`. Past that, the rolling window contains no legacy activity by construction (the legacy mechs stopped producing rows at T), so no snapshot row is needed.

### Which consumer queries hit it

`GET /v1/metrics/ai-agent/{ai_agent_name}` returns a `chain` block keyed by chain name; the route maps `chain_id → name` (gnosis, base, polygon) and sums across `source` for the requested window:

```sql
SELECT chain_id,
       SUM(total_mech_fees_usd) AS total_mech_fees_usd,
       SUM(total_requests)      AS total_requests,
       SUM(total_deliveries)    AS total_deliveries
  FROM chain_aggregates
 WHERE window_kind = $1
   AND window_end = (
         SELECT MAX(window_end)
           FROM chain_aggregates
          WHERE window_kind = $1
            AND source = 'etl_live'
       )
 GROUP BY chain_id;
```

Why `GROUP BY chain_id` without grouping on source: the consumer wants one merged number per chain per window. The `source` column exists for audit and for the snapshot freeze, not for consumer-visible split.

townhall-kpis' current `NewMechFeesQuery` + `LegacyMechFeesQuery` chain-fee aggregations are replaced by reads against this table via the API. `LegacyMechFeesQuery` itself is not ported — its final result lives in the snapshot rows.

---

## 8. `cursor_state`

One row per ETL job. Updated atomically with the data writes in the same transaction so a crash mid-batch cannot desync.

### DDL

```sql
CREATE TABLE cursor_state (
    job_name                     TEXT             PRIMARY KEY,
    last_processed_request_id    TEXT,
    last_processed_at            TIMESTAMPTZ,
    last_run_at                  TIMESTAMPTZ,
    last_run_status              TEXT,                    -- 'ok' | 'failed' | 'partial'
    last_error                   TEXT,
    rows_processed_last_run      INTEGER
);
```

### Which jobs carry a row

| `job_name` | What it advances |
|------------|------------------|
| `score_new_rows` | last processed `mech_requests.request_id` and `requested_at` |
| `late_resolution_sweep` | last sweep time |
| `rollup_tool_aggregates` | last roll-up time |
| `rollup_agent_aggregates` | last roll-up time (covers both window + daily snapshots) |
| `rollup_mech_aggregates` | last roll-up time |
| `rollup_chain_aggregates` | last roll-up time |
| `fpmm_trades_ingest_omen` | last `creationTimestamp` ingested |
| `fpmm_trades_ingest_polymarket` | last trade cursor (CLOB source TBD — see scope §15 open questions) |

Not consumer-facing.

---

## 9. Cross-cutting notes

### Partitioning

`per_request_scores` is partitioned monthly by `requested_at` once row count crosses ~10M. The aggregate tables stay unpartitioned: their row count is bounded by `n_keys × n_windows × n_window_ends_retained`, which is small (think tens of thousands, not millions).

### Versioning the API, not the schema

When a consumer needs a new aggregate, the preferred path is: add a column to an existing aggregate table (additive), add a key to the JSON the existing endpoint returns. The endpoint stays under `/v1/`. Breaking shape changes ship as `/v2/...` with a deprecation window. The schema is not the lock-in; the JSON is.

### Read-only API access

The Wildcard API connects with a Postgres role that has `SELECT` on all tables in this doc and no `INSERT` / `UPDATE` / `DELETE`. The ETL's role is the only writer. Both roles are scoped to the metrics Postgres only; neither has any access to the predict-api data lake.

### Late resolutions and the unresolved index

`prs_unresolved_idx` is a partial index over `last_resolution_check_at` filtered to `resolved_outcome IS NULL`. It is what makes the late-resolution sweep scale: the sweep query is `WHERE resolved_outcome IS NULL AND last_resolution_check_at < now() - INTERVAL '15 minutes'`, which without the partial index would scan every row.

Rows older than ~14 days that are still unresolved get terminally marked (sweep stops re-querying). The 14-day window matches the trader's bet horizon (`sample_bets_closing_days = 10` plus the 24h Omen challenge window plus buffer).
