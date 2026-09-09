connection: "ota"

include: "/views/*.view.lkml"

datagroup: price_drop_candidates_default_datagroup {
  max_cache_age: "1 hour"
}

explore: price_drop_candidates {
  label: "CI Price Drop Bot"
  description: "Admissible Optimizer candidates found by the Price & Drop simulation — one row per attempt_id (highest-revenue candidate), mirroring ci_pricedrop_bot's MySQL slice: candidacy = 'Admissible', Dropped tag valued 'Price Only', revenue > -50."
  persist_with: price_drop_candidates_default_datagroup

  always_filter: {
    filters: [price_drop_candidates.date_date: "7 days"]
  }
}

explore: price_drop_funnel {
  from: price_drop_any_tag
  label: "CI Price Drop Bot - Funnel"
  description: "Price & Drop funnel: every content source with Price & Drop tag activity (price_drop_any_tag, the base view here) left-joined to its Admissible candidates (price_drop_candidates), if any. Driving the explore from price_drop_any_tag instead of price_drop_candidates is deliberate -- price_drop_any_tag's (date, gds) coverage is always a superset (an Admissible candidate is itself Price Only-tagged), so a content source with zero Admissible candidates that day (e.g. 'abc') still shows up correctly with zeros instead of disappearing, using plain left_outer (this connection's MySQL dialect does not support full_outer). Note: `from:` aliases price_drop_any_tag's fields to this explore's own name (price_drop_funnel.*) everywhere within this explore -- not price_drop_any_tag.* -- see always_filter and the join below."
  persist_with: price_drop_candidates_default_datagroup

  always_filter: {
    filters: [price_drop_funnel.date_date: "7 days", price_drop_candidates.date_date: "7 days"]
  }

  join: price_drop_candidates {
    view_label: "Price & Drop Funnel"
    type: left_outer
    relationship: one_to_many
    sql_on: ${price_drop_funnel.date_date} = ${price_drop_candidates.date_date}
        AND ${price_drop_funnel.gds} = ${price_drop_candidates.gds} ;;
  }
}

explore: price_drop_candidacy_breakdown {
  label: "CI Price Drop Bot - Candidacy Breakdown"
  description: "Candidacy distribution of every contestant (any candidacy, no revenue floor, no per-attempt dedup) belonging to a content source with at least one Dropped='Price Only' tag in the window — mirrors ci_pricedrop_bot's Candidacy Breakdown tile."
  persist_with: price_drop_candidates_default_datagroup

  always_filter: {
    filters: [price_drop_candidacy_breakdown.date_date: "7 days"]
  }
}

explore: price_drop_price_rate {
  label: "CI Price Drop Bot - Price Rate"
  description: "Same population as Candidacy Breakdown, classified by revenue vs. booked/eligible baseline instead of by candidacy label — mirrors ci_pricedrop_bot's Price Rate tile."
  persist_with: price_drop_candidates_default_datagroup

  always_filter: {
    filters: [price_drop_price_rate.date_date: "7 days"]
  }
}
