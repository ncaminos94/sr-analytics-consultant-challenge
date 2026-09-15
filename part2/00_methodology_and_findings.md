# Part 2: Methodology and findings

Backs the summary in `LOG.md`. This document covers the reasoning behind the model in
`01_bigquery_data_model.sql`; the four business questions are answered in `02_business_questions.sql`.

## Source data

| Source | Rows | Date range | Grain as shipped |
|---|---|---|---|
| `data/google_ads.csv` | 488 | 2026-05-01 → 2026-06-30 | 1 row per campaign per day |
| `data/meta.csv` | 488 | 2026-05-01 → 2026-06-30 | 1 row per campaign per day |
| `data/ga4.csv` | 12,200 | 2026-05-01 → 2026-06-30 | 1 row per event |

Join integrity on the 16 campaign IDs (8 Google Ads + 8 Meta) is complete in both directions
against GA4's `Campaign ID` column, with no orphaned IDs on either side.

## Two structural findings that drive the model

`session_id` looks like a session identifier but is actually a per-user counter: it only takes 6
distinct values (1–6) across the whole file. Grouping on `session_id` alone collapses the data to
6 sessions instead of 2,663, a roughly 440x undercount. The real session key is
`User ID || session_id`, the same pattern GA4's own BigQuery export uses
(`user_pseudo_id || ga_session_id`); `int_sessions` fixes this once.

Campaign ID only appears on `landing_page` events: 2,339 of 2,663 sessions have one, and no
`purchase` event carries a Campaign ID directly. Attribution has to be propagated from each
session's landing event to every other event in that session, `purchase` included. Once
propagated, 287 of 330 purchases attribute to a campaign, and 43 purchases ($10,015) belong to
sessions with no landing campaign. That's real unattributed demand, reported as its own line item
rather than folded into any channel's totals.

## Data quality issues found during exploration

| # | Issue | Business impact |
|---|---|---|
| 1 | Ad platform exports contain no conversions and no revenue, only clicks/impressions/spend | Every ROAS/CPA figure depends on joining GA4; platform-reported conversions are unavailable for cross-checking |
| 2 | `META_FOREVER21_SEARCH_AWARENESS_...` runs with `Ad Location = "Google Search"` | Either mis-tagged placement or a mislabelled campaign; channel reporting is wrong either way |
| 3 | Third-party brand tokens (`H&M`, `FOREVER21`) inside XYZ's own ad accounts | Naming convention isn't governed; brand-level reporting is unreliable |
| 4 | `Forerver21` misspelled in the GA4 `brand` parameter, coexisting with `Forever21` | Silently splits brand-level revenue |
| 5 | `"GRWM usign Sun Glasses"` maps to two distinct Campaign IDs (name also misspelled) | Any join on campaign name double-counts or drops spend |
| 6 | `Account ID` is `99999` (integer) in Google Ads vs `987as231` (string) in Meta | Type cast required before any union |
| 7 | Total spend $2.17M vs GA4 revenue $75.5K (ROAS ≈ 0.03) | Implausible; treated as a scaling artefact of the sample extract, not a basis for budget decisions |
| 8 | `landing_page` is a custom event running alongside standard `page_view` | Non-standard; session-entry logic depends on it and it is undocumented |

Campaign IDs follow a parseable convention
(`PLATFORM_BRAND_CHANNEL_OBJECTIVE_COUNTRY_REGION_SEASON`, 7 underscore-delimited tokens
consistently across all 16 IDs), which yields five reporting dimensions without extra
instrumentation and feeds directly into `dim_campaign`. `data/ad_spend.csv` also ships with the
repo, with `campaign_name` values matching Part 1's CRM records exactly, but since it's tied to
Part 1's offline conversions rather than the platform-vs-GA4 comparison this part asks for, it's
left out of the model built here.

## Layer design

```
raw (1 table per source CSV, append-only, exact source headers as STRING)
      │
      ▼
staging  (typed, standardized names, 1:1 row mirror, PARTITION BY event_date)
   ├── stg_google_ads
   ├── stg_meta
   └── stg_ga4_events         (Event Parameters JSON parsed once, here)
      │
      ▼
intermediate  (the two structural fixes applied exactly once)
   ├── int_sessions            (session_key + propagated landing campaign)
   ├── int_ga4_events_enriched (every event + attributed_campaign_id + standardized brand)
   └── int_ad_spend_daily      (Google Ads + Meta unioned; campaign dimensions parsed from ID)
      │
      ▼
marts  (query-ready, one documented grain each)
   ├── dim_campaign               grain: 1 row per campaign_id
   ├── fct_ad_spend_daily         grain: 1 row per campaign_id + event_date
   ├── fct_purchases              grain: 1 row per transaction_id
   └── fct_campaign_performance   grain: 1 row per campaign_id + event_date (spend+revenue pre-joined)
```

Each transformation is applied in exactly one place, so a fix made once carries through every
downstream query rather than getting re-implemented per report. The session key fix lives in
`int_sessions`, which builds the real key as `CONCAT(user_id, '-', session_id)`. Campaign
propagation happens in the same table: it carries each session's earliest `landing_page` campaign
forward as `landing_campaign_id`, and `int_ga4_events_enriched` joins that onto every event in the
session. The cross-platform union casts `Account ID` to `STRING` on both sides before the
`UNION ALL` in `int_ad_spend_daily`, and that same table splits each campaign ID once into its five
dimensions (platform, brand, channel, objective, country/region/season), so nothing downstream has
to re-parse it. Brand standardization corrects `Forerver21` to `Forever21` in
`int_ga4_events_enriched`. `fct_campaign_performance` aggregates spend, revenue, and sessions to
the same grain (`campaign_id` + `event_date`) in separate CTEs before joining them, which keeps the
join from fanning out. Every fact table is partitioned by `event_date` and clustered by
`campaign_id` for cost control at production volume.

## Notes on the DDL as shipped

`01_bigquery_data_model.sql` materializes each layer with `CREATE OR REPLACE TABLE ... AS SELECT`
against the sample-scale data, so the whole model is reproducible end to end from `raw` in one
pass. At production volume, `raw → staging` would run as a scheduled incremental load (append new
partitions, not a full rebuild) and `staging → intermediate → marts` would run as scheduled
`MERGE`/partition-overwrite jobs instead of a full `CREATE OR REPLACE`; the transformation logic
itself doesn't change, only how it's scheduled and materialized.
