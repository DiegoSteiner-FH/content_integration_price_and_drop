view: price_drop_any_tag_bookings {
  # Why (2026-09-14, DS): booking-scoped sibling of price_drop_any_tag,
  # same top-of-funnel population (every attempt with a Dropped='Price
  # Only' tagged candidate for this content source, regardless of that
  # candidate's own candidacy or revenue) but additionally requiring the
  # attempt's real booking to have status='issued' AND is_test=0 -- a
  # genuinely completed, non-test sale. Same relationship to
  # price_drop_any_tag's own attempts_with_price_drop_count that
  # price_drop_candidates' booking_count/booking_total_revenue/
  # booking_avg_revenue/booking_extra_rev_best_only measures (PR #50) have
  # to their own opportunity-scoped counterparts -- a floor on real
  # conversion, not a replacement for the top-of-funnel denominator, which
  # stays as-is.
  #
  # Built as a fully separate view (not a measure bolted onto
  # price_drop_any_tag itself) for the same reason price_drop_share_summary
  # was kept separate from price_drop_share: additive, easily revertible --
  # if this doesn't earn its place on the Funnel tile, drop this view, its
  # join in the model file, and the one new measure, with zero effect on
  # anything else.
  #
  # Dedup is per (attempt, gds), matching price_drop_any_tag's own PR #49
  # fix -- NOT a single cross-gds winner-take-all pick per attempt. An
  # attempt with tagged, real-booked candidates from multiple content
  # sources counts under every one of them here, same as the top-of-funnel
  # view.
  #
  # Pre-aggregated to (date, gds), same shape as price_drop_any_tag --
  # joined into price_drop_funnel alongside price_drop_candidates (a
  # genuine one-to-many join on that same explore already relies on
  # Looker's symmetric aggregates to stay correct despite the physical
  # multiplication -- this view's own join is one-to-one on (date, gds),
  # the same safe shape price_drop_any_tag already has in this explore, so
  # it adds no new fan-out risk).
  #
  # Verified 2026-09-08 to 2026-09-14, gds='abc': 3,462/4,457/4,229/3,647/
  # 3,268/3,261/654 -- smaller than price_drop_any_tag's own (fixed) count
  # for the same window (5,166/6,884/6,635/5,818/5,169/5,516/1,001) on
  # every day, as expected (a strict subset gated by real booking status).
  derived_table: {
    sql:
      WITH tagged AS (
        SELECT
          oc.id AS candidate_id, oc.attempt_id, oc.gds,
          DATE(oc.created_at) AS d,
          ROW_NUMBER() OVER (PARTITION BY oc.attempt_id, oc.gds ORDER BY oc.revenue DESC, oc.id ASC) AS rn
        FROM ota.optimizer_candidates oc
        JOIN ota.optimizer_candidate_tags oct ON oct.candidate_id = oc.id
         AND {% condition price_drop_funnel.date_date %} oct.created_at {% endcondition %}
        JOIN ota.optimizer_tags ot ON ot.id = oct.tag_id AND ot.name = 'Dropped'
        WHERE oct.value = 'Price Only'
          AND {% condition price_drop_funnel.date_date %} oc.created_at {% endcondition %}
          AND EXISTS (
            SELECT 1 FROM ota.optimizer_attempt_bookings oab
            JOIN ota.bookings b ON b.id = oab.booking_id
            WHERE oab.attempt_id = oc.attempt_id
              AND b.status = 'issued' AND b.is_test = 0
          )
      )
      SELECT d, gds, COUNT(*) AS n
      FROM tagged
      WHERE rn = 1
      GROUP BY d, gds
    ;;
  }

  dimension: pk {
    primary_key: yes
    hidden: yes
    type: string
    sql: CONCAT(${TABLE}.d, '|', ${TABLE}.gds) ;;
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
    description: "Calendar day (UTC) this attempt's Price & Drop tag was created."
  }

  # -------------------------
  # 2. CONTESTANT INFO
  # -------------------------

  dimension: gds {
    type: string
    group_label: "2. CONTESTANT INFO"
    label: "Content Source"
    sql: ${TABLE}.gds ;;
    description: "Content source with a tagged candidate on this attempt whose real booking is issued and non-test. Dedup is per (attempt, gds), same as price_drop_any_tag -- an attempt with real-booked tagged candidates from multiple content sources counts under every one of them."
  }

  # -------------------------
  # 3. COUNTS
  # -------------------------

  measure: attempts_with_price_drop_booking_count {
    type: sum
    sql: ${TABLE}.n ;;
    group_label: "3. COUNTS"
    label: "Attempts w/ Price & Drop (Real Bookings)"
    description: "Count of distinct attempts where THIS content source has a Dropped='Price Only' tagged candidate AND the attempt's real booking is issued and non-test -- the same top-of-funnel population as price_drop_any_tag's own Attempts w/ Price & Drop, narrowed to genuinely completed sales. A floor on real conversion at the top of the funnel, not a replacement for that measure, which stays scoped to every tagged attempt regardless of booking outcome."
  }
}
