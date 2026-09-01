import { describe, expect, it } from 'vitest'
import { onRequestPost as visit } from './analytics/visit'
import { onRequestPost as optOut } from './analytics/opt-out'
import { onRequestPost as optIn } from './analytics/opt-in'
import { onRequestGet as github } from './github'
import { onRequestGet as download } from './download'
import type { D1Database, D1PreparedStatement, FunctionContext } from './lib/runtime'

class Statement implements D1PreparedStatement {
  readonly query: string
  readonly shouldThrow: boolean
  values: unknown[]
  constructor(query: string, shouldThrow: boolean, values: unknown[] = []) {
    this.query = query
    this.shouldThrow = shouldThrow
    this.values = values
  }
  bind(...values: unknown[]) { this.values = values; return this }
  async first<T>() { if (this.shouldThrow) throw new Error('d1 unavailable'); return null as T | null }
  async all<T>() { if (this.shouldThrow) throw new Error('d1 unavailable'); return { success: true, results: [] as T[] } }
  async run<T>() { if (this.shouldThrow) throw new Error('d1 unavailable'); return { success: true, results: [] as T[] } }
}

class Database implements D1Database {
  statements: Statement[] = []
  readonly shouldThrow: boolean
  constructor(shouldThrow = false) { this.shouldThrow = shouldThrow }
  prepare(query: string) { const value = new Statement(query, this.shouldThrow); this.statements.push(value); return value }
  async batch<T>(statements: D1PreparedStatement[]) {
    if (this.shouldThrow) throw new Error('d1 unavailable')
    return statements.map(() => ({ success: true, results: [] as T[] }))
  }
}

function context(request: Request, db = new Database()): FunctionContext {
  return {
    request,
    env: {
      ANALYTICS_DB: db,
      ANALYTICS_SIGNING_KEY: 'a-test-secret-that-is-long-enough-for-hmac',
      RELEASE_DOWNLOAD_URL: 'https://candela.fyi/Candela-1.0.0.zip',
    },
  }
}

// No RELEASE_DOWNLOAD_URL, so the built-in fallback answers. It shipped
// pointing at a release that did not exist, and nothing exercised this branch.
function contextWithoutReleaseUrl(request: Request): FunctionContext {
  const value = context(request)
  delete value.env.RELEASE_DOWNLOAD_URL
  return value
}

function post(path: string, cookie?: string) {
  return new Request(`https://candela.fyi${path}`, {
    method: 'POST',
    headers: {
      origin: 'https://candela.fyi',
      'content-type': 'application/json',
      ...(cookie ? { cookie } : {}),
    },
    body: path === '/analytics/visit' ? JSON.stringify({ referrerHost: 'github.com' }) : undefined,
    redirect: 'manual',
  })
}

describe('analytics routes', () => {
  it('creates a visit window and rejects cross-origin submissions', async () => {
    const response = await visit(context(post('/analytics/visit')))
    expect(response.status).toBe(204)
    expect(response.headers.get('set-cookie')).toContain('candela_measurement=')

    const hostile = post('/analytics/visit')
    hostile.headers.set('origin', 'https://example.com')
    expect((await visit(context(hostile))).status).toBe(403)
  })

  it('opts out by removing measurement state and setting a visible preference', async () => {
    const created = await visit(context(post('/analytics/visit')))
    const cookie = created.headers.get('set-cookie')!.split(';', 1)[0]
    const response = await optOut(context(post('/analytics/opt-out', cookie)))
    expect(response.status).toBe(303)
    expect(response.headers.get('location')).toBe('https://candela.fyi/privacy/?status=off')
    expect(response.headers.get('set-cookie')).toContain('candela_measurement=')
    expect(response.headers.get('set-cookie')).toContain('candela_analytics=off')
  })

  it('opts back in without creating a measurement in the preference request', async () => {
    const response = await optIn(context(post('/analytics/opt-in', 'candela_analytics=off')))
    expect(response.status).toBe(303)
    expect(response.headers.get('set-cookie')).toContain('candela_analytics=')
    expect(response.headers.get('set-cookie')).not.toContain('candela_measurement=')
  })

  it('records eligible GitHub navigation and always uses the fixed destination', async () => {
    const created = await visit(context(post('/analytics/visit')))
    const cookie = created.headers.get('set-cookie')!.split(';', 1)[0]
    const request = new Request('https://candela.fyi/github?placement=hero&url=https://example.com', {
      headers: { cookie, 'sec-fetch-site': 'same-origin', 'sec-fetch-mode': 'navigate', 'sec-fetch-dest': 'document' },
      redirect: 'manual',
    })
    const response = await github(context(request))
    expect(response.status).toBe(302)
    expect(response.headers.get('location')).toBe('https://github.com/Rydersel/Candela')
  })

  it('redirects even if D1 fails and does not write after opt-out', async () => {
    const failed = await download(context(new Request('https://candela.fyi/download?placement=hero', {
      headers: { 'sec-fetch-site': 'same-origin', 'sec-fetch-mode': 'navigate', 'sec-fetch-dest': 'document' },
      redirect: 'manual',
    }), new Database(true)))
    expect(failed.status).toBe(302)
    expect(failed.headers.get('location')).toBe('https://candela.fyi/Candela-1.0.0.zip')

    const db = new Database()
    await github(context(new Request('https://candela.fyi/github?placement=header', {
      headers: { cookie: 'candela_analytics=off', 'sec-fetch-site': 'same-origin', 'sec-fetch-mode': 'navigate', 'sec-fetch-dest': 'document' },
      redirect: 'manual',
    }), db))
    expect(db.statements).toHaveLength(0)
  })

  it('falls back to the current release archive when no download URL is configured', async () => {
    const response = await download(contextWithoutReleaseUrl(new Request('https://candela.fyi/download', {
      headers: { 'sec-fetch-site': 'same-origin', 'sec-fetch-mode': 'navigate', 'sec-fetch-dest': 'document' },
      redirect: 'manual',
    })))
    expect(response.status).toBe(302)
    expect(response.headers.get('location')).toBe(
      'https://github.com/Rydersel/Candela/releases/download/v1.0.0/Candela-1.0.0.zip',
    )
  })
})
