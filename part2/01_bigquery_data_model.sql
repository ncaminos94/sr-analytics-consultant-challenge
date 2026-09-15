-- Part 2: BigQuery data model
-- Rationale: part2/00_methodology_and_findings.md
-- Replace `project.dataset` prefixes with the real target project before running.

-- =========================================================================
-- RAW: 1 table per source CSV, append-only, exact source headers as STRING
-- =========================================================================

CREATE TABLE IF NOT EXISTS `raw.google_ads` (
  `Date` STRING,
  `Campaign Name` STRING,
  `Campaign ID` STRING,
  `Placement ID` STRING,
  `Account ID` STRING,
  `Account Name` STRING,
  `Country` STRING,
  `Clicks` STRING,
  `Impressions` STRING,
  `Spend` STRING
);

CREATE TABLE IF NOT EXISTS `raw.meta` (
  `Date` STRING,
  `Campaign Name` STRING,
  `Campaign ID` STRING,
  `Ad Location` STRING,
  `Account ID` STRING,
  `Account Name` STRING,
  `Country` STRING,
  `Clicks` STRING,
  `Impressions` STRING,
  `Spend` STRING
);

CREATE TABLE IF NOT EXISTS `raw.ga4_events` (
  `User ID` STRING,
  `session_id` STRING,
  `Timestamp` STRING,
  `Event Name` STRING,
  `Event Parameters` STRING,
  `Campaign ID` STRING,
  `Stream Name` STRING,
  `Page URL` STRING,
  `Country` STRING,
  `Is Conversion` STRING
);

-- =========================================================================
-- STAGING: typed, standardized names, 1:1 row mirror, PARTITION BY event_date
-- =========================================================================

CREATE OR REPLACE TABLE `staging.stg_google_ads`
PARTITION BY event_date
CLUSTER BY campaign_id
AS
SELECT
  PARSE_DATE('%Y-%m-%d', `Date`)   AS event_date,
  `Campaign Name`                  AS campaign_name,
  `Campaign ID`                    AS campaign_id,
  `Placement ID`                   AS placement_id,
  CAST(`Account ID` AS STRING)     AS account_id,
  `Account Name`                  AS account_name,
  `Country`                        AS country,
  CAST(`Clicks` AS INT64)          AS clicks,
  CAST(`Impressions` AS INT64)     AS impressions,
  CAST(`Spend` AS NUMERIC)         AS spend_usd
FROM `raw.google_ads`;

CREATE OR REPLACE TABLE `staging.stg_meta`
PARTITION BY event_date
CLUSTER BY campaign_id
AS
SELECT
  PARSE_DATE('%Y-%m-%d', `Date`)   AS event_date,
  `Campaign Name`                  AS campaign_name,
  `Campaign ID`                    AS campaign_id,
  `Ad Location`                    AS ad_location,
  CAST(`Account ID` AS STRING)     AS account_id,
  `Account Name`                  AS account_name,
  `Country`                        AS country,
  CAST(`Clicks` AS INT64)          AS clicks,
  CAST(`Impressions` AS INT64)     AS impressions,
  CAST(`Spend` AS NUMERIC)         AS spend_usd
FROM `raw.meta`;

-- Event Parameters is parsed into JSON here, once, so every downstream table
-- reads pre-parsed JSON instead of re-parsing the raw string.
CREATE OR REPLACE TABLE `staging.stg_ga4_events`
PARTITION BY event_date
CLUSTER BY event_name
AS
SELECT
  `User ID`                                    AS user_id,
  `session_id`                                 AS session_seq,
  TIMESTAMP_MILLIS(CAST(`Timestamp` AS INT64))  AS event_timestamp,
  DATE(TIMESTAMP_MILLIS(CAST(`Timestamp` AS INT64))) AS event_date,
  `Event Name`                                  AS event_name,
  PARSE_JSON(`Event Parameters`)                AS event_params,
  NULLIF(`Campaign ID`, '')                     AS campaign_id,
  `Stream Name`                                 AS stream_name,
  `Page URL`                                    AS page_url,
  `Country`                                     AS country,
  CAST(`Is Conversion` AS BOOL)                 AS is_conversion
FROM `raw.ga4_events`;

-- =========================================================================
-- INTERMEDIATE: the two structural fixes applied exactly once
-- =========================================================================

-- Grain: 1 row per session_key. Real session identity (session_key) plus the
-- campaign attributed at session entry, propagated forward from the
-- earliest landing_page event in that session (NULL when the session has none).
CREATE OR REPLACE TABLE `intermediate.int_sessions`
PARTITION BY session_date
AS
WITH all_sessions AS (
  SELECT DISTINCT
    user_id,
    session_seq,
    CONCAT(user_id, '-', session_seq) AS session_key
  FROM `staging.stg_ga4_events`
),
session_bounds AS (
  SELECT user_id, session_seq, MIN(event_timestamp) AS session_start_ts
  FROM `staging.stg_ga4_events`
  GROUP BY user_id, session_seq
),
landing AS (
  SELECT
    user_id,
    session_seq,
    campaign_id AS landing_campaign_id,
    ROW_NUMBER() OVER (
      PARTITION BY user_id, session_seq ORDER BY event_timestamp ASC
    ) AS rn
  FROM `staging.stg_ga4_events`
  WHERE event_name = 'landing_page'
)
SELECT
  s.session_key,
  s.user_id,
  s.session_seq,
  b.session_start_ts,
  DATE(b.session_start_ts) AS session_date,
  l.landing_campaign_id
FROM all_sessions s
JOIN session_bounds b USING (user_id, session_seq)
LEFT JOIN landing l
  ON l.user_id = s.user_id AND l.session_seq = s.session_seq AND l.rn = 1;

-- Grain: 1 row per GA4 event. Every event enriched with its session's real
-- key, its attributed campaign (propagated, not just its own), and a
-- standardized brand for the events that carry one.
CREATE OR REPLACE TABLE `intermediate.int_ga4_events_enriched`
PARTITION BY event_date
CLUSTER BY attributed_campaign_id
AS
SELECT
  e.user_id,
  e.session_seq,
  s.session_key,
  e.event_timestamp,
  e.event_date,
  e.event_name,
  e.is_conversion,
  s.landing_campaign_id AS attributed_campaign_id,
  JSON_VALUE(e.event_params, '$.transaction_id')            AS transaction_id,
  CAST(JSON_VALUE(e.event_params, '$.value') AS NUMERIC)    AS purchase_value,
  JSON_VALUE(e.event_params, '$.currency')                  AS currency,
  CASE JSON_VALUE(e.event_params, '$.brand')
    WHEN 'Forerver21' THEN 'Forever21'
    ELSE JSON_VALUE(e.event_params, '$.brand')
  END                                                        AS brand,
  e.page_url,
  e.country
FROM `staging.stg_ga4_events` e
JOIN `intermediate.int_sessions` s USING (user_id, session_seq);

-- Grain: 1 row per campaign_id + event_date + platform. Google Ads and Meta
-- unioned onto one shape, campaign ID split once into its five dimensions.
CREATE OR REPLACE TABLE `intermediate.int_ad_spend_daily`
PARTITION BY event_date
CLUSTER BY campaign_id
AS
WITH unioned AS (
  SELECT event_date, campaign_id, campaign_name, account_id,
         clicks, impressions, spend_usd, 'google_ads' AS platform_source
  FROM `staging.stg_google_ads`
  UNION ALL
  SELECT event_date, campaign_id, campaign_name, account_id,
         clicks, impressions, spend_usd, 'meta' AS platform_source
  FROM `staging.stg_meta`
)
SELECT
  *,
  SPLIT(campaign_id, '_')[SAFE_OFFSET(0)] AS platform_code,
  SPLIT(campaign_id, '_')[SAFE_OFFSET(1)] AS brand_code,
  SPLIT(campaign_id, '_')[SAFE_OFFSET(2)] AS channel_code,
  SPLIT(campaign_id, '_')[SAFE_OFFSET(3)] AS objective_code,
  SPLIT(campaign_id, '_')[SAFE_OFFSET(4)] AS country_code,
  SPLIT(campaign_id, '_')[SAFE_OFFSET(5)] AS region_code,
  SPLIT(campaign_id, '_')[SAFE_OFFSET(6)] AS season_code
FROM unioned;

-- =========================================================================
-- MARTS: query-ready, one documented grain each
-- =========================================================================

-- Grain: 1 row per campaign_id.
CREATE OR REPLACE TABLE `marts.dim_campaign`
CLUSTER BY campaign_id
AS
SELECT
  campaign_id,
  ANY_VALUE(campaign_name)   AS campaign_name,
  ANY_VALUE(platform_code)   AS platform_code,
  ANY_VALUE(brand_code)      AS brand_code,
  ANY_VALUE(channel_code)    AS channel_code,
  ANY_VALUE(objective_code)  AS objective_code,
  ANY_VALUE(country_code)    AS country_code,
  ANY_VALUE(region_code)     AS region_code,
  ANY_VALUE(season_code)     AS season_code
FROM `intermediate.int_ad_spend_daily`
GROUP BY campaign_id;

-- Grain: 1 row per campaign_id + event_date.
CREATE OR REPLACE TABLE `marts.fct_ad_spend_daily`
PARTITION BY event_date
CLUSTER BY campaign_id
AS
SELECT
  event_date,
  campaign_id,
  SUM(clicks)      AS clicks,
  SUM(impressions) AS impressions,
  SUM(spend_usd)   AS spend_usd
FROM `intermediate.int_ad_spend_daily`
GROUP BY event_date, campaign_id;

-- Grain: 1 row per transaction_id.
CREATE OR REPLACE TABLE `marts.fct_purchases`
PARTITION BY event_date
CLUSTER BY attributed_campaign_id
AS
SELECT
  transaction_id,
  user_id,
  session_key,
  event_date,
  event_timestamp,
  purchase_value AS revenue_usd,
  currency,
  brand,
  attributed_campaign_id,
  is_conversion
FROM `intermediate.int_ga4_events_enriched`
WHERE event_name = 'purchase';

-- Grain: 1 row per campaign_id + event_date. Spend, revenue, and session
-- counts are pre-aggregated to this grain in the CTEs below, so the join
-- itself can't fan out rows.
CREATE OR REPLACE TABLE `marts.fct_campaign_performance`
PARTITION BY event_date
CLUSTER BY campaign_id
AS
WITH spend AS (
  SELECT event_date, campaign_id, spend_usd, clicks, impressions
  FROM `marts.fct_ad_spend_daily`
),
revenue AS (
  SELECT
    event_date,
    attributed_campaign_id AS campaign_id,
    COUNT(*)          AS purchases,
    SUM(revenue_usd)  AS revenue_usd
  FROM `marts.fct_purchases`
  WHERE attributed_campaign_id IS NOT NULL
  GROUP BY event_date, attributed_campaign_id
),
sessions AS (
  SELECT
    session_date AS event_date,
    landing_campaign_id AS campaign_id,
    COUNT(*) AS sessions
  FROM `intermediate.int_sessions`
  WHERE landing_campaign_id IS NOT NULL
  GROUP BY session_date, landing_campaign_id
)
SELECT
  COALESCE(sp.event_date, rv.event_date, se.event_date)       AS event_date,
  COALESCE(sp.campaign_id, rv.campaign_id, se.campaign_id)    AS campaign_id,
  sp.spend_usd,
  sp.clicks,
  sp.impressions,
  rv.purchases,
  rv.revenue_usd,
  se.sessions
FROM spend sp
FULL OUTER JOIN revenue rv  USING (event_date, campaign_id)
FULL OUTER JOIN sessions se USING (event_date, campaign_id);
