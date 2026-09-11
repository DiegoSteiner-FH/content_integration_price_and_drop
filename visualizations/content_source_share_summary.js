// Price & Drop Content Source Share -- Summary (SQL-aggregated) variant.
//
// Why (2026-09-11, DS): sibling of content_source_share.js, built for
// price_drop_share_summary instead of price_drop_share_rows. That other
// view ships one row per attempt (or per attempt + profitable source) to
// the browser so this could simulate "If Live" client-side with no
// re-query -- but at real volume that raw-row design silently truncates
// below Looker's ~5,000-row interactive cap (confirmed: real scope is
// ~9,000 attempts/day). price_drop_share_summary moves the ENTIRE
// Today-vs-If-Live computation into the derived table's own SQL instead,
// returning one row per (panel, content source) -- ~25-30 rows total
// regardless of real volume. That trades away the instant client-side
// toggle-pill picker: "which sources are live" is now the view's own
// live_sources filter (a real Looker filter on the tile/dashboard),
// re-running the query when changed, not a click handled in this file.
//
// This viz is therefore just a renderer: group the small set of rows by
// panel, sort by count within each panel, draw the same two-panel bar
// layout as content_source_share.js for visual parity, no interactivity
// of its own.
//
// Required fields (flat, no pivot):
//   price_drop_share_summary.panel
//   price_drop_share_summary.gds
//   price_drop_share_summary.count

(function () {
  var PANEL_FIELD = "price_drop_share_summary.panel";
  var GDS_FIELD = "price_drop_share_summary.gds";
  var COUNT_FIELD = "price_drop_share_summary.count";

  var REQUIRED_FIELDS = [PANEL_FIELD, GDS_FIELD, COUNT_FIELD];

  var NO_BOOKING = "(none)";

  var SHARE_PALETTE = ["#2545d9", "#16a34a", "#dc2626", "#d97706", "#7c3aed", "#0891b2", "#db2777", "#65a30d", "#4b5563"];

  var CSS = "\
    .pd-css { font-family: -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif; font-size: 15px; color: #111827; height: 100%; overflow: auto; padding: 8px 12px; }\
    .pd-css-stat { color: #6b7280; font-size: 13px; margin-bottom: 14px; }\
    .pd-css-stat b { color: #111827; }\
    .pd-css-panels { display: flex; gap: 24px; flex-wrap: wrap; }\
    .pd-css-panel { flex: 1 1 320px; min-width: 280px; }\
    .pd-css-panel h4 { font-size: 13px; font-weight: 700; text-transform: uppercase; letter-spacing: .04em; color: #9ca3af; margin: 0 0 10px; }\
    .share-row { display: flex; align-items: center; gap: 10px; padding: 6px 0; }\
    .share-key { flex: 0 0 140px; font-size: 13px; font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; display: flex; align-items: center; gap: 6px; }\
    .share-swatch { width: 10px; height: 10px; border-radius: 50%; flex: 0 0 auto; }\
    .share-track { flex: 1 1 auto; height: 10px; background: #f1f3f5; border-radius: 5px; overflow: hidden; }\
    .share-fill { height: 100%; border-radius: 5px; }\
    .share-figs { flex: 0 0 auto; font-size: 13px; font-variant-numeric: tabular-nums; white-space: nowrap; }\
    .muted { color: #9ca3af; }\
    .pd-css-empty { padding: 24px; color: #9ca3af; text-align: center; }\
  ";

  function injectStyleOnce() {
    if (document.getElementById("pd-css-style")) return;
    var style = document.createElement("style");
    style.id = "pd-css-style";
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

  // Rows are already aggregated to (panel, gds, count) by the derived
  // table -- no per-attempt reconstruction needed here, unlike
  // content_source_share.js's buildAttemptRecords(). Just bucket by panel
  // and compute each row's share of its own panel's total.
  function buildPanels(rawRows) {
    var byPanel = {};
    rawRows.forEach(function (row) {
      var panel = strVal(row[PANEL_FIELD], "");
      var gds = strVal(row[GDS_FIELD], NO_BOOKING) || NO_BOOKING;
      var count = numVal(row[COUNT_FIELD]);
      if (!byPanel[panel]) byPanel[panel] = {};
      byPanel[panel][gds] = (byPanel[panel][gds] || 0) + count;
    });
    function toSorted(m) {
      var total = Object.keys(m).reduce(function (sum, k) { return sum + m[k]; }, 0);
      return {
        total: total,
        items: Object.keys(m).map(function (key) {
          return { key: key, count: m[key], pct: total ? round2((100 * m[key]) / total) : 0 };
        }).sort(function (a, b) { return b.count - a.count; })
      };
    }
    return {
      today: toSorted(byPanel.today || {}),
      if_live: toSorted(byPanel.if_live || {})
    };
  }

  function shareBarsHtml(items) {
    if (!items.length) return "<p class='muted'>No data in this range.</p>";
    return items.map(function (it) {
      return '<div class="share-row">' +
        '<span class="share-key"><span class="share-swatch" style="background:' + colorForKey(it.key) + '"></span>' + esc(it.key) + "</span>" +
        '<div class="share-track"><div class="share-fill" style="width:' + it.pct + '%;background:' + colorForKey(it.key) + '"></div></div>' +
        '<span class="share-figs">' + it.pct + '% <span class="muted">(' + it.count.toLocaleString() + ')</span></span>' +
        "</div>";
    }).join("");
  }

  looker.plugins.visualizations.add({
    id: "price_drop_content_source_share_summary",
    label: "Price Drop Content Source Share (Summary)",
    options: {},

    create: function (element, config) {
      injectStyleOnce();
      element.innerHTML = '<div class="pd-css"></div>';
      this._rows = [];
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
      var root = this._element.querySelector(".pd-css");
      var panels = buildPanels(this._rows);

      if (!panels.today.total && !panels.if_live.total) {
        root.innerHTML = '<div class="pd-css-empty">No rows for this date range / filter selection</div>';
        return;
      }

      root.innerHTML =
        '<div class="pd-css-stat">Bookings in scope: <b>' + panels.today.total.toLocaleString() + "</b></div>" +
        '<div class="pd-css-panels">' +
        '<div class="pd-css-panel"><h4>Today (actual bookings)</h4>' + shareBarsHtml(panels.today.items) + "</div>" +
        '<div class="pd-css-panel"><h4>If Live</h4>' + shareBarsHtml(panels.if_live.items) + "</div>" +
        "</div>";
    }
  });
})();
