// @vitest-environment jsdom

import { beforeEach, describe, expect, it, vi } from 'vitest'
import { analyticsEnabled, externalReferrerHost, startAnalytics } from './analytics'

describe('website analytics bootstrap', () => {
  beforeEach(() => {
    document.head.querySelectorAll('[data-candela-web-analytics]').forEach((node) => node.remove())
  })

  it('recognizes only the first-party off preference', () => {
    expect(analyticsEnabled('theme=dark; candela_analytics=off')).toBe(false)
    expect(analyticsEnabled('candela_analytics=on')).toBe(true)
    expect(analyticsEnabled('')).toBe(true)
  })

  it('reduces referrers to external hostnames before transmission', () => {
    expect(externalReferrerHost('https://github.com/Rydersel/Candela?tab=readme', 'candela.fyi')).toBe('github.com')
    expect(externalReferrerHost('https://candela.fyi/privacy/', 'candela.fyi')).toBeNull()
    expect(externalReferrerHost('', 'candela.fyi')).toBeNull()
  })

  it('sends one first-party visit and conditionally inserts the Cloudflare beacon', async () => {
    const fetcher = vi.fn(async () => new Response(null, { status: 204 }))
    await startAnalytics({
      cookie: '',
      hostname: 'candela.fyi',
      referrer: 'https://github.com/Rydersel/Candela',
      fetcher,
      documentObject: document,
      webAnalyticsToken: 'public-beacon-token',
    })

    expect(fetcher).toHaveBeenCalledTimes(1)
    expect(fetcher).toHaveBeenCalledWith('/analytics/visit', expect.objectContaining({
      method: 'POST',
      keepalive: true,
      credentials: 'same-origin',
      body: JSON.stringify({ referrerHost: 'github.com' }),
    }))
    const beacon = document.head.querySelector<HTMLScriptElement>('[data-candela-web-analytics]')
    expect(beacon?.src).toBe('https://static.cloudflareinsights.com/beacon.min.js')
    expect(beacon?.dataset.cfBeacon).toContain('public-beacon-token')
  })

  it('suppresses both analytics systems after opt-out', async () => {
    const fetcher = vi.fn()
    await startAnalytics({
      cookie: 'candela_analytics=off',
      hostname: 'candela.fyi',
      referrer: 'https://github.com/',
      fetcher,
      documentObject: document,
      webAnalyticsToken: 'public-beacon-token',
    })
    expect(fetcher).not.toHaveBeenCalled()
    expect(document.head.querySelector('[data-candela-web-analytics]')).toBeNull()
  })
})
