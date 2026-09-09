view: price_drop_share_rows {
  # Why (2026-09-09, DS): ports ci_pricedrop_bot's own "Content Source
  # Share" section to this project (see contentSourceShare(),
  # PD_CANDIDATES_BY_GDS_SQL, and BOOKED_WITHOUT_ADMISSIBLE_SQL in that
  # bot's generate_report.py) -- two panels, "Today (actual bookings)" vs.
  # "If Live" (what the mix would look like if a chosen set of content
  # sources' Price & Drop candidates replaced today's real outcome
  # whenever they'd win). Both panels always share the SAME denominator:
  # every real booking in the window, whether or not it ever got a Price
  # & Drop candidate at all -- confirmed explicitly with the user as full
  # bot parity, a deliberate exception to how every OTHER tile in this
  # project is scoped (tag-anchored only). Real volume measured 2026-09-09
  # for 2026-09-02: 10,460 total bookings, 4,007 already covered by the
  # admissible-tagged population, 6,453 booked with no admissible
  # candidate at all -- a real but bounded number, not explosive.
  #
  # One confirmed, deliberate divergence from the bot: a content source
  # only "wins" a row in the If Live scenario when it beats the best real
  # Eligible candidate on that attempt (eligible_delta > 0 -- this
  # project's own Profitable definition, see near_miss_bucket in
  # price_drop_candidates.view.lkml), NOT raw revenue > 0 like the bot's
  # own PD_CANDIDATES_BY_GDS_SQL (`oc.revenue > 0`). Confirmed explicitly
  # with the user given this project already redefined every other
  # Profitable-scoped measure the same way.
  #
  # Grain is NOT one row per attempt, unlike price_drop_candidates --
  # this view needs to know EVERY content source that had its own
  # profitable candidate on a given attempt (not just the single overall
  # winner across all sources), so an attempt where two sources both beat
  # best Eligible appears as two rows here. Every attempt gets at least
  # one row: if it has zero profitable candidates anywhere, one row still
  # exists with pd_gds/pd_delta both NULL, so the "Today" denominator
  # never silently loses volume. The custom visualization
  # (price_drop_content_source_share.js) reconstructs one record per
  # attempt_id client-side before running the actual today-vs-if-live
  # comparison -- see that file's own comments.
  #
  # Same hard safety-cap pattern as price_drop_candidates (PR #29): the
  # {% condition price_drop_share.date_date %} tags below only fire when a
  # query filters this explore's own date_date field directly; a 30-day
  # internal AND is the fallback for any other case, generous margin above
  # the 7-day default window, never an outer WHERE so it can't break NULL
  # preservation the way an always_filter on a joined view would.
  derived_table: {
    sql:
      WITH admissible_by_gds AS (
        SELECT
          oc.attempt_id, oc.gds, oc.revenue,
          ROW_NUMBER() OVER (PARTITION BY oc.attempt_id, oc.gds ORDER BY oc.revenue DESC, oc.id ASC) AS rn
        FROM ota.optimizer_candidates oc
        STRAIGHT_JOIN ota.optimizer_candidate_tags oct ON oct.candidate_id = oc.id
        STRAIGHT_JOIN ota.optimizer_tags ot ON ot.id = oct.tag_id AND ot.name = 'Dropped'
        WHERE oct.value = 'Price Only'
          AND oc.candidacy = 'Admissible'
          AND oc.revenue > -50
          AND oc.created_at >= DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY)
          AND {% condition price_drop_share.date_date %} oc.created_at {% endcondition %}
      ),
      best_per_gds AS (
        SELECT * FROM admissible_by_gds WHERE rn = 1
      ),
      admissible_attempts AS (
        SELECT DISTINCT attempt_id FROM best_per_gds
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
      ),
      best_eligible AS (
        SELECT attempt_id, best_eligible_revenue FROM best_eligible_ranked WHERE rn = 1
      ),
      profitable_by_gds AS (
        SELECT
          bg.attempt_id, bg.gds,
          bg.revenue - COALESCE(be.best_eligible_revenue, 0) AS eligible_delta
        FROM best_per_gds bg
        LEFT JOIN best_eligible be ON be.attempt_id = bg.attempt_id
        WHERE (bg.revenue - COALESCE(be.best_eligible_revenue, 0)) > 0
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
          oab.attempt_id, bc.gds AS booked_gds, oa.created_at,
          ROW_NUMBER() OVER (PARTITION BY oab.attempt_id ORDER BY bc.revenue DESC, bc.id ASC) AS rn
        FROM ota.optimizer_attempt_bookings oab
        JOIN ota.optimizer_candidates bc ON bc.id = oab.candidate_id
        JOIN ota.optimizer_attempts oa ON oa.id = oab.attempt_id
        WHERE oa.created_at >= DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY)
          AND {% condition price_drop_share.date_date %} oa.created_at {% endcondition %}
          AND oab.attempt_id NOT IN (SELECT attempt_id FROM admissible_attempts)
      ),
      booked_without_admissible_best AS (
        SELECT attempt_id, booked_gds, created_at FROM booked_without_admissible WHERE rn = 1
      ),
      base_attempts AS (
        SELECT aa.attempt_id, oa.created_at, bab.booked_gds
        FROM admissible_attempts aa
        JOIN ota.optimizer_attempts oa ON oa.id = aa.attempt_id
        LEFT JOIN booked_admissible_best bab ON bab.attempt_id = aa.attempt_id
        UNION ALL
        SELECT bwab.attempt_id, bwab.created_at, bwab.booked_gds
        FROM booked_without_admissible_best bwab
      )
      SELECT
        ba.attempt_id,
        ba.created_at,
        ba.booked_gds,
        pbg.gds AS pd_gds,
        pbg.eligible_delta AS pd_delta
      FROM base_attempts ba
      LEFT JOIN profitable_by_gds pbg ON pbg.attempt_id = ba.attempt_id
    ;;
  }

  dimension: id {
    primary_key: yes
    hidden: yes
    type: string
    sql: CONCAT(${TABLE}.attempt_id, '|', COALESCE(${TABLE}.pd_gds, '(none)')) ;;
  }

  dimension: attempt_id {
    group_label: "1. ATTEMPT"
    label: "Attempt ID"
    type: number
    sql: ${TABLE}.attempt_id ;;
    description: "The Optimizer search attempt this row belongs to (ota.optimizer_attempts.id). One attempt can appear on multiple rows here -- once per content source that beat the best Eligible candidate on it."
  }

  dimension_group: date {
    type: time
    timeframes: [date, week, month, quarter, year, raw]
    sql: ${TABLE}.created_at ;;
    group_label: "1. ATTEMPT"
    label: "Created"
    description: "Attempt's created_at timestamp (stored UTC). Same literal-date-string convention as every other tile in this project -- see price_drop_candidates' own date_date description."
  }

  dimension: booked_gds {
    type: string
    group_label: "2. CONTESTANT INFO"
    label: "Booked Content Source"
    sql: ${TABLE}.booked_gds ;;
    description: "The content source that actually fulfilled this attempt's real booking, if any (NULL if the attempt was never booked at all). Drives the 'Today (actual bookings)' panel -- every real booking counts here regardless of whether Price & Drop ever produced a candidate for it."
  }

  dimension: pd_gds {
    type: string
    group_label: "2. CONTESTANT INFO"
    label: "Profitable Content Source"
    sql: ${TABLE}.pd_gds ;;
    description: "A content source that had its own candidate on this attempt beating the best real Eligible alternative (eligible_delta > 0). NULL on the one extra row that exists for every attempt with zero profitable candidates anywhere -- keeps that attempt counted in the denominator without implying any source would have won it."
  }

  dimension: pd_delta {
    type: number
    group_label: "2. CONTESTANT INFO"
    label: "Eligible Delta"
    value_format: "$#,##0.00"
    sql: ${TABLE}.pd_delta ;;
    description: "pd_gds's own revenue minus the best real Eligible candidate's revenue on this attempt. NULL wherever pd_gds is NULL. Only ever used client-side (price_drop_content_source_share.js) to pick the best-of-the-selected-sources winner for the 'If Live' panel -- never summed or averaged as a measure, since this view's grain (one row per profitable content source per attempt) would make any aggregate here meaningless. Not hidden, unlike most helper dimensions in this project -- the custom viz requires it as a raw output column, so it must stay selectable in the field picker."
  }
}
