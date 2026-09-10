// Price Rate Table -- custom Looker visualization.
//
// Why (2026-09-09, DS): reproduces the Price Rate tile's shape (one row per
// date, one column per price outcome, cell = % of that date's contestants)
// without needing Looker's native pivot + a hand-added "%" table
// calculation every time. Query stays FLAT (not pivoted) -- one row per
// (date, outcome) -- and this viz reshapes + computes percentages entirely
// client-side, same "aggregate once, reshape in JS" architecture as
// price_drop_breakdown_explorer.
//
// v2 (2026-09-10): added per-content-source tabs, built dynamically from
// whatever GDS values are present in the raw query rows each render -- no
// hardcoded list, same pattern as price_drop_funnel_table.js's tabs. An
// "All" tab (first, default) aggregates every source together, identical
// to this viz's original behavior; a GDS-specific tab filters the raw rows
// to that one source BEFORE the existing date-level aggregation runs, so
// grouping-by-date is unchanged -- only which rows feed it changes.
//
// Required fields, in this exact query (from the price_drop_price_rate
// explore, flat/non-pivoted, no Looker-level pivot):
//   price_drop_price_rate.date_date
//   price_drop_price_rate.gds
//   price_drop_price_rate.outcome
//   price_drop_price_rate.total_contestants_count
//
// Any OTHER fields in the query (office/carrier/etc.) are still ignored for
// grouping -- rows are always grouped by date (and now optionally filtered
// by the active GDS tab). Add a filter on those fields instead of a query
// dimension if you want to narrow the population further.

(function () {
  var VIEW = "price_drop_price_rate";
  var DATE_FIELD = VIEW + ".date_date";
  var GDS_FIELD = VIEW + ".gds";
  var OUTCOME_FIELD = VIEW + ".outcome";
  var COUNT_FIELD = VIEW + ".total_contestants_count";

  var REQUIRED_FIELDS = [DATE_FIELD, GDS_FIELD, OUTCOME_FIELD, COUNT_FIELD];

  var ALL_TAB = "__all__";

  var OUTCOME_COLUMNS = [
    { key: "better", label: "% Better Price" },
    { key: "same", label: "% Same Price" },
    { key: "worse", label: "% Worse Price" },
    { key: "no_price", label: "% No Price" }
  ];

  var CSS = "\
    .pd-pr { font-family: -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif; font-size: 15px; color: #111827; height: 100%; overflow: auto; }\
    .pd-pr-tabs { display: flex; gap: 4px; border-bottom: 1px solid #e5e7eb; padding: 0 4px; flex-wrap: wrap; }\
    .pd-pr-tab { padding: 10px 16px; cursor: pointer; font-weight: 600; font-size: 14px; color: #6b7280; border-bottom: 2px solid transparent; user-select: none; }\
    .pd-pr-tab:hover { color: #111827; }\
    .pd-pr-tab.active { color: #2545d9; border-bottom-color: #2545d9; }\
    .pd-pr-wrap { padding: 8px 4px; }\
    table.pd-pr-table { width: 100%; border-collapse: collapse; table-layout: fixed; }\
    table.pd-pr-table col.pd-pr-col-date { width: 14%; }\
    table.pd-pr-table col.pd-pr-col-total { width: 20%; }\
    table.pd-pr-table th { text-align: left; font-size: 12px; font-weight: 700; text-transform: uppercase; letter-spacing: .04em; color: #9ca3af; padding: 10px 12px; cursor: pointer; white-space: normal; line-height: 1.35; vertical-align: bottom; border-bottom: 1px solid #e5e7eb; position: sticky; top: 0; background: #fff; z-index: 2; }\
    table.pd-pr-table th:hover { color: #111827; }\
    table.pd-pr-table th.num, table.pd-pr-table td.num { text-align: right; }\
    table.pd-pr-table td { padding: 10px 12px; border-bottom: 1px solid #f1f3f5; font-variant-numeric: tabular-nums; white-space: nowrap; position: relative; }\
    table.pd-pr-table tbody tr:hover td { background: #f7f8fa; }\
    table.pd-pr-table tfoot td { font-weight: 700; border-top: 2px solid #e5e7eb; border-bottom: none; background: #f7f8fa; position: sticky; bottom: 0; z-index: 2; }\
    .pd-pr-bar-wrap { position: relative; }\
    .pd-pr-bar-wrap span { position: relative; z-index: 1; }\
    .pd-pr-bar { position: absolute; left: 0; top: 4px; bottom: 4px; background: #eaf0fe; border-radius: 3px; z-index: 0; }\
    .pd-pr-sort-arrow { margin-left: 3px; font-size: 10px; }\
    .pd-pr-empty { padding: 24px; color: #9ca3af; text-align: center; }\
  ";

  function injectStyleOnce() {
    if (document.getElementById("pd-pr-style")) return;
    var style = document.createElement("style");
    style.id = "pd-pr-style";
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

  // Blue intensity scale matching the reference dashboard -- 0% white,
  // 100% full blue. Applied per-cell from that cell's own percentage.
  function heatBg(p) {
    var t = Math.max(0, Math.min(1, p / 100));
    var alpha = 0.08 + t * 0.55;
    return "rgba(37, 69, 217, " + alpha.toFixed(3) + ")";
  }

  // Distinct GDS values present in the raw (pre-aggregation) rows, ordered
  // by each source's own total contestant count descending -- most active
  // content source first. Built fresh every render, same no-hardcoded-list
  // pattern as price_drop_funnel_table.js's tabs.
  function distinctGds(rawRows) {
    var totals = {};
    var order = [];
    rawRows.forEach(function (row) {
      var g = strVal(row[GDS_FIELD]);
      if (!(g in totals)) { totals[g] = 0; order.push(g); }
      totals[g] += numVal(row[COUNT_FIELD]);
    });
    order.sort(function (a, b) { return totals[b] - totals[a]; });
    return order;
  }

  // One row per date: { date, total, counts: {better, same, worse, no_price} }.
  function buildRows(rawRows) {
    var byDate = {};
    var order = [];
    rawRows.forEach(function (row) {
      var d = strVal(row[DATE_FIELD]);
      var outcome = strVal(row[OUTCOME_FIELD]);
      var n = numVal(row[COUNT_FIELD]);
      if (!byDate[d]) {
        byDate[d] = { date: d, total: 0, counts: { better: 0, same: 0, worse: 0, no_price: 0 } };
        order.push(d);
      }
      byDate[d].total += n;
      if (byDate[d].counts.hasOwnProperty(outcome)) {
        byDate[d].counts[outcome] += n;
      }
    });
    return order.map(function (d) { return byDate[d]; });
  }

  function computeTotals(rows) {
    var t = { date: "Total", total: 0, counts: { better: 0, same: 0, worse: 0, no_price: 0 } };
    rows.forEach(function (r) {
      t.total += r.total;
      OUTCOME_COLUMNS.forEach(function (c) { t.counts[c.key] += r.counts[c.key]; });
    });
    return t;
  }

  looker.plugins.visualizations.add({
    id: "price_drop_price_rate_table",
    label: "Price Drop Price Rate Table",
    options: {},

    create: function (element, config) {
      injectStyleOnce();
      element.innerHTML = '<div class="pd-pr"></div>';
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
      var root = this._element.querySelector(".pd-pr");
      var gdsList = distinctGds(this._rows);

      if (self._activeTab !== ALL_TAB && gdsList.indexOf(self._activeTab) === -1) {
        self._activeTab = ALL_TAB;
      }

      var rawRows = self._activeTab === ALL_TAB
        ? this._rows
        : this._rows.filter(function (row) { return strVal(row[GDS_FIELD]) === self._activeTab; });

      var rows = buildRows(rawRows);

      var sortCol = this._sort.col;
      var dir = this._sort.dir === "asc" ? 1 : -1;
      rows.sort(function (a, b) {
        var av = sortCol === "date" ? a.date : sortCol === "total" ? a.total : (a.total ? a.counts[sortCol] / a.total : 0);
        var bv = sortCol === "date" ? b.date : sortCol === "total" ? b.total : (b.total ? b.counts[sortCol] / b.total : 0);
        if (typeof av === "string") return dir * av.localeCompare(bv);
        return dir * (av - bv);
      });

      var maxTotal = rows.reduce(function (m, r) { return Math.max(m, r.total); }, 0) || 1;

      function sortArrow(col) {
        return sortCol === col ? '<span class="pd-pr-sort-arrow">' + (self._sort.dir === "desc" ? "▼" : "▲") + "</span>" : "";
      }

      var tabsHtml = ['<div class="pd-pr-tab' + (self._activeTab === ALL_TAB ? " active" : "") + '" data-tab="' + ALL_TAB + '">All</div>']
        .concat(gdsList.map(function (g) {
          var cls = "pd-pr-tab" + (g === self._activeTab ? " active" : "");
          return '<div class="' + cls + '" data-tab="' + g + '">' + g + "</div>";
        })).join("");

      var headHtml = '<th data-col="date">Date' + sortArrow("date") + "</th>" +
        '<th class="num" data-col="total">Total Contestants' + sortArrow("total") + "</th>" +
        OUTCOME_COLUMNS.map(function (c) {
          return '<th class="num" data-col="' + c.key + '">' + c.label + sortArrow(c.key) + "</th>";
        }).join("");

      function rowHtml(r, isTotal) {
        var barPct = isTotal ? 100 : (r.total / maxTotal) * 100;
        var totalCell = isTotal
          ? '<td class="num">' + r.total.toLocaleString() + "</td>"
          : '<td class="num pd-pr-bar-wrap"><span class="pd-pr-bar" style="width:' + barPct.toFixed(1) + '%"></span><span>' + r.total.toLocaleString() + "</span></td>";
        var outcomeCells = OUTCOME_COLUMNS.map(function (c) {
          var p = r.total ? (r.counts[c.key] / r.total) * 100 : 0;
          var style = isTotal ? "" : ' style="background:' + heatBg(p) + '"';
          return '<td class="num"' + style + ">" + pct(p) + "</td>";
        }).join("");
        return "<tr><td>" + r.date + "</td>" + totalCell + outcomeCells + "</tr>";
      }

      var bodyHtml = rows.length
        ? rows.map(function (r) { return rowHtml(r, false); }).join("")
        : '<tr><td colspan="6" class="pd-pr-empty">No rows for this date range / filter selection</td></tr>';

      var footHtml = rows.length ? rowHtml(computeTotals(rows), true) : "";

      root.innerHTML =
        '<div class="pd-pr-tabs">' + tabsHtml + "</div>" +
        '<div class="pd-pr-wrap"><table class="pd-pr-table"><colgroup><col class="pd-pr-col-date"><col class="pd-pr-col-total"></colgroup><thead><tr>' +
        headHtml + "</tr></thead><tbody>" + bodyHtml + "</tbody><tfoot>" + footHtml + "</tfoot></table></div>";

      root.querySelectorAll(".pd-pr-tab").forEach(function (el) {
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
