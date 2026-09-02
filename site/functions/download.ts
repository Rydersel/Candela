import { recordEvent, requestCountry } from './lib/events'
import { readAnalyticsPreference, reduceDeviceCategory } from './lib/measurement'
import { actionMeasurement, isEligibleNavigation, redirect } from './lib/request'
import { externalPlacements, parsePlacement, type FunctionContext } from './lib/runtime'
import { recordAction } from './lib/store'

const releaseArchiveUrl = 'https://github.com/Rydersel/Candela/releases/download/v1.0.0/Candela-1.0.0.dmg'

export const onRequestGet = async (context: FunctionContext) => {
  const placement = parsePlacement(new URL(context.request.url).searchParams.get('placement'))
  const eligible = placement && isEligibleNavigation(context.request, { allowCrossSite: externalPlacements.has(placement) })
  if (placement && eligible && readAnalyticsPreference(context.request) !== 'off') {
    recordEvent(context.env, {
      metric: 'download_attempt',
      placement,
      countryCode: requestCountry(context.request),
      deviceCategory: reduceDeviceCategory(context.request.headers.get('user-agent')),
    })
    try {
      await recordAction(context.env.ANALYTICS_DB, {
        action: 'download',
        placement,
        at: Date.now(),
        measurement: await actionMeasurement(context.request, context.env),
      })
    } catch {
      // Download access is never coupled to analytics availability.
    }
  }
  return redirect(context.env.RELEASE_DOWNLOAD_URL ?? releaseArchiveUrl)
}
