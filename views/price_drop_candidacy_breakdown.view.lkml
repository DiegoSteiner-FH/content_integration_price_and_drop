view: price_drop_candidacy_breakdown {
  # Why (2026-09-08, DS): rule 1 escape hatch -- ports ci_pricedrop_bot's
  # CANDIDACY_BREAKDOWN_SQL (generate_report.py) directly. Pre-aggregated to
  # (date, gds, office, carrier, fare_type, currency, affiliate_id,
  # candidacy) inside the derived table itself, matching the bot's own
  # ~1.5K-rows/day shipping strategy, instead of exposing the full raw
  # contestant population to Looker.
  #
  # Why (2026-09-08, DS), fare_type/currency/affiliate_id added: affiliate_id
  # does not exist on ota.optimizer_candidates (same gotcha fixed earlier on
  # price_drop_candidates) -- it lives on ota.optimizer_attempts, joined via
  # attempt_id.
  #
  # Why (2026-09-09, DS), population narrowed to tag-only rows: originally
  # every candidate belonging to a GDS active for Price & Drop that day (any
  # gds with >=1 candidate tagged Dropped='Price Only' in the window, via an
  # active_pd_gds_by_date CTE), regardless of whether the row itself carried
  # the tag -- this matched ci_pricedrop_bot's own CANDIDACY_BREAKDOWN_SQL,
  # which was itself ported from and verified digit-for-digit against a
  # content_integration_optimizer Looker explore tile on 2026-08-14. Live
  # check 2026-09-09 found zero candidates with candidacy='Eligible' actually
  # carry the Dropped='Price Only' tag (dropped-for-price and eligible-winner
  # are mutually exclusive by construction) -- the ~8% Eligible share in the
  # old population came entirely from same-GDS/same-day siblings, not tagged
  # rows. The analyst who owns this dashboard determined it should only ever
  # report on candidates the tag was actually applied to, matching how
  # price_drop_candidates has always worked (STRAIGHT_JOIN directly on the
  # candidate's own tag row) -- intentionally diverging from
  # content_integration_optimizer going forward. ci_pricedrop_bot's own
  # generate_report.py was changed the same way in the same session. Verified
  # 2026-09-09 against 2026-09-08: total contestants 687,636 -> 91,189 (both
  # this view and ci_pricedrop_bot's updated report agree on the new total).
  derived_table: {
    sql:
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
      JOIN ota.optimizer_candidate_tags oct ON oct.candidate_id = oc.id
       AND {% condition price_drop_candidacy_breakdown.date_date %} oct.created_at {% endcondition %}
      JOIN ota.optimizer_tags ot ON ot.id = oct.tag_id AND ot.name = 'Dropped'
      JOIN ota.optimizer_attempts oa ON oa.id = oc.attempt_id
      LEFT JOIN ota.optimizer_candidates opc
        ON opc.id = oc.parent_id AND opc.reprice_type = 'single_to_multi'
      WHERE oct.value = 'Price Only'
        AND {% condition price_drop_candidacy_breakdown.date_date %} oc.created_at {% endcondition %}
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
    description: "Content source (GDS) of the candidate. Every row in this view is a candidate that itself carries a Dropped='Price Only' tag."
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
    description: "Candidate eligibility status. Contestants whose parent has reprice_type='single_to_multi' are force-reclassified to 'Inadmissible' regardless of their own raw candidacy value, matching a temporary override in the reference content_integration_optimizer Looker project. 'Eligible' never appears here -- a candidate dropped for price reasons is by definition not the winning/eligible one."
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
