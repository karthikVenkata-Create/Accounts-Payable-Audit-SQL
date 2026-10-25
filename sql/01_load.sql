-- 01_load.sql
-- Load the raw Procure-to-Pay data into typed staging tables.
--   purchase_orders : one row per PO (vendor, department, value, terms)
--   events          : one row per process step (the event log)

CREATE OR REPLACE TABLE purchase_orders AS
SELECT
    Case_ID                                  AS po_id,
    Vendor                                   AS vendor_name,
    Vendor_Region                            AS vendor_region,
    Department                               AS department,
    Requester                                AS requester,
    CAST(Order_Value_USD AS DECIMAL(12,2))   AS po_amount,
    Payment_Terms                            AS payment_terms,
    CASE Payment_Terms WHEN 'Net 45' THEN 45 ELSE 30 END       AS net_days,
    Payment_Terms = '2/10 Net 30'                             AS discount_terms,
    Requires_2nd_Approval = 'Yes'                             AS requires_2nd_approval,
    Case_Status                                              AS case_status
FROM read_csv('data/p2p_cases.csv', header = true, all_varchar = true);

CREATE OR REPLACE TABLE events AS
SELECT
    Case_ID                            AS po_id,
    Activity                           AS activity,
    CAST("Timestamp" AS TIMESTAMP)     AS event_ts,
    "User"                             AS user_id,
    -- order of steps within each PO, used for sequence checks
    ROW_NUMBER() OVER (PARTITION BY Case_ID ORDER BY CAST("Timestamp" AS TIMESTAMP), Activity) AS step_no
FROM read_csv('data/p2p_activities.csv', header = true, all_varchar = true);

CREATE OR REPLACE TABLE vendors AS
SELECT
    ROW_NUMBER() OVER (ORDER BY vendor_name)              AS vendor_id,
    vendor_name,
    vendor_region,
    -- short code used in invoice numbers, e.g. "Apex Industrial Supply" -> "AIS"
    regexp_replace(vendor_name, '([A-Z])[a-z]*\s*', '\1', 'g') AS vendor_code
FROM (SELECT DISTINCT vendor_name, vendor_region FROM purchase_orders);
