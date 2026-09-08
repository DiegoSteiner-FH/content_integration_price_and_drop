view: price_drop_candidacy_breakdown {
  # Why (2026-09-08, DS): rule 1 escape hatch -- ports ci_pricedrop_bot's
  # CANDIDACY_BREAKDOWN_SQL (generate_report.py) directly. Population is EVERY
  # contestant (any candidacy, no revenue floor, no per-attempt dedup) on a
  # content source that has at least one Dropped='Price Only' tag in the window
  # -- a much broader population than price_drop_candidates (Admissible only).
  # Pre-aggregated to (date, gds, carrier, candidacy) inside the derived table
  # itself, matching the bot's own ~1.5K-rows/day shipping strategy, instead of
  # exposing the full ~75K-row/day contestant population to Looker. Verified
  # 2026-09-08 against 2026-09-02: 74,722 total contestants, Admissible 7.29%,
  # Incalculable 66.45%, Unbookable 20.53% -- matches ci_pricedrop_bot's
  # Candidacy Breakdown tile exactly.
  derived_table: {
    sql:
      WITH active_pd_gds AS (
        SELECT DISTINCT oc.gds
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
        oc.validating_carrier AS carrier,
        CASE WHEN opc.id IS NOT NULL THEN 'Inadmissible' ELSE oc.candidacy END AS candidacy,
        COUNT(*) AS n
      FROM ota.optimizer_candidates oc
      JOIN active_pd_gds ag ON ag.gds = oc.gds
      LEFT JOIN ota.optimizer_candidates opc
        ON opc.id = oc.parent_id AND opc.reprice_type = 'single_to_multi'
      WHERE {% condition price_drop_candidacy_breakdown.date_date %} oc.created_at {% endcondition %}
        AND NOT EXISTS (
          SELECT 1 FROM ota.optimizer_attempt_bookings oab
          JOIN ota.bookings b ON b.id = oab.booking_id
          WHERE oab.attempt_id = oc.attempt_id
            AND (b.is_test = 1 OR b.cancel_reason = 'test')
        )
      GROUP BY DATE(oc.created_at), oc.gds, oc.validating_carrier, candidacy
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
    description: "Content source (GDS) that has at least one Dropped='Price Only'-tagged candidate in the query window -- not restricted to the 5 sources ci_pricedrop_bot's other tiles focus on, since this covers every candidacy, not just Admissible ones."
  }

  dimension: carrier {
    type: string
    group_label: "2. CONTESTANT INFO"
    label: "Validating Carrier"
    sql: ${TABLE}.carrier ;;
    description: "Validating carrier of the contestant."
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
