import { describe, expect, it, vi } from 'vitest'
import { onRequest } from './_middleware'

type TestContext = Parameters<typeof onRequest>[0]

function contextFor(accept?: string) {
  const request = new Request('https://candela.fyi/', {
    headers: accept ? { accept } : undefined,
  })
  const next = vi.fn(async () => new Response('<html><body>Candela</body></html>', {
    headers: { 'content-type': 'text/html; charset=utf-8' },
  }))
  const markdown = `---\ntitle: Candela\n---\n\n# Candela\n\nDisplay health for Mac.\n`
  const fetch = vi.fn(async () => new Response(markdown, {
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
