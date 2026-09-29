-- ============================================================
-- mPrompto | USER JOURNEY FLOW - RECOMMENDATION IMPACT (v2)
-- EMBARK PERFUMES
--
-- REWRITTEN TO MATCH INTENDED LOGIC:
--   * DISTINCT USERS on BOTH lanes (no journey grain).
--   * TRUE FUNNEL: Total -> (Rec / Non-Rec) -> PDP visitors -> ATC.
--   * ATC is measured as a SUBSET of PDP visitors (PDP-gated).
--   * Rec ATC users split: same (recommended) product vs different product.
--
-- ATTRIBUTION RULE (rec lane): PDP / ATC must occur AFTER the
--   recommendation, in the SAME session as the recommendation.
-- Non-rec lane: any PDP / ATC within the window.
-- ============================================================
WITH
params AS (
    SELECT DATE '2026-09-20' AS report_start,
           DATE '2026-09-27' AS report_end
),

/* Total active users (distinct fingerprints) */
active_users AS (
    SELECT DISTINCT fingerprint
    FROM silver_db.activity_logs_v2
    CROSS JOIN params p
    WHERE LOWER(TRIM(client_name)) = 'embarkperfumes-client'
      AND event_date BETWEEN p.report_start AND p.report_end
      AND fingerprint IS NOT NULL
),

/* Recommendation events */
recommendation_logs AS (
    SELECT DISTINCT
        fingerprint,
        event_ts_utc AS recommendation_ts,
        CAST(json_parse(recommended_product_ids_json) AS ARRAY(VARCHAR)) AS recommended_products
    FROM silver_db.nudge_recommendation_logs_v2
    CROSS JOIN params p
    WHERE LOWER(TRIM(client_name)) = 'embarkperfumes-client'
      AND event_ts_utc IS NOT NULL
      AND CAST(event_ts_utc AS DATE) BETWEEN p.report_start AND p.report_end
      AND fingerprint IS NOT NULL
      AND recommended_product_ids_json IS NOT NULL
),

recommended_users AS (           -- DISTINCT rec users (green denominator)
    SELECT DISTINCT fingerprint FROM recommendation_logs
),

user_recommended_products AS (   -- products recommended per user
    SELECT DISTINCT r.fingerprint, LOWER(TRIM(pid)) AS recommended_product_id
    FROM recommendation_logs r
    CROSS JOIN UNNEST(r.recommended_products) AS t(pid)
    WHERE pid IS NOT NULL AND TRIM(pid) <> ''
),

sessions AS (
    SELECT fingerprint, session_id,
           MIN(session_start_ts) AS session_start_ts,
           MAX(session_end_ts)   AS session_end_ts
    FROM silver_db.activity_logs_v2
    CROSS JOIN params p
    WHERE LOWER(TRIM(client_name)) = 'embarkperfumes-client'
      AND event_date BETWEEN p.report_start AND p.report_end
      AND fingerprint IS NOT NULL AND session_id IS NOT NULL
    GROUP BY fingerprint, session_id
),

rec_sessions AS (                -- sessions that contain a recommendation
    SELECT DISTINCT r.fingerprint, s.session_id, r.recommendation_ts
    FROM recommendation_logs r
    JOIN sessions s
      ON s.fingerprint = r.fingerprint
     AND r.recommendation_ts BETWEEN s.session_start_ts AND s.session_end_ts
),

/* GREEN: rec users who visited a PDP (after rec, same session) */
rec_pdp_users AS (
    SELECT DISTINCT rs.fingerprint
    FROM rec_sessions rs
    JOIN silver_db.activity_logs_v2 a
      ON LOWER(TRIM(a.client_name)) = 'embarkperfumes-client'
     AND a.fingerprint = rs.fingerprint AND a.session_id = rs.session_id
     AND a.event_timestamp >= rs.recommendation_ts
     AND LOWER(TRIM(a.page_type)) = 'product page'
    CROSS JOIN params p
    WHERE a.event_date BETWEEN p.report_start AND p.report_end
),

/* GREEN: rec ATC events (after rec, same session) */
rec_atc_all AS (
    SELECT DISTINCT rs.fingerprint, LOWER(TRIM(a.product_id)) AS product_id
    FROM rec_sessions rs
    JOIN silver_db.activity_logs_v2 a
      ON LOWER(TRIM(a.client_name)) = 'embarkperfumes-client'
     AND a.fingerprint = rs.fingerprint AND a.session_id = rs.session_id
     AND a.event_timestamp >= rs.recommendation_ts
     AND LOWER(TRIM(a.event)) = 'add_to_cart'
     AND a.product_id IS NOT NULL AND TRIM(a.product_id) <> ''
    CROSS JOIN params p
    WHERE a.event_date BETWEEN p.report_start AND p.report_end
),

rec_atc_users AS (               -- ATC subset of PDP visitors (funnel-gated)
    SELECT DISTINCT x.fingerprint
    FROM rec_atc_all x JOIN rec_pdp_users pv ON pv.fingerprint = x.fingerprint
),

rec_atc_recommended_users AS (   -- bought a recommended product
    SELECT DISTINCT x.fingerprint
    FROM rec_atc_all x
    JOIN user_recommended_products urp
      ON urp.fingerprint = x.fingerprint AND urp.recommended_product_id = x.product_id
    JOIN rec_pdp_users pv ON pv.fingerprint = x.fingerprint
),

/* BLUE: non-recommended distinct users */
non_recommended_users AS (
    SELECT a.fingerprint
    FROM active_users a
    LEFT JOIN recommended_users r ON r.fingerprint = a.fingerprint
    WHERE r.fingerprint IS NULL
),

non_rec_pdp_users AS (
    SELECT DISTINCT a.fingerprint
    FROM silver_db.activity_logs_v2 a
    JOIN non_recommended_users n ON n.fingerprint = a.fingerprint
    CROSS JOIN params p
    WHERE LOWER(TRIM(a.client_name)) = 'embarkperfumes-client'
      AND a.event_date BETWEEN p.report_start AND p.report_end
      AND LOWER(TRIM(a.page_type)) = 'product page'
),

non_rec_atc_users AS (           -- ATC subset of non-rec PDP visitors
    SELECT DISTINCT a.fingerprint
    FROM silver_db.activity_logs_v2 a
    JOIN non_rec_pdp_users pv ON pv.fingerprint = a.fingerprint
    CROSS JOIN params p
    WHERE LOWER(TRIM(a.client_name)) = 'embarkperfumes-client'
      AND a.event_date BETWEEN p.report_start AND p.report_end
      AND LOWER(TRIM(a.event)) = 'add_to_cart'
      AND a.product_id IS NOT NULL AND TRIM(a.product_id) <> ''
),

m AS (
    SELECT
        (SELECT COUNT(*) FROM active_users)              AS total_users,
        (SELECT COUNT(*) FROM recommended_users)         AS rec_users,
        (SELECT COUNT(*) FROM non_recommended_users)     AS nonrec_users,
        (SELECT COUNT(*) FROM rec_pdp_users)             AS rec_pdp_users,
        (SELECT COUNT(*) FROM rec_atc_users)             AS rec_atc_users,
        (SELECT COUNT(*) FROM rec_atc_recommended_users) AS rec_atc_recommended,
        (SELECT COUNT(*) FROM non_rec_pdp_users)         AS nonrec_pdp_users,
        (SELECT COUNT(*) FROM non_rec_atc_users)         AS nonrec_atc_users
)

SELECT metric, users, percentage, pct_base FROM (
    SELECT 1 sort_order,'Total users' metric, total_users users, 100.00 percentage,'total' pct_base FROM m
    UNION ALL SELECT 2,'Received recommendation (distinct users)',rec_users,ROUND(100.0*rec_users/NULLIF(total_users,0),2),'of total' FROM m
    UNION ALL SELECT 3,'Did NOT receive recommendation',nonrec_users,ROUND(100.0*nonrec_users/NULLIF(total_users,0),2),'of total' FROM m
    UNION ALL SELECT 4,'Rec users who visited a Product Page',rec_pdp_users,ROUND(100.0*rec_pdp_users/NULLIF(rec_users,0),2),'of rec users' FROM m
    UNION ALL SELECT 5,'Rec PDP visitors who ATC',rec_atc_users,ROUND(100.0*rec_atc_users/NULLIF(rec_pdp_users,0),2),'of rec PDP visitors' FROM m
    UNION ALL SELECT 6,'Rec ATC: recommended product',rec_atc_recommended,ROUND(100.0*rec_atc_recommended/NULLIF(rec_atc_users,0),2),'of rec ATC users' FROM m
    UNION ALL SELECT 7,'Rec ATC: different product',(rec_atc_users-rec_atc_recommended),ROUND(100.0*(rec_atc_users-rec_atc_recommended)/NULLIF(rec_atc_users,0),2),'of rec ATC users' FROM m
    UNION ALL SELECT 8,'Non-rec users who visited a Product Page',nonrec_pdp_users,ROUND(100.0*nonrec_pdp_users/NULLIF(nonrec_users,0),2),'of non-rec users' FROM m
    UNION ALL SELECT 9,'Non-rec PDP visitors who ATC',nonrec_atc_users,ROUND(100.0*nonrec_atc_users/NULLIF(nonrec_pdp_users,0),2),'of non-rec PDP visitors' FROM m
) x
ORDER BY sort_order;
