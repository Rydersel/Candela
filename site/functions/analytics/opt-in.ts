import { clearOptOutCookie } from '../lib/measurement'
import { isSameOriginPost, redirect } from '../lib/request'
import { recordPreferenceChange } from '../lib/store'
import type { FunctionContext } from '../lib/runtime'

export const onRequestPost = async (context: FunctionContext) => {
  if (!isSameOriginPost(context.request)) return new Response('Forbidden', { status: 403 })
  try {
    await recordPreferenceChange(context.env.ANALYTICS_DB, 'opt_in')
  } catch {
    // Preference clearing remains available during analytics failures.
  }
  const response = redirect(new URL('/privacy/?status=on', context.request.url).toString(), 303)
  response.headers.append('set-cookie', clearOptOutCookie())
  return response
}
