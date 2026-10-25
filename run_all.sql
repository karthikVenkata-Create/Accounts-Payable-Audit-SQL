-- run_all.sql
-- Builds the database, runs every test and writes the results to output/.
-- Run from the repo folder:   duckdb ap_audit.duckdb < run_all.sql

.bail on
.read sql/01_load.sql
.read sql/02_build_ledger.sql
.read sql/03_checks.sql

-- Stop here if any integrity check failed
SELECT CASE WHEN count(*) > 0
            THEN error('Integrity check failed: ' || string_agg(check_name, '; '))
       END
FROM audit_checks WHERE NOT passed;

.read sql/04_three_way_match.sql
.read sql/05_duplicate_invoices.sql
.read sql/06_controls.sql
.read sql/07_payment_timing.sql
.read sql/08_cycle_times.sql
.read sql/09_vendor_scorecard.sql
.read sql/10_summary.sql

COPY audit_checks             TO 'output/audit_checks.csv'             (HEADER);
COPY status_label_mismatch    TO 'output/status_label_mismatch.csv'    (HEADER);
COPY three_way_match          TO 'output/three_way_match.csv'          (HEADER);
COPY three_way_match_summary  TO 'output/three_way_match_summary.csv'  (HEADER);
COPY duplicate_test_results   TO 'output/duplicate_test_results.csv'   (HEADER);
COPY duplicate_invoices       TO 'output/duplicate_invoices.csv'       (HEADER);
COPY control_breaks           TO 'output/control_breaks.csv'           (HEADER);
COPY control_breaks_summary   TO 'output/control_breaks_summary.csv'   (HEADER);
COPY segregation_of_duties    TO 'output/segregation_of_duties.csv'    (HEADER);
COPY payment_timing_summary   TO 'output/payment_timing_summary.csv'   (HEADER);
COPY late_payments_by_vendor  TO 'output/late_payments_by_vendor.csv'  (HEADER);
COPY late_payments_by_month   TO 'output/late_payments_by_month.csv'   (HEADER);
COPY slowest_handoffs         TO 'output/slowest_handoffs.csv'         (HEADER);
COPY cycle_time_by_vendor     TO 'output/cycle_time_by_vendor.csv'     (HEADER);
COPY rework_impact            TO 'output/rework_impact.csv'            (HEADER);
COPY vendor_scorecard         TO 'output/vendor_scorecard.csv'         (HEADER);
COPY audit_summary            TO 'output/audit_summary.csv'            (HEADER);

.mode box
SELECT section, finding, items, dollars FROM audit_summary;
