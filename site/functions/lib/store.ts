import type { AnalyticsAction, D1Database, DeviceCategory, Placement } from './runtime'

const sevenDays = 7 * 86_400_000

type Visit = {
  windowKey: string
  startedAt: number
  expiresAt: number
  cohortDay: string
  countryCode: string
  deviceCategory: DeviceCategory
  referrerHost: string
}

export type ActionMeasurement = {
  windowKey: string
  startedAt: number
  expiresAt: number
  cohortDay: string
}

type ActionEvent = {
  action: AnalyticsAction
  placement: Placement
  at: number
  measurement: ActionMeasurement | null
}

function counter(db: D1Database, day: string, metric: string, placement = 'all') {
  return db.prepare(`
    INSERT INTO daily_counters (day, metric, placement, value)
    VALUES (?, ?, ?, 1)
    ON CONFLICT(day, metric, placement) DO UPDATE SET value = value + 1
  `).bind(day, metric, placement)
}

function windowInsert(db: D1Database, visit: Omit<Visit, 'countryCode' | 'deviceCategory' | 'referrerHost'> & Partial<Pick<Visit, 'countryCode' | 'deviceCategory' | 'referrerHost'>>) {
  return db.prepare(`
    INSERT INTO measurement_windows (
      window_key, started_at, expires_at, retention_until, cohort_day,
      country_code, device_category, referrer_host
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(window_key) DO NOTHING
  `).bind(
    visit.windowKey,
    visit.startedAt,
    visit.expiresAt,
    visit.startedAt + sevenDays,
    visit.cohortDay,
    visit.countryCode ?? 'unknown',
    visit.deviceCategory ?? 'unknown',
    visit.referrerHost ?? 'direct',
  )
}

export async function recordVisit(db: D1Database, visit: Visit) {
  await db.batch([windowInsert(db, visit), counter(db, visit.cohortDay, 'pageview')])
}

export async function recordAction(db: D1Database, event: ActionEvent) {
  const day = new Date(event.at).toISOString().slice(0, 10)
  const statements = [counter(db, day, `${event.action}_attempt`, event.placement)]
  if (event.measurement) {
    statements.unshift(windowInsert(db, event.measurement))
    statements.push(db.prepare(`
      INSERT INTO unique_actions (window_key, action, first_placement, first_at)
      VALUES (?, ?, ?, ?)
      ON CONFLICT(window_key, action) DO NOTHING
    `).bind(event.measurement.windowKey, event.action, event.placement, event.at))
  }
  await db.batch(statements)
}

export async function deleteMeasurement(db: D1Database, windowKey: string) {
  await db.batch([
    db.prepare('DELETE FROM unique_actions WHERE window_key = ?').bind(windowKey),
    db.prepare('DELETE FROM measurement_windows WHERE window_key = ?').bind(windowKey),
  ])
}

export async function recordPreferenceChange(db: D1Database, metric: 'opt_out' | 'opt_in', now = new Date()) {
  await counter(db, now.toISOString().slice(0, 10), metric).run()
}
