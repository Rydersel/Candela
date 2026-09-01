import { pathToFileURL } from 'node:url'

const validDays = new Set([7, 30])

export function parseArgs(argv) {
  let days = 7
  let format = 'table'
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === '--days') days = Number(argv[++index])
    else if (argv[index] === '--format') format = argv[++index]
    else throw new Error(`Unknown option: ${argv[index]}`)
  }
  if (!validDays.has(days)) throw new Error('--days must be 7 or 30')
  if (!['table', 'csv'].includes(format)) throw new Error('--format must be table or csv')
  return { days, format }
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

function percentage(numerator, denominator) {
  return denominator === 0 ? 0 : Math.round((numerator / denominator) * 10_000) / 100
}

export function buildReport(data, days) {
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
    placements: {
      github: placementMap(groups, 'unique_github'),
      download: placementMap(groups, 'unique_download'),
    },
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
]

export function formatCsv(report) {
  const quote = (value) => `"${String(value).replaceAll('"', '""')}"`
  return ['metric,value', ...reportRows(report).map(([metric, value]) => `${quote(metric)},${value}`)].join('\n')
}

export function formatTable(report) {
  const rows = reportRows(report)
  const width = Math.max(...rows.map(([label]) => label.length))
  const placements = ['github', 'download'].flatMap((action) =>
    Object.entries(report.placements[action]).map(([placement, value]) => [`${action} unique from ${placement}`, value]),
  )
  return [...rows, ...placements].map(([label, value]) => `${label.padEnd(width)}  ${value}`).join('\n')
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

async function loadData(days) {
  const cutoff = new Date(Date.now() - (days - 1) * 86_400_000).toISOString().slice(0, 10)
  const now = Date.now()
  const [counters, rollups, liveCompleted, provisional] = await Promise.all([
    d1Query(`SELECT metric, placement, SUM(value) AS value FROM daily_counters WHERE day >= '${cutoff}' GROUP BY metric, placement`),
    d1Query(`SELECT metric, dimension_name, dimension_value, SUM(value) AS value FROM cohort_rollups WHERE cohort_day >= '${cutoff}' GROUP BY metric, dimension_name, dimension_value`),
    d1Query(`
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
    d1Query(`SELECT COUNT(*) AS value FROM measurement_windows WHERE cohort_day >= '${cutoff}' AND expires_at > ${now}`),
  ])
  return { counters, rollups, liveCompleted, provisionalWindows: provisional[0]?.value ?? 0 }
}

async function main() {
  const options = parseArgs(process.argv.slice(2))
  const report = buildReport(await loadData(options.days), options.days)
  process.stdout.write(`${options.format === 'csv' ? formatCsv(report) : formatTable(report)}\n`)
}

const entry = process.argv[1] ? pathToFileURL(process.argv[1]).href : ''
if (import.meta.url === entry) {
  main().catch((error) => {
    process.stderr.write(`${error instanceof Error ? error.message : 'Analytics report failed'}\n`)
    process.exitCode = 1
  })
}
