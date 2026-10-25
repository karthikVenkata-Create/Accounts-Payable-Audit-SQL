-- 07_payment_timing.sql
-- When each invoice was paid compared with when it was due.
--   Late           : paid after the due date (vendor relationship and late fees)
--   Missed discount: 2/10 Net 30 invoice paid after day 10, so the 2% was lost
--   Early          : Net-terms invoice paid more than 10 days before it was due,
--                    so cash left the business sooner than it had to
-- Due dates are recomputed from the dates, not taken from the status field (see 03).

CREATE OR REPLACE TABLE payment_timing AS
SELECT
    pay.payment_id,
    i.po_id,
    p.vendor_name,
    p.payment_terms,
    p.discount_terms,
    CAST(i.received_ts AS DATE)                                    AS invoice_date,
    CAST(i.received_ts AS DATE) + p.net_days                       AS due_date,
    CAST(pay.paid_ts AS DATE)                                      AS paid_date,
    date_diff('day', CAST(i.received_ts AS DATE), CAST(pay.paid_ts AS DATE))  AS days_to_pay,
    date_diff('day', CAST(i.received_ts AS DATE) + p.net_days, CAST(pay.paid_ts AS DATE)) AS days_past_due,
    pay.gross_amount,
    pay.discount_taken
FROM payments pay
JOIN invoices i USING (invoice_id)
JOIN purchase_orders p USING (po_id)
WHERE i.invoice_id < 'INV-9';

-- Assumption for the cost of paying early: 5% annual cost of capital
CREATE OR REPLACE TABLE payment_timing_summary AS
SELECT
    count(*)                                                        AS invoices_paid,
    count(*) FILTER (WHERE days_past_due > 0)                       AS paid_late,
    round(100.0 * count(*) FILTER (WHERE days_past_due > 0) / count(*), 1) AS pct_late,
    -- Same test, but a due date on Saturday or Sunday rolls to Monday
    count(*) FILTER (WHERE days_past_due > CASE dayofweek(due_date) WHEN 6 THEN 2 WHEN 0 THEN 1 ELSE 0 END)
                                                                    AS paid_late_weekend_rollover,
    median(days_past_due) FILTER (WHERE days_past_due > 0)          AS median_days_late,
    max(days_past_due)                                              AS worst_days_late,
    count(*) FILTER (WHERE discount_terms)                          AS discount_eligible,
    count(*) FILTER (WHERE discount_terms AND discount_taken > 0)   AS discount_taken_count,
    sum(discount_taken)                                             AS discount_captured,
    CAST(sum(gross_amount * 0.02) FILTER (WHERE discount_terms AND discount_taken = 0) AS DECIMAL(12,2)) AS discount_missed,
    count(*) FILTER (WHERE NOT discount_terms AND days_past_due < -10) AS paid_early,
    CAST(sum(gross_amount * (-days_past_due) * 0.05 / 365)
         FILTER (WHERE NOT discount_terms AND days_past_due < -10) AS DECIMAL(12,2)) AS early_payment_cost
FROM payment_timing;

-- Late-payment rate and days-to-pay by vendor, ranked
CREATE OR REPLACE TABLE late_payments_by_vendor AS
SELECT
    vendor_name,
    count(*)                                                        AS invoices,
    count(*) FILTER (WHERE days_past_due > 0)                       AS paid_late,
    round(100.0 * count(*) FILTER (WHERE days_past_due > 0) / count(*), 1) AS pct_late,
    round(avg(days_to_pay), 1)                                      AS avg_days_to_pay,
    round(quantile_cont(days_past_due, 0.9), 1)                     AS p90_days_past_due,
    RANK() OVER (ORDER BY count(*) FILTER (WHERE days_past_due > 0) * 1.0 / count(*) DESC) AS late_rank
FROM payment_timing
GROUP BY vendor_name
ORDER BY late_rank;

-- Month by month: are we getting better or worse?
CREATE OR REPLACE TABLE late_payments_by_month AS
SELECT
    date_trunc('month', due_date)                                    AS due_month,
    count(*)                                                         AS invoices_due,
    count(*) FILTER (WHERE days_past_due > 0)                        AS paid_late,
    round(100.0 * count(*) FILTER (WHERE days_past_due > 0) / count(*), 1) AS pct_late,
    -- 3-month rolling late rate, to smooth out small months
    round(100.0 * sum(count(*) FILTER (WHERE days_past_due > 0)) OVER w
               / sum(count(*)) OVER w, 1)                            AS rolling_3m_pct_late
FROM payment_timing
GROUP BY due_month
WINDOW w AS (ORDER BY due_month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)
ORDER BY due_month;
