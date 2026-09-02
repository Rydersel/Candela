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

export function requestCountry(request: Request) {
  const country = (request as Request & { cf?: { country?: string } }).cf?.country?.toUpperCase() ?? 'unknown'
  return /^[A-Z]{2}$/.test(country) ? country : 'unknown'
}
