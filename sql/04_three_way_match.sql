-- 04_three_way_match.sql
-- Three-way match: compare what was ordered (PO), what arrived (goods receipt)
-- and what was billed (invoice). The most we should ever pay is the lower of
-- the PO and the receipt. Anything billed above that, past a small tolerance,
-- is an exception.
--
-- Tolerance: more than 2% AND more than $100 over the matched value.
-- Both tests, so tiny invoices don't flood the list and big ones can't hide behind %.

CREATE OR REPLACE TABLE three_way_match AS
WITH blocks AS (
    SELECT po_id, TRUE AS was_blocked
    FROM events
    WHERE activity = 'Set Payment Block'
    GROUP BY po_id
),
base AS (
    SELECT
        i.po_id,
        p.vendor_name,
        p.po_amount,
        g.received_amount,
        i.invoice_amount,
        least(p.po_amount, g.received_amount)              AS matched_value,
        pay.gross_amount                                   AS paid_gross,
        coalesce(b.was_blocked, FALSE)                     AS was_blocked
    FROM invoices i
    JOIN purchase_orders p USING (po_id)
    JOIN goods_receipts g  USING (po_id)
    LEFT JOIN payments pay ON pay.invoice_id = i.invoice_id
    LEFT JOIN blocks b     USING (po_id)
    WHERE i.invoice_id < 'INV-9'          -- duplicates are handled in 05
)
SELECT
    *,
    invoice_amount - matched_value                                   AS billed_over_match,
    round(100.0 * (invoice_amount - matched_value) / matched_value, 1) AS pct_over_match,
    CASE
        WHEN invoice_amount > po_amount AND received_amount < po_amount THEN 'Price and quantity'
        WHEN invoice_amount > po_amount                                 THEN 'Price'
        WHEN received_amount < po_amount                                THEN 'Quantity'
    END AS mismatch_type,
    paid_gross - matched_value                                       AS paid_over_match,
    CASE
        WHEN NOT was_blocked                     THEN 'Missed: paid with no block'
        WHEN paid_gross <= matched_value + 0.01  THEN 'Blocked, then short-paid to matched value'
        ELSE                                          'Blocked, then released and paid in full'
    END AS outcome
FROM base
WHERE invoice_amount - matched_value > 0.02 * matched_value
  AND invoice_amount - matched_value > 100;

-- How the payment block control performed
CREATE OR REPLACE TABLE three_way_match_summary AS
SELECT
    outcome,
    count(*)                         AS invoices,
    sum(billed_over_match)           AS billed_over_match,
    sum(paid_over_match)             AS paid_over_match
FROM three_way_match
GROUP BY outcome
UNION ALL
-- The other side of the control: blocks placed on invoices that were within tolerance
SELECT
    'Blocked, but within tolerance (no real exception)',
    count(*), 0, 0
FROM events e
WHERE e.activity = 'Set Payment Block'
  AND e.po_id NOT IN (SELECT po_id FROM three_way_match)
ORDER BY paid_over_match DESC, invoices DESC;
