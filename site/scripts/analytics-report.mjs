import { spawn } from 'node:child_process'
import { writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'

const validDays = new Set([7, 30])
const validFormats = ['table', 'csv', 'html']

export function parseArgs(argv) {
  let days = 7
  let format = 'table'
  let open = false
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === '--days') days = Number(argv[++index])
    else if (argv[index] === '--format') format = argv[++index]
    else if (argv[index] === '--open') open = true
    else throw new Error(`Unknown option: ${argv[index]}`)
  }
  if (!validDays.has(days)) throw new Error('--days must be 7 or 30')
  if (!validFormats.includes(format)) throw new Error('--format must be table, csv or html')
  if (open && format !== 'html') throw new Error('--open only applies to --format html')
  return { days, format, open }
}

const dayKey = (date) => date.toISOString().slice(0, 10)

export function dayRange(days, today = new Date()) {
  const end = Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), today.getUTCDate())
  return Array.from({ length: days }, (_, offset) => dayKey(new Date(end - (days - 1 - offset) * 86_400_000)))
}

const dailyMetrics = { pageview: 'pageviews', download_attempt: 'downloads', github_attempt: 'github' }

// Every day in the range appears, zero-filled, so a chart never hides a quiet day by skipping it
function dailySeries(rows, days, today) {
  const byDay = new Map(dayRange(days, today).map((day) => [day, { day, pageviews: 0, downloads: 0, github: 0 }]))
  for (const row of rows ?? []) {
    const point = byDay.get(row.day)
    const field = dailyMetrics[row.metric]
    if (point && field) point[field] += Number(row.value)
  }
  return [...byDay.values()]
}

function sum(rows, metric, placement) {
  return rows
    .filter((row) => row.metric === metric && (placement === undefined || row.placement === placement))
    .reduce((total, row) => total + Number(row.value), 0)
}

function rollupSum(groups, metric, dimensionName = 'all', dimensionValue = 'all') {
  return groups.flat()
    .filter((row) => row.metric === metric && row.dimension_name === dimensionName && row.dimension_value === dimensionValue)
    .reduce((total, row) => total + Number(row.value), 0)
}

function placementMap(groups, metric) {
  const result = {}
  for (const row of groups.flat()) {
    if (row.metric === metric && row.dimension_name === 'placement') {
      result[row.dimension_value] = (result[row.dimension_value] ?? 0) + Number(row.value)
    }
  }
  return result
}

function dimensionMap(groups, dimensionName) {
  const result = {}
  for (const row of groups.flat()) {
    if (row.metric === 'unique_windows' && row.dimension_name === dimensionName) {
      result[row.dimension_value] = (result[row.dimension_value] ?? 0) + Number(row.value)
    }
  }
  return result
}

function percentage(numerator, denominator) {
  return denominator === 0 ? 0 : Math.round((numerator / denominator) * 10_000) / 100
}

export function buildReport(data, days, today = new Date()) {
  const groups = [data.rollups, data.liveCompleted]
  const completedWindows = rollupSum(groups, 'unique_windows')
  const uniqueGithubWindows = rollupSum(groups, 'unique_github')
  const uniqueDownloadWindows = rollupSum(groups, 'unique_download')
  return {
    days,
    pageviews: sum(data.counters, 'pageview'),
    completedWindows,
    provisionalWindows: Number(data.provisionalWindows),
    githubAttempts: sum(data.counters, 'github_attempt'),
    uniqueGithubWindows,
    githubConversion: percentage(uniqueGithubWindows, completedWindows),
    downloadAttempts: sum(data.counters, 'download_attempt'),
    uniqueDownloadWindows,
    downloadConversion: percentage(uniqueDownloadWindows, completedWindows),
    optOuts: sum(data.counters, 'opt_out'),
    droppedWrites: sum(data.counters, 'dropped_write'),
    cleanupRuns: sum(data.counters, 'cohorts_finalized'),
    placements: {
      github: placementMap(groups, 'unique_github'),
      download: placementMap(groups, 'unique_download'),
    },
    dimensions: {
      country: dimensionMap(groups, 'country'),
      device: dimensionMap(groups, 'device'),
      referrer: dimensionMap(groups, 'referrer'),
    },
    daily: dailySeries(data.daily, days, today),
  }
}

const reportRows = (report) => [
  ['Period (days)', report.days],
  ['Pageviews', report.pageviews],
  ['Completed 24-hour browser windows', report.completedWindows],
  ['Provisional active browser windows', report.provisionalWindows],
  ['GitHub attempts', report.githubAttempts],
  ['Unique GitHub browser windows', report.uniqueGithubWindows],
  ['GitHub conversion (%)', report.githubConversion],
  ['Download attempts', report.downloadAttempts],
  ['Unique Download browser windows', report.uniqueDownloadWindows],
  ['Download conversion (%)', report.downloadConversion],
  ['Opt-outs', report.optOuts],
  ['Dropped writes recorded', report.droppedWrites],
  ['Cohorts finalized', report.cleanupRuns],
]

export function formatCsv(report) {
  const quote = (value) => `"${String(value).replaceAll('"', '""')}"`
  return ['metric,value', ...reportRows(report).map(([metric, value]) => `${quote(metric)},${value}`)].join('\n')
}

export function formatTable(report) {
  const rows = reportRows(report)
  const placements = ['github', 'download'].flatMap((action) =>
    Object.entries(report.placements[action]).map(([placement, value]) => [`${action} unique from ${placement}`, value]),
  )
  const dimensions = ['country', 'device', 'referrer'].flatMap((dimension) =>
    Object.entries(report.dimensions[dimension]).map(([valueName, value]) => [`${dimension}: ${valueName}`, value]),
  )
  const allRows = [...rows, ...placements, ...dimensions]
  const width = Math.max(...allRows.map(([label]) => label.length))
  return allRows.map(([label, value]) => `${label.padEnd(width)}  ${value}`).join('\n')
}

const escapeHtml = (value) =>
  String(value).replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;')

const chartWidth = 720
const chartHeight = 120

function barChart(points, field, colour) {
  const max = Math.max(1, ...points.map((point) => point[field]))
  const slot = chartWidth / points.length
  const barWidth = Math.max(2, slot - 3)
  const bars = points.map((point, index) => {
    const height = Math.round((point[field] / max) * (chartHeight - 4))
    const x = (index * slot).toFixed(1)
    return `<rect x="${x}" y="${chartHeight - height}" width="${barWidth.toFixed(1)}" height="${height}" fill="${colour}"><title>${escapeHtml(point.day)}: ${point[field]}</title></rect>`
  })
  const first = points[0]?.day ?? ''
  const last = points.at(-1)?.day ?? ''
  return `<svg viewBox="0 0 ${chartWidth} ${chartHeight}" role="img" aria-label="${field} per day">${bars.join('')}</svg>
<div class="axis"><span>${escapeHtml(first)}</span><span>peak ${max}</span><span>${escapeHtml(last)}</span></div>`
}

function breakdownTable(title, entries, colour) {
  const rows = Object.entries(entries).sort((a, b) => b[1] - a[1])
  if (rows.length === 0) return `<section><h2>${escapeHtml(title)}</h2><p class="empty">No completed windows yet.</p></section>`
  const max = Math.max(1, ...rows.map(([, value]) => value))
  const body = rows.map(([label, value]) => `<tr><th scope="row">${escapeHtml(label)}</th><td>${value}</td><td><div class="bar" style="width:${Math.round((value / max) * 100)}%;background:${colour}"></div></td></tr>`)
  return `<section><h2>${escapeHtml(title)}</h2><table>${body.join('')}</table></section>`
}

export function formatHtml(report, generatedAt = new Date()) {
  const tile = (label, value, note = '') => `<div class="tile"><span class="value">${value}</span><span class="label">${escapeHtml(label)}</span>${note ? `<span class="note">${escapeHtml(note)}</span>` : ''}</div>`
  const tiles = [
    tile('Pageviews', report.pageviews),
    tile('Download attempts', report.downloadAttempts, `${report.uniqueDownloadWindows} unique windows, ${report.downloadConversion}% of completed`),
    tile('GitHub attempts', report.githubAttempts, `${report.uniqueGithubWindows} unique windows, ${report.githubConversion}% of completed`),
    tile('Completed windows', report.completedWindows, `${report.provisionalWindows} still provisional`),
    tile('Opt-outs', report.optOuts),
    tile('Dropped writes', report.droppedWrites, `${report.cleanupRuns} cohort rollups`),
  ]
  const charts = [
    ['Pageviews per day', 'pageviews', '#f2b544'],
    ['Download attempts per day', 'downloads', '#ff8a4c'],
    ['GitHub attempts per day', 'github', '#8fb3ff'],
  ].map(([title, field, colour]) => `<section><h2>${title}</h2>${barChart(report.daily, field, colour)}</section>`)
  const breakdowns = [
    breakdownTable('Unique downloads by placement', report.placements.download, '#ff8a4c'),
    breakdownTable('Unique GitHub clicks by placement', report.placements.github, '#8fb3ff'),
    breakdownTable('Completed windows by country', report.dimensions.country, '#f2b544'),
    breakdownTable('Completed windows by device', report.dimensions.device, '#f2b544'),
    breakdownTable('Completed windows by referrer', report.dimensions.referrer, '#f2b544'),
  ]
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Candela analytics, last ${report.days} days</title>
<style>
  :root { color-scheme: dark; }
  body { margin: 0; padding: 32px; background: #121110; color: #f3ede4; font: 14px/1.5 -apple-system, "Helvetica Neue", sans-serif; }
  main { max-width: 760px; margin: 0 auto; }
  h1 { font-size: 22px; margin: 0 0 4px; }
  .meta { color: #9a938a; margin: 0 0 24px; }
  .tiles { display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 12px; margin-bottom: 32px; }
  .tile { background: #1c1a18; border: 1px solid #2c2925; border-radius: 9px; padding: 14px 16px; display: flex; flex-direction: column; }
  .tile .value { font-size: 28px; font-weight: 600; font-variant-numeric: tabular-nums; }
  .tile .label { color: #cfc7bc; }
  .tile .note { color: #9a938a; font-size: 12px; }
  section { margin-bottom: 28px; }
  h2 { font-size: 15px; font-weight: 600; margin: 0 0 8px; color: #cfc7bc; }
  svg { width: 100%; height: ${chartHeight}px; display: block; background: #1c1a18; border-radius: 9px; }
  .axis { display: flex; justify-content: space-between; color: #9a938a; font-size: 12px; margin-top: 4px; }
  table { width: 100%; border-collapse: collapse; }
  th, td { text-align: left; padding: 4px 8px 4px 0; font-weight: normal; vertical-align: middle; }
  td:nth-child(2) { width: 3em; text-align: right; font-variant-numeric: tabular-nums; }
  td:last-child { width: 50%; }
  .bar { height: 8px; border-radius: 4px; }
  .empty { color: #9a938a; margin: 0; }
</style>
</head>
<body>
<main>
<h1>Candela analytics</h1>
<p class="meta">Last ${report.days} days, generated ${escapeHtml(generatedAt.toISOString().replace('T', ' ').slice(0, 16))} UTC. Attempts are button clicks; windows are anonymous 24-hour browser sessions.</p>
<div class="tiles">${tiles.join('')}</div>
${charts.join('\n')}
${breakdowns.join('\n')}
</main>
</body>
</html>
`
}

async function d1Query(sql) {
  const accountId = process.env.CLOUDFLARE_ACCOUNT_ID
  const databaseId = process.env.CANDELA_ANALYTICS_DATABASE_ID
  const token = process.env.CLOUDFLARE_API_TOKEN
  if (!accountId || !databaseId || !token) {
    throw new Error('Set CLOUDFLARE_ACCOUNT_ID, CANDELA_ANALYTICS_DATABASE_ID and a read-only CLOUDFLARE_API_TOKEN')
  }
  const response = await fetch(`https://api.cloudflare.com/client/v4/accounts/${accountId}/d1/database/${databaseId}/query`, {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: JSON.stringify({ sql }),
  })
  const payload = await response.json()
  if (!response.ok || !payload.success) throw new Error('Cloudflare D1 query failed')
  return payload.result?.[0]?.results ?? []
}

export async function loadData(days, query = d1Query) {
  const cutoff = new Date(Date.now() - (days - 1) * 86_400_000).toISOString().slice(0, 10)
  const now = Date.now()
  const [counters, rollups, liveSummary, liveDimensions, provisional, daily] = await Promise.all([
    query(`SELECT metric, placement, SUM(value) AS value FROM daily_counters WHERE day >= '${cutoff}' GROUP BY metric, placement`),
    query(`SELECT metric, dimension_name, dimension_value, SUM(value) AS value FROM cohort_rollups WHERE cohort_day >= '${cutoff}' GROUP BY metric, dimension_name, dimension_value`),
    query(`
      SELECT 'unique_windows' AS metric, 'all' AS dimension_name, 'all' AS dimension_value, COUNT(*) AS value
      FROM measurement_windows WHERE cohort_day >= '${cutoff}' AND expires_at <= ${now}
      UNION ALL
      SELECT 'unique_' || action, 'all', 'all', COUNT(*) FROM unique_actions a
      JOIN measurement_windows w ON w.window_key = a.window_key
      WHERE w.cohort_day >= '${cutoff}' AND w.expires_at <= ${now} GROUP BY action
      UNION ALL
      SELECT 'unique_' || action, 'placement', first_placement, COUNT(*) FROM unique_actions a
      JOIN measurement_windows w ON w.window_key = a.window_key
      WHERE w.cohort_day >= '${cutoff}' AND w.expires_at <= ${now} GROUP BY action, first_placement
    `),
    query(`
      SELECT 'unique_windows', 'country', country_code, COUNT(*) FROM measurement_windows
      WHERE cohort_day >= '${cutoff}' AND expires_at <= ${now} GROUP BY country_code
      UNION ALL
      SELECT 'unique_windows', 'device', device_category, COUNT(*) FROM measurement_windows
      WHERE cohort_day >= '${cutoff}' AND expires_at <= ${now} GROUP BY device_category
      UNION ALL
      SELECT 'unique_windows', 'referrer', referrer_host, COUNT(*) FROM measurement_windows
      WHERE cohort_day >= '${cutoff}' AND expires_at <= ${now} GROUP BY referrer_host
    `),
    query(`SELECT COUNT(*) AS value FROM measurement_windows WHERE cohort_day >= '${cutoff}' AND expires_at > ${now}`),
    query(`SELECT day, metric, SUM(value) AS value FROM daily_counters WHERE day >= '${cutoff}' AND metric IN ('pageview', 'download_attempt', 'github_attempt') GROUP BY day, metric ORDER BY day`),
  ])
  return {
    counters,
    rollups,
    liveCompleted: [...liveSummary, ...liveDimensions],
    provisionalWindows: provisional[0]?.value ?? 0,
    daily,
  }
}

async function main() {
  const options = parseArgs(process.argv.slice(2))
  const report = buildReport(await loadData(options.days), options.days)
  if (options.format !== 'html') {
    process.stdout.write(`${options.format === 'csv' ? formatCsv(report) : formatTable(report)}\n`)
    return
  }
  const path = join(tmpdir(), `candela-analytics-${options.days}d.html`)
  await writeFile(path, formatHtml(report))
  process.stdout.write(`${path}\n`)
  if (options.open) {
    const opener = process.platform === 'darwin' ? 'open' : process.platform === 'win32' ? 'start' : 'xdg-open'
    spawn(opener, [path], { stdio: 'ignore', detached: true, shell: process.platform === 'win32' }).unref()
  }
}

const entry = process.argv[1] ? pathToFileURL(process.argv[1]).href : ''
if (import.meta.url === entry) {
  main().catch((error) => {
    process.stderr.write(`${error instanceof Error ? error.message : 'Analytics report failed'}\n`)
    process.exitCode = 1
  })
}
