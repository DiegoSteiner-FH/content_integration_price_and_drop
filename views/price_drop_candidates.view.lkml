view: price_drop_candidates {
  # Why (2026-09-08, DS): rule 1 escape hatch -- unavoidable window function.
  # The prior version was a plain view on ota.optimizer_candidates with the
  # per-attempt de-dup and booked/eligible baseline lookups implemented as
  # correlated subqueries, each duplicated once per referencing measure in
  # Looker's generated SQL (verified: up to 4x per query). Measured 5,017,035
  # candidate rows scanned for a 7-day window when only ~36,530 are actually
  # Admissible + Dropped='Price Only'. This derived table filters to that
  # slice up front, ranks with ROW_NUMBER() once, and joins to the booked/
  # eligible baselines once via their own ranked CTEs (same shape as
  # ci_pricedrop_bot's own generate_report.py). Verified parity against the
  # prior plain-view version for 2026-09-01..09-08: profitable_count=20156,
  # total_revenue=755793.55, avg_revenue=37.50, extra_revenue_sum=233893.47,
  # extra_revenue_best_only_sum=380963.63 -- all five match exactly.
  derived_table: {
    sql:
      WITH admissible AS (
        SELECT
          oc.id, oc.attempt_id, oc.gds, oc.gds_account_id, oc.validating_carrier,
          oc.revenue, oc.fare_type, oc.currency, oc.created_at,
          ROW_NUMBER() OVER (PARTITION BY oc.attempt_id ORDER BY oc.revenue DESC, oc.id ASC) AS rn
        FROM ota.optimizer_candidates oc
        STRAIGHT_JOIN ota.optimizer_candidate_tags oct ON oct.candidate_id = oc.id
        STRAIGHT_JOIN ota.optimizer_tags ot ON ot.id = oct.tag_id AND ot.name = 'Dropped'
        WHERE oct.value = 'Price Only'
          AND oc.candidacy = 'Admissible'
          AND oc.revenue > -50
          AND {% condition price_drop_candidates.date_date %} oc.created_at {% endcondition %}
      ),
      best_per_attempt AS (
        SELECT * FROM admissible WHERE rn = 1
      ),
      booked_ranked AS (
        SELECT oab.attempt_id, bc.revenue AS booked_revenue,
          ROW_NUMBER() OVER (PARTITION BY oab.attempt_id ORDER BY bc.revenue DESC, bc.id ASC) AS rn
        FROM ota.optimizer_attempt_bookings oab
        JOIN ota.optimizer_candidates bc ON bc.id = oab.candidate_id
        WHERE oab.attempt_id IN (SELECT attempt_id FROM best_per_attempt)
      ),
      booked AS (
        SELECT attempt_id, booked_revenue FROM booked_ranked WHERE rn = 1
      ),
      best_eligible_ranked AS (
        SELECT oc2.attempt_id, oc2.revenue AS best_eligible_revenue,
          ROW_NUMBER() OVER (PARTITION BY oc2.attempt_id ORDER BY oc2.revenue DESC, oc2.id ASC) AS rn
        FROM ota.optimizer_candidates oc2
        WHERE oc2.attempt_id IN (SELECT attempt_id FROM best_per_attempt)
          AND oc2.candidacy = 'Eligible'
          AND NOT EXISTS (
            SELECT 1
            FROM ota.optimizer_candidate_tags octlr
            JOIN ota.optimizer_tags otlr ON otlr.id = octlr.tag_id AND otlr.name = 'LowRevenue'
            WHERE octlr.candidate_id = oc2.id
          )
      ),
      best_eligible AS (
        SELECT attempt_id, best_eligible_revenue FROM best_eligible_ranked WHERE rn = 1
      )
      SELECT
        b.id,
        b.attempt_id,
        b.gds,
        b.gds_account_id,
        b.validating_carrier,
        b.revenue,
        b.fare_type,
        b.currency,
        oa.affiliate_id,
        b.created_at,
        bk.booked_revenue,
        be.best_eligible_revenue
      FROM best_per_attempt b
      JOIN ota.optimizer_attempts oa ON oa.id = b.attempt_id
      LEFT JOIN booked bk ON bk.attempt_id = b.attempt_id
      LEFT JOIN best_eligible be ON be.attempt_id = b.attempt_id
    ;;
  }

  # -------------------------
  # DIMENSIONS
  # -------------------------

  dimension: id {
    primary_key: yes
    hidden: yes
    type: number
    sql: ${TABLE}.id ;;
  }

  dimension: attempt_id {
    hidden: yes
    type: number
    sql: ${TABLE}.attempt_id ;;
  }

  # -------------------------
  # 1. DATE
  # -------------------------

  dimension_group: date {
    type: time
    timeframes: [date, week, month, quarter, year, hour, time, raw]
    sql: ${TABLE}.created_at ;;
    group_label: "1. DATE"
    label: "Created"
    description: "Optimizer candidate's created_at timestamp (stored UTC). ci_pricedrop_bot's own report labels itself America/Toronto but never actually converts before querying (its strftime() on a tz-aware datetime just formats the naive wall-clock fields) — so its real window is the literal date string, same as this dimension. Verified 2026-09-08 against 2026-09-02: literal UTC-style day boundary reproduces the bot's Profitable Opportunities figures ($103,072.31 / 3,128 / $32.95 avg) exactly."
  }

  # -------------------------
  # 2. CONTESTANT INFO
  # -------------------------

  dimension: gds {
    type: string
    group_label: "2. CONTESTANT INFO"
    label: "Content Source"
    sql: ${TABLE}.gds ;;
    suggestions: ["aerohub", "tiantai", "travelportplus", "gtsfly", "travelcaster"]
    description: "Content source (GDS) that produced this candidate. Confirmed 2026-08-14 (ci_pricedrop_bot skill doc) to be one of 5 sources currently active for the Price & Drop simulation; a new source can appear before this list is updated."
  }

  dimension: office {
    type: string
    group_label: "2. CONTESTANT INFO"
    label: "Office Id"
    sql: ${TABLE}.gds_account_id ;;
    description: "GDS account / office ID of the candidate (ota.optimizer_candidates.gds_account_id)."
  }

  dimension: carrier {
    type: string
    group_label: "2. CONTESTANT INFO"
    label: "Validating Carrier"
    sql: ${TABLE}.validating_carrier ;;
    description: "Validating carrier of the candidate."
  }

  dimension: fare_type {
    type: string
    group_label: "2. CONTESTANT INFO"
    label: "Fare Type"
    sql: ${TABLE}.fare_type ;;
    description: "Fare type of the candidate."
  }

  dimension: currency {
    type: string
    group_label: "2. CONTESTANT INFO"
    label: "Currency"
    sql: ${TABLE}.currency ;;
    description: "Candidate's own currency (ota.optimizer_candidates.currency) — read directly off MySQL, unlike ci_pricedrop_bot's report which pulls currency from ClickHouse jupiter_optimizer_attempt_summary because non-booked candidates have no bookability row."
  }

  dimension: affiliate_id {
    type: number
    group_label: "2. CONTESTANT INFO"
    label: "Affiliate ID"
    sql: ${TABLE}.affiliate_id ;;
    description: "Affiliate the search attempt belongs to. Fixed 2026-09-08: sourced from ota.optimizer_attempts (joined via attempt_id) inside the derived table — that column does not exist on ota.optimizer_candidates at all, and the prior version of this field would have errored the moment anyone queried it."
  }

  # -------------------------
  # 2b. BREAKDOWN SWITCHER
  # -------------------------

  parameter: breakdown_by {
    type: string
    label: "Breakdown By"
    description: "Drives the breakdown dimension below — pick which contestant-info field a single tile groups by, instead of building one tile per field. Route is not available (would need a new ClickHouse join to jupiter_optimizer_attempt_summary, not present in this project)."
    allowed_value: { label: "Content Source" value: "gds" }
    allowed_value: { label: "Office" value: "office" }
    allowed_value: { label: "Validating Carrier" value: "carrier" }
    allowed_value: { label: "Currency" value: "currency" }
    allowed_value: { label: "Fare Type" value: "fare_type" }
    allowed_value: { label: "Affiliate ID" value: "affiliate_id" }
    default_value: "gds"
  }

  dimension: breakdown {
    label_from_parameter: breakdown_by
    type: string
    group_label: "2. CONTESTANT INFO"
    sql:
      CASE
        WHEN {% parameter breakdown_by %} = 'gds' THEN ${gds}
        WHEN {% parameter breakdown_by %} = 'office' THEN ${office}
        WHEN {% parameter breakdown_by %} = 'carrier' THEN ${carrier}
        WHEN {% parameter breakdown_by %} = 'currency' THEN ${currency}
        WHEN {% parameter breakdown_by %} = 'fare_type' THEN ${fare_type}
        WHEN {% parameter breakdown_by %} = 'affiliate_id' THEN CAST(${affiliate_id} AS CHAR)
      END ;;
    description: "Switches which contestant-info dimension this row groups by, based on the Breakdown By parameter above. Group a tile by this single field (instead of gds/office/carrier/etc. individually) to reproduce ci_pricedrop_bot's Breakdown Explorer tabs in one tile — switching the parameter re-groups the same tile instead of needing six separate ones."
  }

  # -------------------------
  # 3. BUCKETS
  # -------------------------

  dimension: near_miss_bucket {
    type: string
    group_label: "3. BUCKETS"
    label: "Revenue Bucket"
    sql: CASE
      WHEN ${TABLE}.revenue > 0 THEN 'Profitable'
      WHEN ${TABLE}.revenue = 0 THEN 'Breakeven'
      ELSE 'Near-miss'
    END ;;
    suggestions: ["Profitable", "Breakeven", "Near-miss"]
    description: "Profitable (revenue > 0), Breakeven (= 0), or Near-miss (-50 < revenue <= 0) — the same three buckets ci_pricedrop_bot's report and dashboard track. Every row in this view is already the de-duplicated Price & Drop Admissible candidate for its attempt (filtered inside the derived table above), so this bucket always resolves to one of the three values — never NULL."
  }

  # -------------------------
  # 4. MONETARY
  # -------------------------

  dimension: revenue {
    type: number
    value_format: "#,##0.00"
    group_label: "4. MONETARY"
    sql: ${TABLE}.revenue ;;
    description: "Simulated Price & Drop revenue of this candidate."
  }

  dimension: booked_revenue_on_attempt {
    hidden: yes
    type: number
    sql: ${TABLE}.booked_revenue ;;
    description: "Revenue of the highest-revenue candidate in ota.optimizer_attempt_bookings for this attempt (any row, not just a finalized booking_id) — hidden helper for extra_revenue. Computed once in the derived table's own booked_ranked CTE, matching ci_pricedrop_bot's booked_ranked CTE exactly."
  }

  dimension: best_eligible_revenue_on_attempt {
    hidden: yes
    type: number
    sql: ${TABLE}.best_eligible_revenue ;;
    description: "Revenue of the best Eligible-candidacy candidate on this attempt, excluding LowRevenue-tagged candidates (a LowRevenue candidate can still be Eligible but would never actually get booked in practice, same exclusion ci_pricedrop_bot applies) — hidden fallback helper for extra_revenue when nothing was booked. Computed once in the derived table's own best_eligible_ranked CTE."
  }

  dimension: extra_revenue {
    hidden: yes
    type: number
    sql: ${revenue} - COALESCE(${booked_revenue_on_attempt}, ${best_eligible_revenue_on_attempt}, 0) ;;
    description: "This row's revenue minus whatever was actually booked on the attempt, or the best non-LowRevenue Eligible candidate if nothing was booked, or 0 if neither exists. Mirrors ci_pricedrop_bot's compute_comparison() baseline chain (booked -> best Eligible -> $0)."
  }

  # -------------------------
  # 5. COUNTS
  # -------------------------

  measure: admissible_candidates_count {
    type: count_distinct
    sql: ${attempt_id} ;;
    group_label: "5. COUNTS"
    label: "Admissible Candidates Count"
    description: "Count of distinct attempts with a de-duplicated Price & Drop Admissible candidate — one per attempt_id, matching ci_pricedrop_bot's headline count. Every row in this view already is that de-duped candidate (filtered inside the derived table above), so no additional CASE filter is needed."
  }

  measure: near_miss_count {
    type: count_distinct
    sql: CASE WHEN ${near_miss_bucket} = 'Near-miss' THEN ${attempt_id} END ;;
    group_label: "5. COUNTS"
    label: "Near-Miss Count"
    description: "Count of de-duplicated Price & Drop Admissible candidates with -50 < revenue <= 0."
  }

  # -------------------------
  # 6. REVENUE
  # -------------------------

  measure: revenue_sum {
    type: sum
    sql: ${revenue} ;;
    value_format: "$#,##0.00"
    group_label: "6. REVENUE"
    label: "Total Revenue"
    description: "Sum of revenue across de-duplicated Price & Drop Admissible candidates."
  }

  measure: extra_revenue_sum {
    type: sum
    sql: ${extra_revenue} ;;
    value_format: "$#,##0.00"
    group_label: "6. REVENUE"
    label: "Extra Revenue (If Booked)"
    description: "Sum of extra_revenue across de-duplicated Price & Drop Admissible candidates — the incremental revenue these content sources would have added if live-booking instead of simulation-only, vs. what was actually booked or the best Eligible alternative."
  }

  measure: extra_revenue_best_only_sum {
    type: sum
    sql: CASE WHEN ${near_miss_bucket} = 'Profitable' AND ${extra_revenue} > 0 THEN ${extra_revenue} END ;;
    value_format: "$#,##0.00"
    group_label: "6. REVENUE"
    label: "Extra Rev. (Best Only)"
    description: "Sum of extra_revenue, clipped to zero on rows where the price-drop candidate lost to its booked/eligible baseline, restricted to profitable rows — the incremental revenue if this content source only ever substituted in on searches where it's the best option (vs. extra_revenue_sum, which nets in the losing searches too). Matches ci_pricedrop_bot's dashboard 'Extra Rev. (Best Only)' KPI tile exactly (verified 2026-09-08 against 2026-09-02: $46,602.01)."
  }

  measure: average_revenue {
    type: average
    sql: ${revenue} ;;
    value_format: "$#,##0.00"
    group_label: "6. REVENUE"
    label: "Average Revenue"
    description: "Average revenue per de-duplicated Price & Drop Admissible candidate."
  }
}
