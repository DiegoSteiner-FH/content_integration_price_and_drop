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
  # Why (2026-09-10, DS), retitled "Revenue Rate" -- outcome compares REVENUE
  # (not base+tax price, and not the older booked-then-eligible-then-$0
  # chain either), gated on Admissible: a same-day earlier attempt at this
  # (comparing base+tax price directly) hit a real counterexample on attempt
  # 17631681 -- a CAD travelportplus candidate had a cheaper base+tax than
  # the best Eligible candidate, but once its merchant_fee (currency
  # conversion cost, 38.20) was applied its actual revenue was -12.22, while
  # a sibling USD candidate on the SAME attempt/GDS had a less competitive
  # price but +16.00 revenue. Price and revenue can disagree whenever
  # currency-conversion fees, markup, or commission differ between
  # candidates -- base+tax never reflects any of that. Comparing revenue
  # directly (what the business actually cares about, per the analyst who
  # owns this dashboard) resolves this with no extra per-attempt-winner
  # de-dup step needed: both travelportplus rows above correctly come out
  # 'worse' against the best Eligible's own revenue (18.00) once revenue is
  # the metric, no special-casing required.
  #
  # The Admissible gate carries over unchanged from that same-day attempt:
  # 'better'/'same' can only ever be assigned to a candidacy='Admissible'
  # row -- orthogonal to the metric swap, still a safeguard against a
  # non-bookable row looking like a false "win" on whichever metric is used.
  # Best Eligible is still selected by revenue DESC (this project's existing
  # "best Eligible" convention, unchanged everywhere else); the ONLY change
  # from that convention is that this view no longer carries a base+tax
  # total for it at all (reverted -- best_eligible_ranked/best_eligible only
  # carry revenue again).
  # Assumption: when an attempt's tagged population has NO Eligible
  # candidate at all (best_eligible_revenue is NULL), the baseline falls
  # back to $0 -- same fallback convention as eligible_delta elsewhere in
  # this project. Not yet hit a real example of this edge case to confirm
  # against; flagging it as an assumption rather than a verified behavior.
  #
  # Why (2026-09-10, DS), attempt_id_filter added: requested a way to filter
  # this view down to one specific attempt and see its own Revenue Outcome
  # breakdown. This view is pre-aggregated (grain is date/gds/office/
  # carrier/fare_type/currency/affiliate_id/outcome -- attempt_id does NOT
  # survive past the contestants CTE), so a real, groupable attempt_id
  # dimension isn't possible without un-aggregating the whole view into a
  # much bigger row-level population (same cost profile as
  # price_drop_candidates / the Attempt Examples tile). Instead added a
  # filter-only field (below) whose value is pushed into the derived
  # table's own WHERE clause via a Liquid condition tag -- same mechanism
  # the date filter already uses -- so it narrows the contestant
  # population BEFORE aggregation runs, with no grain or cost change to
  # the aggregated output itself. Not usable as a group-by/display column,
  # by design.
  #
  # Why (2026-09-10, DS), hotfix -- broken Liquid tag in a description:
  # attempt_id_filter's own description string originally contained a
  # literal, unclosed "condition" Liquid tag (no field argument, no
  # matching end tag) meant purely as human-readable prose -- but
  # description: strings get Liquid-processed too, unlike a # comment
  # (which is stripped before compilation and can safely mention the same
  # phrase, as this comment block does throughout). That broke the whole
  # model with "Liquid parse exception: Missing End Tag" until fixed by
  # describing the mechanism in plain English instead of literal Liquid
  # tag syntax.
  #
  # Why (2026-09-10, DS), single_to_multi override applied to best_eligible_
  # ranked: same gap and same fix as price_drop_candidates.view.lkml /
  # price_drop_share_rows.view.lkml -- this view's own best_eligible_ranked
  # CTE only checked candidacy='Eligible' on the raw column, never applying
  # the force-reclassify-to-Inadmissible override for a candidate whose
  # parent has reprice_type='single_to_multi' (price_drop_candidacy_
  # breakdown.view.lkml already applies this rule). Affects the Revenue
  # Rate outcome comparison's own baseline.
  derived_table: {
    sql:
      WITH contestants AS (
        SELECT
          oc.id AS candidate_id, oc.attempt_id, oc.gds, oc.gds_account_id AS office_id,
          oc.validating_carrier AS carrier, oc.fare_type, oc.currency, oa.affiliate_id,
          oc.candidacy, oc.revenue, DATE(oc.created_at) AS d
        FROM ota.optimizer_candidates oc
        JOIN ota.optimizer_candidate_tags oct ON oct.candidate_id = oc.id
         AND {% condition price_drop_price_rate.date_date %} oct.created_at {% endcondition %}
        JOIN ota.optimizer_tags ot ON ot.id = oct.tag_id AND ot.name = 'Dropped'
        JOIN ota.optimizer_attempts oa ON oa.id = oc.attempt_id
        WHERE oct.value = 'Price Only'
          AND {% condition price_drop_price_rate.date_date %} oc.created_at {% endcondition %}
          AND {% condition price_drop_price_rate.attempt_id_filter %} oc.attempt_id {% endcondition %}
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
          AND NOT EXISTS (
            SELECT 1 FROM ota.optimizer_candidates opc
            WHERE opc.id = oc2.parent_id AND opc.reprice_type = 'single_to_multi'
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
          WHEN ct.candidacy = 'Admissible' AND ct.revenue > COALESCE(be.best_eligible_revenue, 0) THEN 'better'
          WHEN ct.candidacy = 'Admissible' AND ct.revenue = COALESCE(be.best_eligible_revenue, 0) THEN 'same'
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

  filter: attempt_id_filter {
    type: number
    group_label: "2. CONTESTANT INFO"
    label: "Attempt ID"
    description: "Filter-only -- narrows the underlying contestant population to one specific ota.optimizer_attempts.id before aggregation runs (pushed into the derived table's own WHERE clause via Looker's condition-tag mechanism, same as the date filter). Not a real output column: this view is pre-aggregated and does not carry attempt_id past its own derived table's contestants CTE, so it can't be used as a group-by/display dimension -- filter to a single attempt to see just that one attempt's own Revenue Outcome breakdown."
  }

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
    label: "Revenue Outcome"
    sql: ${TABLE}.outcome ;;
    suggestions: ["better", "same", "worse", "no_price"]
    description: "'no_price': the contestant has no revenue at all (the repricing attempt never produced a usable price). Otherwise, the contestant's own revenue vs. the best non-LowRevenue Eligible candidate's own revenue on the same attempt ($0 if no Eligible candidate exists at all -- see the derived table's own comments for that edge case). 'better'/'same' can ONLY be assigned when the contestant's own candidacy is 'Admissible' -- a non-Admissible candidate with a real revenue value always resolves to 'worse', even if its own revenue happens to be numerically higher than the baseline, since a non-Admissible fare was never actually bookable at that price. Retitled 2026-09-10 from a price (base+tax) comparison to a revenue comparison -- a real example (attempt 17631681) showed price and revenue disagreeing once a currency-conversion merchant fee was involved; revenue is what this dashboard's owner actually cares about, and comparing it directly needs no extra per-attempt-winner logic to handle that case correctly."
  }

  # -------------------------
  # 4. COUNTS
  # -------------------------

  measure: total_contestants_count {
    type: sum
    sql: ${TABLE}.n ;;
    group_label: "4. COUNTS"
    label: "Total Contestants"
    description: "Sum of pre-aggregated contestant counts. Pivot on Revenue Outcome in the tile to reproduce the Revenue Rate table shape (one column per outcome); use a % of total table calculation for the percentage columns."
  }
}
