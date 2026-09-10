view: price_drop_any_tag {
  # Why (2026-09-09, DS): rule 1 escape hatch -- ports ci_pricedrop_bot's
  # ANY_PD_TAG_SQL / fetch_any_pricedrop_tag_rows() directly. Top-of-funnel
  # denominator for the Price & Drop funnel: every attempt with a
  # Dropped='Price Only' tag on ANY candidate, regardless of that
  # candidate's own candidacy or revenue -- a strict superset of
  # price_drop_candidates' own population (Admissible + revenue > -50
  # only). Verified 2026-09-09 against 2026-09-08: 2,670 distinct attempts
  # for gds='aerohub', matching a direct run of the bot's own
  # fetch_any_pricedrop_tag_rows() exactly.
  #
  # Why (2026-09-09, DS), pre-aggregated to (date, gds): originally one row
  # per attempt_id (with attempt_id as primary key, office/carrier/
  # fare_type/currency/affiliate_id dims carried too), joined into the
  # price_drop_candidates explore at the (date, gds) grain. Looker does NOT
  # pre-aggregate either side of a join before executing it -- confirmed via
  # the actual generated SQL for a 7-day funnel tile query, which was a raw
  # `FROM price_drop_candidates LEFT JOIN price_drop_any_tag ON date=date
  # AND gds=gds` between two multi-thousand-row-per-day tables (~1,900 x
  # ~2,670 rows = ~5M joined rows for one gds on one day alone, before
  # GROUP BY). Looker's symmetric aggregates kept the final counts/sums
  # correct despite this, but MySQL still had to physically build that huge
  # join first -- the tile was genuinely slow, not just cold-cache. Fixed by
  # pre-aggregating this derived table down to (date, gds) directly, same
  # pattern as price_drop_candidacy_breakdown / price_drop_price_rate --
  # this side of the join is now a few dozen rows, not thousands.
  #
  # Why (2026-09-09, DS), primary key restored: dropping attempt_id also
  # dropped this view's only primary key. That silently broke
  # attempts_with_price_drop_count -- price_drop_candidates still has many
  # rows per (date, gds) (one per attempt), so summing this view's `n`
  # across the join without a declared primary key to dedup against would
  # inflate it by however many admissible rows share that date+gds; Looker
  # refuses to run that unsafe SUM rather than return a wrong number, and
  # silently drops the field from every query instead (confirmed: LookML
  # validated fine, project was fully deployed, field was still missing
  # from every query result). Fixed with a synthetic primary key -- a
  # composite of the two group-by columns, which uniquely identifies one
  # row now that this table is aggregated (no natural per-row identity like
  # attempt_id survives the aggregation). Adds no query cost; it's a string
  # concat of two already-selected columns, not a new join or subquery.
  #
  # Why (2026-09-09, DS), {% condition %} refs use price_drop_funnel, not
  # price_drop_any_tag: this view is only ever used via `from:
  # price_drop_any_tag` on the price_drop_funnel explore, which aliases
  # every field reference to that explore's own name -- including {%
  # condition %}/{% parameter %} liquid parameters inside this view's own
  # derived_table SQL, not just always_filter/join sql_on in the model
  # file (that mistake was already fixed once for the model file; missed
  # this spot the first time).
  #
  # Why (2026-09-10, DS), carrier added to the grain: requested a
  # Validating Carrier dimension on the Funnel explore. Added HERE (the
  # funnel's base view), deliberately not on price_drop_candidates (the
  # joined "many" side) -- filtering on that joined view's own carrier
  # field would reopen the exact LEFT JOIN NULL-preservation bug already
  # fixed twice this session (price_drop_candidates.date_date, then
  # price_drop_share_rows' equivalent): an outer WHERE-level filter on a
  # field that's NULL for zero-Admissible content sources (like 'abc')
  # silently drops that entire row. This view's own carrier field has no
  # such risk -- it's on the base/superset side of the join, populated for
  # every row. No value change for any existing query: every current
  # measure sums this view's `n` (attempts_with_price_drop_count is a
  # plain SUM), and splitting one (date, gds) row into several
  # (date, gds, carrier) rows always sums back to the identical total when
  # carrier isn't selected or filtered on. Primary key extended to include
  # carrier to match the new (date, gds, carrier) grain -- unchanged
  # concat-of-already-selected-columns approach, still zero extra query
  # cost.
  derived_table: {
    sql:
      WITH tagged AS (
        SELECT
          oc.id AS candidate_id, oc.attempt_id, oc.gds, oc.validating_carrier AS carrier,
          DATE(oc.created_at) AS d,
          ROW_NUMBER() OVER (PARTITION BY oc.attempt_id ORDER BY oc.revenue DESC, oc.id ASC) AS rn
        FROM ota.optimizer_candidates oc
        JOIN ota.optimizer_candidate_tags oct ON oct.candidate_id = oc.id
         AND {% condition price_drop_funnel.date_date %} oct.created_at {% endcondition %}
        JOIN ota.optimizer_tags ot ON ot.id = oct.tag_id AND ot.name = 'Dropped'
        WHERE oct.value = 'Price Only'
          AND {% condition price_drop_funnel.date_date %} oc.created_at {% endcondition %}
      )
      SELECT d, gds, carrier, COUNT(*) AS n
      FROM tagged
      WHERE rn = 1
      GROUP BY d, gds, carrier
    ;;
  }

  dimension: pk {
    primary_key: yes
    hidden: yes
    type: string
    sql: CONCAT(${TABLE}.d, '|', ${TABLE}.gds, '|', COALESCE(${TABLE}.carrier, '(none)')) ;;
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
    description: "Content source of the (arbitrary, highest-revenue) candidate picked to represent each attempt's Price & Drop tag -- any candidacy, no revenue floor. Used only for the Price & Drop funnel's top-of-funnel count; a different attempt-representative candidate than price_drop_candidates' own Admissible-only pick, so don't expect a 1:1 relationship with that view's rows -- combine their measures at the (date, gds) grain instead, matching ci_pricedrop_bot's own computePriceDropFunnel()."
  }

  dimension: carrier {
    type: string
    group_label: "2. CONTESTANT INFO"
    label: "Validating Carrier"
    sql: ${TABLE}.carrier ;;
    description: "Validating carrier of the same (arbitrary, highest-revenue) candidate gds picks to represent each attempt's Price & Drop tag -- see gds's own description for that caveat. Safe to filter by directly (unlike price_drop_candidates.carrier, the joined view's own field, which would drop zero-Admissible content sources like 'abc' if used as an outer filter -- see the derived table's own comments). Added 2026-09-10; splitting the prior (date, gds) grain by carrier changes nothing about any existing measure's totals when this field isn't selected or filtered."
  }

  # -------------------------
  # 3. COUNTS
  # -------------------------

  measure: attempts_with_price_drop_count {
    type: sum
    sql: ${TABLE}.n ;;
    group_label: "3. COUNTS"
    label: "Attempts w/ Price & Drop"
    description: "Count of distinct attempts with a Dropped='Price Only' tag on any candidate, regardless of candidacy or revenue -- the Price & Drop funnel's top-of-funnel denominator. Matches ci_pricedrop_bot's any_pricedrop_tag_count exactly (verified 2026-09-09 against 2026-09-08, gds='aerohub': 2,670)."
  }
}
