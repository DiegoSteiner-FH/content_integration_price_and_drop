view: price_drop_any_tag {
  # Why (2026-09-09, DS): rule 1 escape hatch -- ports ci_pricedrop_bot's
  # ANY_PD_TAG_SQL / fetch_any_pricedrop_tag_rows() directly. Top-of-funnel
  # denominator for the Price & Drop funnel: every attempt with a
  # Dropped='Price Only' tag on ANY candidate, regardless of that
  # candidate's own candidacy or revenue -- a strict superset of
  # price_drop_candidates' own population (Admissible + revenue > -50
  # only). One row per attempt_id (arbitrary highest-revenue candidate pick
  # among same-attempt tagged candidates -- irrelevant here since these
  # rows only carry dimensions for cross-filtering/counting attempts, not
  # revenue), matching the bot's own ANY_PD_TAG_SQL exactly. Verified
  # 2026-09-09 against 2026-09-08: 2,670 distinct attempts for
  # gds='aerohub', matching a direct run of the bot's own
  # fetch_any_pricedrop_tag_rows() exactly.
  derived_table: {
    sql:
      WITH tagged AS (
        SELECT
          oc.id AS candidate_id, oc.attempt_id, oc.gds, oc.gds_account_id AS office_id,
          oc.validating_carrier AS carrier, oc.fare_type, oc.currency, oa.affiliate_id,
          DATE(oc.created_at) AS d,
          ROW_NUMBER() OVER (PARTITION BY oc.attempt_id ORDER BY oc.revenue DESC, oc.id ASC) AS rn
        FROM ota.optimizer_candidates oc
        JOIN ota.optimizer_candidate_tags oct ON oct.candidate_id = oc.id
         AND {% condition price_drop_any_tag.date_date %} oct.created_at {% endcondition %}
        JOIN ota.optimizer_tags ot ON ot.id = oct.tag_id AND ot.name = 'Dropped'
        JOIN ota.optimizer_attempts oa ON oa.id = oc.attempt_id
        WHERE oct.value = 'Price Only'
          AND {% condition price_drop_any_tag.date_date %} oc.created_at {% endcondition %}
      )
      SELECT candidate_id, attempt_id, gds, office_id, carrier, fare_type, currency, affiliate_id, d
      FROM tagged
      WHERE rn = 1
    ;;
  }

  dimension: attempt_id {
    primary_key: yes
    hidden: yes
    type: number
    sql: ${TABLE}.attempt_id ;;
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
    description: "Content source of the (arbitrary, highest-revenue) candidate picked to represent this attempt's Price & Drop tag -- any candidacy, no revenue floor. Used only for the Price & Drop funnel's top-of-funnel count; a different attempt-representative candidate than price_drop_candidates' own Admissible-only pick, so don't join these two views' rows 1:1 by attempt_id -- combine their measures at the (date, gds) grain instead, matching ci_pricedrop_bot's own computePriceDropFunnel()."
  }

  dimension: office {
    type: string
    group_label: "2. CONTESTANT INFO"
    label: "Office Id"
    sql: ${TABLE}.office_id ;;
    description: "GDS account / office ID of the representative candidate."
  }

  dimension: carrier {
    type: string
    group_label: "2. CONTESTANT INFO"
    label: "Validating Carrier"
    sql: ${TABLE}.carrier ;;
    description: "Validating carrier of the representative candidate."
  }

  dimension: fare_type {
    type: string
    group_label: "2. CONTESTANT INFO"
    label: "Fare Type"
    sql: ${TABLE}.fare_type ;;
    description: "Fare type of the representative candidate."
  }

  dimension: currency {
    type: string
    group_label: "2. CONTESTANT INFO"
    label: "Currency"
    sql: ${TABLE}.currency ;;
    description: "Representative candidate's own currency (ota.optimizer_candidates.currency)."
  }

  dimension: affiliate_id {
    type: number
    group_label: "2. CONTESTANT INFO"
    label: "Affiliate ID"
    sql: ${TABLE}.affiliate_id ;;
    description: "Affiliate the search attempt belongs to (ota.optimizer_attempts.affiliate_id, joined via attempt_id)."
  }

  # -------------------------
  # 3. COUNTS
  # -------------------------

  measure: attempts_with_price_drop_count {
    type: count_distinct
    sql: ${attempt_id} ;;
    group_label: "3. COUNTS"
    label: "Attempts w/ Price & Drop"
    description: "Count of distinct attempts with a Dropped='Price Only' tag on any candidate, regardless of candidacy or revenue -- the Price & Drop funnel's top-of-funnel denominator. Matches ci_pricedrop_bot's any_pricedrop_tag_count exactly (verified 2026-09-09 against 2026-09-08, gds='aerohub': 2,670)."
  }
}
