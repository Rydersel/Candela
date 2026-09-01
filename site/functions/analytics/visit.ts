import {
  cohortDay,
  deriveWindowKey,
  getOrCreateMeasurement,
  readAnalyticsPreference,
  reduceDeviceCategory,
  sanitizeReferrerHost,
} from '../lib/measurement'
import { isSameOriginPost } from '../lib/request'
import { recordVisit } from '../lib/store'
import type { FunctionContext } from '../lib/runtime'

export const onRequestPost = async (context: FunctionContext) => {
  if (!isSameOriginPost(context.request)) return new Response('Forbidden', { status: 403 })
  if (readAnalyticsPreference(context.request) === 'off') return new Response(null, { status: 204 })

  const now = new Date()
  const measurement = await getOrCreateMeasurement(context.request, context.env, now)
  let payload: { referrerHost?: unknown } = {}
  try {
    payload = await context.request.json() as { referrerHost?: unknown }
  } catch {
    // Empty or malformed input is simply a direct visit; no request data is logged.
  }

  const cloudflareRequest = context.request as Request & { cf?: { country?: string } }
  const country = cloudflareRequest.cf?.country?.toUpperCase() ?? 'unknown'
  const countryCode = /^[A-Z]{2}$/.test(country) ? country : 'unknown'
  const ownHost = new URL(context.request.url).hostname
  const referrerHost = sanitizeReferrerHost(payload.referrerHost, ownHost) ?? 'direct'

  try {
    await recordVisit(context.env.ANALYTICS_DB, {
      windowKey: await deriveWindowKey(measurement.rawId, context.env),
      startedAt: measurement.issuedAt,
      expiresAt: measurement.expiresAt,
      cohortDay: cohortDay(new Date(measurement.issuedAt)),
      countryCode,
      deviceCategory: reduceDeviceCategory(context.request.headers.get('user-agent')),
      referrerHost,
    })
  } catch {
    // Analytics is deliberately fail-open.
  }

  const headers = new Headers()
  if (measurement.setCookie) headers.append('set-cookie', measurement.setCookie)
  return new Response(null, { status: 204, headers })
}
