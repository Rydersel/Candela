import type { AnalyticsEnv, DeviceCategory, Placement } from './runtime'

export type SiteEventMetric = 'pageview' | 'download_attempt' | 'github_attempt'

export type SiteEvent = {
  metric: SiteEventMetric
  placement: Placement | 'all'
  countryCode: string
  deviceCategory: DeviceCategory
}

type EventEnv = Pick<AnalyticsEnv, 'ANALYTICS_PAGEVIEWS' | 'ANALYTICS_DOWNLOADS' | 'ANALYTICS_GITHUB'>

const datasetFor: Record<SiteEventMetric, keyof EventEnv> = {
  pageview: 'ANALYTICS_PAGEVIEWS',
  download_attempt: 'ANALYTICS_DOWNLOADS',
  github_attempt: 'ANALYTICS_GITHUB',
}

// One data point per counted event in that event's own dataset, carrying
// only the fields the daily counters already hold: never the browser window
// key. Fire-and-forget by design; the bindings are optional so local runs
// and tests need no dataset.
export function recordEvent(env: EventEnv, event: SiteEvent) {
  try {
    env[datasetFor[event.metric]]?.writeDataPoint({
      indexes: [event.placement],
      blobs: [event.placement, event.countryCode, event.deviceCategory],
      doubles: [1],
    })
  } catch {
    // The chart copy never affects the visitor's request.
  }
}

// Only the version comes out of the User-Agent: a version is not an
// identifier, and a client that is not Sparkle is not an install.
const sparkleUserAgent = /^Candela\/(\d{1,5}(?:\.\d{1,5}){0,3}) Sparkle\//

export function updateCheckVersion(userAgent: string | null) {
  return userAgent?.match(sparkleUserAgent)?.[1] ?? null
}

// Version only, no country: the privacy page says the version is the only
// thing read from this request, and that has to stay literally true.
export function recordUpdateCheckEvent(env: Pick<AnalyticsEnv, 'ANALYTICS_UPDATES'>, version: string) {
  try {
    env.ANALYTICS_UPDATES?.writeDataPoint({ indexes: [version], blobs: [version], doubles: [1] })
  } catch {
    // The chart copy never affects the feed request.
  }
}

export function requestCountry(request: Request) {
  const country = (request as Request & { cf?: { country?: string } }).cf?.country?.toUpperCase() ?? 'unknown'
  return /^[A-Z]{2}$/.test(country) ? country : 'unknown'
}
