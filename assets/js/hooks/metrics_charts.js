// Live training-metric charts for a run: one small uPlot line chart per
// metric, grouped by prefix ("algo/...", "env/..."), with a filter and an
// EMA smoothing control above them.
//
// Server protocol (see RunLive.Show):
//   pushEvent("load_metrics") -> {steps, series: {key: [..]}, nan: {key: {first, last, count}}}
//   handleEvent("metrics_append", {rows: [{step, values: {key: v}, nan: [key]}]})
import uPlot from "uplot"

const SMOOTHING_STORAGE_KEY = "metrics:smoothing"
const DEFAULT_SMOOTHING = 0.6
const CHART_HEIGHT = 160
const SYNC_KEY = "run-metrics"

// Validated against the app's base-100 surfaces (dataviz palette slot 1).
const SERIES_COLOR = { light: "#2a78d6", dark: "#3987e5" }

const theme = () => (document.documentElement.dataset.theme === "dark" ? "dark" : "light")

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

function chromeColors() {
  return {
    axis: cssColor("text-base-content/60"),
    // Hairline one step off the surface in either theme.
    grid: cssColor("text-base-content/10"),
    surface: cssColor("text-base-100"),
    series: SERIES_COLOR[theme()],
    seriesFaint: SERIES_COLOR[theme()] + "40",
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

const CRITICAL = "#d03b3b"

// Tells a run that diverged (NaN from some step to the end) apart from
// occasional NaNs. `diverged` runs get a shaded band and a NaN latest value.
function nanSummary(nan, steps) {
  if (nan.count >= steps.length) return { diverged: true, label: "NaN at every step" }
  const stepsSinceFirst = steps.length - steps.findIndex((s) => s >= nan.first)
  if (nan.last === steps[steps.length - 1] && nan.count >= stepsSinceFirst) {
    return { diverged: true, label: `NaN from step ${formatStep(nan.first)}` }
  }
  return { diverged: false, label: `NaN at ${compact.format(nan.count)} ${nan.count === 1 ? "step" : "steps"}` }
}

// Washes the diverged stretch of the plot in the critical hue.
function nanBandPlugin(chart) {
  return {
    hooks: {
      drawClear: (u) => {
        const band = chart.nanBand
        if (!band) return
        const x0 = u.valToPos(band.from, "x", true)
        const x1 = u.valToPos(band.to, "x", true)
        const { top, height, left, width } = u.bbox
        const start = Math.max(Math.min(x0, x1), left)
        const end = Math.min(Math.max(x0, x1), left + width)
        if (end <= start) return
        u.ctx.save()
        u.ctx.fillStyle = CRITICAL + "1a"
        u.ctx.fillRect(start, top, Math.max(end - start, 2), height)
        u.ctx.restore()
      },
    },
  }
}

function lastValue(values) {
  for (let i = values.length - 1; i >= 0; i--) if (values[i] != null) return values[i]
  return null
}

function splitKey(key) {
  const i = key.indexOf("/")
  return i === -1 ? ["other", key] : [key.slice(0, i), key.slice(i + 1)]
}

function el(tag, className, text) {
  const node = document.createElement(tag)
  if (className) node.className = className
  // Metric names come from the log file: always textContent, never innerHTML.
  if (text != null) node.textContent = text
  return node
}

// Crosshair readout for the chart under the pointer (the others only show the
// synced crosshair). Values lead, labels follow.
function tooltipPlugin(chart) {
  let tip
  let hovering = false

  const row = (value, label, color, faint) => {
    const line = el("div", "flex items-center gap-2")
    const key = el("span", "inline-block h-0.5 w-3 rounded-full")
    key.style.background = color
    if (faint) key.style.opacity = "0.4"
    line.append(key, el("span", "font-semibold tabular-nums", formatValue(value)), el("span", "text-base-content/60", label))
    return line
  }

  return {
    hooks: {
      init: (u) => {
        tip = el("div", "pointer-events-none absolute top-1 z-10 hidden rounded-field border border-base-300 bg-base-100 px-2 py-1.5 text-xs shadow-sm")
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

        const colors = chart.colors
        const raw = chart.raw[i]
        const step = u.data[0][i]
        const rows = [el("div", "mb-0.5 text-base-content/60", `step ${step}`)]
        if (raw == null && chart.nan && step >= chart.nan.first && step <= chart.nan.last) {
          rows.push(el("div", "font-semibold", "NaN / Inf"))
        } else if (chart.smoothing > 0) {
          rows.push(row(u.data[2][i], "smoothed", colors.series), row(raw, "raw", colors.series, true))
        } else {
          rows.push(row(raw, "value", colors.series))
        }
        tip.replaceChildren(...rows)
        tip.classList.remove("hidden")

        // Keep the tooltip inside the plot: flip to the left past the midpoint.
        const left = u.cursor.left
        const flip = left > u.over.clientWidth / 2
        tip.style.left = flip ? "" : `${left + 12}px`
        tip.style.right = flip ? `${u.over.clientWidth - left + 12}px` : ""
      },
    },
  }
}

export default {
  mounted() {
    this.steps = []
    this.series = {}
    this.nan = {}
    this.charts = new Map()
    this.filter = ""
    this.smoothing = this.loadSmoothing()

    this.el.replaceChildren(el("p", "py-8 text-center text-sm text-base-content/60", "Loading metrics..."))

    this.pushEvent("load_metrics", {}, (reply) => {
      this.steps = reply.steps
      this.series = reply.series
      this.nan = reply.nan
      this.render()
    })

    this.handleEvent("metrics_append", ({ rows }) => this.append(rows))

    // Charts draw on canvas, so they have to be rebuilt to pick up a theme change.
    this.themeObserver = new MutationObserver(() => this.render())
    this.themeObserver.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] })
  },

  destroyed() {
    this.themeObserver.disconnect()
    this.destroyCharts()
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

  append(rows) {
    let newKeys = false
    for (const { step, values, nan } of rows) {
      const index = this.steps.length
      this.steps.push(step)
      for (const key of Object.keys(values)) {
        if (!(key in this.series)) {
          this.series[key] = new Array(index).fill(null)
          newKeys = true
        }
      }
      for (const key of Object.keys(this.series)) this.series[key].push(values[key] ?? null)
      for (const key of nan) {
        const info = this.nan[key]
        if (info) {
          info.last = step
          info.count++
        } else {
          this.nan[key] = { first: step, last: step, count: 1 }
        }
      }
    }

    if (newKeys || this.charts.size === 0) return this.render()
    for (const chart of this.charts.values()) this.updateChart(chart)
  },

  destroyCharts() {
    for (const chart of this.charts.values()) {
      chart.resizeObserver.disconnect()
      chart.plot.destroy()
    }
    this.charts.clear()
  },

  // Rebuilds everything: the controls row and one card per metric.
  render() {
    this.destroyCharts()
    const keys = Object.keys(this.series).sort()

    if (keys.length === 0) {
      this.el.replaceChildren(
        el("p", "rounded-box border border-dashed border-base-300 py-8 text-center text-sm text-base-content/60", "No metrics logged yet."),
      )
      return
    }

    const groups = new Map()
    for (const key of keys) {
      const [group] = splitKey(key)
      if (!groups.has(group)) groups.set(group, [])
      groups.get(group).push(key)
    }

    const sections = []
    for (const [group, groupKeys] of groups) {
      const grid = el("div", "grid gap-3 sm:grid-cols-2 xl:grid-cols-3")
      const section = el("section", "space-y-2")
      section.dataset.group = group
      section.append(el("h3", "text-xs font-semibold uppercase tracking-wide text-base-content/60", group), grid)
      sections.push(section)
      for (const key of groupKeys) grid.appendChild(this.buildCard(key))
    }

    this.el.replaceChildren(this.buildControls(), ...sections)
    this.applyFilter()
  },

  buildControls() {
    const row = el("div", "mb-4 flex flex-wrap items-center gap-x-6 gap-y-2")

    const filter = el("input", "input input-sm w-56")
    filter.type = "search"
    filter.placeholder = "Filter metrics"
    filter.value = this.filter
    filter.setAttribute("aria-label", "Filter metrics")
    filter.addEventListener("input", () => {
      this.filter = filter.value
      this.applyFilter()
    })

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

    const hint = el("span", "text-xs text-base-content/50", "Drag to zoom · double-click to reset")
    row.append(filter, smoothingLabel, hint)
    return row
  },

  applyFilter() {
    const query = this.filter.trim().toLowerCase()
    for (const [key, chart] of this.charts) chart.card.hidden = query !== "" && !key.toLowerCase().includes(query)
    for (const section of this.el.querySelectorAll("section[data-group]")) {
      section.hidden = [...section.querySelectorAll("[data-metric]")].every((card) => card.hidden)
    }
  },

  buildCard(key) {
    const [, title] = splitKey(key)
    const card = el("div", "rounded-box border border-base-300 bg-base-100 p-3")
    card.dataset.metric = key

    const header = el("div", "flex items-baseline justify-between gap-2")
    const name = el("h4", "truncate text-xs font-medium text-base-content/70", title)
    name.title = key
    const latest = el("span", "text-sm font-semibold")
    header.append(name, latest)

    const badge = el("div", "mt-1 hidden")
    const plotEl = el("div", "relative mt-1")
    card.append(header, badge, plotEl)

    const chart = { key, card, latest, badge, plotEl, colors: chromeColors(), raw: this.series[key], smoothing: this.smoothing, nan: null, nanBand: null }
    chart.plot = this.createPlot(chart)
    chart.resizeObserver = new ResizeObserver(() => {
      const width = plotEl.clientWidth
      if (width > 0 && width !== chart.plot.width) chart.plot.setSize({ width, height: CHART_HEIGHT })
    })
    chart.resizeObserver.observe(plotEl)

    this.charts.set(key, chart)
    this.updateChart(chart)
    return card
  },

  createPlot(chart) {
    const { axis, grid, series, seriesFaint, surface } = chart.colors
    const axisStyle = {
      stroke: axis,
      font: "11px system-ui, sans-serif",
      grid: { stroke: grid, width: 1 },
      ticks: { show: false },
    }

    return new uPlot(
      {
        width: Math.max(chart.plotEl.clientWidth, 200),
        height: CHART_HEIGHT,
        legend: { show: false },
        cursor: {
          // Crosshair and zoom follow the pointer across every chart.
          sync: { key: SYNC_KEY, setSeries: false, scales: ["x", null] },
          y: false,
          // 8px marker with a 2px surface ring so it stays legible on the line.
          points: { size: 12, width: 2, fill: series, stroke: surface },
          drag: { x: true, y: false },
        },
        scales: { x: { time: false } },
        axes: [
          { ...axisStyle, size: 28, values: (u, splits) => splits.map(formatStep) },
          { ...axisStyle, size: 52, values: (u, splits) => splits.map(formatValue) },
        ],
        series: [
          { label: "step" },
          { label: "raw", stroke: seriesFaint, width: 1, points: { show: false } },
          { label: "value", stroke: series, width: 2, points: { show: false } },
        ],
        plugins: [nanBandPlugin(chart), tooltipPlugin(chart)],
      },
      [[], [], []],
      chart.plotEl,
    )
  },

  updateChart(chart) {
    const raw = this.series[chart.key]
    chart.raw = raw
    chart.smoothing = this.smoothing
    chart.nan = this.nan[chart.key] ?? null
    const summary = chart.nan && nanSummary(chart.nan, this.steps)
    chart.nanBand = summary?.diverged ? { from: chart.nan.first, to: this.steps[this.steps.length - 1] } : null

    const plot = chart.plot
    const lastStepShown = plot.scales.x.max
    const previousLastStep = plot.data[0].length ? plot.data[0][plot.data[0].length - 1] : null
    // Keep the user's zoom when new data arrives; otherwise follow the data.
    const zoomed = previousLastStep != null && lastStepShown != null && lastStepShown < previousLastStep

    const hidden = new Array(raw.length).fill(null)
    plot.setData([this.steps, this.smoothing > 0 ? raw : hidden, smooth(raw, this.smoothing)], !zoomed)

    // A diverged metric's current value is NaN, not its last finite value.
    chart.latest.textContent = summary?.diverged ? "NaN" : formatValue(lastValue(raw))

    if (summary) {
      // Solid critical fill with white text: clears contrast on both themes
      // and says what happened in words, not only color.
      const pill = el("span", "inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-xs font-medium text-white")
      pill.style.background = CRITICAL
      pill.append(el("span", "hero-exclamation-triangle-micro size-3.5"), summary.label)
      chart.badge.replaceChildren(pill)
      chart.badge.classList.remove("hidden")
    }
  },
}
