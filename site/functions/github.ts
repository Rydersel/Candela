import { readAnalyticsPreference } from './lib/measurement'
import { actionMeasurement, isEligibleNavigation, redirect } from './lib/request'
import { parsePlacement, type FunctionContext } from './lib/runtime'
import { recordAction } from './lib/store'

const githubUrl = 'https://github.com/Rydersel/Candela'

export const onRequestGet = async (context: FunctionContext) => {
  const placement = parsePlacement(new URL(context.request.url).searchParams.get('placement'))
  if (placement && isEligibleNavigation(context.request) && readAnalyticsPreference(context.request) !== 'off') {
    try {
      await recordAction(context.env.ANALYTICS_DB, {
        action: 'github',
        placement,
        at: Date.now(),
        measurement: await actionMeasurement(context.request, context.env),
      })
    } catch {
      // The fixed redirect remains available when analytics fails.
    }
  }
  return redirect(githubUrl)
}
