type AnalyticsOptions = {
  cookie: string
  hostname: string
  referrer: string
  fetcher: typeof fetch
  documentObject: Document
  webAnalyticsToken?: string
}

export function analyticsEnabled(cookie: string) {
  return !cookie.split(';').some((part) => part.trim() === 'candela_analytics=off')
}

export function externalReferrerHost(referrer: string, ownHost: string) {
  if (!referrer) return null
  try {
    const hostname = new URL(referrer).hostname.toLowerCase().replace(/\.$/, '')
    return hostname && hostname !== ownHost.toLowerCase() ? hostname : null
  } catch {
    return null
  }
}

export async function startAnalytics(options: AnalyticsOptions = {
  cookie: document.cookie,
  hostname: window.location.hostname,
  referrer: document.referrer,
  fetcher: window.fetch.bind(window),
  documentObject: document,
  webAnalyticsToken: import.meta.env.VITE_CLOUDFLARE_WEB_ANALYTICS_TOKEN,
}) {
  if (!analyticsEnabled(options.cookie)) return

  if (options.webAnalyticsToken && !options.documentObject.head.querySelector('[data-candela-web-analytics]')) {
    const beacon = options.documentObject.createElement('script')
    beacon.defer = true
    beacon.src = 'https://static.cloudflareinsights.com/beacon.min.js'
    beacon.dataset.candelaWebAnalytics = ''
    beacon.dataset.cfBeacon = JSON.stringify({ token: options.webAnalyticsToken })
    options.documentObject.head.append(beacon)
  }

  try {
    await options.fetcher('/analytics/visit', {
      method: 'POST',
      keepalive: true,
      credentials: 'same-origin',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        referrerHost: externalReferrerHost(options.referrer, options.hostname),
      }),
    })
  } catch {
    // The page never changes behavior because analytics is unavailable.
  }
}
