// Training-metric charts for one run or several runs side by side: one small
// uPlot line chart per metric, grouped by prefix ("algo/...", "env/..."),
// with a filter, EMA smoothing, a chart/table toggle and per-chart expand.
//
// A metric logged as a distribution (llm_rl's `rewards.mean`, `rewards.min`,
// `rewards.max`, `rewards.std`) gets one chart: the mean as the line, with a
// min–max band behind it on a run's page.
//
// data-mode="single" (a run's page): the run's raw values drawn faint behind
//   the smoothed line, its latest value in each card, and a shaded band where
//   it diverged to NaN.
// data-mode="compare": one smoothed line per run, colored by the run's slot
//   (--series-N), with every run's value in the tooltip.
//
// Server protocol (RunLive.Show, CompareLive):
//   pushEvent("load_metrics") ->
//     {runs: [{name, slot, steps, series: {key: [..]}, nan: {key: {first, last, count}}}]}
//   handleEvent("metrics_append", {run, rows: [{step, values: {key: v}, nan: [key]}]})
//   handleEvent("metrics_reload") -> load again (the compared runs changed)
import uPlot from "uplot"

const SMOOTHING_STORAGE_KEY = "metrics:smoothing"
const DEFAULT_SMOOTHING = 0.6
const CHART_HEIGHT = 160
const EXPANDED_HEIGHT = 420
const SYNC_KEY = "run-metrics"
const CRITICAL = "#d03b3b"

// Resolves a Tailwind color class to a computed color string for the canvas.
function cssColor(className) {
  const probe = document.createElement("span")
  probe.className = className
  probe.style.display = "none"
  document.body.appendChild(probe)
  const color = getComputedStyle(probe).color
  probe.remove()
  return color
}

const seriesColor = (slot) =>
  getComputedStyle(document.documentElement).getPropertyValue(`--series-${slot + 1}`).trim()

function chromeColors() {
  return {
    axis: cssColor("text-base-content/60"),
    // Hairline one step off the surface in either theme.
    grid: cssColor("text-base-content/10"),
    surface: cssColor("text-base-100"),
  }
}

const compact = new Intl.NumberFormat(undefined, { notation: "compact", maximumSignificantDigits: 3 })
const precise = new Intl.NumberFormat(undefined, { maximumSignificantDigits: 4 })

function formatValue(v) {
  if (v == null || !Number.isFinite(v)) return "—"
  const abs = Math.abs(v)
  if (abs !== 0 && abs < 1e-3) return v.toExponential(2)
  if (abs >= 1e5) return compact.format(v)
  return precise.format(v)
}

const formatStep = (s) => (Math.abs(s) >= 1e4 ? compact.format(s) : String(s))

// TensorBoard-style debiased exponential moving average. Gaps stay gaps.
function smooth(values, weight) {
  if (weight <= 0) return values
  const out = new Array(values.length)
  let last = 0
  let count = 0
  for (let i = 0; i < values.length; i++) {
    const v = values[i]
    if (v == null || !Number.isFinite(v)) {
      out[i] = null
      continue
    }
    last = last * weight + (1 - weight) * v
    count++
    out[i] = last / (1 - Math.pow(weight, count))
  }
  return out
}

function lastValue(values) {
  for (let i = values.length - 1; i >= 0; i--) if (values[i] != null) return values[i]
  return null
}

function extent(values) {
  let min = null
  let max = null
  for (const v of values) {
    if (v == null) continue
    if (min == null || v < min) min = v
    if (max == null || v > max) max = v
  }
  return [min, max]
}

function splitKey(key) {
  const i = key.indexOf("/")
  return i === -1 ? ["other", key] : [key.slice(0, i), key.slice(i + 1)]
}

const byId = (a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0)

// What to chart: one spec per chart, `{id, group, title, value, min, max,
// std, keys}`. `value` is the series drawn as the line; a distribution's
// `min`/`max`/`std` are its sibling keys (or null). `keys` lists every
// metric the chart covers, for the filter.
function chartSpecs(keys) {
  const present = new Set(keys)
  const covered = new Set()
  const specs = []

  for (const key of keys) {
    if (!key.endsWith(".mean")) continue
    const id = key.slice(0, -".mean".length)
    const stat = (name) => (present.has(`${id}.${name}`) ? `${id}.${name}` : null)
    const [min, max, std] = [stat("min"), stat("max"), stat("std")]
    if (!min && !max && !std) continue
    for (const k of [key, min, max, std]) if (k) covered.add(k)
    specs.push({ id, value: key, min, max, std })
  }
  for (const key of keys) {
    if (!covered.has(key)) specs.push({ id: key, value: key, min: null, max: null, std: null })
  }

  return specs.sort(byId).map((spec) => {
    const [group, title] = splitKey(spec.id)
    return { ...spec, group, title, keys: [spec.value, spec.min, spec.max, spec.std].filter(Boolean) }
  })
}

// A min–max band needs both edges.
const hasBand = (spec) => spec.min != null && spec.max != null

function el(tag, className, text) {
  const node = document.createElement(tag)
  if (className) node.className = className
  // Metric and run names come from files on disk: always textContent.
  if (text != null) node.textContent = text
  return node
}

function icon(name, className = "size-3.5") {
  return el("span", `${name} ${className}`)
}

// A short stroke in the series color: identity for tooltip rows and table
// headers (text itself stays in text colors).
function lineKey(color, faint = false) {
  const key = el("span", "inline-block h-0.5 w-3 shrink-0 rounded-full")
  key.style.background = color
  if (faint) key.style.opacity = "0.4"
  return key
}

// Tells a run that diverged (NaN from some step to the end) apart from
// occasional NaNs.
function nanSummary(nan, steps) {
  if (nan.count >= steps.length) return { diverged: true, label: "NaN at every step" }
  const stepsSinceFirst = steps.length - steps.findIndex((s) => s >= nan.first)
  if (nan.last === steps[steps.length - 1] && nan.count >= stepsSinceFirst) {
    return { diverged: true, label: `NaN from step ${formatStep(nan.first)}` }
  }
  return { diverged: false, label: `NaN at ${compact.format(nan.count)} ${nan.count === 1 ? "step" : "steps"}` }
}

// Puts several runs' values for one metric on a shared x axis (the union of
// their steps). jaxrl logs steps 0..n-1, which takes the fast path.
function align(runs, key) {
  const withKey = runs.filter((run) => run.series[key])
  const contiguous = withKey.every((run) => run.steps.length === 0 || run.steps[run.steps.length - 1] === run.steps.length - 1)

  if (contiguous) {
    const length = Math.max(0, ...withKey.map((run) => run.steps.length))
    const x = Array.from({ length }, (_, i) => i)
    const ys = runs.map((run) => {
      const values = run.series[key] ?? []
      return values.length === length ? values : values.concat(new Array(length - values.length).fill(null))
    })
    return { x, ys }
  }

  const x = [...new Set(withKey.flatMap((run) => run.steps))].sort((a, b) => a - b)
  const position = new Map(x.map((step, i) => [step, i]))
  const ys = runs.map((run) => {
    const out = new Array(x.length).fill(null)
    const values = run.series[key]
    if (values) run.steps.forEach((step, i) => (out[position.get(step)] = values[i]))
    return out
  })
  return { x, ys }
}

// Washes the diverged stretch of a single run's plot in the critical hue.
function nanBandPlugin(chart) {
  return {
    hooks: {
      drawClear: (u) => {
        const band = chart.nanBand
        if (!band) return
        const { top, height, left, width } = u.bbox
        const start = Math.max(u.valToPos(band.from, "x", true), left)
        const end = Math.min(u.valToPos(band.to, "x", true), left + width)
        if (end < start) return
        u.ctx.save()
        u.ctx.fillStyle = CRITICAL + "1a"
        u.ctx.fillRect(start, top, Math.max(end - start, 2), height)
        u.ctx.restore()
      },
    },
  }
}

// Readout for the chart under the pointer (the others only show the synced
// crosshair). Values lead, labels follow.
function tooltipPlugin(chart) {
  let tip
  let hovering = false

  return {
    hooks: {
      init: (u) => {
        tip = el("div", "pointer-events-none absolute top-1 z-10 hidden max-w-72 rounded-field border border-base-300 bg-base-100 px-2 py-1.5 text-xs shadow-sm")
        u.over.appendChild(tip)
        u.over.addEventListener("mouseenter", () => (hovering = true))
        u.over.addEventListener("mouseleave", () => {
          hovering = false
          tip.classList.add("hidden")
        })
      },
      setCursor: (u) => {
        const i = u.cursor.idx
        if (!hovering || i == null) return tip.classList.add("hidden")

        tip.replaceChildren(el("div", "mb-0.5 text-base-content/60", `step ${u.data[0][i]}`), ...chart.tooltipRows(i))
        tip.classList.remove("hidden")

        // Stay inside the plot: flip to the left past the midpoint.
        const left = u.cursor.left
        const flip = left > u.over.clientWidth / 2
        tip.style.left = flip ? "" : `${left + 12}px`
        tip.style.right = flip ? `${u.over.clientWidth - left + 12}px` : ""
      },
    },
  }
}

function valueRow(value, label, color, faint = false) {
  const row = el("div", "flex items-center gap-2")
  row.append(lineKey(color, faint), el("span", "font-semibold tabular-nums", value), el("span", "truncate text-base-content/60", label))
  return row
}

export default {
  mounted() {
    this.compare = this.el.dataset.mode === "compare"
    this.runs = []
    // Every metric key when the charts were last built; a new one rebuilds them.
    this.knownKeys = new Set()
    this.charts = new Map()
    this.expanded = new Set()
    this.filter = ""
    this.view = "charts"
    this.smoothing = this.loadSmoothing()

    this.el.replaceChildren(el("p", "py-8 text-center text-sm text-base-content/60", "Loading metrics..."))
    this.load()

    this.handleEvent("metrics_append", ({ run, rows }) => this.append(run, rows))
    this.handleEvent("metrics_reload", () => this.load())

    // Canvas colors have to be re-resolved when the theme changes.
    this.themeObserver = new MutationObserver(() => this.render())
    this.themeObserver.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] })
  },

  destroyed() {
    this.themeObserver.disconnect()
    this.destroyCharts()
  },

  load() {
    this.pushEvent("load_metrics", {}, ({ runs }) => {
      this.runs = runs
      this.render()
    })
  },

  loadSmoothing() {
    try {
      const stored = parseFloat(localStorage.getItem(SMOOTHING_STORAGE_KEY))
      return Number.isFinite(stored) ? stored : DEFAULT_SMOOTHING
    } catch {
      return DEFAULT_SMOOTHING
    }
  },

  saveSmoothing() {
    try {
      localStorage.setItem(SMOOTHING_STORAGE_KEY, String(this.smoothing))
    } catch {}
  },

  metricKeys() {
    return [...new Set(this.runs.flatMap((run) => Object.keys(run.series)))].sort()
  },

  append(runName, rows) {
    const run = this.runs.find((r) => r.name === runName)
    if (!run) return

    let newKeys = false
    for (const { step, values, nan } of rows) {
      const index = run.steps.length
      run.steps.push(step)
      for (const key of Object.keys(values)) {
        if (!(key in run.series)) {
          run.series[key] = new Array(index).fill(null)
          if (!this.knownKeys.has(key)) newKeys = true
        }
      }
      for (const key of Object.keys(run.series)) run.series[key].push(values[key] ?? null)
      for (const key of nan) {
        const info = run.nan[key]
        if (info) {
          info.last = step
          info.count++
        } else {
          run.nan[key] = { first: step, last: step, count: 1 }
        }
      }
    }

    if (newKeys || this.view === "table" || this.charts.size === 0) return this.render()
    for (const chart of this.charts.values()) this.updateChart(chart)
  },

  destroyCharts() {
    for (const chart of this.charts.values()) {
      chart.resizeObserver.disconnect()
      chart.plot.destroy()
    }
    this.charts.clear()
  },

  // Rebuilds everything: the controls row, then the charts or the table.
  render() {
    this.destroyCharts()
    const keys = this.metricKeys()
    this.knownKeys = new Set(keys)

    if (keys.length === 0) {
      const message = this.compare && this.runs.length === 0 ? "Add runs to compare them." : "No metrics logged yet."
      this.el.replaceChildren(el("p", "rounded-box border border-dashed border-base-300 py-8 text-center text-sm text-base-content/60", message))
      return
    }

    const body = this.view === "table" ? this.buildTable(keys) : this.buildChartSections(chartSpecs(keys))
    this.el.replaceChildren(this.buildControls(), ...body)
    this.applyFilter()
  },

  buildControls() {
    const row = el("div", "mb-4 flex flex-wrap items-center gap-x-4 gap-y-3 sm:gap-x-6")

    const filter = el("input", "input input-sm w-full sm:w-56")
    filter.type = "search"
    filter.placeholder = "Filter metrics"
    filter.value = this.filter
    filter.setAttribute("aria-label", "Filter metrics")
    filter.addEventListener("input", () => {
      this.filter = filter.value
      this.applyFilter()
    })

    const views = el("div", "join")
    for (const [view, label] of [["charts", "Charts"], ["table", "Table"]]) {
      const button = el("button", `btn btn-xs join-item ${this.view === view ? "btn-active" : ""}`, label)
      button.type = "button"
      button.setAttribute("aria-pressed", String(this.view === view))
      button.addEventListener("click", () => {
        if (this.view === view) return
        this.view = view
        this.render()
      })
      views.append(button)
    }

    const smoothingLabel = el("label", "flex items-center gap-2 text-xs text-base-content/70")
    const slider = el("input", "range range-xs w-32")
    slider.type = "range"
    slider.min = "0"
    slider.max = "0.99"
    slider.step = "0.01"
    slider.value = String(this.smoothing)
    const smoothingValue = el("span", "w-8 tabular-nums", this.smoothing.toFixed(2))
    slider.addEventListener("input", () => {
      this.smoothing = parseFloat(slider.value)
      smoothingValue.textContent = this.smoothing.toFixed(2)
      this.saveSmoothing()
      for (const chart of this.charts.values()) this.updateChart(chart)
    })
    smoothingLabel.append("Smoothing", slider, smoothingValue)

    row.append(filter, views)
    if (this.view === "charts") {
      row.append(smoothingLabel, el("span", "hidden text-xs text-base-content/50 [@media(hover:hover)]:inline", "Drag to zoom · double-click to reset"))
    }
    return row
  },

  applyFilter() {
    const query = this.filter.trim().toLowerCase()
    const hide = (key) => query !== "" && !key.toLowerCase().includes(query)

    for (const node of this.el.querySelectorAll("[data-metric]")) node.hidden = hide(node.dataset.metric)
    for (const section of this.el.querySelectorAll("section[data-group]")) {
      section.hidden = [...section.querySelectorAll("[data-metric]")].every((node) => node.hidden)
    }
  },

  buildChartSections(specs) {
    const groups = new Map()
    for (const spec of specs) {
      if (!groups.has(spec.group)) groups.set(spec.group, [])
      groups.get(spec.group).push(spec)
    }
    // Metrics without "group/" prefixes (llm_rl's) are all "other": a
    // heading saying so would add nothing.
    const headings = !(groups.size === 1 && groups.has("other"))

    return [...groups].map(([group, groupSpecs]) => {
      const grid = el("div", "grid gap-3 sm:grid-cols-2 xl:grid-cols-3")
      const section = el("section", "mb-5 space-y-2")
      section.dataset.group = group
      if (headings) section.append(el("h3", "text-xs font-semibold uppercase tracking-wide text-base-content/60", group))
      section.append(grid)
      for (const spec of groupSpecs) grid.appendChild(this.buildCard(spec))
      return section
    })
  },

  buildCard(spec) {
    const card = el("div", "rounded-box border border-base-300 bg-base-100 p-3")
    // Everything the filter can match: the chart's name and each metric in it.
    card.dataset.metric = [spec.id, ...spec.keys].join(" ")

    const header = el("div", "flex items-center justify-between gap-2")
    const name = el("h4", "flex min-w-0 items-baseline gap-1.5 text-xs font-medium text-base-content/70")
    name.append(el("span", "truncate", spec.title))
    if (spec.value !== spec.id) {
      const shows = !this.compare && hasBand(spec) ? "mean · min–max" : "mean"
      name.append(el("span", "shrink-0 font-normal text-base-content/45", shows))
    }
    name.title = spec.keys.join(", ")
    const right = el("div", "flex shrink-0 items-center gap-1")
    const latest = el("span", "text-sm font-semibold")
    const expand = el("button", "btn btn-ghost btn-xs btn-square text-base-content/60")
    expand.type = "button"
    right.append(latest, expand)
    header.append(name, right)

    const badges = el("div", "mt-1 flex flex-wrap gap-1 empty:hidden")
    const plotEl = el("div", "relative mt-1")
    card.append(header, badges, plotEl)

    const chart = { key: spec.id, spec, card, latest, badges, plotEl, expand, colors: chromeColors(), nanBand: null }
    chart.band = !this.compare && hasBand(spec)
    chart.plot = this.createPlot(chart)
    chart.resizeObserver = new ResizeObserver(() => this.resize(chart))
    chart.resizeObserver.observe(plotEl)
    expand.addEventListener("click", () => this.toggleExpanded(chart))

    this.charts.set(spec.id, chart)
    this.applyExpanded(chart)
    this.updateChart(chart)
    return card
  },

  toggleExpanded(chart) {
    if (this.expanded.has(chart.key)) this.expanded.delete(chart.key)
    else this.expanded.add(chart.key)
    this.applyExpanded(chart)
    this.resize(chart)
    chart.card.scrollIntoView({ block: "nearest", behavior: "smooth" })
  },

  applyExpanded(chart) {
    const expanded = this.expanded.has(chart.key)
    chart.card.classList.toggle("col-span-full", expanded)
    chart.expand.setAttribute("aria-pressed", String(expanded))
    chart.expand.setAttribute("aria-label", expanded ? "Collapse chart" : "Expand chart")
    chart.expand.title = expanded ? "Collapse" : "Expand"
    chart.expand.replaceChildren(icon(expanded ? "hero-arrows-pointing-in-micro" : "hero-arrows-pointing-out-micro"))
  },

  resize(chart) {
    const width = chart.plotEl.clientWidth
    const height = this.expanded.has(chart.key) ? EXPANDED_HEIGHT : CHART_HEIGHT
    if (width > 0 && (width !== chart.plot.width || height !== chart.plot.height)) {
      chart.plot.setSize({ width, height })
    }
  },

  // uPlot series layout. Single: [x, raw (faint), smoothed], led by the band's
  // [min, max] edges (drawn first, so the band sits behind the lines) when the
  // chart has one. Compare: [x, one smoothed line per run].
  seriesSpec(chart) {
    if (!this.compare) {
      const color = seriesColor(0)
      const edge = (label) => ({ label, stroke: "transparent", width: 0, points: { show: false } })
      return [
        ...(chart.band ? [edge("min"), edge("max")] : []),
        { label: "raw", stroke: color + "40", width: 1, points: { show: false } },
        { label: "value", stroke: color, width: 2, points: { show: false } },
      ]
    }
    return this.runs.map((run) => ({ label: run.name, stroke: seriesColor(run.slot), width: 2, points: { show: false } }))
  },

  createPlot(chart) {
    const { axis, grid, surface } = chart.colors
    const axisStyle = {
      stroke: axis,
      font: "11px system-ui, sans-serif",
      grid: { stroke: grid, width: 1 },
      ticks: { show: false },
    }

    const series = [{ label: "step" }, ...this.seriesSpec(chart)]

    return new uPlot(
      {
        width: Math.max(chart.plotEl.clientWidth, 200),
        height: this.expanded.has(chart.key) ? EXPANDED_HEIGHT : CHART_HEIGHT,
        legend: { show: false },
        cursor: {
          // Crosshair and zoom follow the pointer across every chart.
          sync: { key: SYNC_KEY, setSeries: false, scales: ["x", null] },
          y: false,
          // 8px markers with a 2px surface ring so they stay legible on lines.
          points: { size: 12, width: 2, stroke: surface },
          drag: { x: true, y: false },
        },
        scales: { x: { time: false } },
        axes: [
          { ...axisStyle, size: 28, values: (u, splits) => splits.map(formatStep) },
          { ...axisStyle, size: 52, values: (u, splits) => splits.map(formatValue) },
        ],
        series,
        // Fills between max (series 2) and min (series 1).
        bands: chart.band ? [{ series: [2, 1], fill: seriesColor(0) + "24" }] : [],
        plugins: [nanBandPlugin(chart), tooltipPlugin(chart)],
      },
      series.map(() => []),
      chart.plotEl,
    )
  },

  updateChart(chart) {
    const { spec } = chart
    const { x, ys } = align(this.runs, spec.value)
    const plot = chart.plot

    const previousLastStep = plot.data?.[0]?.length ? plot.data[0][plot.data[0].length - 1] : null
    // Keep the user's zoom when new data arrives; otherwise follow the data.
    const zoomed = previousLastStep != null && plot.scales.x.max != null && plot.scales.x.max < previousLastStep

    const summaries = this.runs.map((run) => (run.nan[spec.value] ? nanSummary(run.nan[spec.value], run.steps) : null))

    if (this.compare) {
      const smoothed = ys.map((values) => smooth(values, this.smoothing))
      plot.setData([x, ...smoothed], !zoomed)

      chart.tooltipRows = (i) =>
        this.runs.map((run, r) => valueRow(formatValue(smoothed[r][i]), run.name, seriesColor(run.slot)))
      chart.latest.textContent = ""
    } else {
      const raw = ys[0] ?? []
      const summary = summaries[0]
      const nan = this.runs[0]?.nan[spec.value]
      chart.nanBand = summary?.diverged ? { from: nan.first, to: x[x.length - 1] } : null

      const smoothed = smooth(raw, this.smoothing)
      const stat = (key) => (key ? (align(this.runs, key).ys[0] ?? []) : [])
      const [min, max, std] = [stat(spec.min), stat(spec.max), stat(spec.std)]
      // The band is smoothed like the line, or it'd be noise around a calm line.
      const edges = chart.band ? [smooth(min, this.smoothing), smooth(max, this.smoothing)] : []
      plot.setData([x, ...edges, this.smoothing > 0 ? raw : new Array(raw.length).fill(null), smoothed], !zoomed)

      const color = seriesColor(0)
      // A distribution's raw stats at the step, after the mean.
      const statRows = (i) =>
        [["min", min], ["max", max], ["std", std]]
          .filter(([, values]) => values.length > 0)
          .map(([label, values]) => valueRow(formatValue(values[i]), label, color, true))

      chart.tooltipRows = (i) => {
        if (raw[i] == null && nan && x[i] >= nan.first && x[i] <= nan.last) return [el("div", "font-semibold", "NaN / Inf")]
        const mean = spec.value !== spec.id ? "mean" : null
        if (this.smoothing > 0) {
          return [
            valueRow(formatValue(smoothed[i]), mean ? "mean, smoothed" : "smoothed", color),
            valueRow(formatValue(raw[i]), mean ? "mean" : "raw", color, true),
            ...statRows(i),
          ]
        }
        return [valueRow(formatValue(raw[i]), mean ?? "value", color), ...statRows(i)]
      }
      // A diverged metric's current value is NaN, not its last finite value.
      chart.latest.textContent = summary?.diverged ? "NaN" : formatValue(lastValue(raw))
    }

    // NaN badges: solid critical fill with white text clears contrast on both
    // themes and says what happened in words, not only color.
    chart.badges.replaceChildren(
      ...summaries.flatMap((summary, r) => {
        if (!summary) return []
        const pill = el("span", "inline-flex max-w-full items-center gap-1 rounded-full px-2 py-0.5 text-xs font-medium text-white")
        pill.style.background = CRITICAL
        const label = this.compare ? `${this.runs[r].name}: ${summary.label}` : summary.label
        pill.append(icon("hero-exclamation-triangle-micro", "size-3.5 shrink-0"), el("span", "truncate", label))
        pill.title = label
        return [pill]
      }),
    )
  },

  // The table view: every value the charts show the end of, readable without
  // hovering. Single run: last/min/max per metric. Compare: last value per run.
  buildTable(keys) {
    const table = el("table", "table table-sm")
    const head = el("tr")
    head.append(el("th", "", "Metric"))

    if (this.compare) {
      for (const run of this.runs) {
        const th = el("th", "text-right")
        const label = el("span", "inline-flex items-center justify-end gap-1.5")
        label.append(lineKey(seriesColor(run.slot)), el("span", "font-mono font-normal", run.name))
        th.append(label)
        head.append(th)
      }
    } else {
      for (const label of ["Last", "Min", "Max"]) head.append(el("th", "text-right", label))
    }

    const body = el("tbody")
    for (const key of keys) {
      const row = el("tr")
      row.dataset.metric = key
      row.append(el("td", "font-mono text-xs", key))

      const cells = this.compare
        ? this.runs.map((run) => this.lastCell(run, key))
        : (() => {
            const values = this.runs[0].series[key] ?? []
            const [min, max] = extent(values)
            return [this.lastCell(this.runs[0], key), formatValue(min), formatValue(max)]
          })()

      for (const cell of cells) row.append(el("td", "text-right tabular-nums", cell))
      body.append(row)
    }

    const thead = el("thead")
    thead.append(head)
    table.append(thead, body)
    const wrapper = el("div", "overflow-x-auto rounded-box border border-base-300 bg-base-100")
    wrapper.append(table)
    return [wrapper]
  },

  lastCell(run, key) {
    const values = run.series[key]
    if (!values) return "—"
    const nan = run.nan[key]
    if (nan && nanSummary(nan, run.steps).diverged) return "NaN"
    return formatValue(lastValue(values))
  },
}
