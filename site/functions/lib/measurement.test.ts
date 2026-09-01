import { describe, expect, it } from 'vitest'
import {
  clearOptOutCookie,
  deriveWindowKey,
  expireMeasurementCookie,
  getOrCreateMeasurement,
  readAnalyticsPreference,
  reduceDeviceCategory,
  reduceReferrerHost,
  setOptOutCookie,
} from './measurement'
import { parsePlacement, type AnalyticsEnv } from './runtime'

const secret = 'a-test-secret-that-is-long-enough-for-hmac'
const now = new Date('2026-09-01T12:00:00.000Z')
const env = { ANALYTICS_SIGNING_KEY: secret } as AnalyticsEnv

describe('measurement windows', () => {
  it('creates and verifies a fixed 24-hour signed host-only cookie', async () => {
    const created = await getOrCreateMeasurement(new Request('https://candela.fyi/'), env, now)
    expect(created.created).toBe(true)
    expect(created.expiresAt).toBe(now.getTime() + 86_400_000)
    expect(created.setCookie).toContain('Max-Age=86400')
    expect(created.setCookie).toContain('HttpOnly')
    expect(created.setCookie).toContain('Secure')
    expect(created.setCookie).toContain('SameSite=Lax')
    expect(created.setCookie).not.toContain('Domain=')

    const request = new Request('https://candela.fyi/', {
      headers: { cookie: created.setCookie!.split(';', 1)[0] },
    })
    const verified = await getOrCreateMeasurement(request, env, new Date(now.getTime() + 60_000))
    expect(verified.created).toBe(false)
    expect(verified.rawId).toBe(created.rawId)
    expect(verified.expiresAt).toBe(created.expiresAt)
    expect(verified.setCookie).toBeNull()
  })

  it('replaces tampered and expired cookies', async () => {
    const created = await getOrCreateMeasurement(new Request('https://candela.fyi/'), env, now)
    const original = created.setCookie!.split(';', 1)[0]
    const tampered = `${original.slice(0, -1)}x`
    const tamperedResult = await getOrCreateMeasurement(new Request('https://candela.fyi/', {
      headers: { cookie: tampered },
    }), env, now)
    expect(tamperedResult.created).toBe(true)
    expect(tamperedResult.rawId).not.toBe(created.rawId)

    const expiredResult = await getOrCreateMeasurement(new Request('https://candela.fyi/', {
      headers: { cookie: original },
    }), env, new Date(now.getTime() + 86_400_001))
    expect(expiredResult.created).toBe(true)
  })

  it('derives a stable database key without exposing the raw identifier', async () => {
    const key = await deriveWindowKey('raw-browser-window', env)
    expect(key).toBe(await deriveWindowKey('raw-browser-window', env))
    expect(key).not.toContain('raw-browser-window')
    expect(key).not.toBe(await deriveWindowKey('another-window', env))
  })
})

describe('privacy-safe inputs', () => {
  it('recognizes opt-out and emits preference cookie controls', () => {
    const request = new Request('https://candela.fyi/', {
      headers: { cookie: 'theme=dark; candela_analytics=off' },
    })
    expect(readAnalyticsPreference(request)).toBe('off')
    expect(setOptOutCookie()).toContain('Max-Age=31536000')
    expect(setOptOutCookie()).not.toContain('HttpOnly')
    expect(clearOptOutCookie()).toContain('Max-Age=0')
    expect(expireMeasurementCookie()).toContain('HttpOnly')
  })

  it('reduces referrers to an external hostname', () => {
    expect(reduceReferrerHost('https://news.ycombinator.com/item?id=1', 'candela.fyi')).toBe('news.ycombinator.com')
    expect(reduceReferrerHost('https://candela.fyi/privacy/?status=off', 'candela.fyi')).toBeNull()
    expect(reduceReferrerHost('not a url', 'candela.fyi')).toBeNull()
  })

  it('reduces user agents without returning their source', () => {
    expect(reduceDeviceCategory('Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X)')).toBe('tablet')
    expect(reduceDeviceCategory('Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) Mobile')).toBe('mobile')
    expect(reduceDeviceCategory('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)')).toBe('desktop')
    expect(reduceDeviceCategory('')).toBe('unknown')
  })

  it('accepts only known CTA placements', () => {
    expect(parsePlacement('header')).toBe('header')
    expect(parsePlacement('hero')).toBe('hero')
    expect(parsePlacement('footer')).toBe('footer')
    expect(parsePlacement('sidebar')).toBeNull()
  })
})
