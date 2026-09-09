// Price Drop Breakdown Explorer -- custom Looker visualization.
//
// Why (2026-09-08, DS): reproduces ci_pricedrop_bot's own "Breakdown Explorer"
// tab UI (GDS / Office / Carrier / Currency / Fare Type / Affiliate) as ONE
// tile, matching the bot dashboard's client-side architecture -- pull
// aggregated data once, re-aggregate per tab entirely in JS, so switching
// tabs never re-queries the database. Route is not included (no ClickHouse
// join in this LookML project).
//
// v2 (2026-09-08): reworked to consume the explore's own pre-aggregated
// measures (grouped by all 6 contestant-info dims at once) instead of raw
// per-row Revenue / Extra Revenue -- the user wanted the query built from
// the same named measures already used elsewhere on the dashboard
// (Admissible Candidates Count, Total Revenue, Extra Revenue (If Booked),
// Extra Rev. (Best Only)) rather than two extra raw fields. Average Revenue
// is NOT read from the query -- it's recomputed per tab as
// sum(Total Revenue) / sum(Count) across whichever rows share that tab's
// key, never as an average-of-averages (that would be mathematically wrong
// once rows are re-grouped to a coarser key). Sums are safe to combine this
// way because every row's Count is a distinct-attempt count over a set of
// attempts that appears in exactly one (gds, office, carrier, currency,
// fare_type, affiliate_id) combination -- no attempt can span two rows, so
// no double-counting when summing across rows that share one dimension.
//
// v3 (2026-09-08): style pass -- bigger font, proportional column widths
// (colgroup) instead of content-driven sizing so a long header like
// "Extra Revenue (If Booked 100% of the Time)" no longer dominates the
// layout, and a totals (tfoot) row.
//
// Required fields, in this exact query (from the price_drop_candidates
// explore, grouped by all 6 dims below -- do NOT add Created Date as an
// output column, only as a filter, or every tab will double-count across
// dates instead of combining them):
//   price_drop_candidates.gds
//   price_drop_candidates.office
//   price_drop_candidates.carrier
//   price_drop_candidates.currency
//   price_drop_candidates.fare_type
//   price_drop_candidates.affiliate_id
//   price_drop_candidates.admissible_candidates_count
//   price_drop_candidates.revenue_sum
//   price_drop_candidates.extra_revenue_sum
//   price_drop_candidates.extra_revenue_best_only_sum
//
// Average Revenue is optional in the query (ignored if present -- this viz
// always recomputes it itself, see above).

(function () {
  var VIEW = "price_drop_candidates";

  var TABS = [
    { key: "gds", label: "GDS", field: VIEW + ".gds" },
    { key: "office", label: "Office", field: VIEW + ".office" },
    { key: "carrier", label: "Carrier", field: VIEW + ".carrier" },
    { key: "currency", label: "Currency", field: VIEW + ".currency" },
    { key: "fare_type", label: "Fare Type", field: VIEW + ".fare_type" },
    { key: "affiliate_id", label: "Affiliate", field: VIEW + ".affiliate_id" }
  ];

  var COUNT_FIELD = VIEW + ".admissible_candidates_count";
  var REVENUE_SUM_FIELD = VIEW + ".revenue_sum";
  var EXTRA_SUM_FIELD = VIEW + ".extra_revenue_sum";
  var EXTRA_BEST_FIELD = VIEW + ".extra_revenue_best_only_sum";

  var REQUIRED_FIELDS = TABS.map(function (t) { return t.field; })
    .concat([COUNT_FIELD, REVENUE_SUM_FIELD, EXTRA_SUM_FIELD, EXTRA_BEST_FIELD]);

  var CSS = "\
    .pd-be { font-family: -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif; font-size: 15px; color: #111827; height: 100%; overflow: auto; }\
    .pd-be-tabs { display: flex; gap: 4px; border-bottom: 1px solid #e5e7eb; padding: 0 4px; flex-wrap: wrap; }\
    .pd-be-tab { padding: 10px 16px; cursor: pointer; font-weight: 600; font-size: 14px; color: #6b7280; border-bottom: 2px solid transparent; user-select: none; }\
    .pd-be-tab:hover { color: #111827; }\
    .pd-be-tab.active { color: #2545d9; border-bottom-color: #2545d9; }\
    .pd-be-table-wrap { padding: 8px 4px; }\
    table.pd-be-table { width: 100%; border-collapse: collapse; table-layout: fixed; }\
    table.pd-be-table col.pd-be-col-key { width: 16%; }\
    table.pd-be-table col.pd-be-col-count { width: 10%; }\
    table.pd-be-table col.pd-be-col-totalRevenue { width: 15%; }\
    table.pd-be-table col.pd-be-col-avgRevenue { width: 13%; }\
    table.pd-be-table col.pd-be-col-extraIfBooked { width: 23%; }\
    table.pd-be-table col.pd-be-col-extraBestOnly { width: 23%; }\
    table.pd-be-table th { text-align: left; font-size: 12px; font-weight: 700; text-transform: uppercase; letter-spacing: .04em; color: #9ca3af; padding: 10px 12px; cursor: pointer; white-space: normal; line-height: 1.35; vertical-align: bottom; border-bottom: 1px solid #e5e7eb; }\
    table.pd-be-table th:hover { color: #111827; }\
    table.pd-be-table th.num, table.pd-be-table td.num { text-align: right; }\
    table.pd-be-table td { padding: 10px 12px; border-bottom: 1px solid #f1f3f5; font-variant-numeric: tabular-nums; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }\
    table.pd-be-table tr:hover td { background: #f7f8fa; }\
    table.pd-be-table tfoot td { font-weight: 700; border-top: 2px solid #e5e7eb; border-bottom: none; background: #f7f8fa; }\
    .pd-be-pos { color: #16a34a; }\
    .pd-be-neg { color: #dc2626; }\
    .pd-be-sort-arrow { margin-left: 3px; font-size: 10px; }\
    .pd-be-empty { padding: 24px; color: #9ca3af; text-align: center; }\
  ";

  function injectStyleOnce() {
    if (document.getElementById("pd-be-style")) return;
    var style = document.createElement("style");
    style.id = "pd-be-style";
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

  function money(n) {
    var sign = n < 0 ? "-" : "";
    return sign + "$" + Math.abs(n).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  }

  function moneySigned(n) {
    var sign = n > 0 ? "+" : n < 0 ? "-" : "";
    return sign + "$" + Math.abs(n).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  }

  // Re-aggregates the query's own pre-aggregated rows (grouped by all 6
  // dims at once) down to just the one dimension the active tab represents.
  // Sums are safe across rows sharing a tab key -- see the v2 note at the
  // top of this file for why. Average is always recomputed from the summed
  // total and summed count, never carried forward as an average-of-averages.
  function aggregateBy(rows, fieldName) {
    var groups = {};
    var order = [];
    rows.forEach(function (row) {
      var key = strVal(row[fieldName]);
      if (!groups[key]) {
        groups[key] = { key: key, count: 0, totalRevenue: 0, extraIfBooked: 0, extraBestOnly: 0 };
        order.push(key);
      }
      var g = groups[key];
      g.count += numVal(row[COUNT_FIELD]);
      g.totalRevenue += numVal(row[REVENUE_SUM_FIELD]);
      g.extraIfBooked += numVal(row[EXTRA_SUM_FIELD]);
      g.extraBestOnly += numVal(row[EXTRA_BEST_FIELD]);
    });
    return order.map(function (key) {
      var g = groups[key];
      g.avgRevenue = g.count ? g.totalRevenue / g.count : 0;
      return g;
    });
  }

  // Grand total row -- avgRevenue recomputed from the totals, same rule as
  // aggregateBy (never an average of per-row averages).
  function computeTotals(grouped) {
    var t = { count: 0, totalRevenue: 0, extraIfBooked: 0, extraBestOnly: 0 };
    grouped.forEach(function (g) {
      t.count += g.count;
      t.totalRevenue += g.totalRevenue;
      t.extraIfBooked += g.extraIfBooked;
      t.extraBestOnly += g.extraBestOnly;
    });
    t.avgRevenue = t.count ? t.totalRevenue / t.count : 0;
    return t;
  }

  var COLUMNS = [
    { key: "key", label: null /* filled per-tab */, num: false },
    { key: "count", label: "Count", num: true },
    { key: "totalRevenue", label: "Total Revenue", num: true, fmt: money },
    { key: "avgRevenue", label: "Avg Revenue", num: true, fmt: money },
    { key: "extraIfBooked", label: "Extra Revenue (If Booked 100% of the Time)", num: true, fmt: moneySigned, signed: true },
    { key: "extraBestOnly", label: "Extra Rev. (Best Only)", num: true, fmt: moneySigned, signed: true }
  ];

  looker.plugins.visualizations.add({
    id: "price_drop_breakdown_explorer",
    label: "Price Drop Breakdown Explorer",
    options: {},

    create: function (element, config) {
      injectStyleOnce();
      element.innerHTML = '<div class="pd-be"></div>';
      this._rows = [];
      this._activeTab = TABS[0].key;
      this._sort = { col: "totalRevenue", dir: "desc" };
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
          message: "Add these fields to the query (grouped by all 6 dims, Created Date as a filter only): " + missing.join(", ")
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
      var root = this._element.querySelector(".pd-be");
      var activeTabDef = TABS.filter(function (t) { return t.key === self._activeTab; })[0] || TABS[0];
      var grouped = aggregateBy(this._rows, activeTabDef.field);

      var sortCol = this._sort.col;
      var dir = this._sort.dir === "asc" ? 1 : -1;
      grouped.sort(function (a, b) {
        var av = sortCol === "key" ? a.key : a[sortCol];
        var bv = sortCol === "key" ? b.key : b[sortCol];
        if (typeof av === "string") return dir * av.localeCompare(bv);
        return dir * (av - bv);
      });

      var tabsHtml = TABS.map(function (t) {
        var cls = "pd-be-tab" + (t.key === self._activeTab ? " active" : "");
        return '<div class="' + cls + '" data-tab="' + t.key + '">' + t.label + "</div>";
      }).join("");

      var headHtml = COLUMNS.map(function (c) {
        var label = c.key === "key" ? activeTabDef.label : c.label;
        var arrow = "";
        if (sortCol === c.key) arrow = '<span class="pd-be-sort-arrow">' + (self._sort.dir === "desc" ? "▼" : "▲") + "</span>";
        return '<th class="' + (c.num ? "num" : "") + '" data-col="' + c.key + '">' + label + arrow + "</th>";
      }).join("");

      function rowHtml(g, isTotal) {
        return "<tr>" + COLUMNS.map(function (c) {
          var raw = c.key === "key" && isTotal ? "Total" : g[c.key];
          var display = c.key === "key"
            ? raw
            : (c.fmt ? c.fmt(raw) : raw.toLocaleString());
          var cls = c.num ? "num" : "";
          if (c.signed && typeof raw === "number") cls += raw > 0 ? " pd-be-pos" : raw < 0 ? " pd-be-neg" : "";
          return '<td class="' + cls + '">' + display + "</td>";
        }).join("") + "</tr>";
      }

      var bodyHtml = grouped.length
        ? grouped.map(function (g) { return rowHtml(g, false); }).join("")
        : '<tr><td colspan="' + COLUMNS.length + '" class="pd-be-empty">No rows for this date range / filter selection</td></tr>';

      var footHtml = grouped.length ? rowHtml(computeTotals(grouped), true) : "";

      var colgroupHtml = COLUMNS.map(function (c) {
        return '<col class="pd-be-col-' + c.key + '">';
      }).join("");

      root.innerHTML =
        '<div class="pd-be-tabs">' + tabsHtml + "</div>" +
        '<div class="pd-be-table-wrap"><table class="pd-be-table"><colgroup>' + colgroupHtml + '</colgroup><thead><tr>' + headHtml + "</tr></thead><tbody>" + bodyHtml + "</tbody><tfoot>" + footHtml + "</tfoot></table></div>";

      root.querySelectorAll(".pd-be-tab").forEach(function (el) {
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
