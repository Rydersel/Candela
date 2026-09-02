export type Placement = 'header' | 'hero' | 'footer' | 'readme' | 'guide'
export type AnalyticsAction = 'download' | 'github'
export type DeviceCategory = 'desktop' | 'mobile' | 'tablet' | 'unknown'

export type D1Result<T = Record<string, unknown>> = {
  results?: T[]
  success: boolean
  meta?: Record<string, unknown>
}

export type D1PreparedStatement = {
  bind(...values: unknown[]): D1PreparedStatement
  first<T = Record<string, unknown>>(column?: string): Promise<T | null>
  all<T = Record<string, unknown>>(): Promise<D1Result<T>>
  run<T = Record<string, unknown>>(): Promise<D1Result<T>>
}

export type D1Database = {
  prepare(query: string): D1PreparedStatement
  batch<T = Record<string, unknown>>(statements: D1PreparedStatement[]): Promise<D1Result<T>[]>
}

// Workers Analytics Engine: the dashboard's charting copy of the counts.
// D1 stays the record; this store samples at volume and expires after its
// retention window, so nothing is derived from it.
export type AnalyticsEngineDataset = {
  writeDataPoint(event: { blobs?: string[]; doubles?: number[]; indexes?: string[] }): void
}

export type AnalyticsEnv = {
  ANALYTICS_DB: D1Database
  ANALYTICS_SIGNING_KEY: string
  RELEASE_DOWNLOAD_URL?: string
  // One dataset per counted event, so the dashboard's dataset picker is the
  // chart picker.
  ANALYTICS_PAGEVIEWS?: AnalyticsEngineDataset
  ANALYTICS_DOWNLOADS?: AnalyticsEngineDataset
  ANALYTICS_GITHUB?: AnalyticsEngineDataset
}

export type FunctionContext = {
  request: Request
  env: AnalyticsEnv
  waitUntil?: (promise: Promise<unknown>) => void
}

export const placements = new Set<Placement>(['header', 'hero', 'footer', 'readme', 'guide'])

// Placements reached from another site: the README's download button lives on
// github.com, so its click is a cross-site navigation and must not be dropped
// by the same-origin rule that keeps prefetchers out of the counts.
export const externalPlacements = new Set<Placement>(['readme'])

export function parsePlacement(value: string | null): Placement | null {
  return value && placements.has(value as Placement) ? value as Placement : null
}
