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
