view: price_drop_candidates {
  sql_table_name: ota.optimizer_candidates ;;

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
    timeframes: [date, week, month, quarter, year, raw]
    sql: ${TABLE}.created_at ;;
    group_label: "1. DATE"
    label: "Candidate Created"
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
    label: "Office"
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
    description: "Affiliate the search attempt belongs to."
  }

  # -------------------------
  # 3. BUCKETS
  # -------------------------

  dimension: is_price_only_dropped {
    hidden: yes
    type: yesno
    sql: EXISTS (
      SELECT 1
      FROM ota.optimizer_candidate_tags oct
      INNER JOIN ota.optimizer_tags ot ON ot.id = oct.tag_id
      WHERE oct.candidate_id = ${TABLE}.id
        AND ot.name = 'Dropped'
        AND oct.value = 'Price Only'
    ) ;;
    description: "True when this candidate carries a Dropped tag valued exactly 'Price Only' — the Price & Drop simulation's own demotion tag (distinct from the 'Mixed Fare Types' Dropped value covered by ci_mixedfare_bot instead)."
  }

  dimension: is_price_drop_admissible {
    hidden: yes
    type: yesno
    sql: ${TABLE}.candidacy = 'Admissible' AND ${is_price_only_dropped} AND ${TABLE}.revenue > -50 ;;
    description: "True when candidacy = 'Admissible', the Dropped tag is valued 'Price Only', and revenue clears the -50 near-miss floor (NEAR_MISS_FLOOR) — ci_pricedrop_bot's exact MySQL slice, before per-attempt de-dup."
  }

  # Why (2026-09-08, DS): the Optimizer tries multiple office/GDS accounts per
  # search, so summing every Price & Drop Admissible row overstates the
  # opportunity by roughly 1.5-4x (measured live: 5,120 raw rows / 3,352
  # distinct attempts in a 1-day sample). ci_pricedrop_bot's own report
  # de-dupes to the single highest-revenue candidate per attempt_id; this
  # correlated subquery reproduces that same de-dup in LookML rather than a
  # window function, matching the correlated-subquery style already used for
  # next_eligible_non_promoted_revenue etc. in content_integration_optimizer.
  dimension: is_best_candidate_for_attempt {
    hidden: yes
    type: yesno
    sql: ${TABLE}.id = (
      SELECT oc2.id
      FROM ota.optimizer_candidates oc2
      WHERE oc2.attempt_id = ${TABLE}.attempt_id
        AND oc2.candidacy = 'Admissible'
        AND oc2.revenue > -50
        AND EXISTS (
          SELECT 1
          FROM ota.optimizer_candidate_tags oct2
          INNER JOIN ota.optimizer_tags ot2 ON ot2.id = oct2.tag_id
          WHERE oct2.candidate_id = oc2.id
            AND ot2.name = 'Dropped'
            AND oct2.value = 'Price Only'
        )
      ORDER BY oc2.revenue DESC, oc2.id ASC
      LIMIT 1
    ) ;;
    description: "True only on the single highest-revenue Price & Drop Admissible candidate per attempt_id (ties broken by lowest id) — the de-dup helper for is_price_drop_row."
  }

  dimension: is_price_drop_row {
    type: yesno
    group_label: "3. BUCKETS"
    label: "Is Price Drop Candidate (Deduped)"
    sql: ${is_price_drop_admissible} AND ${is_best_candidate_for_attempt} ;;
    description: "True on exactly one row per attempt_id: the highest-revenue Admissible candidate carrying a Dropped='Price Only' tag with revenue > -50. Every measure on this view is pre-filtered to this = Yes; filter dimension-only queries to this = Yes too, or a plain COUNT(*) will include the un-deduped rows."
  }

  dimension: near_miss_bucket {
    type: string
    group_label: "3. BUCKETS"
    label: "Revenue Bucket"
    sql: CASE
      WHEN NOT ${is_price_drop_row} THEN NULL
      WHEN ${TABLE}.revenue > 0 THEN 'Profitable'
      WHEN ${TABLE}.revenue = 0 THEN 'Breakeven'
      ELSE 'Near-miss'
    END ;;
    suggestions: ["Profitable", "Breakeven", "Near-miss"]
    description: "Profitable (revenue > 0), Breakeven (= 0), or Near-miss (-50 < revenue <= 0) — the same three buckets ci_pricedrop_bot's report and dashboard track. NULL on rows that are not the de-duped Price & Drop row for their attempt."
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

  # Why (2026-09-08, DS): must NOT filter to booking_id IS NOT NULL and must
  # order by revenue DESC before LIMIT 1 -- ci_pricedrop_bot's own booked_ranked
  # CTE treats ANY row in ota.optimizer_attempt_bookings for the attempt as the
  # "booked" baseline (ROW_NUMBER() ... ORDER BY bc.revenue DESC, bc.id ASC),
  # including the 183,312 rows across the table where booking_id IS NULL
  # (attempted-but-not-finalized bookings). An earlier version of this
  # dimension wrongly excluded those, which shifted the booked-vs-eligible
  # baseline for a subset of attempts. Verified 2026-09-08 against 2026-09-02:
  # this exact logic reproduces the dashboard's "Extra vs. Booked/Eligible"
  # figure to the penny ($22,664.02, profitable rows only).
  dimension: booked_revenue_on_attempt {
    hidden: yes
    type: number
    sql: (
      SELECT ocb.revenue
      FROM ota.optimizer_attempt_bookings oab
      INNER JOIN ota.optimizer_candidates ocb ON ocb.id = oab.candidate_id
      WHERE oab.attempt_id = ${TABLE}.attempt_id
      ORDER BY ocb.revenue DESC, ocb.id ASC
      LIMIT 1
    ) ;;
    description: "Revenue of the highest-revenue candidate in ota.optimizer_attempt_bookings for this attempt (any row, not just a finalized booking_id) — hidden helper for extra_revenue. Matches ci_pricedrop_bot's own booked_ranked CTE exactly."
  }

  dimension: best_eligible_revenue_on_attempt {
    hidden: yes
    type: number
    sql: (
      SELECT oce.revenue
      FROM ota.optimizer_candidates oce
      WHERE oce.attempt_id = ${TABLE}.attempt_id
        AND oce.candidacy = 'Eligible'
        AND NOT EXISTS (
          SELECT 1
          FROM ota.optimizer_candidate_tags octlr
          INNER JOIN ota.optimizer_tags otlr ON otlr.id = octlr.tag_id
          WHERE octlr.candidate_id = oce.id
            AND otlr.name = 'LowRevenue'
        )
      ORDER BY oce.revenue DESC, oce.id ASC
      LIMIT 1
    ) ;;
    description: "Revenue of the best Eligible-candidacy candidate on this attempt, excluding LowRevenue-tagged candidates (a LowRevenue candidate can still be Eligible but would never actually get booked in practice, same exclusion ci_pricedrop_bot applies) — hidden fallback helper for extra_revenue when nothing was booked."
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
    sql: CASE WHEN ${is_price_drop_row} THEN ${attempt_id} END ;;
    group_label: "5. COUNTS"
    label: "Admissible Candidates Count"
    description: "Count of distinct attempts with a de-duplicated Price & Drop Admissible candidate — one per attempt_id, matching ci_pricedrop_bot's headline count."
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
    sql: CASE WHEN ${is_price_drop_row} THEN ${revenue} END ;;
    value_format: "$#,##0.00"
    group_label: "6. REVENUE"
    label: "Total Revenue"
    description: "Sum of revenue across de-duplicated Price & Drop Admissible candidates."
  }

  measure: extra_revenue_sum {
    type: sum
    sql: CASE WHEN ${is_price_drop_row} THEN ${extra_revenue} END ;;
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
    sql: CASE WHEN ${is_price_drop_row} THEN ${revenue} END ;;
    value_format: "$#,##0.00"
    group_label: "6. REVENUE"
    label: "Average Revenue"
    description: "Average revenue per de-duplicated Price & Drop Admissible candidate."
  }
}
