import assert from 'node:assert/strict'
import test from 'node:test'
import { buildReport, formatCsv, parseArgs } from './analytics-report.mjs'

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
    ],
    rollups: [
      { metric: 'unique_windows', dimension_name: 'all', dimension_value: 'all', value: 50 },
      { metric: 'unique_github', dimension_name: 'all', dimension_value: 'all', value: 20 },
      { metric: 'unique_download', dimension_name: 'all', dimension_value: 'all', value: 8 },
      { metric: 'unique_github', dimension_name: 'placement', dimension_value: 'hero', value: 18 },
    ],
    liveCompleted: [
      { metric: 'unique_windows', dimension_name: 'all', dimension_value: 'all', value: 10 },
      { metric: 'unique_github', dimension_name: 'all', dimension_value: 'all', value: 4 },
      { metric: 'unique_download', dimension_name: 'all', dimension_value: 'all', value: 2 },
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
  assert.equal(report.placements.github.hero, 18)
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
    placements: { github: {}, download: {} },
  })
  assert.match(csv, /^metric,value$/m)
  assert.match(csv, /"Completed 24-hour browser windows",1/)
})
