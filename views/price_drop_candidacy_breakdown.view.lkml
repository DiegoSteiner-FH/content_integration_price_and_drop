view: price_drop_candidacy_breakdown {
  # Why (2026-09-08, DS): rule 1 escape hatch -- ports ci_pricedrop_bot's
  # CANDIDACY_BREAKDOWN_SQL (generate_report.py) directly. Population is EVERY
  # contestant (any candidacy, no revenue floor, no per-attempt dedup) on a
  # content source that has at least one Dropped='Price Only' tag on THAT SAME
  # DAY (see active_pd_gds_by_date below -- this must be scoped per-day, not
  # over the whole queried range, or a GDS that only becomes active partway
  # through a multi-day window gets counted as active retroactively for every
  # earlier day too). A much broader population than price_drop_candidates
  # (Admissible only). Pre-aggregated to (date, gds, office, carrier,
  # fare_type, currency, affiliate_id, candidacy) inside the derived table
  # itself, matching the bot's own ~1.5K-rows/day shipping strategy, instead of
  # exposing the full ~75K-row/day contestant population to Looker. Verified
  # 2026-09-08 against 2026-09-02: 74,722 total contestants, Admissible 7.29%,
  # Incalculable 66.45%, Unbookable 20.53% -- matches ci_pricedrop_bot's
  # Candidacy Breakdown tile exactly. Re-verified 2026-09-08 across
  # 2026-09-02..09-07 after the active_pd_gds per-day fix: 74722 / 635895 /
  # 578748 / 467893 / 458624 / 530900 -- all six days match a live 7-day-
  # window query exactly, including 09-02 which was wrong (636,208) before
  # that fix because 'amadeus' only started carrying a Dropped='Price Only'
  # tag on 09-03 onward and was incorrectly back-applied to 09-02 under the
  # old whole-window active_pd_gds.
  #
  # Why (2026-09-08, DS), fare_type/currency/affiliate_id added: affiliate_id
  # does not exist on ota.optimizer_candidates (same gotcha fixed earlier on
  # price_drop_candidates) -- it lives on ota.optimizer_attempts, joined via
  # attempt_id. Grain measured (correctly scoped to active_pd_gds_by_date,
  # not the whole optimizer_candidates table) at 2,057 -> 13,819 rows for
  # 2026-09-02 after adding all three -- small enough to stay fast. SUM(n)
  # still equals 74,722 for that day, confirming no value regression.
  derived_table: {
    sql:
      WITH active_pd_gds_by_date AS (
        SELECT DISTINCT DATE(oct.created_at) AS d, oc.gds
        FROM ota.optimizer_candidates oc
        JOIN ota.optimizer_candidate_tags oct ON oct.candidate_id = oc.id
         AND {% condition price_drop_candidacy_breakdown.date_date %} oct.created_at {% endcondition %}
        JOIN ota.optimizer_tags ot ON ot.id = oct.tag_id AND ot.name = 'Dropped'
        WHERE oct.value = 'Price Only'
          AND {% condition price_drop_candidacy_breakdown.date_date %} oc.created_at {% endcondition %}
      )
      SELECT
        DATE(oc.created_at) AS d,
        oc.gds,
        oc.gds_account_id AS office_id,
        oc.validating_carrier AS carrier,
        oc.fare_type,
        oc.currency,
        oa.affiliate_id,
        CASE WHEN opc.id IS NOT NULL THEN 'Inadmissible' ELSE oc.candidacy END AS candidacy,
        COUNT(*) AS n
      FROM ota.optimizer_candidates oc
      JOIN active_pd_gds_by_date ag ON ag.gds = oc.gds AND ag.d = DATE(oc.created_at)
      JOIN ota.optimizer_attempts oa ON oa.id = oc.attempt_id
      LEFT JOIN ota.optimizer_candidates opc
        ON opc.id = oc.parent_id AND opc.reprice_type = 'single_to_multi'
      WHERE {% condition price_drop_candidacy_breakdown.date_date %} oc.created_at {% endcondition %}
        AND NOT EXISTS (
          SELECT 1 FROM ota.optimizer_attempt_bookings oab
          JOIN ota.bookings b ON b.id = oab.booking_id
          WHERE oab.attempt_id = oc.attempt_id
            AND (b.is_test = 1 OR b.cancel_reason = 'test')
        )
      GROUP BY DATE(oc.created_at), oc.gds, oc.gds_account_id, oc.validating_carrier, oc.fare_type, oc.currency, oa.affiliate_id, candidacy
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
    description: "Content source (GDS) that has at least one Dropped='Price Only'-tagged candidate on this same day -- not restricted to the 5 sources ci_pricedrop_bot's other tiles focus on, since this covers every candidacy, not just Admissible ones."
  }

  dimension: office {
    type: string
    group_label: "2. CONTESTANT INFO"
    label: "Office Id"
    sql: ${TABLE}.office_id ;;
    description: "GDS account / office ID of the contestant (ota.optimizer_candidates.gds_account_id)."
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
    description: "Affiliate the search attempt belongs to (ota.optimizer_attempts.affiliate_id, joined via attempt_id -- this column does not exist on ota.optimizer_candidates itself)."
  }

  # -------------------------
  # 3. CANDIDACY
  # -------------------------

  dimension: candidacy {
    type: string
    group_label: "3. CANDIDACY"
    label: "Candidacy"
    sql: ${TABLE}.candidacy ;;
    suggestions: ["Admissible", "Unmatchable", "Unprofitable", "Unbookable", "Inadmissible", "Incalculable", "Unprocessable"]
    description: "Candidate eligibility status. Contestants whose parent has reprice_type='single_to_multi' are force-reclassified to 'Inadmissible' regardless of their own raw candidacy value, matching a temporary override in the reference content_integration_optimizer Looker project."
  }

  # -------------------------
  # 4. COUNTS
  # -------------------------

  measure: total_contestants_count {
    type: sum
    sql: ${TABLE}.n ;;
    group_label: "4. COUNTS"
    label: "Total Contestants"
    description: "Sum of pre-aggregated contestant counts. Pivot on Candidacy in the tile to reproduce ci_pricedrop_bot's Candidacy Breakdown table shape (one column per candidacy value); use a % of total table calculation for the percentage columns."
  }
}
