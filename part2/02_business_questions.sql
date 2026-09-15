-- Part 2: Business questions
-- Run against the marts built in part2/01_bigquery_data_model.sql.

-- =========================================================================
-- 1. Multi-channel performance and investment
--    Relative efficiency between Google Ads and Meta in this sample.
--    See data quality issue #7 in 00_methodology_and_findings.md before
--    treating the absolute ROAS as production-ready: total spend in this
--    extract is implausible relative to GA4 revenue.
-- =========================================================================

SELECT
  c.platform_code AS platform,
  SUM(p.spend_usd)                                    AS total_spend_usd,
  SUM(p.revenue_usd)                                  AS total_revenue_usd,
  SAFE_DIVIDE(SUM(p.revenue_usd), SUM(p.spend_usd))   AS roas,
  SAFE_DIVIDE(SUM(p.spend_usd), SUM(p.purchases))     AS cpa,
  SAFE_DIVIDE(SUM(p.spend_usd), SUM(p.clicks))        AS cpc,
  SAFE_DIVIDE(SUM(p.purchases), SUM(p.sessions))      AS session_conversion_rate
FROM `marts.fct_campaign_performance` p
JOIN `marts.dim_campaign` c USING (campaign_id)
GROUP BY platform
ORDER BY total_revenue_usd DESC;

-- =========================================================================
-- 2. Attribution and campaign effectiveness
--    Ranked by campaign_id, never campaign_name: see data quality issue #5
--    (one campaign name maps to two distinct campaign IDs).
-- =========================================================================

SELECT
  c.campaign_id,
  ANY_VALUE(c.campaign_name) AS campaign_name,
  SUM(p.purchases)   AS conversions,
  SUM(p.revenue_usd) AS revenue_usd,
  SUM(p.spend_usd)   AS spend_usd
FROM `marts.fct_campaign_performance` p
JOIN `marts.dim_campaign` c USING (campaign_id)
GROUP BY c.campaign_id
ORDER BY revenue_usd DESC;

-- =========================================================================
-- 3. Acquisition channel analysis
--    Blends ad spend with onsite behavior (sessions, converting sessions,
--    session-conversion-rate) by channel. The 43 unattributed purchases
--    ($10,015) are reported separately, not folded into any channel.
-- =========================================================================

SELECT
  c.channel_code AS channel,
  SUM(p.spend_usd)                                AS spend_usd,
  SUM(p.sessions)                                 AS sessions,
  SUM(p.purchases)                                AS converting_sessions,
  SAFE_DIVIDE(SUM(p.purchases), SUM(p.sessions))  AS session_conversion_rate
FROM `marts.fct_campaign_performance` p
JOIN `marts.dim_campaign` c USING (campaign_id)
GROUP BY channel
ORDER BY spend_usd DESC;

-- Unattributed demand, reported as its own line item per the exploration finding.
SELECT
  COUNT(*)          AS unattributed_purchases,
  SUM(revenue_usd)  AS unattributed_revenue_usd
FROM `marts.fct_purchases`
WHERE attributed_campaign_id IS NULL;

-- =========================================================================
-- 4. BigQuery data model and architecture
--    The raw → staging → intermediate → marts design in
--    01_bigquery_data_model.sql answers this directly: session identity,
--    campaign propagation, the cross-platform union, dimension parsing,
--    brand standardization, and pre-aggregation are each handled in one
--    layer, so nothing downstream has to redo them. No additional SQL
--    beyond that DDL is needed for this question.
-- =========================================================================
