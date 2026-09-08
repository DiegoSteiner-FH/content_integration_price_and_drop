connection: "ota"

include: "/views/*.view.lkml"

explore: price_drop_candidates {
  label: "CI Price Drop Bot"
  description: "Admissible Optimizer candidates found by the Price & Drop simulation — one row per attempt_id (highest-revenue candidate), mirroring ci_pricedrop_bot's MySQL slice: candidacy = 'Admissible', Dropped tag valued 'Price Only', revenue > -50."

  always_filter: {
    filters: [price_drop_candidates.date_date: "7 days"]
  }
}
