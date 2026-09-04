import type { StaticAssets } from './runtime'

export const releasesPageUrl = 'https://github.com/Rydersel/Candela/releases/latest'

// The appcast cannot fall behind: a release that skips it is invisible to shipped apps.
// Its enclosure is the zip Sparkle installs; the dmg sits beside it under the same name.
export async function latestArchiveUrl(assets: StaticAssets, requestUrl: string) {
  try {
    const feed = await assets.fetch(new Request(new URL('/appcast.xml', requestUrl)))
    if (!feed.ok) return releasesPageUrl
    const newest = newestEnclosure(await feed.text())
    return newest ? newest.replace(/\.zip$/, '.dmg') : releasesPageUrl
  } catch {
    return releasesPageUrl
  }
}

function newestEnclosure(xml: string) {
  let best: { version: number[]; url: string } | null = null
  for (const [, item] of xml.matchAll(/<item>([\s\S]*?)<\/item>/g)) {
    const version = item.match(/<sparkle:version>\s*([^<\s]+)\s*</)?.[1]
    const url = item.match(/<enclosure[^>]*?\burl="([^"]+)"/)?.[1]
    if (!version || !url) continue
    const parts = version.split('.').map(Number)
    if (parts.some(Number.isNaN)) continue
    if (!best || compareVersions(parts, best.version) > 0) best = { version: parts, url }
  }
  return best?.url ?? null
}

function compareVersions(a: number[], b: number[]) {
  for (let i = 0; i < Math.max(a.length, b.length); i += 1) {
    const difference = (a[i] ?? 0) - (b[i] ?? 0)
    if (difference !== 0) return difference
  }
  return 0
}
