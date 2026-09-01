import type { AnalyticsEnv, DeviceCategory } from './runtime'

const measurementName = 'candela_measurement'
const preferenceName = 'candela_analytics'
const windowSeconds = 86_400
const encoder = new TextEncoder()

export type Measurement = {
  rawId: string
  issuedAt: number
  expiresAt: number
  created: boolean
  setCookie: string | null
}

function encodeBase64Url(bytes: Uint8Array) {
  let binary = ''
  for (const byte of bytes) binary += String.fromCharCode(byte)
  return btoa(binary).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '')
}

function decodeBase64Url(value: string) {
  const base64 = value.replaceAll('-', '+').replaceAll('_', '/')
  const padded = base64.padEnd(Math.ceil(base64.length / 4) * 4, '=')
  const binary = atob(padded)
  return Uint8Array.from(binary, (character) => character.charCodeAt(0))
}

function cookieMap(request: Request) {
  const values = new Map<string, string>()
  for (const part of (request.headers.get('cookie') ?? '').split(';')) {
    const separator = part.indexOf('=')
    if (separator < 1) continue
    values.set(part.slice(0, separator).trim(), part.slice(separator + 1).trim())
  }
  return values
}

async function hmacKey(secret: string) {
  return crypto.subtle.importKey(
    'raw',
    encoder.encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign', 'verify'],
  )
}

async function sign(value: string, env: Pick<AnalyticsEnv, 'ANALYTICS_SIGNING_KEY'>) {
  const signature = await crypto.subtle.sign('HMAC', await hmacKey(env.ANALYTICS_SIGNING_KEY), encoder.encode(value))
  return encodeBase64Url(new Uint8Array(signature))
}

async function verify(value: string, signature: string, env: Pick<AnalyticsEnv, 'ANALYTICS_SIGNING_KEY'>) {
  try {
    return crypto.subtle.verify(
      'HMAC',
      await hmacKey(env.ANALYTICS_SIGNING_KEY),
      decodeBase64Url(signature),
      encoder.encode(value),
    )
  } catch {
    return false
  }
}

function measurementCookie(value: string) {
  return `${measurementName}=${value}; Path=/; Max-Age=${windowSeconds}; HttpOnly; Secure; SameSite=Lax`
}

async function readMeasurement(
  request: Request,
  env: Pick<AnalyticsEnv, 'ANALYTICS_SIGNING_KEY'>,
  now: Date,
): Promise<Omit<Measurement, 'created' | 'setCookie'> | null> {
  const value = cookieMap(request).get(measurementName)
  if (!value) return null
  const [version, issuedText, expiresText, rawId, signature, ...extra] = value.split('.')
  if (version !== 'v1' || extra.length > 0 || !issuedText || !expiresText || !rawId || !signature) return null
  const issuedAt = Number(issuedText)
  const expiresAt = Number(expiresText)
  if (!Number.isSafeInteger(issuedAt) || !Number.isSafeInteger(expiresAt)) return null
  if (expiresAt <= now.getTime() || expiresAt - issuedAt !== windowSeconds * 1000) return null
  const unsigned = [version, issuedText, expiresText, rawId].join('.')
  if (!await verify(`measurement-cookie:${unsigned}`, signature, env)) return null
  return { rawId, issuedAt, expiresAt }
}

export async function getOrCreateMeasurement(
  request: Request,
  env: Pick<AnalyticsEnv, 'ANALYTICS_SIGNING_KEY'>,
  now = new Date(),
): Promise<Measurement> {
  const current = await readMeasurement(request, env, now)
  if (current) return { ...current, created: false, setCookie: null }

  const random = new Uint8Array(16)
  crypto.getRandomValues(random)
  const rawId = encodeBase64Url(random)
  const issuedAt = now.getTime()
  const expiresAt = issuedAt + windowSeconds * 1000
  const unsigned = `v1.${issuedAt}.${expiresAt}.${rawId}`
  const signature = await sign(`measurement-cookie:${unsigned}`, env)
  return {
    rawId,
    issuedAt,
    expiresAt,
    created: true,
    setCookie: measurementCookie(`${unsigned}.${signature}`),
  }
}

export async function currentMeasurement(
  request: Request,
  env: Pick<AnalyticsEnv, 'ANALYTICS_SIGNING_KEY'>,
  now = new Date(),
) {
  return readMeasurement(request, env, now)
}

export async function deriveWindowKey(rawId: string, env: Pick<AnalyticsEnv, 'ANALYTICS_SIGNING_KEY'>) {
  return sign(`measurement-window:${rawId}`, env)
}

export function readAnalyticsPreference(request: Request) {
  return cookieMap(request).get(preferenceName) === 'off' ? 'off' : 'on'
}

export function expireMeasurementCookie() {
  return `${measurementName}=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Lax`
}

export function setOptOutCookie() {
  return `${preferenceName}=off; Path=/; Max-Age=31536000; Secure; SameSite=Lax`
}

export function clearOptOutCookie() {
  return `${preferenceName}=; Path=/; Max-Age=0; Secure; SameSite=Lax`
}

export function cohortDay(date: Date) {
  return date.toISOString().slice(0, 10)
}

export function reduceReferrerHost(value: string | null | undefined, ownHost: string) {
  if (!value) return null
  try {
    const hostname = new URL(value).hostname.toLowerCase().replace(/\.$/, '')
    if (!hostname || hostname.length > 253 || hostname === ownHost.toLowerCase()) return null
    return hostname
  } catch {
    return null
  }
}

export function sanitizeReferrerHost(value: unknown, ownHost: string) {
  if (typeof value !== 'string' || value.length > 253) return null
  const hostname = value.toLowerCase().replace(/\.$/, '')
  if (hostname === ownHost.toLowerCase()) return null
  if (!/^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(hostname)) return null
  return hostname
}

export function reduceDeviceCategory(userAgent: string | null): DeviceCategory {
  if (!userAgent) return 'unknown'
  if (/ipad|tablet|kindle|silk/i.test(userAgent)) return 'tablet'
  if (/mobile|iphone|ipod|android/i.test(userAgent)) return 'mobile'
  if (/macintosh|windows|linux|cros/i.test(userAgent)) return 'desktop'
  return 'unknown'
}
