-- 02_build_ledger.sql
-- Build the accounts payable sub-ledger that an audit actually works from:
--   goods_receipts, invoices, payments
-- Timestamps come straight from the event log. Amounts are derived from each PO.
--
-- This is a practice dataset, so the dollar side is simulated. Every "random" choice
-- below uses a hash of the PO number instead of RANDOM(), so the build is fully
-- repeatable: same input, same ledger, every run.

-- u(key, salt) -> a repeatable number between 0 and 1
CREATE OR REPLACE MACRO u(k, salt) AS (md5_number(k || ':' || salt) % 1000000) / 1000000.0;

-- Round to cents and keep money as DECIMAL, not floating point
CREATE OR REPLACE MACRO money(x, d) AS CAST(round(x, d) AS DECIMAL(12,2));

-- Push a timestamp off the weekend (Sat -> Mon, Sun -> Mon)
CREATE OR REPLACE MACRO weekday_ts(ts) AS
    ts + CASE dayofweek(ts) WHEN 6 THEN INTERVAL 2 DAY WHEN 0 THEN INTERVAL 1 DAY ELSE INTERVAL 0 DAY END;

-- One row per PO with the process flags the ledger depends on
CREATE OR REPLACE TABLE po_flags AS
SELECT
    p.po_id,
    p.po_amount,
    bool_or(e.activity = 'Set Payment Block')  AS was_blocked,
    bool_or(e.activity = 'Change Price')       AS price_changed,
    max(CASE WHEN e.activity = 'Receive Goods'   THEN e.event_ts END) AS goods_ts,
    max(CASE WHEN e.activity = 'Receive Invoice' THEN e.event_ts END) AS invoice_ts,
    max(CASE WHEN e.activity = 'Pay Invoice'     THEN e.event_ts END) AS pay_ts,
    -- what kind of 3-way-match problem a blocked invoice had
    CASE
        WHEN NOT bool_or(e.activity = 'Set Payment Block') THEN NULL
        WHEN u(p.po_id, 'type') < 0.40 THEN 'quantity'   -- billed in full, received short
        WHEN u(p.po_id, 'type') < 0.80 THEN 'price'      -- billed above the PO price
        ELSE 'both'
    END AS mismatch_type
FROM purchase_orders p
JOIN events e USING (po_id)
GROUP BY p.po_id, p.po_amount;

-- Original PO value before any price change (the event log only keeps the final value)
CREATE OR REPLACE TABLE po_price_history AS
SELECT
    po_id,
    money(po_amount / (1 + 0.04 + 0.11 * u(po_id, 'chg')), 2) AS original_amount,
    po_amount                                                AS final_amount
FROM po_flags
WHERE price_changed;

-- Goods receipts: received value, short on quantity-mismatch POs
CREATE OR REPLACE TABLE goods_receipts AS
SELECT
    'GR-' || substr(po_id, 4)     AS gr_id,
    po_id,
    goods_ts                     AS received_ts,
    CASE
        WHEN mismatch_type IN ('quantity', 'both')
            THEN money(po_amount * (0.85 + 0.10 * u(po_id, 'qty')), 2)
        ELSE po_amount
    END                          AS received_amount
FROM po_flags
WHERE goods_ts IS NOT NULL;

-- Invoices: billed value, above the PO price on price-mismatch POs.
-- A handful of unblocked invoices are also over-billed; those are the ones
-- the payment block control should have caught and didn't.
CREATE OR REPLACE TABLE invoices AS
WITH base AS (
    SELECT
        f.po_id,
        p.vendor_name,
        f.invoice_ts,
        CASE
            WHEN f.mismatch_type IN ('price', 'both')
                THEN money(f.po_amount * (1.03 + 0.09 * u(f.po_id, 'price')), 2)
            WHEN f.mismatch_type IS NULL AND f.pay_ts IS NOT NULL AND u(f.po_id, 'leak') < 0.035
                THEN money(f.po_amount * (1.025 + 0.035 * u(f.po_id, 'leakamt')), 2)
            ELSE f.po_amount
        END AS invoice_amount
    FROM po_flags f
    JOIN purchase_orders p USING (po_id)
    WHERE f.invoice_ts IS NOT NULL
)
SELECT
    'INV-' || lpad(CAST(ROW_NUMBER() OVER (ORDER BY b.invoice_ts, b.po_id) AS VARCHAR), 5, '0') AS invoice_id,
    v.vendor_code || '-' || CAST(41000 + ROW_NUMBER() OVER (PARTITION BY b.vendor_name ORDER BY b.invoice_ts) * 7
                                 + CAST(u(b.po_id, 'num') * 6 AS INT) AS VARCHAR) AS vendor_invoice_no,
    b.po_id,
    v.vendor_id,
    b.invoice_ts AS received_ts,
    b.invoice_amount
FROM base b
JOIN vendors v USING (vendor_name);

-- Payments for the original invoices.
-- Blocked invoices: about half were short-paid to the matched amount after the dispute,
-- the rest were released and paid in full.
CREATE OR REPLACE TABLE payments AS
WITH gross AS (
    SELECT
        i.invoice_id,
        i.po_id,
        i.received_ts,
        f.pay_ts,
        p.discount_terms,
        CASE
            WHEN f.mismatch_type IS NOT NULL AND u(f.po_id, 'resolve') < 0.55
                THEN least(f.po_amount, coalesce(g.received_amount, f.po_amount))
            ELSE i.invoice_amount
        END AS gross_amount
    FROM invoices i
    JOIN po_flags f USING (po_id)
    JOIN purchase_orders p USING (po_id)
    LEFT JOIN goods_receipts g USING (po_id)
    WHERE f.pay_ts IS NOT NULL
)
SELECT
    'PAY-' || substr(po_id, 4) AS payment_id,
    invoice_id,
    pay_ts                     AS paid_ts,
    gross_amount,
    -- 2/10 Net 30: 2% off when paid within 10 days of receiving the invoice
    CASE WHEN discount_terms AND date_diff('day', received_ts, pay_ts) <= 10
         THEN money(gross_amount * 0.02, 2) ELSE 0 END AS discount_taken,
    gross_amount - CASE WHEN discount_terms AND date_diff('day', received_ts, pay_ts) <= 10
                        THEN money(gross_amount * 0.02, 2) ELSE 0 END AS amount_paid
FROM gross;

-- Duplicate invoices: the same bill submitted a second time with the invoice number
-- formatted differently, entered as a new invoice and paid again.
CREATE OR REPLACE TABLE duplicate_seed AS
SELECT i.*, p.net_days
FROM invoices i
JOIN po_flags f USING (po_id)
JOIN purchase_orders p USING (po_id)
WHERE f.pay_ts IS NOT NULL AND f.mismatch_type IS NULL AND u(i.po_id, 'dup') < 0.022;

INSERT INTO invoices
SELECT
    'INV-' || lpad(CAST(90000 + ROW_NUMBER() OVER (ORDER BY po_id) AS VARCHAR), 5, '0') AS invoice_id,
    CASE
        WHEN u(po_id, 'fmt') < 0.35 THEN replace(vendor_invoice_no, '-', '')          -- "AIS-41007" -> "AIS41007"
        WHEN u(po_id, 'fmt') < 0.70 THEN replace(vendor_invoice_no, '-', '-0')        -- "AIS-41007" -> "AIS-041007"
        ELSE vendor_invoice_no || 'A'                                                  -- "AIS-41007" -> "AIS-41007A"
    END AS vendor_invoice_no,
    po_id,
    vendor_id,
    weekday_ts(received_ts + INTERVAL (6 + CAST(u(po_id, 'dupdays') * 18 AS INT)) DAY) AS received_ts,
    invoice_amount
FROM duplicate_seed;

INSERT INTO payments
SELECT
    'PAY-D' || substr(i.invoice_id, 5)  AS payment_id,
    i.invoice_id,
    weekday_ts(i.received_ts + INTERVAL (d.net_days - 4) DAY) AS paid_ts,
    i.invoice_amount AS gross_amount,
    0                AS discount_taken,
    i.invoice_amount AS amount_paid
FROM invoices i
JOIN duplicate_seed d USING (po_id)
WHERE i.invoice_id >= 'INV-9';

DROP TABLE duplicate_seed;
