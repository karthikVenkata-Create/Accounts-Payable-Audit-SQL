-- 08_cycle_times.sql
-- Where the time goes: step-to-step waiting time across the whole process,
-- and what rework and payment blocks do to it.

-- Waiting time before each step, using LAG over the event log
CREATE OR REPLACE TABLE step_waits AS
SELECT
    po_id,
    lag(activity) OVER (PARTITION BY po_id ORDER BY step_no) AS from_step,
    activity                                                 AS to_step,
    date_diff('hour', lag(event_ts) OVER (PARTITION BY po_id ORDER BY step_no), event_ts) / 24.0 AS wait_days
FROM events;

-- The handoffs that hold orders up the most, in total days across all POs
CREATE OR REPLACE TABLE slowest_handoffs AS
SELECT
    from_step || ' -> ' || to_step         AS handoff,
    count(*)                               AS times_seen,
    round(median(wait_days), 1)            AS median_days,
    round(quantile_cont(wait_days, 0.9), 1) AS p90_days,
    round(sum(wait_days))                  AS total_days
FROM step_waits
WHERE from_step IS NOT NULL
GROUP BY handoff
HAVING count(*) >= 20
ORDER BY total_days DESC
LIMIT 10;

-- End to end: first event to payment, for paid POs
CREATE OR REPLACE TABLE cycle_time_by_vendor AS
SELECT
    p.vendor_name,
    count(*)                                                               AS paid_pos,
    round(median(date_diff('hour', t.first_event_ts, t.paid_ts) / 24.0), 1) AS median_days_end_to_end,
    round(median(date_diff('hour', t.sent_ts, t.goods_ts) / 24.0), 1)       AS median_days_to_receive_goods,
    round(median(date_diff('hour', t.invoice_ts, t.cleared_ts) / 24.0), 1)  AS median_days_invoice_to_clear,
    round(quantile_cont(date_diff('hour', t.first_event_ts, t.paid_ts) / 24.0, 0.9), 1) AS p90_days_end_to_end
FROM po_timeline t
JOIN purchase_orders p USING (po_id)
WHERE t.paid_ts IS NOT NULL
GROUP BY p.vendor_name
ORDER BY median_days_end_to_end DESC;

-- What rework and payment blocks cost in days
CREATE OR REPLACE TABLE rework_impact AS
WITH flags AS (
    SELECT
        po_id,
        bool_or(activity = 'Change Price')      AS had_price_change,
        bool_or(activity = 'Set Payment Block') AS had_payment_block
    FROM events
    GROUP BY po_id
)
SELECT
    CASE
        WHEN f.had_price_change AND f.had_payment_block THEN 'Price change and payment block'
        WHEN f.had_price_change                         THEN 'Price change only'
        WHEN f.had_payment_block                        THEN 'Payment block only'
        ELSE 'Clean (no rework)'
    END AS path,
    count(*)                                                                AS paid_pos,
    round(median(date_diff('hour', t.first_event_ts, t.paid_ts) / 24.0), 1) AS median_days_end_to_end,
    round(median(date_diff('hour', t.invoice_ts, t.cleared_ts) / 24.0), 1)  AS median_days_invoice_to_clear,
    round(100.0 * count(*) FILTER (WHERE pt.days_past_due > 0) / count(*), 1) AS pct_paid_late
FROM flags f
JOIN po_timeline t USING (po_id)
JOIN payment_timing pt USING (po_id)
WHERE t.paid_ts IS NOT NULL
GROUP BY path
ORDER BY median_days_end_to_end;
