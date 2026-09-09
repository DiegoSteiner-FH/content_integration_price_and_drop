// Candidacy Breakdown Table -- custom Looker visualization.
//
// Why (2026-09-09, DS): reproduces the Candidacy Breakdown tile's shape (one
// row per date, one column per candidacy value, cell = % of that date's
// contestants) without needing Looker's native pivot + a hand-added "%"
// table calculation every time. Query stays FLAT (not pivoted) -- one row
// per (date, candidacy) -- and this viz reshapes + computes percentages
// entirely client-side, same "aggregate once, reshape in JS" architecture
// as price_drop_breakdown_explorer / price_drop_price_rate_table.
//
// Column order matches ci_pricedrop_bot's own CANDIDACY_COLUMN_ORDER
// (Admissible / Unmatchable / Unprofitable / Unbookable / Inadmissible /
// Incalculable / Unprocessable); any candidacy value outside that fixed
// list (e.g. Eligible, Saver, Unsalable) is appended alphabetically after
// it, same rule the bot's dashboard uses so header order never drifts
// between the two.
//
// Required fields, in this exact query (from the price_drop_candidacy_breakdown
// explore, flat/non-pivoted, no Looker-level pivot):
//   price_drop_candidacy_breakdown.date_date
//   price_drop_candidacy_breakdown.candidacy
//   price_drop_candidacy_breakdown.total_contestants_count
//
// Any other fields in the query (gds/office/carrier/etc.) are ignored for
// grouping -- rows are always grouped by date only. Add a filter on those
// fields instead of a query dimension if you want to narrow the population.

(function () {
  var VIEW = "price_drop_candidacy_breakdown";
  var DATE_FIELD = VIEW + ".date_date";
  var CANDIDACY_FIELD = VIEW + ".candidacy";
  var COUNT_FIELD = VIEW + ".total_contestants_count";

  var REQUIRED_FIELDS = [DATE_FIELD, CANDIDACY_FIELD, COUNT_FIELD];

  var FIXED_ORDER = [
    "Admissible", "Unmatchable", "Unprofitable", "Unbookable",
    "Inadmissible", "Incalculable", "Unprocessable"
  ];

  var CSS = "\
    .pd-cb { font-family: -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif; font-size: 15px; color: #111827; height: 100%; overflow: auto; }\
    .pd-cb-wrap { padding: 8px 4px; }\
    table.pd-cb-table { width: 100%; border-collapse: collapse; }\
    table.pd-cb-table th { text-align: left; font-size: 12px; font-weight: 700; text-transform: uppercase; letter-spacing: .04em; color: #9ca3af; padding: 10px 12px; cursor: pointer; white-space: normal; line-height: 1.35; vertical-align: bottom; border-bottom: 1px solid #e5e7eb; position: sticky; top: 0; background: #fff; z-index: 2; }\
    table.pd-cb-table th:hover { color: #111827; }\
    table.pd-cb-table th.num, table.pd-cb-table td.num { text-align: right; }\
    table.pd-cb-table td { padding: 10px 12px; border-bottom: 1px solid #f1f3f5; font-variant-numeric: tabular-nums; white-space: nowrap; position: relative; }\
    table.pd-cb-table tbody tr:hover td { background: #f7f8fa; }\
    table.pd-cb-table tfoot td { font-weight: 700; border-top: 2px solid #e5e7eb; border-bottom: none; background: #f7f8fa; position: sticky; bottom: 0; z-index: 2; }\
    .pd-cb-bar-wrap { position: relative; }\
    .pd-cb-bar-wrap span { position: relative; z-index: 1; }\
    .pd-cb-bar { position: absolute; left: 0; top: 4px; bottom: 4px; background: #eaf0fe; border-radius: 3px; z-index: 0; }\
    .pd-cb-sort-arrow { margin-left: 3px; font-size: 10px; }\
    .pd-cb-empty { padding: 24px; color: #9ca3af; text-align: center; }\
  ";

  function injectStyleOnce() {
    if (document.getElementById("pd-cb-style")) return;
    var style = document.createElement("style");
    style.id = "pd-cb-style";
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

  function pct(n) {
    return n.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 }) + "%";
  }

  // Green intensity scale matching the reference dashboard -- 0% white,
  // 100% full green. Applied per-cell from that cell's own percentage.
  function heatBg(p) {
    var t = Math.max(0, Math.min(1, p / 100));
    var alpha = 0.08 + t * 0.55;
    return "rgba(22, 163, 74, " + alpha.toFixed(3) + ")";
  }

  // One row per date: { date, total, counts: { candidacyValue: count } }.
  // Also returns the full set of distinct candidacy values seen, ordered
  // FIXED_ORDER-first then alphabetically for anything outside that list.
  function buildRows(rawRows) {
    var byDate = {};
    var order = [];
    var seen = {};
    rawRows.forEach(function (row) {
      var d = strVal(row[DATE_FIELD]);
      var candidacy = strVal(row[CANDIDACY_FIELD]);
      var n = numVal(row[COUNT_FIELD]);
      seen[candidacy] = true;
      if (!byDate[d]) {
        byDate[d] = { date: d, total: 0, counts: {} };
        order.push(d);
      }
      byDate[d].total += n;
      byDate[d].counts[candidacy] = (byDate[d].counts[candidacy] || 0) + n;
    });
    var extras = Object.keys(seen).filter(function (c) { return FIXED_ORDER.indexOf(c) === -1; }).sort();
    var columnOrder = FIXED_ORDER.filter(function (c) { return seen[c]; }).concat(extras);
    return { rows: order.map(function (d) { return byDate[d]; }), columns: columnOrder };
  }

  function computeTotals(rows, columns) {
    var t = { date: "Total", total: 0, counts: {} };
    columns.forEach(function (c) { t.counts[c] = 0; });
    rows.forEach(function (r) {
      t.total += r.total;
      columns.forEach(function (c) { t.counts[c] += r.counts[c] || 0; });
    });
    return t;
  }

  looker.plugins.visualizations.add({
    id: "price_drop_candidacy_breakdown_table",
    label: "Price Drop Candidacy Breakdown Table",
    options: {},

    create: function (element, config) {
      injectStyleOnce();
      element.innerHTML = '<div class="pd-cb"></div>';
      this._rows = [];
      this._sort = { col: "date", dir: "desc" };
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
      var root = this._element.querySelector(".pd-cb");
      var built = buildRows(this._rows);
      var rows = built.rows;
      var columns = built.columns;

      var sortCol = this._sort.col;
      var dir = this._sort.dir === "asc" ? 1 : -1;
      rows.sort(function (a, b) {
        var av = sortCol === "date" ? a.date : sortCol === "total" ? a.total : (a.total ? (a.counts[sortCol] || 0) / a.total : 0);
        var bv = sortCol === "date" ? b.date : sortCol === "total" ? b.total : (b.total ? (b.counts[sortCol] || 0) / b.total : 0);
        if (typeof av === "string") return dir * av.localeCompare(bv);
        return dir * (av - bv);
      });

      var maxTotal = rows.reduce(function (m, r) { return Math.max(m, r.total); }, 0) || 1;

      function sortArrow(col) {
        return sortCol === col ? '<span class="pd-cb-sort-arrow">' + (self._sort.dir === "desc" ? "▼" : "▲") + "</span>" : "";
      }

      var headHtml = '<th data-col="date">Date' + sortArrow("date") + "</th>" +
        '<th class="num" data-col="total">Total Contestants' + sortArrow("total") + "</th>" +
        columns.map(function (c) {
          return '<th class="num" data-col="' + c + '">' + c + sortArrow(c) + "</th>";
        }).join("");

      function rowHtml(r, isTotal) {
        var barPct = isTotal ? 100 : (r.total / maxTotal) * 100;
        var totalCell = isTotal
          ? '<td class="num">' + r.total.toLocaleString() + "</td>"
          : '<td class="num pd-cb-bar-wrap"><span class="pd-cb-bar" style="width:' + barPct.toFixed(1) + '%"></span><span>' + r.total.toLocaleString() + "</span></td>";
        var candidacyCells = columns.map(function (c) {
          var count = r.counts[c] || 0;
          var p = r.total ? (count / r.total) * 100 : 0;
          var style = isTotal ? "" : ' style="background:' + heatBg(p) + '"';
          return '<td class="num"' + style + ">" + (count ? pct(p) : "0%") + "</td>";
        }).join("");
        return "<tr><td>" + r.date + "</td>" + totalCell + candidacyCells + "</tr>";
      }

      var bodyHtml = rows.length
        ? rows.map(function (r) { return rowHtml(r, false); }).join("")
        : '<tr><td colspan="' + (columns.length + 2) + '" class="pd-cb-empty">No rows for this date range / filter selection</td></tr>';

      var footHtml = rows.length ? rowHtml(computeTotals(rows, columns), true) : "";

      root.innerHTML =
        '<div class="pd-cb-wrap"><table class="pd-cb-table"><thead><tr>' +
        headHtml + "</tr></thead><tbody>" + bodyHtml + "</tbody><tfoot>" + footHtml + "</tfoot></table></div>";

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
