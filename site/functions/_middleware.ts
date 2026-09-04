import { recordUpdateCheckEvent, updateCheckVersion } from './lib/events'
import { recordUpdateCheck } from './lib/store'
import type { AnalyticsEnv } from './lib/runtime'

type Context = {
  request: Request
  next: () => Promise<Response>
  env: Partial<AnalyticsEnv> & Pick<AnalyticsEnv, 'ASSETS'>
  waitUntil?: (promise: Promise<unknown>) => void
}

// Versions the feed lists; anything else counts as "other". Each version is a
// primary-key row in a table nothing prunes, so a stranger must not be able to add rows.
let feedVersions: Promise<Set<string>> | null = null
function knownVersions(context: Context) {
  if (!feedVersions) {
    feedVersions = (async () => {
      const feed = await context.env.ASSETS.fetch(new Request(new URL('/appcast.xml', context.request.url)))
      if (!feed.ok) throw new Error('feed unavailable')
      const xml = await feed.text()
      return new Set([...xml.matchAll(/<sparkle:shortVersionString>\s*([^<\s]+)\s*</g)].map((match) => match[1]))
    })().catch(() => {
      feedVersions = null
      return new Set<string>()
    })
  }
  return feedVersions
}

export function resetFeedVersionsForTests() {
  feedVersions = null
}

// Everything here runs after the response where the runtime allows, and
// nothing in it can decide whether the feed is served.
function countUpdateCheck(context: Context) {
  try {
    if (context.request.method !== 'GET') return
    const version = updateCheckVersion(context.request.headers.get('user-agent'))
    if (!version) return
    const write = (async () => {
      const bucket = (await knownVersions(context)).has(version) ? version : 'other'
      recordUpdateCheckEvent(context.env, bucket)
      if (context.env.ANALYTICS_DB) await recordUpdateCheck(context.env.ANALYTICS_DB, bucket)
    })().catch(() => {})
    if (context.waitUntil) context.waitUntil(write)
  } catch {
    // Counting is never a reason to fail the feed.
  }
}

function acceptsMarkdown(value: string | null) {
  if (!value) return false
  return value.split(',').some((range) => {
    const [mediaType, ...parameters] = range.trim().toLowerCase().split(';')
    if (mediaType !== 'text/markdown') return false
    const quality = parameters
      .map((parameter) => parameter.trim())
      .find((parameter) => parameter.startsWith('q='))
    return quality ? Number(quality.slice(2)) > 0 : true
  })
}

function withAcceptVary(headers: Headers) {
  const vary = headers.get('vary')
  const values = vary?.split(',').map((value) => value.trim()) ?? []
  if (!values.some((value) => value.toLowerCase() === 'accept')) values.push('Accept')
  headers.set('vary', values.join(', '))
}

async function htmlResponse(context: Context) {
  const response = await context.next()
  const headers = new Headers(response.headers)
  withAcceptVary(headers)
  return new Response(response.body, {
    headers,
    status: response.status,
    statusText: response.statusText,
  })
}

const canonicalHost = 'candela.fyi'

// Only the landing and the guides section get a Markdown twin from the prerender.
function markdownAssetPath(pathname: string) {
  if (pathname === '/') return '/index.md'
  if (/^\/guides\/(?:[a-z0-9-]+\/)?$/.test(pathname)) return `${pathname}index.md`
  return null
}

export const onRequest = async (context: Context) => {
  const url = new URL(context.request.url)
  // www is a Pages custom domain so that it resolves at all; the apex is the
  // one address the sitemap, canonical tags and analytics know.
  if (url.hostname === `www.${canonicalHost}`) {
    url.hostname = canonicalHost
    return Response.redirect(url.toString(), 301)
  }
  if (url.pathname === '/appcast.xml') {
    countUpdateCheck(context)
    return context.next()
  }
  const markdownPath = markdownAssetPath(url.pathname)
  if (!markdownPath) return context.next()
  if (!acceptsMarkdown(context.request.headers.get('accept'))) return htmlResponse(context)

  let asset: Response
  let markdown: string
  try {
    const markdownUrl = new URL(markdownPath, url)
    asset = await context.env.ASSETS.fetch(new Request(markdownUrl, {
      headers: { accept: 'text/plain' },
    }))
    if (!asset.ok) return htmlResponse(context)
    markdown = await asset.text()
  } catch {
    return htmlResponse(context)
  }

  const headers = new Headers(asset.headers)
  headers.set('content-type', 'text/markdown; charset=utf-8')
  headers.set('x-markdown-tokens', String(Math.ceil(markdown.length / 4)))
  withAcceptVary(headers)

  return new Response(markdown, {
    headers,
    status: asset.status,
    statusText: asset.statusText,
  })
}
