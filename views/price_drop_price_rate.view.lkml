view: price_drop_price_rate {
  # Why (2026-09-08, DS): rule 1 escape hatch -- ports ci_pricedrop_bot's
  # PRICE_RATE_SQL (generate_report.py) directly. Same population as
  # price_drop_candidacy_breakdown (every contestant, any candidacy, no
  # revenue floor, no per-attempt dedup, on a content source active for Price
  # & Drop on THAT SAME DAY -- see active_pd_gds_by_date below), classified by
  # revenue vs. baseline instead of by candidacy label. Baseline is booked
  # (status='issued', is_test=0 -- stricter than price_drop_candidates' own
  # booked_revenue_on_attempt, which intentionally has no status filter for
  # that Admissible-only slice; this is a genuinely different "booked"
  # definition for this broader population, matching the bot's own
  # PRICE_RATE_SQL exactly) then best non-LowRevenue Eligible candidate, then
  # null ("no_price"). Pre-aggregated to (date, gds, office, carrier,
  # fare_type, currency, affiliate_id, outcome) inside the derived table, same
  # size rationale as price_drop_candidacy_breakdown. Verified 2026-09-08
  # against 2026-09-02: 74,722 total contestants, no_price 68.46%, worse
  # ~24.8%, better ~6.3%, same ~0.37% -- matches ci_pricedrop_bot's Price Rate
  # tile (small % rounding differences only, total exact).
  #
  # Why (2026-09-08, DS), active_pd_gds fix: originally computed once across
  # the whole outer date-filtered range, then joined against every day's row
  # uniformly -- a GDS that only starts producing Dropped='Price Only'
  # candidates partway through a multi-day window (confirmed live: amadeus,
  # active from 2026-09-03 onward but not on 2026-09-02) got incorrectly
  # back-applied to every earlier day too, inflating those days' totals.
  # Fixed to compute active_pd_gds per (date, gds) pair, matching
  # ci_pricedrop_bot's own per-day invocation of PRICE_RATE_SQL exactly (the
  # bot always queries one single day at a time, so this distinction never
  # showed up in its own output). Re-verified 2026-09-08 across
  # 2026-09-02..09-07 after the fix: 74722 / 635895 / 578748 / 467893 /
  # 458624 / 530900 total contestants per day -- all match a live 7-day
  # window query exactly.
  #
  # Why (2026-09-08, DS), fare_type/currency/affiliate_id added: affiliate_id
  # does not exist on ota.optimizer_candidates -- it lives on
  # ota.optimizer_attempts, joined via attempt_id. Grain measured (correctly
  # scoped to active_pd_gds_by_date) at 2,057 -> 13,819 rows for 2026-09-02
  # after adding all three -- small enough to stay fast.
  derived_table: {
    sql:
      WITH active_pd_gds_by_date AS (
        SELECT DISTINCT DATE(oct.created_at) AS d, oc.gds
        FROM ota.optimizer_candidates oc
        JOIN ota.optimizer_candidate_tags oct ON oct.candidate_id = oc.id
         AND {% condition price_drop_price_rate.date_date %} oct.created_at {% endcondition %}
        JOIN ota.optimizer_tags ot ON ot.id = oct.tag_id AND ot.name = 'Dropped'
        WHERE oct.value = 'Price Only'
          AND {% condition price_drop_price_rate.date_date %} oc.created_at {% endcondition %}
      ),
      contestants AS (
        SELECT
          oc.id AS candidate_id, oc.attempt_id, oc.gds, oc.gds_account_id AS office_id,
          oc.validating_carrier AS carrier, oc.fare_type, oc.currency, oa.affiliate_id,
          oc.revenue, DATE(oc.created_at) AS d
        FROM ota.optimizer_candidates oc
        JOIN active_pd_gds_by_date ag ON ag.gds = oc.gds AND ag.d = DATE(oc.created_at)
        JOIN ota.optimizer_attempts oa ON oa.id = oc.attempt_id
        WHERE {% condition price_drop_price_rate.date_date %} oc.created_at {% endcondition %}
          AND NOT EXISTS (
            SELECT 1 FROM ota.optimizer_attempt_bookings oab
            JOIN ota.bookings b ON b.id = oab.booking_id
            WHERE oab.attempt_id = oc.attempt_id
              AND (b.is_test = 1 OR b.cancel_reason = 'test')
          )
      ),
      booked_ranked AS (
        SELECT oab.attempt_id, bc.revenue AS booked_revenue,
          ROW_NUMBER() OVER (PARTITION BY oab.attempt_id ORDER BY bc.revenue DESC, bc.id ASC) AS rn
        FROM ota.optimizer_attempt_bookings oab
        JOIN ota.optimizer_candidates bc ON bc.id = oab.candidate_id
        JOIN ota.bookings b ON b.id = oab.booking_id
        WHERE oab.attempt_id IN (SELECT DISTINCT attempt_id FROM contestants)
          AND b.status = 'issued' AND b.is_test = 0
      ),
      booked AS (
        SELECT attempt_id, booked_revenue FROM booked_ranked WHERE rn = 1
      ),
      best_eligible_ranked AS (
        SELECT oc2.attempt_id, oc2.revenue AS best_eligible_revenue,
          ROW_NUMBER() OVER (PARTITION BY oc2.attempt_id ORDER BY oc2.revenue DESC, oc2.id ASC) AS rn
        FROM ota.optimizer_candidates oc2
        WHERE oc2.attempt_id IN (SELECT DISTINCT attempt_id FROM contestants)
          AND oc2.candidacy = 'Eligible'
          AND NOT EXISTS (
            SELECT 1
            FROM ota.optimizer_candidate_tags oct_lr
            JOIN ota.optimizer_tags ot_lr ON ot_lr.id = oct_lr.tag_id AND ot_lr.name = 'LowRevenue'
            WHERE oct_lr.candidate_id = oc2.id
          )
      ),
      best_eligible AS (
        SELECT attempt_id, best_eligible_revenue FROM best_eligible_ranked WHERE rn = 1
      )
      SELECT
        ct.d,
        ct.gds,
        ct.office_id,
        ct.carrier,
        ct.fare_type,
        ct.currency,
        ct.affiliate_id,
        CASE
          WHEN ct.revenue IS NULL THEN 'no_price'
          WHEN ct.revenue > COALESCE(bk.booked_revenue, be.best_eligible_revenue, 0) THEN 'better'
          WHEN ct.revenue = COALESCE(bk.booked_revenue, be.best_eligible_revenue, 0) THEN 'same'
          ELSE 'worse'
        END AS outcome,
        COUNT(*) AS n
      FROM contestants ct
      LEFT JOIN booked bk ON bk.attempt_id = ct.attempt_id
      LEFT JOIN best_eligible be ON be.attempt_id = ct.attempt_id
      GROUP BY ct.d, ct.gds, ct.office_id, ct.carrier, ct.fare_type, ct.currency, ct.affiliate_id, outcome
    ;;
  }

  # -------------------------
  # 1. DATE
  # -------------------------

  dimension_group: date {
    type: time
    timeframes: [date, week, month, quarter, year]
    sql: ${TABLE}.d ;;
    group_label: "1. DATE"
    label: "Created"
    description: "Calendar day (UTC) the contestants in this row were created."
  }

  # -------------------------
  # 2. CONTESTANT INFO
  # -------------------------

  dimension: gds {
    type: string
    group_label: "2. CONTESTANT INFO"
    label: "Content Source"
    sql: ${TABLE}.gds ;;
    description: "Content source (GDS) that has at least one Dropped='Price Only'-tagged candidate on this same day."
  }

  dimension: office {
    type: string
    group_label: "2. CONTESTANT INFO"
    label: "Office Id"
    sql: ${TABLE}.office_id ;;
    description: "GDS account / office ID of the contestant."
  }

  dimension: carrier {
    type: string
    group_label: "2. CONTESTANT INFO"
    label: "Validating Carrier"
    sql: ${TABLE}.carrier ;;
    description: "Validating carrier of the contestant."
  }

  dimension: fare_type {
    type: string
    group_label: "2. CONTESTANT INFO"
    label: "Fare Type"
    sql: ${TABLE}.fare_type ;;
    description: "Fare type of the contestant (ota.optimizer_candidates.fare_type)."
  }

  dimension: currency {
    type: string
    group_label: "2. CONTESTANT INFO"
    label: "Currency"
    sql: ${TABLE}.currency ;;
    description: "Contestant's own currency (ota.optimizer_candidates.currency)."
  }

  dimension: affiliate_id {
    type: number
    group_label: "2. CONTESTANT INFO"
    label: "Affiliate ID"
    sql: ${TABLE}.affiliate_id ;;
    description: "Affiliate the search attempt belongs to (ota.optimizer_attempts.affiliate_id, joined via attempt_id)."
  }

  # -------------------------
  # 3. OUTCOME
  # -------------------------

  dimension: outcome {
    type: string
    group_label: "3. OUTCOME"
    label: "Price Outcome"
    sql: ${TABLE}.outcome ;;
    suggestions: ["better", "same", "worse", "no_price"]
    description: "'no_price': the contestant's own revenue is NULL (the repricing attempt never produced a usable price). 'better'/'same'/'worse': the contestant's own revenue vs. baseline, where baseline is the booked candidate on that attempt (status='issued', is_test=0) if one exists, else the best non-LowRevenue Eligible candidate, else $0."
  }

  # -------------------------
  # 4. COUNTS
  # -------------------------

  measure: total_contestants_count {
    type: sum
    sql: ${TABLE}.n ;;
    group_label: "4. COUNTS"
    label: "Total Contestants"
    description: "Sum of pre-aggregated contestant counts. Pivot on Price Outcome in the tile to reproduce ci_pricedrop_bot's Price Rate table shape (one column per outcome); use a % of total table calculation for the percentage columns."
  }
}
