-- 09_vendor_scorecard.sql
-- One row per vendor, pulling every test together, so the follow-up list
-- starts with the vendors that cost the most.

CREATE OR REPLACE TABLE vendor_scorecard AS
WITH
spend AS (
    SELECT vendor_name, count(*) AS pos, sum(po_amount) AS spend
    FROM purchase_orders WHERE case_status <> 'Cancelled'
    GROUP BY vendor_name
),
match AS (
    SELECT vendor_name, count(*) AS match_exceptions, sum(paid_over_match) AS overpaid
    FROM three_way_match GROUP BY vendor_name
),
dups AS (
    SELECT vendor_name, count(*) AS duplicates, sum(paid_again) AS duplicate_paid
    FROM duplicate_invoices GROUP BY vendor_name
),
breaks AS (
    SELECT vendor_name, count(*) AS control_breaks FROM control_breaks GROUP BY vendor_name
),
missed AS (
    SELECT vendor_name,
           CAST(sum(gross_amount * 0.02) FILTER (WHERE discount_terms AND discount_taken = 0) AS DECIMAL(12,2)) AS discount_missed
    FROM payment_timing GROUP BY vendor_name
)
SELECT
    s.vendor_name,
    s.pos,
    s.spend,
    coalesce(m.match_exceptions, 0)   AS match_exceptions,
    coalesce(d.duplicates, 0)         AS duplicates,
    coalesce(b.control_breaks, 0)     AS control_breaks,
    l.pct_late,
    c.median_days_end_to_end,
    coalesce(m.overpaid, 0) + coalesce(d.duplicate_paid, 0) + coalesce(x.discount_missed, 0) AS dollars_lost,
    round(100.0 * (coalesce(m.overpaid, 0) + coalesce(d.duplicate_paid, 0) + coalesce(x.discount_missed, 0))
          / s.spend, 2)               AS lost_pct_of_spend,
    RANK() OVER (ORDER BY coalesce(m.overpaid, 0) + coalesce(d.duplicate_paid, 0) + coalesce(x.discount_missed, 0) DESC) AS priority
FROM spend s
LEFT JOIN match m  USING (vendor_name)
LEFT JOIN dups d   USING (vendor_name)
LEFT JOIN breaks b USING (vendor_name)
LEFT JOIN missed x USING (vendor_name)
LEFT JOIN late_payments_by_vendor l USING (vendor_name)
LEFT JOIN cycle_time_by_vendor c    USING (vendor_name)
ORDER BY priority;
