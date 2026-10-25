-- 05_duplicate_invoices.sql
-- Duplicate payments. Three tests, from strict to loose:
--   1. Exact: same vendor + same invoice number (what most AP systems already block)
--   2. Normalized: same vendor + same invoice number after stripping dashes,
--      leading zeros and trailing letters
--   3. Same vendor + same amount within 45 days, whatever the invoice number says

CREATE OR REPLACE MACRO normalize_invoice_no(no) AS
    -- "AIS-041286", "AIS41286", "AIS-41286A" -> "AIS41286"
    regexp_extract(upper(no), '^[A-Z]+')
    || CAST(CAST(regexp_extract(upper(no), '[0-9]+') AS INTEGER) AS VARCHAR);

CREATE OR REPLACE TABLE invoice_keys AS
SELECT
    i.*,
    normalize_invoice_no(i.vendor_invoice_no) AS normalized_no,
    pay.amount_paid,
    pay.paid_ts
FROM invoices i
LEFT JOIN payments pay USING (invoice_id);

-- Test 1 and 2 side by side, to show what the exact match misses
CREATE OR REPLACE TABLE duplicate_test_results AS
SELECT 'Exact invoice number' AS test,
       count(*) AS duplicate_groups
FROM (SELECT vendor_id, vendor_invoice_no FROM invoice_keys
      GROUP BY ALL HAVING count(*) > 1)
UNION ALL
SELECT 'Normalized invoice number',
       count(*)
FROM (SELECT vendor_id, normalized_no FROM invoice_keys
      GROUP BY ALL HAVING count(*) > 1)
UNION ALL
SELECT 'Same vendor, same amount, within 45 days',
       count(*)
FROM (
    SELECT a.invoice_id
    FROM invoice_keys a
    JOIN invoice_keys b
      ON a.vendor_id = b.vendor_id
     AND a.invoice_amount = b.invoice_amount
     AND a.invoice_id < b.invoice_id
     AND abs(date_diff('day', a.received_ts, b.received_ts)) <= 45
);

-- The duplicates themselves: every invoice after the first in its group was paid in error.
CREATE OR REPLACE TABLE duplicate_invoices AS
WITH ranked AS (
    SELECT
        k.*,
        v.vendor_name,
        ROW_NUMBER() OVER (PARTITION BY k.vendor_id, k.normalized_no ORDER BY k.received_ts) AS copy_no,
        count(*)     OVER (PARTITION BY k.vendor_id, k.normalized_no)                         AS copies,
        first_value(k.vendor_invoice_no) OVER (PARTITION BY k.vendor_id, k.normalized_no ORDER BY k.received_ts) AS original_no,
        first_value(k.received_ts)       OVER (PARTITION BY k.vendor_id, k.normalized_no ORDER BY k.received_ts) AS original_received_ts
    FROM invoice_keys k
    JOIN vendors v USING (vendor_id)
)
SELECT
    vendor_name,
    po_id,
    original_no,
    vendor_invoice_no                                   AS duplicate_no,
    date_diff('day', original_received_ts, received_ts) AS days_after_original,
    invoice_amount,
    amount_paid                                         AS paid_again
FROM ranked
WHERE copies > 1 AND copy_no > 1
ORDER BY paid_again DESC;
