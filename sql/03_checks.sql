-- 03_checks.sql
-- Integrity checks. Every audit number below depends on these passing,
-- so run_all.sql stops with an error if any of them fail.

CREATE OR REPLACE TABLE audit_checks AS
WITH
po_steps AS (
    SELECT
        po_id,
        count(*) FILTER (WHERE activity = 'Create Purchase Order')         AS n_create,
        count(*) FILTER (WHERE activity = 'Send Purchase Order to Vendor') AS n_send,
        count(*) FILTER (WHERE activity = 'Pay Invoice')                   AS n_pay
    FROM events
    GROUP BY po_id
),
orig_inv AS (SELECT * FROM invoices WHERE invoice_id < 'INV-9')
SELECT * FROM (VALUES
    ('Every event belongs to a known PO',
        0, (SELECT count(*) FROM events e ANTI JOIN purchase_orders p USING (po_id))),
    ('Every PO appears in the event log',
        0, (SELECT count(*) FROM purchase_orders p ANTI JOIN events e USING (po_id))),
    ('Each PO is created exactly once',
        0, (SELECT count(*) FROM po_steps WHERE n_create <> 1)),
    ('Each PO is sent to the vendor exactly once',
        0, (SELECT count(*) FROM po_steps WHERE n_send <> 1)),
    ('POs with a paid status have exactly one payment event',
        0, (SELECT count(*) FROM purchase_orders p JOIN po_steps s USING (po_id)
            WHERE (p.case_status LIKE 'Paid%') <> (s.n_pay = 1))),
    ('One ledger invoice per invoice event',
        (SELECT count(*) FROM events WHERE activity = 'Receive Invoice'), (SELECT count(*) FROM orig_inv)),
    ('One ledger payment per payment event',
        (SELECT count(*) FROM events WHERE activity = 'Pay Invoice'),
        (SELECT count(*) FROM payments WHERE invoice_id < 'INV-9')),
    ('Every payment points to a real invoice',
        0, (SELECT count(*) FROM payments p ANTI JOIN invoices i USING (invoice_id))),
    ('No payment dated before its invoice arrived',
        0, (SELECT count(*) FROM payments p JOIN invoices i USING (invoice_id) WHERE p.paid_ts < i.received_ts)),
    ('No zero or negative amounts',
        0, (SELECT (SELECT count(*) FROM purchase_orders WHERE po_amount <= 0)
                 + (SELECT count(*) FROM invoices WHERE invoice_amount <= 0)
                 + (SELECT count(*) FROM payments WHERE gross_amount <= 0))),
    ('Payments tie out: gross - discount = paid',
        0, (SELECT count(*) FROM payments WHERE gross_amount - discount_taken <> amount_paid))
) AS t(check_name, expected, actual);

ALTER TABLE audit_checks ADD COLUMN passed BOOLEAN;
UPDATE audit_checks SET passed = (expected = actual);

-- Not a pass/fail check: a data-quality finding about the source's own status label.
-- The status field says "Paid On Time", but the dates say otherwise.
CREATE OR REPLACE TABLE status_label_mismatch AS
SELECT
    p.po_id,
    p.vendor_name,
    p.case_status                                        AS status_in_source,
    CAST(i.received_ts AS DATE) + p.net_days             AS due_date,
    CAST(pay.paid_ts AS DATE)                            AS paid_date,
    date_diff('day', CAST(i.received_ts AS DATE) + p.net_days, CAST(pay.paid_ts AS DATE)) AS days_late
FROM purchase_orders p
JOIN invoices i   ON i.po_id = p.po_id AND i.invoice_id < 'INV-9'
JOIN payments pay ON pay.invoice_id = i.invoice_id
WHERE p.case_status = 'Paid On Time'
  AND CAST(pay.paid_ts AS DATE) > CAST(i.received_ts AS DATE) + p.net_days
ORDER BY days_late DESC, p.po_id;
