import assert from 'node:assert/strict'
import test from 'node:test'
import * as reportModule from './analytics-report.mjs'

const { buildReport, formatCsv, parseArgs } = reportModule

test('parseArgs accepts supported windows and CSV output', () => {
  assert.deepEqual(parseArgs(['--days', '7']), { days: 7, format: 'table' })
  assert.deepEqual(parseArgs(['--days', '30', '--format', 'csv']), { days: 30, format: 'csv' })
  assert.throws(() => parseArgs(['--days', '8']), /7 or 30/)
  assert.throws(() => parseArgs(['--format', 'json']), /table or csv/)
})

test('buildReport keeps attempts, completed browser windows, and provisional windows distinct', () => {
  const report = buildReport({
    counters: [
      { metric: 'pageview', placement: 'all', value: 120 },
      { metric: 'github_attempt', placement: 'hero', value: 30 },
      { metric: 'github_attempt', placement: 'header', value: 5 },
      { metric: 'download_attempt', placement: 'hero', value: 12 },
      { metric: 'opt_out', placement: 'all', value: 2 },
      { metric: 'cohorts_finalized', placement: 'all', value: 3 },
      { metric: 'dropped_write', placement: 'all', value: 1 },
    ],
    rollups: [
      { metric: 'unique_windows', dimension_name: 'all', dimension_value: 'all', value: 50 },
      { metric: 'unique_github', dimension_name: 'all', dimension_value: 'all', value: 20 },
      { metric: 'unique_download', dimension_name: 'all', dimension_value: 'all', value: 8 },
      { metric: 'unique_github', dimension_name: 'placement', dimension_value: 'hero', value: 18 },
      { metric: 'unique_windows', dimension_name: 'country', dimension_value: 'US', value: 50 },
    ],
    liveCompleted: [
      { metric: 'unique_windows', dimension_name: 'all', dimension_value: 'all', value: 10 },
      { metric: 'unique_github', dimension_name: 'all', dimension_value: 'all', value: 4 },
      { metric: 'unique_download', dimension_name: 'all', dimension_value: 'all', value: 2 },
      { metric: 'unique_windows', dimension_name: 'device', dimension_value: 'desktop', value: 10 },
      { metric: 'unique_windows', dimension_name: 'referrer', dimension_value: 'github.com', value: 4 },
    ],
    provisionalWindows: 6,
  }, 7)

  assert.equal(report.pageviews, 120)
  assert.equal(report.completedWindows, 60)
  assert.equal(report.uniqueGithubWindows, 24)
  assert.equal(report.githubConversion, 40)
  assert.equal(report.downloadConversion, 16.67)
  assert.equal(report.provisionalWindows, 6)
  assert.equal(report.githubAttempts, 35)
  assert.equal(report.optOuts, 2)
  assert.equal(report.cleanupRuns, 3)
  assert.equal(report.droppedWrites, 1)
  assert.equal(report.placements.github.hero, 18)
  assert.equal(report.dimensions.country.US, 50)
  assert.equal(report.dimensions.device.desktop, 10)
  assert.equal(report.dimensions.referrer['github.com'], 4)
})

test('formatCsv quotes operator-facing labels safely', () => {
  const csv = formatCsv({
    days: 7,
    pageviews: 1,
    completedWindows: 1,
    provisionalWindows: 0,
    githubAttempts: 1,
    uniqueGithubWindows: 1,
    githubConversion: 100,
    downloadAttempts: 0,
    uniqueDownloadWindows: 0,
    downloadConversion: 0,
    optOuts: 0,
    droppedWrites: 0,
    cleanupRuns: 0,
    placements: { github: {}, download: {} },
    dimensions: { country: {}, device: {}, referrer: {} },
  })
  assert.match(csv, /^metric,value$/m)
  assert.match(csv, /"Completed 24-hour browser windows",1/)
})

test('loadData keeps live aggregation queries within the D1 compound-select limit', async () => {
  assert.equal(typeof reportModule.loadData, 'function')

  const queries = []
  const query = async (sql) => {
    queries.push(sql)
    const selectTerms = sql.match(/\bSELECT\b/gi)?.length ?? 0
    if (selectTerms > 3) throw new Error('too many terms in compound SELECT')
    if (sql.includes("'unique_windows' AS metric, 'all'")) {
      return [{ metric: 'unique_windows', dimension_name: 'all', dimension_value: 'all', value: 4 }]
    }
    if (sql.includes("'unique_windows', 'country'")) {
      return [{ metric: 'unique_windows', dimension_name: 'country', dimension_value: 'US', value: 4 }]
    }
    if (sql.includes('expires_at >')) return [{ value: 2 }]
    return []
  }

  const data = await reportModule.loadData(7, query)

  assert.equal(queries.length, 5)
  assert.deepEqual(data.liveCompleted, [
    { metric: 'unique_windows', dimension_name: 'all', dimension_value: 'all', value: 4 },
    { metric: 'unique_windows', dimension_name: 'country', dimension_value: 'US', value: 4 },
  ])
  assert.equal(data.provisionalWindows, 2)
})
