import { currentMeasurement, deriveWindowKey, expireMeasurementCookie, setOptOutCookie } from '../lib/measurement'
import { isSameOriginPost, redirect } from '../lib/request'
import { deleteMeasurement, recordPreferenceChange } from '../lib/store'
import type { FunctionContext } from '../lib/runtime'

export const onRequestPost = async (context: FunctionContext) => {
  if (!isSameOriginPost(context.request)) return new Response('Forbidden', { status: 403 })
  try {
    const measurement = await currentMeasurement(context.request, context.env)
    if (measurement) {
      await deleteMeasurement(context.env.ANALYTICS_DB, await deriveWindowKey(measurement.rawId, context.env))
    }
    await recordPreferenceChange(context.env.ANALYTICS_DB, 'opt_out')
  } catch {
    // Browser suppression still succeeds if prior server-side state cannot be removed immediately.
  }

  const response = redirect(new URL('/privacy/?status=off', context.request.url).toString(), 303)
  response.headers.append('set-cookie', expireMeasurementCookie())
  response.headers.append('set-cookie', setOptOutCookie())
  return response
}
