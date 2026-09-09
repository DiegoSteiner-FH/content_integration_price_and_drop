// Price & Drop Content Source Share -- custom Looker visualization.
//
// Why (2026-09-09, DS): ports ci_pricedrop_bot's own "Content Source Share"
// section (contentSourceShare() / shareBarsHtml() in its merged dashboard
// JS) to this project. Two panels sharing one denominator -- every real
// booking in the current date range, whether or not it ever got a Price &
// Drop candidate at all: "Today (actual bookings)" is each attempt's real
// booked_gds; "If Live" is each attempt's real outcome UNLESS one of the
// currently-selected content sources had its own candidate beating the
// best real Eligible alternative on that attempt, in which case the best
// such source wins the row instead.
//
// One confirmed, deliberate divergence from the bot: a source only "wins"
// a row here when it beats the best real Eligible candidate (eligible_delta
// > 0, read from price_drop_share_rows.pd_delta -- this project's own
// Profitable definition), not raw revenue > 0 like the bot's own
// PD_CANDIDATES_BY_GDS_SQL. See that view file for the full reasoning.
//
// Query shape is fundamentally different from every other custom viz in
// this project: price_drop_share_rows is at (attempt, profitable content
// source) grain, with one extra row per attempt that has zero profitable
// candidates anywhere (pd_gds/pd_delta both NULL on that row). An attempt
// with two profitable sources therefore appears as two rows here, unlike
// every other tile's one-row-per-attempt or one-row-per-(date,gds) shape.
// buildAttemptRecords() below reconstructs one record per attempt_id
// (merging every profitable-gds row for that attempt into a single
// { bg, pd: {gds: delta} } object) -- mirroring the bot's own
// hydrateRows() step, since Looker can't return a nested per-row map the
// way the bot's own JSON day-entries do. contentSourceShare() then runs
// the SAME today-vs-if-live algorithm the bot uses, verbatim, against
// those reconstructed records.
//
// The "which sources are live" toggle-pill picker is built dynamically
// from whatever pd_gds values are actually present in the current result
// (distinctPdSources) -- no hardcoded list, same pattern as
// price_drop_funnel_table.js's GDS tabs. A brand-new content source shows
// up as its own pill the moment it appears in a query result, defaulted to
// selected (matches "every source live" being the neutral/default state).
//
// Required fields (flat, no pivot):
//   price_drop_share.attempt_id
//   price_drop_share.booked_gds
//   price_drop_share.pd_gds
//   price_drop_share.pd_delta

(function () {
  var ATTEMPT_FIELD = "price_drop_share.attempt_id";
  var BOOKED_GDS_FIELD = "price_drop_share.booked_gds";
  var PD_GDS_FIELD = "price_drop_share.pd_gds";
  var PD_DELTA_FIELD = "price_drop_share.pd_delta";

  var REQUIRED_FIELDS = [ATTEMPT_FIELD, BOOKED_GDS_FIELD, PD_GDS_FIELD, PD_DELTA_FIELD];

  var NO_BOOKING = "(no booking)";

  var SHARE_PALETTE = ["#2545d9", "#16a34a", "#dc2626", "#d97706", "#7c3aed", "#0891b2", "#db2777", "#65a30d", "#4b5563"];

  var CSS = "\
    .pd-cs { font-family: -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif; font-size: 15px; color: #111827; height: 100%; overflow: auto; padding: 8px 12px; }\
    .pd-cs-stat { color: #6b7280; font-size: 13px; margin-bottom: 10px; }\
    .pd-cs-stat b { color: #111827; }\
    .pd-cs-picker-label { font-size: 12px; font-weight: 700; text-transform: uppercase; letter-spacing: .04em; color: #9ca3af; margin-bottom: 6px; }\
    .pd-cs-picker { display: flex; gap: 6px; flex-wrap: wrap; margin-bottom: 18px; }\
    .pd-cs-pill { padding: 5px 12px; border-radius: 999px; border: 1px solid #d1d5db; font-size: 13px; font-weight: 600; cursor: pointer; user-select: none; color: #6b7280; background: #fff; }\
    .pd-cs-pill:hover { border-color: #9ca3af; color: #111827; }\
    .pd-cs-pill.active { background: #eaf0fe; border-color: #2545d9; color: #2545d9; }\
    .pd-cs-panels { display: flex; gap: 24px; flex-wrap: wrap; }\
    .pd-cs-panel { flex: 1 1 320px; min-width: 280px; }\
    .pd-cs-panel h4 { font-size: 13px; font-weight: 700; text-transform: uppercase; letter-spacing: .04em; color: #9ca3af; margin: 0 0 10px; }\
    .share-row { display: flex; align-items: center; gap: 10px; padding: 6px 0; }\
    .share-key { flex: 0 0 140px; font-size: 13px; font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; display: flex; align-items: center; gap: 6px; }\
    .share-swatch { width: 10px; height: 10px; border-radius: 50%; flex: 0 0 auto; }\
    .share-track { flex: 1 1 auto; height: 10px; background: #f1f3f5; border-radius: 5px; overflow: hidden; }\
    .share-fill { height: 100%; border-radius: 5px; }\
    .share-figs { flex: 0 0 auto; font-size: 13px; font-variant-numeric: tabular-nums; white-space: nowrap; }\
    .muted { color: #9ca3af; }\
    .pd-cs-empty { padding: 24px; color: #9ca3af; text-align: center; }\
  ";

  function injectStyleOnce() {
    if (document.getElementById("pd-cs-style")) return;
    var style = document.createElement("style");
    style.id = "pd-cs-style";
    style.textContent = CSS;
    document.head.appendChild(style);
  }

  function numVal(cell) {
    if (!cell || cell.value === null || cell.value === undefined) return 0;
    var n = Number(cell.value);
    return isNaN(n) ? 0 : n;
  }

  function strVal(cell, fallback) {
    if (!cell || cell.value === null || cell.value === undefined || cell.value === "") {
      return fallback === undefined ? null : fallback;
    }
    return String(cell.value);
  }

  function round2(n) {
    return Math.round(n * 100) / 100;
  }

  function esc(s) {
    return String(s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  function colorForKey(key) {
    var h = 0;
    for (var i = 0; i < key.length; i++) h = (h * 31 + key.charCodeAt(i)) >>> 0;
    return SHARE_PALETTE[h % SHARE_PALETTE.length];
  }

  function prettyKey(key) {
    return key === NO_BOOKING ? key : key;
  }

  // Reconstructs one record per attempt_id from the flat (attempt,
  // profitable gds) rows Looker returns -- mirrors the bot's own
  // hydrateRows() step. An attempt with zero profitable candidates
  // anywhere has exactly one row (PD_GDS_FIELD null); an attempt with N
  // profitable sources has N rows, all merged back into one record here.
  function buildAttemptRecords(rawRows) {
    var byAttempt = {};
    var order = [];
    rawRows.forEach(function (row) {
      var attemptId = strVal(row[ATTEMPT_FIELD], "");
      if (!byAttempt[attemptId]) {
        byAttempt[attemptId] = { bg: strVal(row[BOOKED_GDS_FIELD]), pd: {} };
        order.push(attemptId);
      }
      var pdGds = strVal(row[PD_GDS_FIELD]);
      if (pdGds !== null) {
        byAttempt[attemptId].pd[pdGds] = numVal(row[PD_DELTA_FIELD]);
      }
    });
    return order.map(function (id) { return byAttempt[id]; });
  }

  // Verbatim port of ci_pricedrop_bot's own contentSourceShare() (see that
  // function's own comment block in the bot's dashboard JS for the full
  // reasoning) -- `records` is one per attempt (see buildAttemptRecords
  // above), `selected` is the Set of content sources currently toggled on
  // (null/empty = every source considered, i.e. always take whichever is
  // best). Denominator is always `records.length` -- the full population,
  // never narrowed by which sources happen to be selected.
  function contentSourceShare(records, selected) {
    var total = records.length;
    var actual = {};
    var hypo = {};
    records.forEach(function (r) {
      var actualKey = r.bg || NO_BOOKING;
      actual[actualKey] = (actual[actualKey] || 0) + 1;
      var hypoKey = r.bg || NO_BOOKING;
      var bestDelta = 0;
      Object.keys(r.pd).forEach(function (gdsKey) {
        var delta = r.pd[gdsKey];
        if ((!selected || !selected.size || selected.has(gdsKey)) && delta > bestDelta) {
          bestDelta = delta;
          hypoKey = gdsKey;
        }
      });
      hypo[hypoKey] = (hypo[hypoKey] || 0) + 1;
    });
    function toSorted(m) {
      return Object.keys(m).map(function (key) {
        return { key: key, count: m[key], pct: total ? round2((100 * m[key]) / total) : 0 };
      }).sort(function (a, b) { return b.count - a.count; });
    }
    return { total: total, actual: toSorted(actual), hypo: toSorted(hypo) };
  }

  // Distinct content sources that have a profitable candidate anywhere in
  // the current result set -- these become the toggle-pill picker
  // options, rebuilt fresh every render. Sorted alphabetically for a
  // stable picker order (share panels themselves sort by count instead).
  function distinctPdSources(records) {
    var seen = {};
    var order = [];
    records.forEach(function (r) {
      Object.keys(r.pd).forEach(function (g) {
        if (!seen[g]) { seen[g] = true; order.push(g); }
      });
    });
    order.sort();
    return order;
  }

  function shareBarsHtml(items) {
    if (!items.length) return "<p class='muted'>No data in this range.</p>";
    return items.map(function (it) {
      return '<div class="share-row">' +
        '<span class="share-key"><span class="share-swatch" style="background:' + colorForKey(it.key) + '"></span>' + esc(prettyKey(it.key)) + "</span>" +
        '<div class="share-track"><div class="share-fill" style="width:' + it.pct + '%;background:' + colorForKey(it.key) + '"></div></div>' +
        '<span class="share-figs">' + it.pct + '% <span class="muted">(' + it.count.toLocaleString() + ')</span></span>' +
        "</div>";
    }).join("");
  }

  looker.plugins.visualizations.add({
    id: "price_drop_content_source_share",
    label: "Price Drop Content Source Share",
    options: {},

    create: function (element, config) {
      injectStyleOnce();
      element.innerHTML = '<div class="pd-cs"></div>';
      this._rows = [];
      this._selected = new Set();
      this._seen = new Set();
    },

    updateAsync: function (data, element, config, queryResponse, details, done) {
      this.clearErrors();

      var fieldNames = {};
      (queryResponse.fields.dimensions || []).concat(queryResponse.fields.measures || []).forEach(function (f) {
        fieldNames[f.name] = true;
      });
      var missing = REQUIRED_FIELDS.filter(function (f) { return !fieldNames[f]; });
      if (missing.length) {
        this.addError({
          title: "Missing required fields",
          message: "Add these fields to the query (flat, no pivot): " + missing.join(", ")
        });
        done();
        return;
      }

      this._rows = data;
      this._element = element;
      this.render();
      done();
    },

    render: function () {
      var self = this;
      var root = this._element.querySelector(".pd-cs");
      var records = buildAttemptRecords(this._rows);

      if (!records.length) {
        root.innerHTML = '<div class="pd-cs-empty">No rows for this date range / filter selection</div>';
        return;
      }

      var pdSources = distinctPdSources(records);
      // A brand-new content source (never seen on a prior render) defaults
      // to selected -- matches "every source live" being the neutral
      // starting state. A source the user has explicitly toggled off stays
      // off across re-renders (date range changes, etc.) until they click
      // it back on.
      pdSources.forEach(function (g) {
        if (!self._seen.has(g)) {
          self._seen.add(g);
          self._selected.add(g);
        }
      });

      var share = contentSourceShare(records, self._selected);

      var pickerHtml = pdSources.map(function (g) {
        var cls = "pd-cs-pill" + (self._selected.has(g) ? " active" : "");
        return '<div class="' + cls + '" data-gds="' + esc(g) + '">' + esc(g) + "</div>";
      }).join("");

      root.innerHTML =
        '<div class="pd-cs-stat">Bookings in scope: <b>' + share.total.toLocaleString() + "</b></div>" +
        '<div class="pd-cs-picker-label">Content sources live in "If Live"</div>' +
        '<div class="pd-cs-picker">' + (pickerHtml || '<span class="muted">No profitable content source in this range.</span>') + "</div>" +
        '<div class="pd-cs-panels">' +
        '<div class="pd-cs-panel"><h4>Today (actual bookings)</h4>' + shareBarsHtml(share.actual) + "</div>" +
        '<div class="pd-cs-panel"><h4>If Live</h4>' + shareBarsHtml(share.hypo) + "</div>" +
        "</div>";

      root.querySelectorAll(".pd-cs-pill").forEach(function (el) {
        el.addEventListener("click", function () {
          var g = el.getAttribute("data-gds");
          if (self._selected.has(g)) {
            self._selected.delete(g);
          } else {
            self._selected.add(g);
          }
          self.render();
        });
      });
    }
  });
})();
