// Price Drop Booking Funnel Table -- custom Looker visualization.
//
// Why (2026-09-14, DS): sibling of price_drop_funnel_table.js, built on the
// same "CI Price Drop Bot - Funnel" explore, adding the booking-scoped
// columns from PR #50/#51 (Attempts w/ Price & Drop (Real Bookings),
// Admissible Candidates Count, Booking Count, Booking Extra Rev. (vs.
// Booked)) alongside the original top-of-funnel Attempts w/ Price & Drop
// count. Same query shape as the original funnel table -- price_drop_
// any_tag, price_drop_candidates, and price_drop_any_tag_bookings are all
// joined in the explore at the (date, gds) grain already, so each result
// row already IS one funnel row; this viz only derives percentages and
// renders/sorts/totals, no client-side reshaping.
//
// Percentage columns read top-to-bottom as a funnel narrowing at each
// step: Attempts w/ Price & Drop (every tagged attempt, any candidacy) ->
// Attempts w/ Price & Drop (Real Bookings) (% of that, gated on a real
// issued/non-test booking) -> Admissible Candidates (% of Attempts w/
// Price & Drop, this content source's own Admissible-tagged candidates,
// NOT booking-gated) -> Booking Count (% of Admissible Candidates, the
// subset that's both Profitable AND has a real issued/non-test booking).
// Admissible Candidates and Booking Count are two independent cuts of the
// same top-of-funnel population, not a strict sub-step of each other or
// of Attempts w/ Price & Drop (Real Bookings) -- shown side by side
// deliberately, same spirit as price_drop_candidates' own booking_*
// measures sitting alongside their opportunity-scoped counterparts rather
// than replacing them.
//
// Why (2026-09-14, DS), switched from booking_extra_rev_best_only to
// booking_extra_rev_vs_booked: the "Best Only" measure always compares a
// candidate's revenue against the theoretical best Eligible candidate's
// revenue, regardless of which candidate actually got booked or whether
// that specific one succeeded. booking_extra_rev_vs_booked compares
// against what was ACTUALLY booked on the attempt instead -- the more
// meaningful number for a tile framed around real bookings, since the two
// diverge whenever the best-on-paper Eligible candidate wasn't the one
// that ended up booked and issued (verified: PR #54).
//
// Required fields, in this exact query (flat, no pivot), from the
// "CI Price Drop Bot - Funnel" explore:
//   price_drop_funnel.date_date
//   price_drop_funnel.gds
//   price_drop_funnel.attempts_with_price_drop_count
//   price_drop_any_tag_bookings.attempts_with_price_drop_booking_count
//   price_drop_candidates.admissible_candidates_count
//   price_drop_candidates.booking_count
//   price_drop_candidates.booking_extra_rev_vs_booked

(function () {
  var DATE_FIELD = "price_drop_funnel.date_date";
  var GDS_FIELD = "price_drop_funnel.gds";
  var ANY_TAG_FIELD = "price_drop_funnel.attempts_with_price_drop_count";
  var REAL_BOOKING_ANY_TAG_FIELD = "price_drop_any_tag_bookings.attempts_with_price_drop_booking_count";
  var ADMISSIBLE_FIELD = "price_drop_candidates.admissible_candidates_count";
  var BOOKING_COUNT_FIELD = "price_drop_candidates.booking_count";
  var BOOKING_EXTRA_VS_BOOKED_FIELD = "price_drop_candidates.booking_extra_rev_vs_booked";

  var REQUIRED_FIELDS = [DATE_FIELD, GDS_FIELD, ANY_TAG_FIELD, REAL_BOOKING_ANY_TAG_FIELD, ADMISSIBLE_FIELD, BOOKING_COUNT_FIELD, BOOKING_EXTRA_VS_BOOKED_FIELD];

  var ALL_TAB = "__all__";

  var CSS = "\
    .pd-bfn { font-family: -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif; font-size: 15px; color: #111827; height: 100%; overflow: auto; }\
    .pd-bfn-tabs { display: flex; gap: 4px; border-bottom: 1px solid #e5e7eb; padding: 0 4px; flex-wrap: wrap; }\
    .pd-bfn-tab { padding: 10px 16px; cursor: pointer; font-weight: 600; font-size: 14px; color: #6b7280; border-bottom: 2px solid transparent; user-select: none; }\
    .pd-bfn-tab:hover { color: #111827; }\
    .pd-bfn-tab.active { color: #2545d9; border-bottom-color: #2545d9; }\
    .pd-bfn-wrap { padding: 8px 4px; }\
    table.pd-bfn-table { width: 100%; border-collapse: collapse; table-layout: fixed; }\
    table.pd-bfn-table col.pd-bfn-col-date { width: 11%; }\
    table.pd-bfn-table col.pd-bfn-col-gds { width: 13%; }\
    table.pd-bfn-table th { text-align: left; font-size: 12px; font-weight: 700; text-transform: uppercase; letter-spacing: .04em; color: #9ca3af; padding: 10px 12px; cursor: pointer; white-space: normal; line-height: 1.35; vertical-align: bottom; border-bottom: 1px solid #e5e7eb; position: sticky; top: 0; background: #fff; z-index: 2; }\
    table.pd-bfn-table th:hover { color: #111827; }\
    table.pd-bfn-table th.num, table.pd-bfn-table td.num { text-align: right; }\
    table.pd-bfn-table td { padding: 10px 12px; border-bottom: 1px solid #f1f3f5; font-variant-numeric: tabular-nums; white-space: nowrap; position: relative; }\
    table.pd-bfn-table td.cell-key { font-weight: 600; }\
    table.pd-bfn-table tbody tr:hover td { background: #f7f8fa; }\
    table.pd-bfn-table tfoot td { font-weight: 700; border-top: 2px solid #e5e7eb; border-bottom: none; background: #f7f8fa; position: sticky; bottom: 0; z-index: 2; }\
    .pd-bfn-bar-wrap { position: relative; }\
    .pd-bfn-bar-wrap span { position: relative; z-index: 1; }\
    .pd-bfn-bar { position: absolute; left: 0; top: 4px; bottom: 4px; background: #eaf0fe; border-radius: 3px; z-index: 0; }\
    .pd-bfn-pct { color: #6b7280; font-weight: 400; margin-left: 4px; }\
    .pd-bfn-sort-arrow { margin-left: 3px; font-size: 10px; }\
    .pd-bfn-empty { padding: 24px; color: #9ca3af; text-align: center; }\
    .pd-bfn-pos { color: #16a34a; }\
    .pd-bfn-neg { color: #dc2626; }\
  ";

  function injectStyleOnce() {
    if (document.getElementById("pd-bfn-style")) return;
    var style = document.createElement("style");
    style.id = "pd-bfn-style";
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
      var realBookingAnyTag = numVal(row[REAL_BOOKING_ANY_TAG_FIELD]);
      var admissible = numVal(row[ADMISSIBLE_FIELD]);
      var bookingCount = numVal(row[BOOKING_COUNT_FIELD]);
      var bookingExtraVsBooked = numVal(row[BOOKING_EXTRA_VS_BOOKED_FIELD]);
      return {
        date: date,
        gds: gds,
        anyTag: anyTag,
        realBookingAnyTag: realBookingAnyTag,
        admissible: admissible,
        bookingCount: bookingCount,
        bookingExtraVsBooked: bookingExtraVsBooked,
        realBookingPct: anyTag ? (100 * realBookingAnyTag) / anyTag : 0,
        admissiblePct: anyTag ? (100 * admissible) / anyTag : 0,
        bookingCountPct: admissible ? (100 * bookingCount) / admissible : 0,
      };
    });
  }

  function computeTotals(rows) {
    var anyTag = rows.reduce(function (s, r) { return s + r.anyTag; }, 0);
    var realBookingAnyTag = rows.reduce(function (s, r) { return s + r.realBookingAnyTag; }, 0);
    var admissible = rows.reduce(function (s, r) { return s + r.admissible; }, 0);
    var bookingCount = rows.reduce(function (s, r) { return s + r.bookingCount; }, 0);
    var bookingExtraVsBooked = rows.reduce(function (s, r) { return s + r.bookingExtraVsBooked; }, 0);
    return {
      date: "Total",
      gds: "",
      anyTag: anyTag,
      realBookingAnyTag: realBookingAnyTag,
      admissible: admissible,
      bookingCount: bookingCount,
      bookingExtraVsBooked: bookingExtraVsBooked,
      realBookingPct: anyTag ? (100 * realBookingAnyTag) / anyTag : 0,
      admissiblePct: anyTag ? (100 * admissible) / anyTag : 0,
      bookingCountPct: admissible ? (100 * bookingCount) / admissible : 0,
    };
  }

  // Distinct GDS values present in this result set, ordered by each one's
  // own total Attempts w/ Price & Drop across the current rows, descending
  // -- same convention as price_drop_funnel_table.js.
  function distinctGds(rows) {
    var totals = {};
    var order = [];
    rows.forEach(function (r) {
      if (!(r.gds in totals)) {
        totals[r.gds] = 0;
        order.push(r.gds);
      }
      totals[r.gds] += r.anyTag;
    });
    order.sort(function (a, b) { return totals[b] - totals[a]; });
    return order;
  }

  looker.plugins.visualizations.add({
    id: "price_drop_booking_funnel_table",
    label: "Price Drop Booking Funnel Table",
    options: {},

    create: function (element, config) {
      injectStyleOnce();
      element.innerHTML = '<div class="pd-bfn"></div>';
      this._rows = [];
      this._sort = { col: "date_anyTag", dir: "desc" };
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
      var root = this._element.querySelector(".pd-bfn");
      var allRows = buildRows(this._rows);
      var gdsList = distinctGds(allRows);

      if (self._activeTab !== ALL_TAB && gdsList.indexOf(self._activeTab) === -1) {
        self._activeTab = ALL_TAB;
      }

      var showGdsCol = self._activeTab === ALL_TAB;
      var rows = showGdsCol ? allRows : allRows.filter(function (r) { return r.gds === self._activeTab; });

      var sortCol = this._sort.col;
      var dir = this._sort.dir === "asc" ? 1 : -1;
      rows.sort(function (a, b) {
        if (sortCol === "date_anyTag") {
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
        return sortCol === col ? '<span class="pd-bfn-sort-arrow">' + (self._sort.dir === "desc" ? "▼" : "▲") + "</span>" : "";
      }

      var tabsHtml = ['<div class="pd-bfn-tab' + (self._activeTab === ALL_TAB ? " active" : "") + '" data-tab="' + ALL_TAB + '">All</div>']
        .concat(gdsList.map(function (g) {
          var cls = "pd-bfn-tab" + (g === self._activeTab ? " active" : "");
          return '<div class="' + cls + '" data-tab="' + g + '">' + g + "</div>";
        })).join("");

      var headHtml =
        '<th data-col="date">Date' + sortArrow("date") + "</th>" +
        (showGdsCol ? '<th data-col="gds">Content Source' + sortArrow("gds") + "</th>" : "") +
        '<th class="num" data-col="anyTag">Attempts w/ Price &amp; Drop' + sortArrow("anyTag") + "</th>" +
        '<th class="num" data-col="realBookingAnyTag">Attempts w/ Price &amp; Drop (Real Bookings)' + sortArrow("realBookingAnyTag") + "</th>" +
        '<th class="num" data-col="admissible">Admissible Candidates' + sortArrow("admissible") + "</th>" +
        '<th class="num" data-col="bookingCount">Booking Count' + sortArrow("bookingCount") + "</th>" +
        '<th class="num" data-col="bookingExtraVsBooked">Booking Extra Rev. (vs. Booked)' + sortArrow("bookingExtraVsBooked") + "</th>";

      var colCount = showGdsCol ? 7 : 6;

      function rowHtml(r, isTotal) {
        var barPct = isTotal ? 100 : (r.anyTag / maxAnyTag) * 100;
        var anyTagCell = isTotal
          ? '<td class="num">' + fmtInt(r.anyTag) + "</td>"
          : '<td class="num pd-bfn-bar-wrap"><span class="pd-bfn-bar" style="width:' + barPct.toFixed(1) + '%"></span><span>' + fmtInt(r.anyTag) + "</span></td>";
        var realBookingCell = '<td class="num">' + fmtInt(r.realBookingAnyTag) + '<span class="pd-bfn-pct">(' + fmtPct(r.realBookingPct) + ")</span></td>";
        var admissibleCell = '<td class="num">' + fmtInt(r.admissible) + '<span class="pd-bfn-pct">(' + fmtPct(r.admissiblePct) + ")</span></td>";
        var bookingCountCell = '<td class="num">' + fmtInt(r.bookingCount) + '<span class="pd-bfn-pct">(' + fmtPct(r.bookingCountPct) + ")</span></td>";
        var extraCell = '<td class="num' + (r.bookingExtraVsBooked >= 0 ? " pd-bfn-pos" : " pd-bfn-neg") + '">' + fmtMoney(r.bookingExtraVsBooked) + "</td>";
        var keyCell;
        if (showGdsCol) {
          keyCell = isTotal
            ? '<td class="cell-key">' + r.date + "</td><td></td>"
            : "<td>" + r.date + '</td><td class="cell-key">' + r.gds + "</td>";
        } else {
          keyCell = '<td class="cell-key">' + r.date + "</td>";
        }
        return "<tr>" + keyCell + anyTagCell + realBookingCell + admissibleCell + bookingCountCell + extraCell + "</tr>";
      }

      var bodyHtml = rows.length
        ? rows.map(function (r) { return rowHtml(r, false); }).join("")
        : '<tr><td colspan="' + colCount + '" class="pd-bfn-empty">No rows for this date range / filter selection</td></tr>';

      var footHtml = rows.length ? rowHtml(computeTotals(rows), true) : "";

      var colgroupHtml = showGdsCol
        ? '<col class="pd-bfn-col-date"><col class="pd-bfn-col-gds">'
        : '<col class="pd-bfn-col-date">';

      root.innerHTML =
        '<div class="pd-bfn-tabs">' + tabsHtml + "</div>" +
        '<div class="pd-bfn-wrap"><table class="pd-bfn-table"><colgroup>' + colgroupHtml + '</colgroup><thead><tr>' +
        headHtml + "</tr></thead><tbody>" + bodyHtml + "</tbody><tfoot>" + footHtml + "</tfoot></table></div>";

      root.querySelectorAll(".pd-bfn-tab").forEach(function (el) {
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
