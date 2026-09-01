import { describe, expect, it } from 'vitest'
import { recordAction, recordVisit } from './store'
import type { D1Database, D1PreparedStatement } from './runtime'

class Statement implements D1PreparedStatement {
  values: unknown[] = []
  constructor(readonly query: string) {}
  bind(...values: unknown[]) { this.values = values; return this }
  async first<T>() { return null as T | null }
  async all<T>() { return { success: true, results: [] as T[] } }
  async run<T>() { return { success: true, results: [] as T[] } }
}

class Database implements D1Database {
  statements: Statement[] = []
  batches: Statement[][] = []
  prepare(query: string) {
    const statement = new Statement(query)
    this.statements.push(statement)
    return statement
  }
  async batch<T>(statements: D1PreparedStatement[]) {
    this.batches.push(statements as Statement[])
    return statements.map(() => ({ success: true, results: [] as T[] }))
  }
}

describe('analytics store', () => {
  it('records a visit without replacing the first-touch window', async () => {
    const db = new Database()
    await recordVisit(db, {
      windowKey: 'derived-key',
      startedAt: 1_756_728_000_000,
      expiresAt: 1_756_814_400_000,
      cohortDay: '2026-09-01',
      countryCode: 'US',
      deviceCategory: 'desktop',
      referrerHost: 'news.ycombinator.com',
    })

    expect(db.batches).toHaveLength(1)
    expect(db.batches[0]).toHaveLength(2)
    expect(db.batches[0][0].query).toContain('ON CONFLICT(window_key) DO NOTHING')
    expect(db.batches[0][1].values).toEqual(['2026-09-01', 'pageview', 'all'])
  })

  it('keeps attempts separate from first unique action attribution', async () => {
    const db = new Database()
    await recordAction(db, {
      action: 'github',
      placement: 'hero',
      at: 1_756_728_100_000,
      measurement: {
        windowKey: 'derived-key',
        startedAt: 1_756_728_000_000,
        expiresAt: 1_756_814_400_000,
        cohortDay: '2026-09-01',
      },
    })

    expect(db.batches[0]).toHaveLength(3)
    expect(db.batches[0][1].values).toEqual(['2025-09-01', 'github_attempt', 'hero'])
    expect(db.batches[0][2].query).toContain('ON CONFLICT(window_key, action) DO NOTHING')
    expect(db.batches[0][2].values).toEqual(['derived-key', 'github', 'hero', 1_756_728_100_000])
  })

  it('counts an eligible attempt even when no valid measurement window exists', async () => {
    const db = new Database()
    await recordAction(db, {
      action: 'download',
      placement: 'footer',
      at: 1_756_728_100_000,
      measurement: null,
    })

    expect(db.batches[0]).toHaveLength(1)
    expect(db.batches[0][0].values).toEqual(['2025-09-01', 'download_attempt', 'footer'])
  })
})
