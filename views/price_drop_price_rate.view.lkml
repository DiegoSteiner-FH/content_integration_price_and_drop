view: price_drop_price_rate {
  # Why (2026-09-08, DS): rule 1 escape hatch -- ports ci_pricedrop_bot's
  # PRICE_RATE_SQL (generate_report.py) directly. Same population as
  # price_drop_candidacy_breakdown, classified by revenue vs. baseline
  # instead of by candidacy label. Pre-aggregated to (date, gds, office,
  # carrier, fare_type, currency, affiliate_id, outcome) inside the derived
  # table, same size rationale as price_drop_candidacy_breakdown.
  #
  # Why (2026-09-08, DS), fare_type/currency/affiliate_id added: affiliate_id
  # does not exist on ota.optimizer_candidates -- it lives on
  # ota.optimizer_attempts, joined via attempt_id.
  #
  # Why (2026-09-09, DS), booked_ranked/best_eligible_ranked perf fix: this
  # derived table was taking 3m27s+ for a 7-day window in production (vs.
  # ~81.8s for a single day measured directly). EXPLAIN ANALYZE on a single
  # day pinpointed the cause: MySQL's planner picked a full table scan of
  # ota.optimizer_candidates (125M rows, ~34s alone) to evaluate
  # `oc2.attempt_id IN (SELECT DISTINCT attempt_id FROM contestants)` inside
  # best_eligible_ranked, instead of using the existing attempt_id_idx index.
  # Fixed by materializing the distinct attempt-id list once
  # (distinct_contestant_attempts) and STRAIGHT_JOIN + FORCE INDEX
  # (attempt_id_idx)-ing best_eligible_ranked against it, so the small
  # attempt-id list drives the lookup instead of a full-table scan deciding
  # membership row by row.
  #
  # Why (2026-09-09, DS), population narrowed to tag-only rows: originally
  # every candidate belonging to a GDS active for Price & Drop that day (any
  # gds with >=1 candidate tagged Dropped='Price Only' in the window, via the
  # active_pd_gds_by_date CTE below), regardless of whether the row itself
  # carried the tag -- this matched ci_pricedrop_bot's own PRICE_RATE_SQL,
  # itself the sibling of CANDIDACY_BREAKDOWN_SQL (ported from and verified
  # digit-for-digit against a content_integration_optimizer Looker explore
  # tile on 2026-08-14). Live check 2026-09-09 (on the sibling candidacy
  # breakdown population) found zero candidates with candidacy='Eligible'
  # actually carry the Dropped='Price Only' tag -- the old population's
  # Eligible share came entirely from same-GDS/same-day siblings, not tagged
  # rows. The analyst who owns this dashboard determined it should only ever
  # report on candidates the tag was actually applied to, matching how
  # price_drop_candidates has always worked -- intentionally diverging from
  # content_integration_optimizer going forward. ci_pricedrop_bot's own
  # generate_report.py was changed the same way in the same session. Dropped
  # active_pd_gds_by_date entirely; contestants now joins ota.optimizer_
  # candidate_tags directly on the candidate's own row. Verified 2026-09-09
  # against 2026-09-08: total contestants 687,636 -> 91,189 (no_price 61037 /
  # worse 24733 / better 5198 / same 221), matching price_drop_candidacy_
  # breakdown's new total and ci_pricedrop_bot's updated report exactly.
  #
  # Why (2026-09-10, DS), outcome redefined -- base+tax vs. best Eligible
  # base+tax, gated on Admissible: dropped the booked-then-eligible-then-$0
  # REVENUE baseline chain entirely (booked_ranked/booked CTEs removed). Two
  # deliberate changes, both requested and verified against real attempt
  # 17631521 (ota.optimizer_candidates):
  # (1) The comparison metric is now each candidate's own base+tax (the real
  #     fare total a customer would pay), not revenue. optimizer_candidates.
  #     total was checked first and confirmed to be a FIXED value repeated
  #     across every candidate on a given attempt (594.66 for all 90 rows on
  #     17631521, admissible or not) -- it does NOT vary by candidate and
  #     cannot be used for this comparison; base+tax must be summed
  #     manually.
  # (2) 'better'/'same' can only ever be assigned to a candidacy='Admissible'
  #     row. A non-Admissible candidate with a real price always resolves to
  #     'worse', even if its own base+tax happens to be numerically lower
  #     than the baseline -- a non-Admissible fare was never actually
  #     bookable at that price, so labeling it a genuine "win" would be
  #     misleading regardless of the raw number.
  # Best Eligible is still selected by revenue DESC (this project's existing
  # "best Eligible" convention, unchanged everywhere else) -- only the
  # DOWNSTREAM comparison value changed, from that winning row's revenue to
  # its own base+tax. Verified end to end on 17631521: AEROHUBUSD
  # (Admissible, 295.28+259.14=554.42) vs. best Eligible UNIFIFIUSD
  # (305.86+272.78=578.64, also the highest-revenue Eligible row at 0.56) ->
  # 'better'; TIANTAIUSD (Admissible, 310.50+272.76=583.26) -> 'worse';
  # GTSFLYEUR (Unbookable, tagged, 323.59+273.19=596.78) -> 'worse' (blocked
  # by the Admissible gate, though also numerically worse here); TCUSD
  # (Incalculable, NULL price) -> 'no_price'.
  # Assumption: when an attempt's tagged population has NO Eligible
  # candidate at all (best_eligible_total is NULL), the baseline falls back
  # to $0 -- same fallback convention as eligible_delta elsewhere in this
  # project -- meaning an Admissible row can never be 'better'/'same' in
  # that case (a real positive price is never < $0), only 'worse'. Not yet
  # hit a real example of this edge case to confirm against; flagging it as
  # an assumption rather than a verified behavior.
  derived_table: {
    sql:
      WITH contestants AS (
        SELECT
          oc.id AS candidate_id, oc.attempt_id, oc.gds, oc.gds_account_id AS office_id,
          oc.validating_carrier AS carrier, oc.fare_type, oc.currency, oa.affiliate_id,
          oc.candidacy, oc.base, oc.tax, DATE(oc.created_at) AS d
        FROM ota.optimizer_candidates oc
        JOIN ota.optimizer_candidate_tags oct ON oct.candidate_id = oc.id
         AND {% condition price_drop_price_rate.date_date %} oct.created_at {% endcondition %}
        JOIN ota.optimizer_tags ot ON ot.id = oct.tag_id AND ot.name = 'Dropped'
        JOIN ota.optimizer_attempts oa ON oa.id = oc.attempt_id
        WHERE oct.value = 'Price Only'
          AND {% condition price_drop_price_rate.date_date %} oc.created_at {% endcondition %}
          AND NOT EXISTS (
            SELECT 1 FROM ota.optimizer_attempt_bookings oab
            JOIN ota.bookings b ON b.id = oab.booking_id
            WHERE oab.attempt_id = oc.attempt_id
              AND (b.is_test = 1 OR b.cancel_reason = 'test')
          )
      ),
      distinct_contestant_attempts AS (
        SELECT DISTINCT attempt_id FROM contestants
      ),
      best_eligible_ranked AS (
        SELECT oc2.attempt_id, oc2.revenue AS best_eligible_revenue,
          oc2.base + oc2.tax AS best_eligible_total,
          ROW_NUMBER() OVER (PARTITION BY oc2.attempt_id ORDER BY oc2.revenue DESC, oc2.id ASC) AS rn
        FROM distinct_contestant_attempts dca
        STRAIGHT_JOIN ota.optimizer_candidates oc2 FORCE INDEX (attempt_id_idx) ON oc2.attempt_id = dca.attempt_id
        WHERE oc2.candidacy = 'Eligible'
          AND NOT EXISTS (
            SELECT 1
            FROM ota.optimizer_candidate_tags oct_lr
            JOIN ota.optimizer_tags ot_lr ON ot_lr.id = oct_lr.tag_id AND ot_lr.name = 'LowRevenue'
            WHERE oct_lr.candidate_id = oc2.id
          )
      ),
      best_eligible AS (
        SELECT attempt_id, best_eligible_total FROM best_eligible_ranked WHERE rn = 1
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
          WHEN ct.base IS NULL THEN 'no_price'
          WHEN ct.candidacy = 'Admissible' AND (ct.base + ct.tax) < COALESCE(be.best_eligible_total, 0) THEN 'better'
          WHEN ct.candidacy = 'Admissible' AND (ct.base + ct.tax) = COALESCE(be.best_eligible_total, 0) THEN 'same'
          ELSE 'worse'
        END AS outcome,
        COUNT(*) AS n
      FROM contestants ct
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
    description: "Content source (GDS) of the candidate. Every row in this view is a candidate that itself carries a Dropped='Price Only' tag."
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
    description: "'no_price': the contestant has no base/tax at all (the repricing attempt never produced a usable price). Otherwise, the contestant's own base+tax (the real fare total) vs. the best non-LowRevenue Eligible candidate's own base+tax on the same attempt ($0 if no Eligible candidate exists at all -- see the derived table's own comments for that edge case). 'better'/'same' can ONLY be assigned when the contestant's own candidacy is 'Admissible' -- a non-Admissible candidate with a real price always resolves to 'worse', even if its own base+tax happens to be numerically lower than the baseline, since a non-Admissible fare was never actually bookable at that price. Redefined 2026-09-10 -- previously compared revenue against a booked-then-Eligible-then-$0 baseline with no candidacy gate; verified against real attempt 17631521 (ota.optimizer_candidates)."
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
