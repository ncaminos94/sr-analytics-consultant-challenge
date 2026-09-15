# Challenge post-mortem and submission log

**Candidate name:** Nicolas Ariel Caminos
**Date completed:** 14/09/2026

---

## Part 1: Conversion tracking

### Architecture decisions

Two ingestion paths feed the same GA4 property (`G-BXX7WK2TCW`):

web/index.html → Client-side GTM (GTM-MT3WNZMS) → sGTM (GTM-N2LXN8QN) → GA4
data/crm_events.json → src/ingest.py → transform.py → send_ga4.py → GA4 Measurement Protocol

---

Why the offline events skip sGTM and go straight to the Measurement Protocol: 
The CRM feed is a batch job with no browser session and no `client_id` cookie context. 
Routing it through sGTM would just add a network hop for no benefit, since sGTM's main value (first-party cookie handling,
request enrichment from headers) doesn't apply to a server-to-server batch call. Sending it
directly keeps the offline path simple and means it doesn't depend on the local sGTM stack being up.

**PII handling, by path:**
- Web: index.html originally pushed plaintext email and phone into the dataLayer.
  Sending that unhashed to GA4 breaks Google's Terms of Service, so I hashed it client-side with a
  verified SHA-256 implementation before it ever reaches the `user_data` event parameter.
  Plaintext PII only ever lives in the page's own in-memory state; it never crosses the network unhashed.
- Offline: `transform.py`'s `hash_pii()` normalizes (trim, lowercase, strip spaces/parens/
  hyphens, Gmail dot-removal) then SHA-256-hashes before the payload is built. PII never leaves
  the process in plaintext.

**Custom dimensions registered in GA4:**
- lead_type: this dimension was added for the generate_lead event
- sha256_email_address: although this dimension is sent with user_data and there is no need to register it as a custom dimension, I add it anyway in case it's needed in the future
- sha256_email_phone: although this dimension is sent with user_data and there is no need to register it as a custom dimension, I add it anyway in case it's needed in the future


### Code structure

transform.py: converts raw CRM records into valid GA4 Measurement Protocol payloads.
send_ga4.py: sends them (debug validation pass, then the real send). 
ingest.py: orchestrates both and reports a final count. 

| # |     File     |                      Defect              |                  Fix            |
|---|---|---|---|
| 1 | transform.py | `hash_pii` hashed the raw string with no normalization | Trim + lowercase + strip ` ()-` + Gmail/Googlemail dot-removal before hashing 
| 2 | transform.py | `transform_record` never mapped `items[]` — every record's products were dropped | Added `build_items()`, mapped into GA4's item schema 
| 3 | transform.py | PII sent as `em`/`ph` inside `params` (Meta CAPI convention, not GA4's) | Moved to payload-level `user_data.sha256_email_address` / `sha256_phone_number` 
| 4 | transform.py | Campaign sent as `campaign`/`source`/`medium` — flagged as invented names and "corrected" to `campaign_source`/`campaign_medium`/`campaign_name`, which was itself wrong | Reverted to GA4's actual reserved traffic-source event parameters: `campaign`, `source`, `medium` 
| 5 | transform.py | `refund` (`crm-010`, `value: -79.5`) sent with a negative value | `abs()` applied to `value` and item `price` specifically for `refund`-class events 
| 6 | transform.py | `deduplicate_records` silently dropped any record without a `transaction_id` | Kept under a synthetic per-record key, with a logged warning instead of silent loss 
| 7 | send_ga4.py  | Validation filter excluded `VALUE_INVALID` from the error list — backwards, since it's the most common real failure | Removed the exclusion: any non-empty `validationMessages` now blocks the real send 
| 8 | send_ga4.py  | `send_batch` appended two result entries per payload in debug mode (one from validation, one from the real send) | Collapsed to exactly one result dict per input payload 
| 9 | transform.py | `timestamp_micros` was set on the event object (`event["timestamp_micros"]`) instead of the payload root | Moved to `payload["timestamp_micros"]`, matching GA4 MP's actual request schema 

The CRM data deliberately contains a handful of edge cases: duplicate `TXN-10001`
(`crm-001`/`crm-004`), a missing `timestamp` (`crm-003`), an invalid `timestamp` string
(`crm-007`), `consent.marketing: false` (`crm-005`), a zero-value purchase with no items
(`crm-008`), a missing `client_id` that falls back to `user_id` and isn't a valid GA4 client_id
format (`crm-006`), and currencies written as `usd`/`US`/`EUR`/`GBP`.

Google's Measurement Protocol docs require `user_id` whenever `user_data` is sent, and most CRM records carrying PII don't have one.
I suppress `user_data` on any event where `user_id` is missing, rather than inventing an identifier the CRM never gave, and `transform.py` logs a warning per suppressed record so it's visible in the pipeline's own logs.
Running `make ingest` against the real CRM data suppresses `user_data` on 5 of the 8records that make it through dedup and consent filtering, since only `crm-001`/`crm-004` (same transaction, deduped) and `crm-006` carry a `user_id`.

### sGTM configuration

 Web container ID | `GTM-MT3WNZMS` 
 Server container ID | `GTM-N2LXN8QN` 
 GA4 Measurement ID | `G-BXX7WK2TCW` 
 Where `CONTAINER_CONFIG` came from | Server container - Admin - Container settings - "Manually provision tagging server" 
 Server container URL registered in GTM Admin | `https://localhost` 
 Web Google Tag transport | Configuration parameter `server_container_url` on the `GA4 Config - Google tag` tag. Set to `https://localhost`.
 sGTM Client | `GA4` (`gaaw_client`), default paths enabled, `cookieManagement: server`, cookie name `FPID`, 2-year max-age 
 sGTM Tag / Trigger | `GA4 - All events`, copy all parameters from original event client-sided. Trigger: Custom event, all events
 Live (`:8888`) vs. preview (`:8889`) | `gtm-live` handles real traffic, `gtm-preview` backs Tag Assistant, and `gtm-live` forwards every request to `gtm-preview` so both show up in the same Preview session 
 How `/g/collect` handling was verified | Confirmed three ways: the browser's Network tab `Request URL` resolves to `https://localhost/g/collect`, the browser's Network tab showing `page_view`/`scroll`/`purchase` all returning status 200, and the nginx access log independently recording the same hits with the hashed `user_data` fields intact 

### Blockers and debugging trail

| # | Symptom | Hypothesis | Test / Action | Result |
|---|---|---|---|---|
| 1 | `LOG.md` and `screenshots/` not staged by git | `.gitignore` excludes graded deliverables | Inspected `.gitignore` | Confirmed; un-ignored both, kept secret-related rules intact 
| 2 | `make up` fails immediately | README references `.env.example`, absent from the repo | Traced env vars actually read by `src/` and `docker/` | Reconstructed `.env.example` from source 
| 3 | `pytest` → 2 failures in `TestHashPii` | `hash_pii` hashes the raw string with no normalization | Compared expected digests in the test file | Confirmed; normalization fix (trim/lowercase/strip) resolved both cases 
| 4 | Remaining `transform.py`/`send_ga4.py` defects (items dropped, wrong PII/campaign param names, refund sign, silent dedup drop, inverted validation, double-append) | Code review against the GA4 MP schema and the test suite's implied contract | Rewrote both modules; re-ran `pytest` | 16/16 passing 
| 5 | `/g/collect` requests never reached `gtm-live` on the configured port — the browser's Network tab and the nginx access log consistently showed `https://localhost/g/collect` with no port, or an outright `net::ERR_CONNECTION_REFUSED`, no matter what scheme/port was set in `server_container_url` | Ruled out in sequence: wrong config field, a stale Tag Assistant session, an unpublished GTM workspace (which runs zero tags outside Preview) — then confirmed: the Google tag's client-side library silently drops any non-standard port when building the measurement hit URL | Inspected the Network tab's Request URL and the nginx access log at each step; confirmed the port-stripping specifically by watching even a `:8888` attempt land on `https://localhost/g/collect`, port stripped | Published the workspace, exposed `gtm-live` on standard HTTPS port 443 (`nginx.conf` + `docker-compose.yml`), set `server_container_url` to a bare `https://localhost`. Verified end to end: `page_view`/`scroll`/`purchase` all landed on `https://localhost/g/collect` with `200`, cross-checked against the nginx access log with hashed `user_data` intact on `purchase` 
| 6 | Before doing a real (non-debug) send of the offline pipeline, re-reviewed `transform.py`'s campaign parameters and `timestamp_micros` placement against GA4's official Measurement Protocol reference, rather than assuming the row-#4 fix from the initial code review was correct | The row-#4 fix had assumed GA4 required custom parameter names `campaign_source`/`campaign_medium`/`campaign_name`, without checking the actual MP schema | Checked GA4's documented native traffic-source event parameters (`campaign`, `source`, `medium`, `term`, `content`, `campaign_id`) and the top-level MP payload schema | Found two defects, both introduced by the earlier fix rather than in the starter code's remaining behavior: (a) GA4's real reserved names are `campaign`/`source`/`medium` — not the invented `campaign_source`/`campaign_medium`/`campaign_name` — so the original starter code's naming had actually been correct all along; (b) `timestamp_micros` was nested inside the event object instead of the payload root. Reverted both in `transform.py`; re-ran `pytest`, 16/16 still pass since no test had pinned the incorrect names. Left the now-orphaned `campaign_name` custom dimension registered in GA4 Admin rather than deleting it (see Custom dimensions section above) 

### Verification and evidence

I validated this end to end: dataLayer pushes trigger GTM Preview (tags fire with the correct
resolved parameters, including the verified `user_data.sha256_email_address`/
`sha256_phone_number`), the Network tab shows the Request URL resolving to
`https://localhost/g/collect`, sGTM Preview shows the Client claiming the request and the Tag
forwarding it, and the browser's Network tab cross-checked against the nginx access log confirms the same hits
landing with `200` responses. The offline pipeline is validated separately: `pytest` 16/16, and
`make ingest` completes with the expected 8-of-10 record count after dedup/consent filtering.

**Evidence:** Screenshots in `screenshots/`:
- `GA4 Config - Google tag.png` — the Google tag's config, `server_container_url` set to `https://localhost`
- `sGTM - GA4 All events tag.png` — sGTM Preview, the `GA4 - All events` tag firing with its resolved parameters
- `sGTM - GA4 client claimed.png` — sGTM Preview, the Client claiming the incoming request
- `sGTM - GA4 tag forwarding.png` — sGTM Preview, the Tag forwarding the request to GA4
- `Network - request 200 ok.png` — browser Network tab, request resolving to `https://localhost/g/collect` with a `200`
- `GA4 Event - generate_lead.png` / `GA4 Event - purchase.png` — GA4 event tags in GTM
- `GA4 - custom definitions.png` — the registered custom dimensions (`lead_type`, `sha256_email_address`, `sha256_email_phone`)
- `GA4 - Realtime overview.png` - snapshot of GA4 realtime overview, showing events reaching realtime to the property

Not yet captured: `pytest -v` output and `make ingest` output for the offline pipeline.

---

## Part 2: Data engineering

### Data exploration

Row counts: `google_ads.csv` has 488 rows, `meta.csv` has 488, `ga4.csv` has 12,200. Date range:
all three cover 2026-05-01 through 2026-06-30. Join integrity across the 16 campaign IDs is
complete in both directions, no orphans.

Two things I found early on shape the whole model:

1. `session_id` is not unique. It only holds six distinct values (1 to 6): it's a per-user session
   counter, not an identifier. The real session key is `User ID || session_id`. Grouping on
   `session_id` alone reports 6 sessions instead of 2,663, a roughly 440x error. This mirrors the
   `user_pseudo_id || ga_session_id` pattern in GA4's BigQuery export.
2. Campaign attribution only lives on `landing_page` events (2,339 of 2,663 sessions). No
   `purchase` event carries a Campaign ID, so campaign has to be propagated from the session's
   landing event to every event after it. Done right, 287 of 330 purchases attribute to a
   campaign, and 43 purchases / $10,015 fall to direct or organic. That's a real finding about
   unattributed demand, not a data error.

**Data quality issues:**

| # | Issue | Business impact |
|---|---|---|
| 1 | Ad platform exports contain **no conversions and no revenue**, only clicks, impressions, spend | Every ROAS/CPA figure depends on joining GA4; platform-reported conversions are unavailable for cross-checking 
| 2 | `META_FOREVER21_SEARCH_AWARENESS_...` runs with `Ad Location = "Google Search"` | Either mis-tagged placement or a mislabelled campaign; channel reporting is wrong either way 
| 3 | Third-party brand tokens (`H&M`, `FOREVER21`) inside XYZ's own ad accounts | Naming convention isn't being governed; brand-level reporting is unreliable 
| 4 | `Forerver21` misspelled in the GA4 `brand` parameter, coexisting with `Forever21` | Silently splits brand-level revenue 
| 5 | `"GRWM usign Sun Glasses"` maps to **two distinct Campaign IDs** (name also misspelled) | Any join on campaign name double-counts or drops spend 
| 6 | `Account ID` is `99999` (integer) in Google Ads vs `987as231` (string) in Meta | Type cast required before any union 
| 7 | Total spend $2.17M vs GA4 revenue $75.5K (ROAS ≈ 0.03) | Implausible; treated as a scaling artefact of the sample extract, not as a basis for budget decisions 
| 8 | `landing_page` is a custom event running alongside standard `page_view` | Non-standard; session-entry logic depends on it and it is undocumented 

Campaign IDs follow a parseable convention (`PLATFORM_BRAND_CHANNEL_OBJECTIVE_COUNTRY_REGION_SEASON`),
which yields five reporting dimensions without extra instrumentation and forms the backbone of `dim_campaign`. `data/ad_spend.csv` also ships with the repo, with `campaign_name` values matching
Part 1's CRM records exactly, but since it's tied to Part 1's offline conversions rather than the platform-vs-GA4 comparison this part asks for, it's left out of the model built here.


### Data model

Full DDL: `part2/01_bigquery_data_model.sql`. 
Methodology and rationale: `part2/00_methodology_and_findings.md`.

**Tables and relationships** (raw, staging, intermediate, marts):

```
raw (1 table per source CSV, append-only, exact source headers as STRING)
      │
      ▼
staging  — typed, standardized names, 1:1 row mirror, PARTITION BY event_date
   ├── stg_google_ads
   ├── stg_meta
   └── stg_ga4_events         (Event Parameters JSON parsed once, here)
      │
      ▼
intermediate  — the two structural fixes applied exactly once
   ├── int_sessions            (session_key + propagated landing campaign)
   ├── int_ga4_events_enriched (every event + attributed_campaign_id + standardized brand)
   └── int_ad_spend_daily      (Google Ads + Meta unioned; campaign dimensions parsed from ID)
      │
      ▼
marts  — query-ready, one documented grain each
   ├── dim_campaign               grain: 1 row per campaign_id
   ├── fct_ad_spend_daily         grain: 1 row per campaign_id + event_date
   ├── fct_purchases              grain: 1 row per transaction_id
   └── fct_campaign_performance   grain: 1 row per campaign_id + event_date (spend+revenue pre-joined)
```

**Key transformations:**

- Session key fix: `int_sessions` builds the real key as `CONCAT(user_id, '-', session_id)`,
  giving the true 2,663 sessions instead of 6.
- Campaign propagation: `int_sessions` takes each session's earliest `landing_page` campaign and
  carries it forward as `landing_campaign_id`; `int_ga4_events_enriched` joins that onto every
  event in the session, including `purchase`.
- Cross-platform union: `Account ID` gets cast to `STRING` on both sides before the `UNION ALL` in
  `int_ad_spend_daily`.
- Campaign dimension parsing: campaign IDs are split once, in `int_ad_spend_daily`, into five
  reusable dimensions (platform, brand, channel, objective, country/region/season), never
  re-derived downstream.
- Brand standardization: `Forerver21` gets corrected to `Forever21` in `int_ga4_events_enriched`.
- Pre-aggregation before joining: `fct_campaign_performance` aggregates spend and revenue to the
  same grain before joining, so there's no fan-out from a raw event-level join.
- Partitioning and clustering: every fact table is `PARTITION BY event_date`,
  `CLUSTER BY campaign_id`.

### Business questions

Runnable SQL for all four: `part2/02_business_questions.sql`.

1. **Multi-channel performance and investment.** I aggregated `fct_campaign_performance` by
   `platform`, computing ROAS, CPA, CPC, and session-conversion-rate. This is reported as
   *relative* efficiency between Google Ads and Meta in this sample; see finding #7 before treating
   the absolute ROAS as production-ready.
2. **Attribution and campaign effectiveness.** Joined to `dim_campaign`, ranked by total revenue
   and conversions per `campaign_id` (never `campaign_name`; see finding #5).
3. **Acquisition channel analysis.** Grouped by `dim_campaign.channel_code`, blending ad spend with
   onsite behavior (sessions, converting sessions, session-conversion-rate). The 43 unattributed
   purchases ($10,015) are reported as their own finding, not folded into any channel's numbers.
4. **BigQuery data model and architecture.** Answered structurally by the staging, intermediate,
   marts design: each layer fixes one class of problem exactly once, so every downstream query
   inherits the fix instead of re-deriving it.

### Action plan

**Data engineering:**
1. Schedule the `raw` → `staging` load daily, landing source headers as `STRING`, deferring all
   casting to `staging`.
2. Add a regression test asserting `COUNT(DISTINCT session_key)` stays far above
   `COUNT(DISTINCT session_seq)` in `int_sessions`.
3. Add a test asserting every `campaign_id` in `fct_ad_spend_daily` exists in `dim_campaign`.
4. Materialize `fct_campaign_performance` on a schedule (table, not view).

**Analytics team / client requirements:**
1. Query only the `marts` layer; never join on `campaign_name`.
2. Report ROAS/CPA with the sample-scale caveat attached until production-volume data is available.
3. Track the 43 unattributed purchases as a standalone line item.
4. Have media buying confirm the `Ad Location = "Google Search"` anomaly before trusting that
   campaign's channel-level numbers.
5. Enforce the Campaign ID naming convention at campaign-creation time so brand/channel parsing
   stays reliable as new campaigns launch.

---

## Executive summary

*Written for a non-technical ad-operations leader. Maximum one page.*

### Situation

XYZ, needed conversion tracking rebuilt end to end: web purchases and leads
flowing through server-side tagging into GA4, plus an offline CRM feed reconciled into the same
property. They also needed to know which ad platform, Google Ads or Meta, and which campaigns were
actually worth the budget.

### What was broken or missing

The starter repository didn't run as shipped. `.gitignore` excluded the graded `LOG.md` and
`screenshots/`, and `.env.example` was missing entirely. The client-side tracking page pushed
plaintext email and phone into the dataLayer, a Google ToS violation if sent unhashed that way.
The offline pipeline's
PII hashing function didn't normalize input before hashing, ecommerce items were silently dropped,
and the ingestion script's validation logic was inverted, treating the most common real error as a
non-error. On the analytics side, two findings change every downstream number: `session_id` has
only 6 distinct values, undercounting sessions by roughly 440x, and campaign attribution only
exists on the `landing_page` event, so every purchase arrives with no campaign unless it's
explicitly propagated.

### What we delivered

A working client-side to server-side GTM pipeline, with ecommerce items and a SHA-256-hashed
`user_data` block (verified against the official standard) flowing through a local sGTM stack into
GA4, validated end to end via GTM Preview, the Network tab, and the nginx access log. A corrected
offline ingestion pipeline, all tests passing, edge cases documented, known limitations flagged
rather than hidden. For Part 2: a staging to intermediate to
marts BigQuery model that fixes the session-key and campaign-attribution defects exactly once,
plus runnable SQL answering all four business questions and a data-quality findings table covering
8 distinct issues in the source data.

### Known limitations

- `crm-006` has no `client_id`; the pipeline falls back to `user_id`, which isn't a valid GA4
  client_id format. These events won't join to web sessions.
- Most CRM records with PII lack a `user_id`, which GA4's Measurement Protocol requires alongside
  `user_data`. Those records' PII currently has no confirmed matching path.
- The sample-scale spend-to-revenue ratio (ROAS ≈ 0.03) makes absolute efficiency figures unusable
  for budget decisions; relative campaign ranking still holds.
- 43 purchases ($10,015) have no campaign attribution because their sessions never had a
  `landing_page` campaign value.
- The local sGTM stack uses self-signed certificates and `NODE_TLS_REJECT_UNAUTHORIZED=0`, neither
  acceptable in production.
- The stack's Docker healthcheck relies on `wget`, which the official sGTM image doesn't include,
  so containers report `(unhealthy)` even when they're working fine. Confirmed as a false
  positive, not fixed at the infrastructure level.

### Recommended next steps

1. Re-run the full pipeline against production-scale data once it's available; several figures here
   should be re-validated at real volume before they inform budget decisions.
2. Replace the local self-signed sGTM stack with a proper Cloud Run deployment behind a real domain
   before any production traffic touches it.
3. Enforce the Campaign ID naming convention at campaign-creation time.
4. Decide, with legal and privacy sign-off, whether Consent Mode and the PII-hashing approach here
   meet the target markets' regulatory requirements before go-live.
