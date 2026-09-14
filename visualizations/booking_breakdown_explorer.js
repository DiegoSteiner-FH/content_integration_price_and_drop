// Price Drop Booking Breakdown Explorer -- custom Looker visualization.
//
// Why (2026-09-14, DS): sibling of breakdown_explorer.js (Price Drop
// Breakdown Explorer), same tab UI (GDS / Office / Carrier / Currency /
// Fare Type / Affiliate) over the same price_drop_candidates explore --
// but reads the booking_* measures instead of the opportunity-scoped ones.
// Those measures additionally require the attempt's real booking to have
// status='issued' AND is_test=0 (see is_real_booking in
// price_drop_candidates.view.lkml) -- a genuinely completed, non-test
// sale, not just a Profitable simulation result. Admissible Candidates
// Count stays from the original (all-bucket, not booking-gated) so a tab
// can be read as "how many opportunities were there, and how many became
// real, paid sales" side by side.
//
// Booking Avg Revenue is NOT read from the query -- same rule as the
// original explorer: recomputed per tab from the summed Booking Total
// Revenue / summed Booking Count (never an average of per-row averages),
// matching booking_avg_revenue's own LookML definition.
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
//   price_drop_candidates.booking_count
//   price_drop_candidates.booking_total_revenue
//   price_drop_candidates.booking_extra_rev_best_only
//
// Booking Avg Revenue is optional in the query (ignored if present --
// this viz always recomputes it itself, see above).

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

  var ADMISSIBLE_FIELD = VIEW + ".admissible_candidates_count";
  var BOOKING_COUNT_FIELD = VIEW + ".booking_count";
  var BOOKING_REVENUE_FIELD = VIEW + ".booking_total_revenue";
  var BOOKING_EXTRA_BEST_FIELD = VIEW + ".booking_extra_rev_best_only";

  var REQUIRED_FIELDS = TABS.map(function (t) { return t.field; })
    .concat([ADMISSIBLE_FIELD, BOOKING_COUNT_FIELD, BOOKING_REVENUE_FIELD, BOOKING_EXTRA_BEST_FIELD]);

  var CSS = "\
    .pd-bbe { font-family: -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif; font-size: 15px; color: #111827; height: 100%; overflow: auto; }\
    .pd-bbe-tabs { display: flex; gap: 4px; border-bottom: 1px solid #e5e7eb; padding: 0 4px; flex-wrap: wrap; }\
    .pd-bbe-tab { padding: 10px 16px; cursor: pointer; font-weight: 600; font-size: 14px; color: #6b7280; border-bottom: 2px solid transparent; user-select: none; }\
    .pd-bbe-tab:hover { color: #111827; }\
    .pd-bbe-tab.active { color: #2545d9; border-bottom-color: #2545d9; }\
    .pd-bbe-table-wrap { padding: 8px 4px; }\
    table.pd-bbe-table { width: 100%; border-collapse: collapse; table-layout: fixed; }\
    table.pd-bbe-table col.pd-bbe-col-key { width: 16%; }\
    table.pd-bbe-table col.pd-bbe-col-admissibleCount { width: 15%; }\
    table.pd-bbe-table col.pd-bbe-col-bookingCount { width: 15%; }\
    table.pd-bbe-table col.pd-bbe-col-bookingRevenue { width: 17%; }\
    table.pd-bbe-table col.pd-bbe-col-bookingAvgRevenue { width: 15%; }\
    table.pd-bbe-table col.pd-bbe-col-bookingExtraBestOnly { width: 22%; }\
    table.pd-bbe-table th { text-align: left; font-size: 12px; font-weight: 700; text-transform: uppercase; letter-spacing: .04em; color: #9ca3af; padding: 10px 12px; cursor: pointer; white-space: normal; line-height: 1.35; vertical-align: bottom; border-bottom: 1px solid #e5e7eb; position: sticky; top: 0; background: #fff; z-index: 2; }\
    table.pd-bbe-table th:hover { color: #111827; }\
    table.pd-bbe-table th.num, table.pd-bbe-table td.num { text-align: right; }\
    table.pd-bbe-table td { padding: 10px 12px; border-bottom: 1px solid #f1f3f5; font-variant-numeric: tabular-nums; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }\
    table.pd-bbe-table tbody tr:hover td { background: #f7f8fa; }\
    table.pd-bbe-table tfoot td { font-weight: 700; border-top: 2px solid #e5e7eb; border-bottom: none; background: #f7f8fa; position: sticky; bottom: 0; z-index: 2; }\
    .pd-bbe-pos { color: #16a34a; }\
    .pd-bbe-neg { color: #dc2626; }\
    .pd-bbe-sort-arrow { margin-left: 3px; font-size: 10px; }\
    .pd-bbe-empty { padding: 24px; color: #9ca3af; text-align: center; }\
  ";

  function injectStyleOnce() {
    if (document.getElementById("pd-bbe-style")) return;
    var style = document.createElement("style");
    style.id = "pd-bbe-style";
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
  // dims at once) down to just the one dimension the active tab
  // represents. Sums are safe across rows sharing a tab key -- same
  // reasoning as breakdown_explorer.js. Booking Avg Revenue is always
  // recomputed from the summed Booking Total Revenue and summed Booking
  // Count, never carried forward as an average-of-averages.
  function aggregateBy(rows, fieldName) {
    var groups = {};
    var order = [];
    rows.forEach(function (row) {
      var key = strVal(row[fieldName]);
      if (!groups[key]) {
        groups[key] = { key: key, admissibleCount: 0, bookingCount: 0, bookingRevenue: 0, bookingExtraBestOnly: 0 };
        order.push(key);
      }
      var g = groups[key];
      g.admissibleCount += numVal(row[ADMISSIBLE_FIELD]);
      g.bookingCount += numVal(row[BOOKING_COUNT_FIELD]);
      g.bookingRevenue += numVal(row[BOOKING_REVENUE_FIELD]);
      g.bookingExtraBestOnly += numVal(row[BOOKING_EXTRA_BEST_FIELD]);
    });
    return order.map(function (key) {
      var g = groups[key];
      g.bookingAvgRevenue = g.bookingCount ? g.bookingRevenue / g.bookingCount : 0;
      return g;
    });
  }

  // Grand total row -- Booking Avg Revenue recomputed from the totals,
  // same rule as aggregateBy.
  function computeTotals(grouped) {
    var t = { admissibleCount: 0, bookingCount: 0, bookingRevenue: 0, bookingExtraBestOnly: 0 };
    grouped.forEach(function (g) {
      t.admissibleCount += g.admissibleCount;
      t.bookingCount += g.bookingCount;
      t.bookingRevenue += g.bookingRevenue;
      t.bookingExtraBestOnly += g.bookingExtraBestOnly;
    });
    t.bookingAvgRevenue = t.bookingCount ? t.bookingRevenue / t.bookingCount : 0;
    return t;
  }

  var COLUMNS = [
    { key: "key", label: null /* filled per-tab */, num: false },
    { key: "admissibleCount", label: "Admissible Candidates", num: true },
    { key: "bookingCount", label: "Booking Count", num: true },
    { key: "bookingRevenue", label: "Booking Total Revenue", num: true, fmt: money },
    { key: "bookingAvgRevenue", label: "Booking Avg Revenue", num: true, fmt: money },
    { key: "bookingExtraBestOnly", label: "Booking Extra Rev. (Best Only)", num: true, fmt: moneySigned, signed: true }
  ];

  looker.plugins.visualizations.add({
    id: "price_drop_booking_breakdown_explorer",
    label: "Price Drop Booking Breakdown Explorer",
    options: {},

    create: function (element, config) {
      injectStyleOnce();
      element.innerHTML = '<div class="pd-bbe"></div>';
      this._rows = [];
      this._activeTab = TABS[0].key;
      this._sort = { col: "bookingRevenue", dir: "desc" };
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
      var root = this._element.querySelector(".pd-bbe");
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
        var cls = "pd-bbe-tab" + (t.key === self._activeTab ? " active" : "");
        return '<div class="' + cls + '" data-tab="' + t.key + '">' + t.label + "</div>";
      }).join("");

      var headHtml = COLUMNS.map(function (c) {
        var label = c.key === "key" ? activeTabDef.label : c.label;
        var arrow = "";
        if (sortCol === c.key) arrow = '<span class="pd-bbe-sort-arrow">' + (self._sort.dir === "desc" ? "▼" : "▲") + "</span>";
        return '<th class="' + (c.num ? "num" : "") + '" data-col="' + c.key + '">' + label + arrow + "</th>";
      }).join("");

      function rowHtml(g, isTotal) {
        return "<tr>" + COLUMNS.map(function (c) {
          var raw = c.key === "key" && isTotal ? "Total" : g[c.key];
          var display = c.key === "key"
            ? raw
            : (c.fmt ? c.fmt(raw) : raw.toLocaleString());
          var cls = c.num ? "num" : "";
          if (c.signed && typeof raw === "number") cls += raw > 0 ? " pd-bbe-pos" : raw < 0 ? " pd-bbe-neg" : "";
          return '<td class="' + cls + '">' + display + "</td>";
        }).join("") + "</tr>";
      }

      var bodyHtml = grouped.length
        ? grouped.map(function (g) { return rowHtml(g, false); }).join("")
        : '<tr><td colspan="' + COLUMNS.length + '" class="pd-bbe-empty">No rows for this date range / filter selection</td></tr>';

      var footHtml = grouped.length ? rowHtml(computeTotals(grouped), true) : "";

      var colgroupHtml = COLUMNS.map(function (c) {
        return '<col class="pd-bbe-col-' + c.key + '">';
      }).join("");

      root.innerHTML =
        '<div class="pd-bbe-tabs">' + tabsHtml + "</div>" +
        '<div class="pd-bbe-table-wrap"><table class="pd-bbe-table"><colgroup>' + colgroupHtml + '</colgroup><thead><tr>' + headHtml + "</tr></thead><tbody>" + bodyHtml + "</tbody><tfoot>" + footHtml + "</tfoot></table></div>";

      root.querySelectorAll(".pd-bbe-tab").forEach(function (el) {
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
