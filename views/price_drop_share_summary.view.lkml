view: price_drop_share_summary {
  # Why (2026-09-11, DS): SQL-aggregated counterpart to price_drop_share /
  # price_drop_share_rows, built specifically to get past Looker's ~5,000-
  # row interactive query cap. That row-level view ships one row per
  # attempt (or per attempt + profitable content source) to the browser so
  # content_source_share.js can simulate "If Live" client-side with no
  # re-query -- but at real volume (measured: ~8,975 attempts/day just for
  # the admissible+booked-without-admissible population, before even
  # multiplying by a multi-day window) that raw-row design silently
  # truncates well below the true booking scope.
  #
  # This view moves the ENTIRE Today-vs-If-Live computation into the
  # derived table's own SQL instead -- same two populations
  # (admissible_by_gds + booked_without_admissible) and the same eligible_
  # delta / single_to_multi / LowRevenue / test-booking exclusions already
  # established in price_drop_share_rows and price_drop_candidates -- but
  # the FINAL output is one row per (panel, content source, carrier):
  # 'today' (each attempt's real booked_gds) and 'if_live' (the best
  # profitable content source among whichever sources the live_sources
  # filter below selects, falling back to the real booked_gds when none
  # qualify). That's still a small number of rows regardless of whether
  # the underlying window covers thousands or hundreds of thousands of
  # real bookings -- the aggregation happens once, in MySQL, never as raw
  # rows in the browser.
  #
  # Trade-off, confirmed explicitly with the user: "which sources are
  # live" is now a real Looker filter (live_sources), not an instant
  # client-side toggle -- changing it re-runs the query. Built as a fully
  # separate explore/view from price_drop_share / price_drop_share_rows /
  # content_source_share.js, which are untouched -- this can be dropped
  # entirely with no effect on anything else if it doesn't work out.
  #
  # Verified for 2026-09-08 (no live_sources filter, i.e. every source
  # considered): 8,975 real attempts, aggregated down to 24 distinct
  # content sources on the Today side (a couple more appear only on the If
  # Live side, e.g. gtsfly/travelcaster -- real Price & Drop-active
  # sources with too few actual bookings today to show up there, but with
  # real profitable candidates).
  #
  # carrier (2026-09-11, DS): added on request, same one-Validating-
  # Carrier-per-ATTEMPT convention price_drop_share_rows already
  # established (not per content source/panel) -- for the admissible-
  # tagged population, the single best-revenue candidate's carrier across
  # ALL content sources on that attempt (best_overall_carrier below, same
  # value price_drop_candidates.carrier / price_drop_share_rows.carrier
  # already use); for a booking with no admissible candidate at all, the
  # real booked candidate's own carrier. Both the Today and If Live rows
  # for one attempt share this same attempt-level carrier value -- this
  # view was never meant to attribute a carrier to one specific content
  # source, only to let you filter/break down the Share by the attempt's
  # own carrier, same as every other tile. Purely additive: this widens
  # the final grain from (panel, gds) to (panel, gds, carrier), which
  # only changes results for a query that explicitly selects carrier --
  # a query selecting just panel + gds (like the existing tile's own
  # query) still gets the exact same counts, since Looker's own SUM
  # re-aggregates across carrier when it isn't selected. No join is
  # involved anywhere in this view (unlike price_drop_any_tag's carrier
  # attempt, PR #44/#45), so there's no fan-out risk from widening the
  # grain here.
  #
  # date_filter / live_sources are both filter-only fields with no
  # corresponding dimension -- this view's final output has no date or
  # per-source-selection column at all (it's aggregated away entirely
  # inside the derived table), so neither can be a real dimension the way
  # every other explore's date_date is. Same pattern as price_drop_price_
  # rate's own attempt_id_filter: the filter value is pushed into the
  # derived table's own WHERE/ranking logic via Looker's condition-tag
  # mechanism, never exposed as an output column.
  filter: date_filter {
    type: date
    label: "Created Date"
    description: "Date range for both panels -- pushed into the derived table's own WHERE clause via Looker's condition-tag mechanism (same as every other date filter in this project), not a real output column since this view's final rows are aggregated across the whole selected range already."
  }

  filter: live_sources {
    type: string
    label: "Live Sources"
    suggestions: ["aerohub", "tiantai", "travelportplus", "gtsfly", "travelcaster"]
    description: "Which content sources count as 'live' in the If Live panel -- select specific sources to simulate 'what if only these were deployed', or leave empty to consider every source with a profitable candidate (the default/neutral state, matching the row-level Content Source Share tile's own default). Pushed into the derived table's own ranking logic via Looker's condition-tag mechanism -- changing this re-runs the query, since this view computes the comparison entirely in SQL specifically to avoid the per-attempt row-cap ceiling the row-level tile hits at real volume."
  }

  derived_table: {
    sql:
      WITH admissible_by_gds AS (
        SELECT
          oc.attempt_id, oc.gds, oc.revenue, oc.validating_carrier,
          ROW_NUMBER() OVER (PARTITION BY oc.attempt_id, oc.gds ORDER BY oc.revenue DESC, oc.id ASC) AS rn,
          ROW_NUMBER() OVER (PARTITION BY oc.attempt_id ORDER BY oc.revenue DESC, oc.id ASC) AS rn_overall
        FROM ota.optimizer_candidates oc
        STRAIGHT_JOIN ota.optimizer_candidate_tags oct ON oct.candidate_id = oc.id
        STRAIGHT_JOIN ota.optimizer_tags ot ON ot.id = oct.tag_id AND ot.name = 'Dropped'
        WHERE oct.value = 'Price Only'
          AND oc.candidacy = 'Admissible'
          AND oc.revenue > -50
          AND oc.created_at >= DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY)
          AND {% condition price_drop_share_summary.date_filter %} oc.created_at {% endcondition %}
          AND NOT EXISTS (
            SELECT 1 FROM ota.optimizer_attempt_bookings oab
            JOIN ota.bookings b ON b.id = oab.booking_id
            WHERE oab.attempt_id = oc.attempt_id
              AND (b.is_test = 1 OR b.cancel_reason = 'test')
          )
      ),
      best_per_gds AS (
        SELECT * FROM admissible_by_gds WHERE rn = 1
      ),
      admissible_attempts AS (
        SELECT DISTINCT attempt_id FROM best_per_gds
      ),
      best_overall_carrier AS (
        SELECT attempt_id, validating_carrier FROM admissible_by_gds WHERE rn_overall = 1
      ),
      best_eligible_ranked AS (
        SELECT
          oc2.attempt_id, oc2.revenue AS best_eligible_revenue,
          ROW_NUMBER() OVER (PARTITION BY oc2.attempt_id ORDER BY oc2.revenue DESC, oc2.id ASC) AS rn
        FROM ota.optimizer_candidates oc2
        WHERE oc2.attempt_id IN (SELECT attempt_id FROM admissible_attempts)
          AND oc2.candidacy = 'Eligible'
          AND NOT EXISTS (
            SELECT 1
            FROM ota.optimizer_candidate_tags octlr
            JOIN ota.optimizer_tags otlr ON otlr.id = octlr.tag_id AND otlr.name = 'LowRevenue'
            WHERE octlr.candidate_id = oc2.id
          )
          AND NOT EXISTS (
            SELECT 1 FROM ota.optimizer_candidates opc
            WHERE opc.id = oc2.parent_id AND opc.reprice_type = 'single_to_multi'
          )
      ),
      best_eligible AS (
        SELECT attempt_id, best_eligible_revenue FROM best_eligible_ranked WHERE rn = 1
      ),
      profitable_by_gds AS (
        SELECT
          bg.attempt_id, bg.gds,
          ROW_NUMBER() OVER (
            PARTITION BY bg.attempt_id
            ORDER BY (bg.revenue - COALESCE(be.best_eligible_revenue, 0)) DESC, bg.gds ASC
          ) AS rn
        FROM best_per_gds bg
        LEFT JOIN best_eligible be ON be.attempt_id = bg.attempt_id
        WHERE (bg.revenue - COALESCE(be.best_eligible_revenue, 0)) > 0
          AND {% condition price_drop_share_summary.live_sources %} bg.gds {% endcondition %}
      ),
      best_live_profitable AS (
        SELECT attempt_id, gds FROM profitable_by_gds WHERE rn = 1
      ),
      booked_admissible AS (
        SELECT
          oab.attempt_id, bc.gds AS booked_gds,
          ROW_NUMBER() OVER (PARTITION BY oab.attempt_id ORDER BY bc.revenue DESC, bc.id ASC) AS rn
        FROM ota.optimizer_attempt_bookings oab
        JOIN ota.optimizer_candidates bc ON bc.id = oab.candidate_id
        WHERE oab.attempt_id IN (SELECT attempt_id FROM admissible_attempts)
      ),
      booked_admissible_best AS (
        SELECT attempt_id, booked_gds FROM booked_admissible WHERE rn = 1
      ),
      booked_without_admissible AS (
        SELECT
          oab.attempt_id, bc.gds AS booked_gds, bc.validating_carrier AS carrier,
          ROW_NUMBER() OVER (PARTITION BY oab.attempt_id ORDER BY bc.revenue DESC, bc.id ASC) AS rn
        FROM ota.optimizer_attempt_bookings oab
        JOIN ota.optimizer_candidates bc ON bc.id = oab.candidate_id
        JOIN ota.optimizer_attempts oa ON oa.id = oab.attempt_id
        WHERE oa.created_at >= DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY)
          AND {% condition price_drop_share_summary.date_filter %} oa.created_at {% endcondition %}
          AND oab.attempt_id NOT IN (SELECT attempt_id FROM admissible_attempts)
          AND NOT EXISTS (
            SELECT 1 FROM ota.bookings b2
            WHERE b2.id = oab.booking_id
              AND (b2.is_test = 1 OR b2.cancel_reason = 'test')
          )
      ),
      booked_without_admissible_best AS (
        SELECT attempt_id, booked_gds, carrier FROM booked_without_admissible WHERE rn = 1
      ),
      base_attempts AS (
        SELECT
          aa.attempt_id,
          bab.booked_gds AS today_gds,
          COALESCE(blp.gds, bab.booked_gds) AS if_live_gds,
          boc.validating_carrier AS carrier
        FROM admissible_attempts aa
        LEFT JOIN booked_admissible_best bab ON bab.attempt_id = aa.attempt_id
        LEFT JOIN best_live_profitable blp ON blp.attempt_id = aa.attempt_id
        LEFT JOIN best_overall_carrier boc ON boc.attempt_id = aa.attempt_id
        UNION ALL
        SELECT
          bwab.attempt_id,
          bwab.booked_gds AS today_gds,
          bwab.booked_gds AS if_live_gds,
          bwab.carrier
        FROM booked_without_admissible_best bwab
      )
      SELECT 'today' AS panel, today_gds AS gds, carrier, COUNT(*) AS n
      FROM base_attempts
      GROUP BY today_gds, carrier
      UNION ALL
      SELECT 'if_live' AS panel, if_live_gds AS gds, carrier, COUNT(*) AS n
      FROM base_attempts
      GROUP BY if_live_gds, carrier
    ;;
  }

  dimension: pk {
    primary_key: yes
    hidden: yes
    type: string
    sql: CONCAT(${TABLE}.panel, '|', COALESCE(${TABLE}.gds, '(none)'), '|', COALESCE(${TABLE}.carrier, '(none)')) ;;
  }

  dimension: panel {
    type: string
    group_label: "1. SHARE"
    label: "Panel"
    sql: ${TABLE}.panel ;;
    suggestions: ["today", "if_live"]
    description: "'today': the attempt's real, actual booked content source. 'if_live': the best content source among the live_sources filter's selection that beat the best real Eligible candidate on that attempt (eligible_delta > 0), falling back to the real booked content source when none qualify. Both panels share the exact same denominator -- every real booking in the window, tagged or not."
  }

  dimension: gds {
    type: string
    group_label: "1. SHARE"
    label: "Content Source"
    sql: ${TABLE}.gds ;;
    description: "The content source this row's count belongs to, within whichever panel (Today or If Live) this row represents. NULL becomes '(none)' upstream for an attempt that was never booked at all and also had no profitable candidate to fall back to."
  }

  dimension: carrier {
    type: string
    group_label: "1. SHARE"
    label: "Validating Carrier"
    sql: ${TABLE}.carrier ;;
    description: "One Validating Carrier per attempt (not per content source/panel) -- for the admissible-tagged population, the single best-revenue candidate's carrier across ALL content sources on that attempt (same value price_drop_candidates.carrier / price_drop_share_rows.carrier already use); for a booking with no admissible candidate at all, the real booked candidate's own carrier. Both the Today and If Live rows for one attempt share this same value. Adding this to a query widens the grain from (panel, gds) to (panel, gds, carrier) -- a query that leaves carrier unselected still gets the exact same Bookings counts as before, since Looker's own SUM re-aggregates across carrier when it isn't in the query."
  }

  measure: count {
    type: sum
    sql: ${TABLE}.n ;;
    group_label: "2. COUNTS"
    label: "Bookings"
    description: "Count of real attempts assigned to this (panel, content source[, carrier]) combination. Sum across every content source within one panel to get that panel's total 'Bookings in scope' -- both panels always sum to the identical total, since they share the same denominator."
  }
}
