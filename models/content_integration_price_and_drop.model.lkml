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
