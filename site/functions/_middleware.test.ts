import { readFileSync } from 'node:fs'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { onRequest, resetFeedVersionsForTests } from './_middleware'

type TestContext = Parameters<typeof onRequest>[0]

function contextFor(accept?: string, path = '/') {
  const request = new Request(`https://candela.fyi${path}`, {
    headers: accept ? { accept } : undefined,
  })
  const next = vi.fn(async () => new Response('<html><body>Candela</body></html>', {
    headers: { 'content-type': 'text/html; charset=utf-8' },
  }))
  const markdown = `---\ntitle: Candela\n---\n\n# Candela\n\nDisplay health for Mac.\n`
  const fetch = vi.fn(async (_request: Request) => new Response(markdown, {
    headers: {
      'cache-control': 'public, max-age=0, must-revalidate',
      vary: 'Accept-Encoding',
    },
  }))

  return {
    context: { request, next, env: { ASSETS: { fetch } } } as unknown as TestContext,
    fetch,
    markdown,
    next,
  }
}

describe('www redirect', () => {
  it('sends www to the apex with the path and query intact', async () => {
    const { context, next } = contextFor()
    Object.defineProperty(context, 'request', {
      value: new Request('https://www.candela.fyi/privacy/?utm_source=x', { headers: { accept: 'text/html' } }),
    })

    const response = await onRequest(context)

    expect(response.status).toBe(301)
    expect(response.headers.get('location')).toBe('https://candela.fyi/privacy/?utm_source=x')
    expect(next).not.toHaveBeenCalled()
  })
})

describe('Markdown content negotiation', () => {
  it('returns the Markdown representation when the request accepts text/markdown', async () => {
    const { context, fetch, markdown, next } = contextFor('text/markdown, text/html;q=0.9')

    const response = await onRequest(context)

    expect(await response.text()).toBe(markdown)
    expect(response.headers.get('content-type')).toBe('text/markdown; charset=utf-8')
    expect(response.headers.get('vary')).toBe('Accept-Encoding, Accept')
    expect(Number(response.headers.get('x-markdown-tokens'))).toBeGreaterThan(0)
    expect(fetch).toHaveBeenCalledTimes(1)
    expect(next).not.toHaveBeenCalled()
  })

  it('leaves the browser HTML response unchanged by default', async () => {
    const { context, fetch, next } = contextFor('text/html')

    const response = await onRequest(context)

    expect(response.headers.get('content-type')).toBe('text/html; charset=utf-8')
    expect(response.headers.get('vary')).toBe('Accept')
    expect(await response.text()).toContain('<body>Candela</body>')
    expect(next).toHaveBeenCalledTimes(1)
    expect(fetch).not.toHaveBeenCalled()
  })

  it('does not return Markdown when its media range has q=0', async () => {
    const { context, fetch, next } = contextFor('text/markdown;q=0, text/html')

    const response = await onRequest(context)

    expect(response.headers.get('content-type')).toBe('text/html; charset=utf-8')
    expect(response.headers.get('vary')).toBe('Accept')
    expect(next).toHaveBeenCalledTimes(1)
    expect(fetch).not.toHaveBeenCalled()
  })

  it('falls back to cache-safe HTML when the Markdown asset request fails', async () => {
    const { context, fetch, next } = contextFor('text/markdown')
    fetch.mockRejectedValueOnce(new Error('asset binding unavailable'))

    const response = await onRequest(context)

    expect(response.headers.get('content-type')).toBe('text/html; charset=utf-8')
    expect(response.headers.get('vary')).toBe('Accept')
    expect(await response.text()).toContain('<body>Candela</body>')
    expect(next).toHaveBeenCalledTimes(1)
  })

  it('falls back to cache-safe HTML when the Markdown asset body cannot be read', async () => {
    const { context, fetch, next } = contextFor('text/markdown')
    fetch.mockResolvedValueOnce(new Response(new ReadableStream({
      start(controller) {
        controller.error(new Error('asset body unavailable'))
      },
    })))

    const response = await onRequest(context)

    expect(response.headers.get('content-type')).toBe('text/html; charset=utf-8')
    expect(response.headers.get('vary')).toBe('Accept')
    expect(await response.text()).toContain('<body>Candela</body>')
    expect(next).toHaveBeenCalledTimes(1)
  })
})

describe('Markdown content negotiation for the guides section', () => {
  it('serves a guide its Markdown twin from beside its HTML', async () => {
    const { context, fetch, markdown, next } = contextFor('text/markdown', '/guides/oled-burn-in-mac/')

    const response = await onRequest(context)

    expect(await response.text()).toBe(markdown)
    expect(response.headers.get('content-type')).toBe('text/markdown; charset=utf-8')
    expect((fetch.mock.calls[0][0] as Request).url).toBe('https://candela.fyi/guides/oled-burn-in-mac/index.md')
    expect(next).not.toHaveBeenCalled()
  })

  it('serves the guides index its twin too', async () => {
    const { context, fetch } = contextFor('text/markdown', '/guides/')

    await onRequest(context)

    expect((fetch.mock.calls[0][0] as Request).url).toBe('https://candela.fyi/guides/index.md')
  })

  it('falls back to the HTML response, which is the 404, for a guide that does not exist', async () => {
    const { context, fetch, next } = contextFor('text/markdown', '/guides/no-such-guide/')
    fetch.mockResolvedValueOnce(new Response('Not found', { status: 404 }))

    const response = await onRequest(context)

    expect(response.headers.get('content-type')).toBe('text/html; charset=utf-8')
    expect(response.headers.get('vary')).toBe('Accept')
    expect(next).toHaveBeenCalledTimes(1)
  })

  it('passes every other path straight through, whatever the client accepts', async () => {
    // A guide URL without its trailing slash is Pages' redirect to make, not
    // the middleware's: the twin only exists beside the canonical path.
    for (const path of ['/guides/oled-burn-in-mac', '/privacy/', '/guides/Not-A-Slug/', '/guides/a/b/', '/download']) {
      const { context, fetch, next } = contextFor('text/markdown', path)

      const response = await onRequest(context)

      expect(next).toHaveBeenCalledTimes(1)
      expect(fetch).not.toHaveBeenCalled()
      expect(response.headers.get('vary')).toBeNull()
    }
  })
})

describe('update feed counting', () => {
  type Statement = { query: string; values: unknown[]; run: () => Promise<unknown> }
  function feedContext(userAgent: string | undefined, { method = 'GET', failing = false, feedMissing = false } = {}) {
    const request = new Request('https://candela.fyi/appcast.xml', {
      method,
      headers: userAgent ? { 'user-agent': userAgent } : undefined,
    })
    const feed = '<?xml version="1.0"?><rss><item><sparkle:shortVersionString>1.0.1</sparkle:shortVersionString></item><item><sparkle:shortVersionString> 1.0.0 </sparkle:shortVersionString></item></rss>'
    const next = vi.fn(async () => new Response(feed, { headers: { 'content-type': 'application/xml' } }))
    const statements: Statement[] = []
    const db = {
      prepare(query: string) {
        const statement: Statement = {
          query,
          values: [],
          run: async () => { if (failing) throw new Error('d1 unavailable'); return { success: true } },
        }
        statements.push(statement)
        return { bind(...values: unknown[]) { statement.values = values; return statement } }
      },
      batch: async () => [],
    }
    const points: unknown[] = []
    const pending: Promise<unknown>[] = []
    const context = {
      request,
      next,
      env: {
        ASSETS: { fetch: vi.fn(async () => feedMissing ? new Response('gone', { status: 404 }) : new Response(feed)) },
        ANALYTICS_DB: db,
        ANALYTICS_UPDATES: { writeDataPoint: (point: unknown) => { points.push(point) } },
      },
      waitUntil: (promise: Promise<unknown>) => { pending.push(promise) },
    } as unknown as TestContext
    return { context, feed, next, statements, points, pending }
  }

  // The known-version set is cached per isolate; every test starts cold.
  beforeEach(() => { resetFeedVersionsForTests() })

  it('serves the feed unchanged and counts a Sparkle check by app version', async () => {
    const { context, feed, next, statements, points, pending } = feedContext('Candela/1.0.1 Sparkle/2.9.6')

    const response = await onRequest(context)
    await Promise.all(pending)

    expect(await response.text()).toBe(feed)
    expect(response.headers.get('content-type')).toBe('application/xml')
    expect(next).toHaveBeenCalledTimes(1)
    expect(statements).toHaveLength(1)
    expect(statements[0].query).toContain('daily_counters')
    expect(statements[0].values.slice(1)).toEqual(['update_check', '1.0.1'])
    expect(statements[0].values[0]).toMatch(/^\d{4}-\d{2}-\d{2}$/)
    expect(points).toEqual([{ indexes: ['1.0.1'], blobs: ['1.0.1'], doubles: [1] }])
  })

  it('reads only the version out of the User-Agent', async () => {
    const { context, statements, pending } = feedContext('Candela/1.0.1 Sparkle/2.9.6 (Macintosh; Intel Mac OS X 15_1)')
    await onRequest(context)
    await Promise.all(pending)
    expect(statements[0].values.slice(1)).toEqual(['update_check', '1.0.1'])
  })

  it.each([
    ['a browser', 'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_1) AppleWebKit/605.1.15'],
    ['curl', 'curl/8.7.1'],
    ['a made-up app name', 'Cendela/1.0.1 Sparkle/2.9.6'],
    ['a version that is not a version', 'Candela/evil<script> Sparkle/2.9.6'],
    ['a version longer than any real one', `Candela/${'9'.repeat(4000)} Sparkle/2.9.6`],
    ['no User-Agent at all', undefined],
  ])('does not count %s', async (_label, userAgent) => {
    const { context, feed, next, statements, points } = feedContext(userAgent)

    const response = await onRequest(context)

    expect(await response.text()).toBe(feed)
    expect(next).toHaveBeenCalledTimes(1)
    expect(statements).toHaveLength(0)
    expect(points).toHaveLength(0)
  })

  it.each([
    ['a version the feed does not list', 'Candela/9.9.9 Sparkle/2.9.6'],
    ['a spelling the feed does not list', 'Candela/01.0.1 Sparkle/2.9.6'],
  ])('files %s under other, so the vocabulary stays closed', async (_label, userAgent) => {
    const { context, statements, points, pending } = feedContext(userAgent)
    await onRequest(context)
    await Promise.all(pending)
    expect(statements[0].values.slice(1)).toEqual(['update_check', 'other'])
    expect(points).toEqual([{ indexes: ['other'], blobs: ['other'], doubles: [1] }])
  })

  it('files every version under other while the feed cannot be read, and retries next time', async () => {
    const { context, statements, pending } = feedContext('Candela/1.0.1 Sparkle/2.9.6', { feedMissing: true })
    await onRequest(context)
    await Promise.all(pending)
    expect(statements[0].values.slice(1)).toEqual(['update_check', 'other'])

    const again = feedContext('Candela/1.0.1 Sparkle/2.9.6')
    await onRequest(again.context)
    await Promise.all(again.pending)
    expect(again.statements[0].values.slice(1)).toEqual(['update_check', '1.0.1'])
  })

  it('reads the feed once per isolate, not once per check', async () => {
    const first = feedContext('Candela/1.0.1 Sparkle/2.9.6')
    await onRequest(first.context)
    await Promise.all(first.pending)
    const second = feedContext('Candela/1.0.0 Sparkle/2.9.6')
    await onRequest(second.context)
    await Promise.all(second.pending)
    const fetches = (context: TestContext) => (context as unknown as { env: { ASSETS: { fetch: ReturnType<typeof vi.fn> } } }).env.ASSETS.fetch
    expect(fetches(first.context)).toHaveBeenCalledTimes(1)
    expect(fetches(second.context)).not.toHaveBeenCalled()
    expect(second.statements[0].values.slice(1)).toEqual(['update_check', '1.0.0'])
  })

  it('routes the feed through Functions, or none of this runs', () => {
    const routes = JSON.parse(readFileSync(new URL('../public/_routes.json', import.meta.url), 'utf8')) as { include: string[] }
    expect(routes.include).toContain('/appcast.xml')
  })

  it('does not count a HEAD request, which is the publication check and not an install', async () => {
    const { context, next, statements, points, pending } = feedContext('Candela/1.0.1 Sparkle/2.9.6', { method: 'HEAD' })
    await onRequest(context)
    await Promise.all(pending)
    expect(next).toHaveBeenCalledTimes(1)
    expect(statements).toHaveLength(0)
    expect(points).toHaveLength(0)
  })

  it('still serves the feed when the database is down', async () => {
    const { context, feed, next, pending } = feedContext('Candela/1.0.1 Sparkle/2.9.6', { failing: true })

    const response = await onRequest(context)
    await Promise.all(pending)

    expect(await response.text()).toBe(feed)
    expect(next).toHaveBeenCalledTimes(1)
  })
})
