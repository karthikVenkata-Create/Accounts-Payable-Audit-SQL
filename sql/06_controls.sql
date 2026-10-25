-- 06_controls.sql
-- Control breaks: spend that went around the purchasing rules.
-- Each one is tested from the event log, so it shows what actually happened,
-- not what the process says should happen.

-- First and last time each step happened on each PO
CREATE OR REPLACE TABLE po_timeline AS
SELECT
    po_id,
    min(event_ts) FILTER (WHERE activity = 'Create Purchase Requisition')        AS requisition_ts,
    min(event_ts) FILTER (WHERE activity = 'Create Purchase Order')              AS po_created_ts,
    min(event_ts) FILTER (WHERE activity = 'Approve Purchase Order')             AS first_approval_ts,
    max(event_ts) FILTER (WHERE activity = 'Approve Purchase Order')             AS last_approval_ts,
    min(event_ts) FILTER (WHERE activity = 'Approve Purchase Order (2nd Level)') AS second_approval_ts,
    max(event_ts) FILTER (WHERE activity = 'Change Price')                       AS price_change_ts,
    min(event_ts) FILTER (WHERE activity = 'Send Purchase Order to Vendor')      AS sent_ts,
    min(event_ts) FILTER (WHERE activity = 'Receive Goods')                      AS goods_ts,
    min(event_ts) FILTER (WHERE activity = 'Receive Invoice')                    AS invoice_ts,
    min(event_ts) FILTER (WHERE activity = 'Clear Invoice')                      AS cleared_ts,
    min(event_ts) FILTER (WHERE activity = 'Pay Invoice')                        AS paid_ts,
    min(event_ts) FILTER (WHERE activity = 'Cancel Purchase Order')              AS cancelled_ts,
    min(event_ts)                                                                AS first_event_ts
FROM events
GROUP BY po_id;

CREATE OR REPLACE TABLE control_breaks AS
-- 1. After-the-fact POs: the invoice arrived before anyone raised a PO
SELECT
    'Invoice before PO (after-the-fact purchasing)' AS control_break,
    p.po_id, p.vendor_name, p.department, p.po_amount,
    date_diff('day', t.invoice_ts, t.po_created_ts) || ' days after the invoice' AS detail
FROM po_timeline t JOIN purchase_orders p USING (po_id)
WHERE t.invoice_ts < t.po_created_ts

UNION ALL
-- 2. Orders over $10K that never got the required second-level approval
SELECT
    'Over $10K with no 2nd-level approval',
    p.po_id, p.vendor_name, p.department, p.po_amount,
    CASE WHEN t.first_approval_ts IS NULL THEN 'no approval of any kind' ELSE 'manager approval only' END
FROM po_timeline t JOIN purchase_orders p USING (po_id)
WHERE p.requires_2nd_approval AND t.second_approval_ts IS NULL

UNION ALL
-- 3. Price changed after approval, and nobody approved the new price
SELECT
    'Price changed with no re-approval',
    p.po_id, p.vendor_name, p.department, p.po_amount,
    'changed ' || strftime(t.price_change_ts, '%Y-%m-%d')
FROM po_timeline t JOIN purchase_orders p USING (po_id)
WHERE t.price_change_ts IS NOT NULL
  AND (t.last_approval_ts IS NULL OR t.last_approval_ts < t.price_change_ts)

UNION ALL
-- 4. Orders cancelled after they had already gone out to the vendor
SELECT
    'Cancelled after being sent to vendor',
    p.po_id, p.vendor_name, p.department, p.po_amount,
    date_diff('day', t.sent_ts, t.cancelled_ts) || ' days after sending'
FROM po_timeline t JOIN purchase_orders p USING (po_id)
WHERE t.cancelled_ts IS NOT NULL;

-- Segregation of duties: did anyone approve their own PO, or both receive goods
-- and clear the invoice? Tested, and reported even when the answer is zero.
CREATE OR REPLACE TABLE segregation_of_duties AS
SELECT
    'Requester approved own PO' AS test,
    count(*)                    AS violations
FROM events e JOIN purchase_orders p USING (po_id)
WHERE e.activity LIKE 'Approve%' AND e.user_id = p.requester
UNION ALL
SELECT
    'Same user received goods and cleared the invoice',
    count(*)
FROM (
    SELECT po_id
    FROM events
    WHERE activity IN ('Receive Goods', 'Clear Invoice')
    GROUP BY po_id, user_id
    HAVING count(DISTINCT activity) = 2
);

CREATE OR REPLACE TABLE control_breaks_summary AS
SELECT
    control_break,
    count(*)        AS purchase_orders,
    sum(po_amount)  AS spend
FROM control_breaks
GROUP BY control_break
ORDER BY spend DESC;
