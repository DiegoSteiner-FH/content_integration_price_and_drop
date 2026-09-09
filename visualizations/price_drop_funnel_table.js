// Price & Drop Funnel Table -- custom Looker visualization.
//
// Why (2026-09-09, DS): reproduces ci_pricedrop_bot's "Price & Drop funnel"
// tile -- one row per (date, content source), showing top-of-funnel volume
// down through Admissible candidates down through Profitable ones (beats the
// best Eligible candidate). Unlike the sibling Price Rate / Candidacy
// Breakdown custom visualizations, this query is NOT reshaped client-side --
// price_drop_any_tag and price_drop_candidates are joined in the explore at
// the (date, gds) grain already, so each result row already IS one funnel
// row. This viz only computes the two percentage columns and renders/sorts/
// totals.
//
// Why (2026-09-09, DS), field swap #1: funnel_wins_count /
// funnel_win_extra_revenue_sum were removed from price_drop_candidates --
// "Profitable" was redefined globally to mean "beats best Eligible" (was
// revenue > 0), making those two fields exact duplicates of
// profitable_candidates_count / extra_revenue_best_only_sum. This viz now
// reads the latter two directly; no other logic changed.
//
// Why (2026-09-09, DS), field swap #2: this tile now runs against the
// dedicated "CI Price Drop Bot - Funnel" explore (price_drop_funnel), which
// uses `from: price_drop_any_tag` to drive the join from that view instead
// of price_drop_candidates (fixes zero-Admissible content sources like
// 'abc' disappearing). Looker's `from:` aliases the base view's own fields
// to the EXPLORE's name for that explore -- so the top-of-funnel count is
// now price_drop_funnel.attempts_with_price_drop_count, not
// price_drop_any_tag.attempts_with_price_drop_count.
//
// Why (2026-09-09, DS), field swap #3: Date/Content Source now read from
// price_drop_funnel.date_date/.gds (the base view, always populated)
// instead of price_drop_candidates.date_date/.gds. That second pair is
// NULL for any (date, gds) with zero Admissible candidates on the LEFT
// JOIN -- exactly the rows this whole redesign exists to surface correctly
// (e.g. 'abc': real Price & Drop activity, zero Admissible candidates).
// Reading Date/Content Source off price_drop_candidates would render
// blank/garbled labels for precisely the rows that matter most.
//
// Required fields, in this exact query (flat, no pivot), from the
// "CI Price Drop Bot - Funnel" explore:
//   price_drop_funnel.date_date
//   price_drop_funnel.gds
//   price_drop_funnel.attempts_with_price_drop_count
//   price_drop_candidates.admissible_candidates_count
//   price_drop_candidates.profitable_candidates_count
//   price_drop_candidates.extra_revenue_best_only_sum

(function () {
  var DATE_FIELD = "price_drop_funnel.date_date";
  var GDS_FIELD = "price_drop_funnel.gds";
  var ANY_TAG_FIELD = "price_drop_funnel.attempts_with_price_drop_count";
  var ADMISSIBLE_FIELD = "price_drop_candidates.admissible_candidates_count";
  var WINS_FIELD = "price_drop_candidates.profitable_candidates_count";
  var EXTRA_REVENUE_FIELD = "price_drop_candidates.extra_revenue_best_only_sum";

  var REQUIRED_FIELDS = [DATE_FIELD, GDS_FIELD, ANY_TAG_FIELD, ADMISSIBLE_FIELD, WINS_FIELD, EXTRA_REVENUE_FIELD];

  var CSS = "\
    .pd-fn { font-family: -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif; font-size: 15px; color: #111827; height: 100%; overflow: auto; }\
    .pd-fn-wrap { padding: 8px 4px; }\
    table.pd-fn-table { width: 100%; border-collapse: collapse; table-layout: fixed; }\
    table.pd-fn-table col.pd-fn-col-date { width: 12%; }\
    table.pd-fn-table col.pd-fn-col-gds { width: 16%; }\
    table.pd-fn-table th { text-align: left; font-size: 12px; font-weight: 700; text-transform: uppercase; letter-spacing: .04em; color: #9ca3af; padding: 10px 12px; cursor: pointer; white-space: normal; line-height: 1.35; vertical-align: bottom; border-bottom: 1px solid #e5e7eb; position: sticky; top: 0; background: #fff; z-index: 2; }\
    table.pd-fn-table th:hover { color: #111827; }\
    table.pd-fn-table th.num, table.pd-fn-table td.num { text-align: right; }\
    table.pd-fn-table td { padding: 10px 12px; border-bottom: 1px solid #f1f3f5; font-variant-numeric: tabular-nums; white-space: nowrap; position: relative; }\
    table.pd-fn-table td.cell-key { font-weight: 600; }\
    table.pd-fn-table tbody tr:hover td { background: #f7f8fa; }\
    table.pd-fn-table tfoot td { font-weight: 700; border-top: 2px solid #e5e7eb; border-bottom: none; background: #f7f8fa; position: sticky; bottom: 0; z-index: 2; }\
    .pd-fn-bar-wrap { position: relative; }\
    .pd-fn-bar-wrap span { position: relative; z-index: 1; }\
    .pd-fn-bar { position: absolute; left: 0; top: 4px; bottom: 4px; background: #eaf0fe; border-radius: 3px; z-index: 0; }\
    .pd-fn-pct { color: #6b7280; font-weight: 400; margin-left: 4px; }\
    .pd-fn-sort-arrow { margin-left: 3px; font-size: 10px; }\
    .pd-fn-empty { padding: 24px; color: #9ca3af; text-align: center; }\
    .pd-fn-pos { color: #16a34a; }\
  ";

  function injectStyleOnce() {
    if (document.getElementById("pd-fn-style")) return;
    var style = document.createElement("style");
    style.id = "pd-fn-style";
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
    var sign = n < 0 ? "-" : "+";
    return sign + "$" + Math.abs(n).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  }

  function fmtPct(n) {
    return n.toLocaleString(undefined, { minimumFractionDigits: 1, maximumFractionDigits: 1 }) + "%";
  }

  // One row per (date, gds) straight from the query -- no client-side
  // aggregation needed, just percentage derivation.
  function buildRows(rawRows) {
    return rawRows.map(function (row) {
      var date = strVal(row[DATE_FIELD]);
      var gds = strVal(row[GDS_FIELD]);
      var anyTag = numVal(row[ANY_TAG_FIELD]);
      var admissible = numVal(row[ADMISSIBLE_FIELD]);
      var wins = numVal(row[WINS_FIELD]);
      var extraRevenue = numVal(row[EXTRA_REVENUE_FIELD]);
      return {
        date: date,
        gds: gds,
        anyTag: anyTag,
        admissible: admissible,
        wins: wins,
        extraRevenue: extraRevenue,
        admissiblePct: anyTag ? (100 * admissible) / anyTag : 0,
        winPct: admissible ? (100 * wins) / admissible : 0,
      };
    });
  }

  function computeTotals(rows) {
    var anyTag = rows.reduce(function (s, r) { return s + r.anyTag; }, 0);
    var admissible = rows.reduce(function (s, r) { return s + r.admissible; }, 0);
    var wins = rows.reduce(function (s, r) { return s + r.wins; }, 0);
    var extraRevenue = rows.reduce(function (s, r) { return s + r.extraRevenue; }, 0);
    return {
      date: "Total",
      gds: "",
      anyTag: anyTag,
      admissible: admissible,
      wins: wins,
      extraRevenue: extraRevenue,
      admissiblePct: anyTag ? (100 * admissible) / anyTag : 0,
      winPct: admissible ? (100 * wins) / admissible : 0,
    };
  }

  looker.plugins.visualizations.add({
    id: "price_drop_funnel_table",
    label: "Price Drop Funnel Table",
    options: {},

    create: function (element, config) {
      injectStyleOnce();
      element.innerHTML = '<div class="pd-fn"></div>';
      this._rows = [];
      // Matches ci_pricedrop_bot's own computePriceDropFunnel() default sort:
      // most recent date first, then most top-of-funnel volume within a date.
      this._sort = { col: "date_anyTag", dir: "desc" };
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
      var root = this._element.querySelector(".pd-fn");
      var rows = buildRows(this._rows);

      var sortCol = this._sort.col;
      var dir = this._sort.dir === "asc" ? 1 : -1;
      rows.sort(function (a, b) {
        if (sortCol === "date_anyTag") {
          // Default: date desc, then anyTag desc within the same date --
          // click-to-sort on other columns overrides this entirely.
          if (a.date !== b.date) return a.date < b.date ? 1 : -1;
          return b.anyTag - a.anyTag;
        }
        var av = sortCol === "date" ? a.date : sortCol === "gds" ? a.gds : a[sortCol];
        var bv = sortCol === "date" ? b.date : sortCol === "gds" ? b.gds : b[sortCol];
        if (typeof av === "string") return dir * av.localeCompare(bv);
        return dir * (av - bv);
      });

      var maxAnyTag = rows.reduce(function (m, r) { return Math.max(m, r.anyTag); }, 0) || 1;

      function sortArrow(col) {
        return sortCol === col ? '<span class="pd-fn-sort-arrow">' + (self._sort.dir === "desc" ? "▼" : "▲") + "</span>" : "";
      }

      var headHtml =
        '<th data-col="date">Date' + sortArrow("date") + "</th>" +
        '<th data-col="gds">Content Source' + sortArrow("gds") + "</th>" +
        '<th class="num" data-col="anyTag">Attempts w/ Price &amp; Drop' + sortArrow("anyTag") + "</th>" +
        '<th class="num" data-col="admissible">Attempts w/ Admissible' + sortArrow("admissible") + "</th>" +
        '<th class="num" data-col="wins">Profitable (vs. Best Eligible)' + sortArrow("wins") + "</th>" +
        '<th class="num" data-col="extraRevenue">Extra Revenue' + sortArrow("extraRevenue") + "</th>";

      function rowHtml(r, isTotal) {
        var barPct = isTotal ? 100 : (r.anyTag / maxAnyTag) * 100;
        var anyTagCell = isTotal
          ? '<td class="num">' + fmtInt(r.anyTag) + "</td>"
          : '<td class="num pd-fn-bar-wrap"><span class="pd-fn-bar" style="width:' + barPct.toFixed(1) + '%"></span><span>' + fmtInt(r.anyTag) + "</span></td>";
        var admissibleCell = '<td class="num">' + fmtInt(r.admissible) + '<span class="pd-fn-pct">(' + fmtPct(r.admissiblePct) + ")</span></td>";
        var winsCell = '<td class="num">' + fmtInt(r.wins) + '<span class="pd-fn-pct">(' + fmtPct(r.winPct) + ")</span></td>";
        var extraCell = '<td class="num' + (r.extraRevenue >= 0 ? " pd-fn-pos" : "") + '">' + fmtMoney(r.extraRevenue) + "</td>";
        var keyCell = isTotal
          ? '<td class="cell-key">' + r.date + "</td><td></td>"
          : "<td>" + r.date + '</td><td class="cell-key">' + r.gds + "</td>";
        return "<tr>" + keyCell + anyTagCell + admissibleCell + winsCell + extraCell + "</tr>";
      }

      var bodyHtml = rows.length
        ? rows.map(function (r) { return rowHtml(r, false); }).join("")
        : '<tr><td colspan="6" class="pd-fn-empty">No rows for this date range / filter selection</td></tr>';

      var footHtml = rows.length ? rowHtml(computeTotals(rows), true) : "";

      root.innerHTML =
        '<div class="pd-fn-wrap"><table class="pd-fn-table"><colgroup><col class="pd-fn-col-date"><col class="pd-fn-col-gds"></colgroup><thead><tr>' +
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
