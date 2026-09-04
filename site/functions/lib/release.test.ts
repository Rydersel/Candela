import { describe, expect, it } from 'vitest'
import { latestArchiveUrl, releasesPageUrl } from './release'

function feed(items: string) {
  return `<?xml version="1.0"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>${items}</channel></rss>`
}

function item(version: string, url: string) {
  return `<item><sparkle:version>${version}</sparkle:version><enclosure\n  url="${url}"\n  length="1" type="application/octet-stream"/></item>`
}

const assets = (body: string | null) => ({
  fetch: async () => body === null ? new Response('gone', { status: 404 }) : new Response(body),
})

describe('latestArchiveUrl', () => {
  it('answers with the disk image beside the newest enclosure', async () => {
    const xml = feed(
      item('1.0.1', 'https://github.com/Rydersel/Candela/releases/download/v1.0.1/Candela-1.0.1.zip')
      + item('1.0.0', 'https://github.com/Rydersel/Candela/releases/download/v1.0.0/Candela-1.0.0.zip'),
    )
    expect(await latestArchiveUrl(assets(xml), 'https://candela.fyi/download'))
      .toBe('https://github.com/Rydersel/Candela/releases/download/v1.0.1/Candela-1.0.1.dmg')
  })

  it('picks the highest version, not the first item, and compares numerically', async () => {
    const xml = feed(
      item('1.9.0', 'https://example.test/v1.9.0/Candela-1.9.0.zip')
      + item('1.10.0', 'https://example.test/v1.10.0/Candela-1.10.0.zip')
      + item('1.2.0', 'https://example.test/v1.2.0/Candela-1.2.0.zip'),
    )
    expect(await latestArchiveUrl(assets(xml), 'https://candela.fyi/download'))
      .toBe('https://example.test/v1.10.0/Candela-1.10.0.dmg')
  })

  it('keeps an enclosure that is already a disk image', async () => {
    const xml = feed(item('2.0.0', 'https://example.test/v2.0.0/Candela-2.0.0.dmg'))
    expect(await latestArchiveUrl(assets(xml), 'https://candela.fyi/download'))
      .toBe('https://example.test/v2.0.0/Candela-2.0.0.dmg')
  })

  it('falls back to the releases page when the feed is missing, empty or unreadable', async () => {
    expect(await latestArchiveUrl(assets(null), 'https://candela.fyi/download')).toBe(releasesPageUrl)
    expect(await latestArchiveUrl(assets(feed('')), 'https://candela.fyi/download')).toBe(releasesPageUrl)
    const throwing = { fetch: async () => { throw new Error('no assets') } }
    expect(await latestArchiveUrl(throwing, 'https://candela.fyi/download')).toBe(releasesPageUrl)
  })

  it('reads the feed from the same origin as the request', async () => {
    const seen: string[] = []
    const recording = { fetch: async (request: Request) => { seen.push(request.url); return new Response(feed('')) } }
    await latestArchiveUrl(recording, 'https://preview.candela.pages.dev/download?placement=hero')
    expect(seen).toEqual(['https://preview.candela.pages.dev/appcast.xml'])
  })
})
