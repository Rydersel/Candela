import { readAnalyticsPreference } from './lib/measurement'
import { actionMeasurement, isEligibleNavigation, redirect } from './lib/request'
import { parsePlacement, type FunctionContext } from './lib/runtime'
import { recordAction } from './lib/store'

const releaseArchiveUrl = 'https://github.com/Rydersel/Candela/releases/download/v1.0.0/Candela-1.0.0.dmg'

export const onRequestGet = async (context: FunctionContext) => {
  const placement = parsePlacement(new URL(context.request.url).searchParams.get('placement'))
  if (placement && isEligibleNavigation(context.request) && readAnalyticsPreference(context.request) !== 'off') {
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
