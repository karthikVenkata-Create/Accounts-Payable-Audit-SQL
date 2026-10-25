-- 10_summary.sql
-- The one-page answer: how much money is recoverable or lost,
-- and how much spend went around the controls.
-- Kept apart on purpose: spend outside controls isn't lost money,
-- it's money nobody checked.

CREATE OR REPLACE TABLE audit_summary AS
SELECT * FROM (
    SELECT 1 AS sort, 'Money out the door' AS section, 'Duplicate invoices paid twice' AS finding,
           (SELECT count(*) FROM duplicate_invoices) AS items,
           (SELECT sum(paid_again) FROM duplicate_invoices) AS dollars
    UNION ALL
    SELECT 2, 'Money out the door', 'Paid above the PO / receipt (released blocks + missed blocks)',
           (SELECT count(*) FROM three_way_match WHERE paid_over_match > 0.01),
           (SELECT sum(paid_over_match) FROM three_way_match WHERE paid_over_match > 0.01)
    UNION ALL
    SELECT 3, 'Money out the door', 'Early-payment discounts missed (2/10 Net 30)',
           (SELECT discount_eligible - discount_taken_count FROM payment_timing_summary),
           (SELECT discount_missed FROM payment_timing_summary)
    UNION ALL
    SELECT 4, 'Money out the door', 'Cost of paying Net-terms invoices >10 days early (5% cost of capital)',
           (SELECT paid_early FROM payment_timing_summary),
           (SELECT early_payment_cost FROM payment_timing_summary)
    UNION ALL
    SELECT 10 + row_number() OVER (ORDER BY spend DESC), 'Spend outside controls', control_break,
           purchase_orders, spend
    FROM control_breaks_summary
)
ORDER BY sort;

-- Section totals. The control-break total counts each PO once,
-- because one PO can break more than one control.
INSERT INTO audit_summary
SELECT 5, 'Money out the door', 'TOTAL', sum(items), sum(dollars)
FROM audit_summary WHERE section = 'Money out the door';

INSERT INTO audit_summary
SELECT 20, 'Spend outside controls', 'TOTAL (each PO counted once)', count(*), sum(po_amount)
FROM (SELECT DISTINCT po_id, po_amount FROM control_breaks);

CREATE OR REPLACE TABLE audit_summary AS SELECT * FROM audit_summary ORDER BY sort;
