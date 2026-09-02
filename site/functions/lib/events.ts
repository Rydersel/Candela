import type { AnalyticsEnv, DeviceCategory, Placement } from './runtime'

export type SiteEvent = {
  metric: 'pageview' | 'download_attempt' | 'github_attempt'
  placement: Placement | 'all'
  countryCode: string
  deviceCategory: DeviceCategory
}

// One data point per counted event, carrying only the fields the daily
// counters already hold: never the browser window key. Fire-and-forget by
// design; the binding is optional so local runs and tests need no dataset.
export function recordEvent(env: Pick<AnalyticsEnv, 'ANALYTICS_EVENTS'>, event: SiteEvent) {
  try {
    env.ANALYTICS_EVENTS?.writeDataPoint({
      indexes: [event.metric],
      blobs: [event.metric, event.placement, event.countryCode, event.deviceCategory],
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
