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
    description: "Switches which contestant-info dimension this row groups by, based on the Breakdown By parameter above. Group a tile by this single field (instead of gds/office/carrier/etc. individually) to reproduce ci_pricedrop_bot's Breakdown Explorer tabs in one tile — switching the parameter re-groups the same tile instead of needing six separate ones. For real clickable tabs in one tile, see the price_drop_breakdown_explorer custom visualization instead."
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
    type: number
    value_format: "$#,##0.00"
    group_label: "4. MONETARY"
    label: "Extra Revenue (vs. Booked/Eligible)"
    sql: ${revenue} - COALESCE(${booked_revenue_on_attempt}, ${best_eligible_revenue_on_attempt}, 0) ;;
    description: "This row's revenue minus whatever was actually booked on the attempt, or the best non-LowRevenue Eligible candidate if nothing was booked, or 0 if neither exists. Mirrors ci_pricedrop_bot's compute_comparison() baseline chain (booked -> best Eligible -> $0). Made public 2026-09-08 (was hidden, used only inside extra_revenue_sum / extra_revenue_best_only_sum) so per-row analysis can use it directly; the price_drop_breakdown_explorer custom visualization no longer requires it (v2 uses pre-aggregated measures instead) but it stays public since it's independently useful."
  }

  dimension: eligible_delta {
    hidden: yes
    type: number
    sql: ${revenue} - ${best_eligible_revenue_on_attempt} ;;
    description: "This candidate's revenue minus the best non-LowRevenue Eligible candidate's revenue on the same attempt -- NULL when no such Eligible candidate exists (SQL NULL propagation, matching ci_pricedrop_bot's compute_vs_eligible_only() returning None). NEVER falls back to booked revenue or $0, unlike extra_revenue above -- this is a genuinely different comparison, used only by the Price & Drop funnel's Wins / Extra Revenue measures below."
  }

  # -------------------------
  # 5. COUNTS
  # -------------------------

  measure: admissible_candidates_count {
    type: count_distinct
    sql: ${attempt_id} ;;
    group_label: "5. COUNTS"
    label: "Admissible Candidates Count"
    description: "Count of distinct attempts with a de-duplicated Price & Drop Admissible candidate — one per attempt_id, matching ci_pricedrop_bot's headline count. Every row in this view already is that de-duped candidate (filtered inside the derived table above), so no additional CASE filter is needed. Intentionally all-buckets (Profitable + Breakeven + Near-miss) — see profitable_candidates_count for the Profitable-only count. Also the Price & Drop funnel's 'Attempts w/ Admissible' column -- confirmed 2026-09-09 by tracing build_dashboard_entry.py: the dashboard's 'rows' JSON field (what computePriceDropFunnel() actually receives) is assigned from explorer_rows, built from all_rows (every revenue bucket) -- not the same-named Python-local `rows` variable (profitable-only) used elsewhere for KPI-row summaries. Those two same-named things are different populations; this measure matches the one the funnel actually uses."
  }

  measure: profitable_candidates_count {
    type: count_distinct
    sql: CASE WHEN ${near_miss_bucket} = 'Profitable' THEN ${attempt_id} END ;;
    group_label: "5. COUNTS"
    label: "Profitable Candidates"
    description: "Count of de-duplicated Price & Drop Admissible candidates with revenue > 0 — matches ci_pricedrop_bot's 'Profitable Opportunities' KPI tile population exactly. Complements admissible_candidates_count (all three revenue buckets) and near_miss_count (near-miss bucket only). Formalizes a custom field the user built ad hoc (Admissible Candidates Count filtered to Revenue Bucket = Profitable) as a real measure."
  }

  measure: near_miss_count {
    type: count_distinct
    sql: CASE WHEN ${near_miss_bucket} = 'Near-miss' THEN ${attempt_id} END ;;
    group_label: "5. COUNTS"
    label: "Near-Miss Count"
    description: "Count of de-duplicated Price & Drop Admissible candidates with -50 < revenue <= 0."
  }

  # Why (2026-09-09, DS): Price & Drop funnel's Wins column. Mirrors
  # ci_pricedrop_bot's computePriceDropFunnel() JS exactly: iterates the
  # FULL admissible population (every revenue bucket -- see
  # admissible_candidates_count's description for why this is NOT
  # Profitable-only, a mistake in an earlier version of this measure) and
  # counts `r.ed > 0` (eligible_delta positive). NOT the same as
  # extra_revenue_best_only_sum's population above (which compares vs.
  # booked-or-eligible, not eligible-only). Verified 2026-09-09 against
  # 2026-09-08, gds='aerohub': wins=1,440 -- matches the dashboard exactly.
  measure: funnel_wins_count {
    type: count_distinct
    sql: CASE WHEN ${eligible_delta} > 0 THEN ${attempt_id} END ;;
    group_label: "5. COUNTS"
    label: "Wins (vs. Best Eligible)"
    description: "Count of de-duplicated Price & Drop Admissible candidates (any revenue bucket) that beat the best non-LowRevenue Eligible candidate on their own attempt (eligible_delta > 0). The Price & Drop funnel's Wins column -- matches ci_pricedrop_bot's computePriceDropFunnel() wins count exactly (verified 2026-09-09 against 2026-09-08, gds='aerohub': 1,440)."
  }

  # -------------------------
  # 6. REVENUE
  # -------------------------

  # Why (2026-09-09, DS): scoped to Revenue Bucket = Profitable (Tier 2 --
  # changes this measure's value for every existing tile using it). Matches
  # ci_pricedrop_bot's own "Total Simulated Revenue" headline KPI, which is
  # also profitable-only (sitting in Admissible price-drop candidates, per
  # the bot's own subtitle) -- previously this summed all three revenue
  # buckets (Profitable + Breakeven + Near-miss), which is why an earlier
  # tile comparison against the bot's dashboard came up short ($100,168.33
  # vs the bot's $103,072.31 for 2026-09-02). Verified match after this
  # change: $103,072.31 exactly.
  measure: revenue_sum {
    type: sum
    sql: CASE WHEN ${near_miss_bucket} = 'Profitable' THEN ${revenue} END ;;
    value_format: "$#,##0.00"
    group_label: "6. REVENUE"
    label: "Total Revenue"
    description: "Sum of revenue across de-duplicated Price & Drop Admissible candidates, restricted to Revenue Bucket = Profitable. Matches ci_pricedrop_bot's 'Total Simulated Revenue' KPI tile exactly (verified 2026-09-09 against 2026-09-02: $103,072.31)."
  }

  measure: extra_revenue_sum {
    type: sum
    sql: CASE WHEN ${near_miss_bucket} = 'Profitable' THEN ${extra_revenue} END ;;
    value_format: "$#,##0.00"
    group_label: "6. REVENUE"
    label: "Extra Revenue (If Booked)"
    description: "Sum of extra_revenue across de-duplicated Price & Drop Admissible candidates, restricted to Revenue Bucket = Profitable — the incremental revenue these content sources would have added if live-booking instead of simulation-only, vs. what was actually booked or the best Eligible alternative. Matches ci_pricedrop_bot's 'Extra vs. Booked/Eligible' KPI tile exactly (verified 2026-09-09 against 2026-09-02: $22,664.02)."
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
    sql: CASE WHEN ${near_miss_bucket} = 'Profitable' THEN ${revenue} END ;;
    value_format: "$#,##0.00"
    group_label: "6. REVENUE"
    label: "Average Revenue"
    description: "Average revenue per de-duplicated Price & Drop Admissible candidate, restricted to Revenue Bucket = Profitable. Matches ci_pricedrop_bot's 'Average per Opportunity' KPI tile exactly (verified 2026-09-09 against 2026-09-02: $32.95)."
  }

  # Why (2026-09-09, DS): Price & Drop funnel's Extra Revenue column.
  # Different metric from extra_revenue_sum/extra_revenue_best_only_sum
  # above -- those compare vs. booked-or-eligible-or-$0 and net in losses
  # (extra_revenue_sum) or clip losses to zero but still include losing rows
  # at $0 (extra_revenue_best_only_sum). This one sums eligible_delta
  # (vs. best Eligible ONLY, never booked) across the FULL admissible
  # population (any revenue bucket -- see admissible_candidates_count's
  # description), ONLY over winning rows (eligible_delta > 0) -- losing rows
  # are excluded entirely, not clipped. Matches ci_pricedrop_bot's
  # computePriceDropFunnel() extraRevenue exactly (verified 2026-09-09
  # against 2026-09-08, gds='aerohub': $37,482.28).
  measure: funnel_win_extra_revenue_sum {
    type: sum
    sql: CASE WHEN ${eligible_delta} > 0 THEN ${eligible_delta} END ;;
    value_format: "$#,##0.00"
    group_label: "6. REVENUE"
    label: "Extra Revenue (Funnel, vs. Best Eligible)"
    description: "Sum of eligible_delta across winning (eligible_delta > 0) Price & Drop Admissible candidates, any revenue bucket. The Price & Drop funnel's Extra Revenue column -- matches ci_pricedrop_bot's computePriceDropFunnel() exactly (verified 2026-09-09 against 2026-09-08, gds='aerohub': $37,482.28)."
  }
}
