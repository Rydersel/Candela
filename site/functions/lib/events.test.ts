import { describe, expect, it, vi } from 'vitest'
import { recordEvent, requestCountry } from './events'

describe('recordEvent', () => {
  it('writes one weighted data point to the dataset of its event, with the counted fields only', () => {
    const downloads = vi.fn()
    const pageviews = vi.fn()
    recordEvent({ ANALYTICS_DOWNLOADS: { writeDataPoint: downloads }, ANALYTICS_PAGEVIEWS: { writeDataPoint: pageviews } }, {
      metric: 'download_attempt', placement: 'readme', countryCode: 'US', deviceCategory: 'desktop',
    })
    expect(downloads).toHaveBeenCalledWith({ indexes: ['readme'], blobs: ['readme', 'US', 'desktop'], doubles: [1] })
    expect(pageviews).not.toHaveBeenCalled()
  })

  it('is a no-op without the binding and swallows a failing write', () => {
    const event = { metric: 'pageview' as const, placement: 'all' as const, countryCode: 'unknown', deviceCategory: 'unknown' as const }
    expect(() => recordEvent({}, event)).not.toThrow()
    const writeDataPoint = vi.fn(() => { throw new Error('quota') })
    expect(() => recordEvent({ ANALYTICS_PAGEVIEWS: { writeDataPoint } }, event)).not.toThrow()
  })
})

describe('requestCountry', () => {
  it('keeps a two-letter country and reduces anything else to unknown', () => {
    const withCf = (country?: string) => Object.assign(new Request('https://candela.fyi/'), { cf: country === undefined ? undefined : { country } })
    expect(requestCountry(withCf('de'))).toBe('DE')
    expect(requestCountry(withCf('T1'))).toBe('unknown')
    expect(requestCountry(withCf())).toBe('unknown')
  })
})
