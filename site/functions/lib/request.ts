import { cohortDay, currentMeasurement, deriveWindowKey, readAnalyticsPreference } from './measurement'
import type { AnalyticsEnv } from './runtime'

export function isSameOriginPost(request: Request) {
  return request.method === 'POST' && request.headers.get('origin') === new URL(request.url).origin
}

export function isEligibleNavigation(request: Request) {
  return request.method === 'GET'
    && request.headers.get('sec-fetch-site') === 'same-origin'
    && request.headers.get('sec-fetch-mode') === 'navigate'
    && request.headers.get('sec-fetch-dest') === 'document'
}

export async function actionMeasurement(request: Request, env: AnalyticsEnv, now = new Date()) {
  if (readAnalyticsPreference(request) === 'off') return null
  const measurement = await currentMeasurement(request, env, now)
  if (!measurement) return null
  return {
    windowKey: await deriveWindowKey(measurement.rawId, env),
    startedAt: measurement.issuedAt,
    expiresAt: measurement.expiresAt,
    cohortDay: cohortDay(new Date(measurement.issuedAt)),
  }
}

export function redirect(location: string, status = 302) {
  return new Response(null, { status, headers: { location } })
}
