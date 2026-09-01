import type { D1Database, D1PreparedStatement } from '../../functions/lib/runtime'

type CleanupEnv = { ANALYTICS_DB: D1Database }
type ScheduledContext = { waitUntil(promise: Promise<unknown>): void }

export type DimensionCell = {
  metric: string
  dimensionName: string
  dimensionValue: string
  value: number
}

type DistributionRow = { value: string; count: number }
type TotalsRow = { unique_windows: number; unique_download: number; unique_github: number }

export function collapseSmallCells(cells: DimensionCell[], minimum = 10) {
  const kept: DimensionCell[] = []
  const folded = new Map<string, DimensionCell>()
  for (const cell of cells) {
    if (cell.value >= minimum) {
      kept.push(cell)
      continue
    }
    const key = `${cell.metric}\u0000${cell.dimensionName}`
    const current = folded.get(key)
    if (current) current.value += cell.value
    else folded.set(key, { ...cell, dimensionValue: 'other' })
  }
  return [...kept, ...folded.values()]
}

async function rows(db: D1Database, query: string, ...values: unknown[]) {
  return (await db.prepare(query).bind(...values).all<DistributionRow>()).results ?? []
}

async function cohortCells(db: D1Database, day: string) {
  const totals = await db.prepare(`
    SELECT
      COUNT(*) AS unique_windows,
      SUM(EXISTS(SELECT 1 FROM unique_actions a WHERE a.window_key = w.window_key AND a.action = 'download')) AS unique_download,
      SUM(EXISTS(SELECT 1 FROM unique_actions a WHERE a.window_key = w.window_key AND a.action = 'github')) AS unique_github
    FROM measurement_windows w WHERE cohort_day = ?
  `).bind(day).first<TotalsRow>() ?? { unique_windows: 0, unique_download: 0, unique_github: 0 }

  const cells: DimensionCell[] = [
    { metric: 'unique_windows', dimensionName: 'all', dimensionValue: 'all', value: Number(totals.unique_windows) },
    { metric: 'unique_download', dimensionName: 'all', dimensionValue: 'all', value: Number(totals.unique_download) },
    { metric: 'unique_github', dimensionName: 'all', dimensionValue: 'all', value: Number(totals.unique_github) },
  ]

  const dimensions = [
    ['country', 'country_code'],
    ['device', 'device_category'],
    ['referrer', 'referrer_host'],
  ] as const
  for (const [dimensionName, column] of dimensions) {
    const distribution = await rows(db, `
      SELECT ${column} AS value, COUNT(*) AS count
      FROM measurement_windows WHERE cohort_day = ? GROUP BY ${column}
    `, day)
    for (const row of distribution) {
      cells.push({ metric: 'unique_windows', dimensionName, dimensionValue: row.value, value: Number(row.count) })
    }
  }

  const placements = await rows(db, `
    SELECT action || ':' || first_placement AS value, COUNT(*) AS count
    FROM unique_actions a JOIN measurement_windows w ON w.window_key = a.window_key
    WHERE w.cohort_day = ? GROUP BY action, first_placement
  `, day)
  for (const row of placements) {
    const [action, placement] = row.value.split(':')
    cells.push({ metric: `unique_${action}`, dimensionName: 'placement', dimensionValue: placement, value: Number(row.count) })
  }
  return collapseSmallCells(cells.filter((cell) => cell.value > 0))
}

function rollupStatement(db: D1Database, day: string, cell: DimensionCell) {
  return db.prepare(`
    INSERT INTO cohort_rollups (cohort_day, metric, dimension_name, dimension_value, value)
    VALUES (?, ?, ?, ?, ?)
    ON CONFLICT(cohort_day, metric, dimension_name, dimension_value)
    DO UPDATE SET value = excluded.value
  `).bind(day, cell.metric, cell.dimensionName, cell.dimensionValue, cell.value)
}

export async function finalizeExpiredCohorts(db: D1Database, now = Date.now()) {
  const cohortResult = await db.prepare(`
    SELECT cohort_day FROM measurement_windows
    GROUP BY cohort_day
    HAVING MAX(expires_at) <= ? AND MAX(retention_until) <= ?
    ORDER BY cohort_day
  `).bind(now, now).all<{ cohort_day: string }>()

  let finalized = 0
  for (const { cohort_day: day } of cohortResult.results ?? []) {
    const cells = await cohortCells(db, day)
    const statements: D1PreparedStatement[] = cells.map((cell) => rollupStatement(db, day, cell))
    statements.push(
      db.prepare('DELETE FROM unique_actions WHERE window_key IN (SELECT window_key FROM measurement_windows WHERE cohort_day = ?)').bind(day),
      db.prepare('DELETE FROM measurement_windows WHERE cohort_day = ?').bind(day),
      db.prepare(`
        INSERT INTO daily_counters (day, metric, placement, value) VALUES (?, 'cohorts_finalized', 'all', 1)
        ON CONFLICT(day, metric, placement) DO UPDATE SET value = value + 1
      `).bind(new Date(now).toISOString().slice(0, 10)),
    )
    await db.batch(statements)
    finalized += 1
  }
  return finalized
}

export default {
  scheduled(_controller: unknown, env: CleanupEnv, context: ScheduledContext) {
    context.waitUntil(finalizeExpiredCohorts(env.ANALYTICS_DB))
  },
}
