// Price & Drop Attempt Examples Table -- custom Looker visualization.
//
// Why (2026-09-09, DS): a flat, per-attempt drill-down table -- similar in
// spirit to ci_pricedrop_bot's own per-row "show N more attempts" dropdown
// (attemptsRowHtml()/explorerRowToAttempt() in its merged dashboard JS),
// but as its own standalone tile rather than nested inside the aggregated
// Breakdown Explorer. Built separately deliberately: the bot itself only
// keeps its own attempt dropdown for the most recent 4 days specifically
// because of cost, and nesting attempt-level detail inside the already-
// cheap, already-working Breakdown Explorer risked the same row-count
// ceiling the Content Source Share tile hit (see price_drop_share_rows.
// view.lkml / content_source_share.js for that story).
//
// Much simpler than the Funnel/Share custom visualizations in this
// project: price_drop_candidates is ALREADY one row per attempt (its own
// derived table dedupes to the single best-revenue candidate per
// attempt_id), so there's no client-side merge/fan-out step needed here --
// this viz only adds tabs, sorting, and formatting on top of what the
// query already returns.
//
// Per-content-source tabs are built dynamically from whatever GDS values
// are actually present in the current result set (distinctGds) -- no
// hardcoded list, same pattern as price_drop_funnel_table.js's tabs. A new
// content source shows up as its own tab the moment it appears in a query
// result. An "All" tab (first, default) shows every content source mixed
// together with its own Content Source column; a GDS-specific tab drops
// that now-redundant column.
//
// The Delta column is eligible_delta (price_drop_candidates.
// eligible_delta) -- this project's own eligible-only "beats best Eligible"
// comparison, paired with best_eligible_revenue_on_attempt as the "vs."
// baseline. Deliberately NOT the bot's own booked-first comparison chain
// (extra_revenue) -- see price_drop_candidates.view.lkml's own comments.
//
// v2 (2026-09-09): Date now leads the row (was Attempt ID first) -- matches
// every other tile's column order in this project. Attempt ID is now a
// clickable link to the internal Optimizer attempt page
// (https://reservations.voyagesalacarte.ca/optimizer/attempt/<id>), opening
// in a new tab so the tile itself stays open underneath.
//
// Required fields (flat, no pivot):
//   price_drop_candidates.attempt_id
//   price_drop_candidates.date_date
//   price_drop_candidates.gds
//   price_drop_candidates.carrier
//   price_drop_candidates.office
//   price_drop_candidates.fare_type
//   price_drop_candidates.revenue
//   price_drop_candidates.best_eligible_revenue_on_attempt
//   price_drop_candidates.eligible_delta

(function () {
  var ATTEMPT_FIELD = "price_drop_candidates.attempt_id";
  var DATE_FIELD = "price_drop_candidates.date_date";
  var GDS_FIELD = "price_drop_candidates.gds";
  var CARRIER_FIELD = "price_drop_candidates.carrier";
  var OFFICE_FIELD = "price_drop_candidates.office";
  var FARE_TYPE_FIELD = "price_drop_candidates.fare_type";
  var REVENUE_FIELD = "price_drop_candidates.revenue";
  var BEST_ELIGIBLE_FIELD = "price_drop_candidates.best_eligible_revenue_on_attempt";
  var DELTA_FIELD = "price_drop_candidates.eligible_delta";

  var REQUIRED_FIELDS = [
    ATTEMPT_FIELD, DATE_FIELD, GDS_FIELD, CARRIER_FIELD, OFFICE_FIELD,
    FARE_TYPE_FIELD, REVENUE_FIELD, BEST_ELIGIBLE_FIELD, DELTA_FIELD
  ];

  var ALL_TAB = "__all__";

  var ATTEMPT_URL_BASE = "https://reservations.voyagesalacarte.ca/optimizer/attempt/";

  var CSS = "\
    .pd-ae { font-family: -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif; font-size: 15px; color: #111827; height: 100%; overflow: auto; }\
    .pd-ae-tabs { display: flex; gap: 4px; border-bottom: 1px solid #e5e7eb; padding: 0 4px; flex-wrap: wrap; }\
    .pd-ae-tab { padding: 10px 16px; cursor: pointer; font-weight: 600; font-size: 14px; color: #6b7280; border-bottom: 2px solid transparent; user-select: none; }\
    .pd-ae-tab:hover { color: #111827; }\
    .pd-ae-tab.active { color: #2545d9; border-bottom-color: #2545d9; }\
    .pd-ae-wrap { padding: 8px 4px; }\
    table.pd-ae-table { width: 100%; border-collapse: collapse; table-layout: fixed; }\
    table.pd-ae-table th { text-align: left; font-size: 12px; font-weight: 700; text-transform: uppercase; letter-spacing: .04em; color: #9ca3af; padding: 10px 12px; cursor: pointer; white-space: normal; line-height: 1.35; vertical-align: bottom; border-bottom: 1px solid #e5e7eb; position: sticky; top: 0; background: #fff; z-index: 2; }\
    table.pd-ae-table th:hover { color: #111827; }\
    table.pd-ae-table th.num, table.pd-ae-table td.num { text-align: right; }\
    table.pd-ae-table td { padding: 10px 12px; border-bottom: 1px solid #f1f3f5; font-variant-numeric: tabular-nums; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }\
    table.pd-ae-table td.mono { font-variant-numeric: tabular-nums; }\
    table.pd-ae-table tbody tr:hover td { background: #f7f8fa; }\
    table.pd-ae-table tfoot td { font-weight: 700; border-top: 2px solid #e5e7eb; border-bottom: none; background: #f7f8fa; position: sticky; bottom: 0; z-index: 2; }\
    .pd-ae-pos { color: #16a34a; }\
    .pd-ae-neg { color: #dc2626; }\
    .pd-ae-sort-arrow { margin-left: 3px; font-size: 10px; }\
    .pd-ae-empty { padding: 24px; color: #9ca3af; text-align: center; }\
    .pd-ae-link { color: #2545d9; text-decoration: none; }\
    .pd-ae-link:hover { text-decoration: underline; }\
  ";

  function injectStyleOnce() {
    if (document.getElementById("pd-ae-style")) return;
    var style = document.createElement("style");
    style.id = "pd-ae-style";
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
      return fallback === undefined ? "(none)" : fallback;
    }
    return String(cell.value);
  }

  function fmtInt(n) {
    return n.toLocaleString();
  }

  function fmtMoney(n) {
    return "$" + n.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  }

  function fmtMoneySigned(n) {
    var sign = n > 0 ? "+" : n < 0 ? "-" : "";
    return sign + "$" + Math.abs(n).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  }

  function esc(s) {
    return String(s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  function buildRows(rawRows) {
    return rawRows.map(function (row) {
      return {
        attemptId: strVal(row[ATTEMPT_FIELD]),
        date: strVal(row[DATE_FIELD]),
        gds: strVal(row[GDS_FIELD]),
        carrier: strVal(row[CARRIER_FIELD]),
        office: strVal(row[OFFICE_FIELD]),
        fareType: strVal(row[FARE_TYPE_FIELD]),
        revenue: numVal(row[REVENUE_FIELD]),
        bestEligible: numVal(row[BEST_ELIGIBLE_FIELD]),
        delta: numVal(row[DELTA_FIELD]),
      };
    });
  }

  // Distinct GDS values present in this result set, ordered by row count
  // descending -- most active content source first. Built fresh every
  // render, same no-hardcoded-list pattern as price_drop_funnel_table.js's
  // tabs -- a brand-new content source becomes its own tab the moment it
  // appears in a query result.
  function distinctGds(rows) {
    var counts = {};
    var order = [];
    rows.forEach(function (r) {
      if (!(r.gds in counts)) { counts[r.gds] = 0; order.push(r.gds); }
      counts[r.gds] += 1;
    });
    order.sort(function (a, b) { return counts[b] - counts[a]; });
    return order;
  }

  looker.plugins.visualizations.add({
    id: "price_drop_attempt_examples_table",
    label: "Price Drop Attempt Examples Table",
    options: {},

    create: function (element, config) {
      injectStyleOnce();
      element.innerHTML = '<div class="pd-ae"></div>';
      this._rows = [];
      this._sort = { col: "date", dir: "desc" };
      this._activeTab = ALL_TAB;
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
      var root = this._element.querySelector(".pd-ae");
      var allRows = buildRows(this._rows);
      var gdsList = distinctGds(allRows);

      if (self._activeTab !== ALL_TAB && gdsList.indexOf(self._activeTab) === -1) {
        self._activeTab = ALL_TAB;
      }

      var showGdsCol = self._activeTab === ALL_TAB;
      var rows = showGdsCol ? allRows : allRows.filter(function (r) { return r.gds === self._activeTab; });

      var sortCol = self._sort.col;
      var dir = self._sort.dir === "asc" ? 1 : -1;
      rows.sort(function (a, b) {
        var av = a[sortCol];
        var bv = b[sortCol];
        if (typeof av === "string") return dir * av.localeCompare(bv);
        return dir * (av - bv);
      });

      function sortArrow(col) {
        return sortCol === col ? '<span class="pd-ae-sort-arrow">' + (self._sort.dir === "desc" ? "▼" : "▲") + "</span>" : "";
      }

      var tabsHtml = ['<div class="pd-ae-tab' + (self._activeTab === ALL_TAB ? " active" : "") + '" data-tab="' + ALL_TAB + '">All</div>']
        .concat(gdsList.map(function (g) {
          var cls = "pd-ae-tab" + (g === self._activeTab ? " active" : "");
          return '<div class="' + cls + '" data-tab="' + g + '">' + g + "</div>";
        })).join("");

      var headHtml =
        '<th data-col="date">Date' + sortArrow("date") + "</th>" +
        '<th data-col="attemptId">Attempt ID' + sortArrow("attemptId") + "</th>" +
        (showGdsCol ? '<th data-col="gds">Content Source' + sortArrow("gds") + "</th>" : "") +
        '<th data-col="carrier">Carrier' + sortArrow("carrier") + "</th>" +
        '<th data-col="office">Office' + sortArrow("office") + "</th>" +
        '<th data-col="fareType">Fare Type' + sortArrow("fareType") + "</th>" +
        '<th class="num" data-col="revenue">PD Rev' + sortArrow("revenue") + "</th>" +
        '<th class="num" data-col="bestEligible">Best Eligible Rev' + sortArrow("bestEligible") + "</th>" +
        '<th class="num" data-col="delta">Delta' + sortArrow("delta") + "</th>";

      var colCount = showGdsCol ? 9 : 8;

      function rowHtml(r) {
        var attemptLink = '<a class="pd-ae-link" href="' + ATTEMPT_URL_BASE + encodeURIComponent(r.attemptId) + '" target="_blank" rel="noopener noreferrer">' + esc(r.attemptId) + "</a>";
        return "<tr>" +
          "<td>" + esc(r.date) + "</td>" +
          '<td class="mono">' + attemptLink + "</td>" +
          (showGdsCol ? "<td>" + esc(r.gds) + "</td>" : "") +
          "<td>" + esc(r.carrier) + "</td>" +
          "<td>" + esc(r.office) + "</td>" +
          "<td>" + esc(r.fareType) + "</td>" +
          '<td class="num">' + fmtMoney(r.revenue) + "</td>" +
          '<td class="num">' + fmtMoney(r.bestEligible) + "</td>" +
          '<td class="num ' + (r.delta > 0 ? "pd-ae-pos" : r.delta < 0 ? "pd-ae-neg" : "") + '">' + fmtMoneySigned(r.delta) + "</td>" +
          "</tr>";
      }

      var bodyHtml = rows.length
        ? rows.map(rowHtml).join("")
        : '<tr><td colspan="' + colCount + '" class="pd-ae-empty">No rows for this date range / filter selection</td></tr>';

      var totalDelta = rows.reduce(function (s, r) { return s + r.delta; }, 0);
      var footHtml = rows.length
        ? '<tr><td colspan="' + (colCount - 1) + '">' + fmtInt(rows.length) + " attempts</td><td class=\"num " + (totalDelta > 0 ? "pd-ae-pos" : totalDelta < 0 ? "pd-ae-neg" : "") + '">' + fmtMoneySigned(totalDelta) + "</td></tr>"
        : "";

      root.innerHTML =
        '<div class="pd-ae-tabs">' + tabsHtml + "</div>" +
        '<div class="pd-ae-wrap"><table class="pd-ae-table"><thead><tr>' +
        headHtml + "</tr></thead><tbody>" + bodyHtml + "</tbody><tfoot>" + footHtml + "</tfoot></table></div>";

      root.querySelectorAll(".pd-ae-tab").forEach(function (el) {
        el.addEventListener("click", function () {
          self._activeTab = el.getAttribute("data-tab");
          self.render();
        });
      });
      root.querySelectorAll("th").forEach(function (el) {
        el.addEventListener("click", function () {
          var col = el.getAttribute("data-col");
          if (self._sort.col === col) {
            self._sort.dir = self._sort.dir === "desc" ? "asc" : "desc";
          } else {
            self._sort.col = col;
            self._sort.dir = "desc";
          }
          self.render();
        });
      });
    }
  });
})();
