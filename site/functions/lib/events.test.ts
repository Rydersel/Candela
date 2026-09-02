import { describe, expect, it, vi } from 'vitest'
import { recordEvent, requestCountry } from './events'

describe('recordEvent', () => {
  it('writes one weighted data point with the counted fields only', () => {
    const writeDataPoint = vi.fn()
    recordEvent({ ANALYTICS_EVENTS: { writeDataPoint } }, {
      metric: 'download_attempt', placement: 'readme', countryCode: 'US', deviceCategory: 'desktop',
    })
    expect(writeDataPoint).toHaveBeenCalledWith({
      indexes: ['download_attempt'],
      blobs: ['download_attempt', 'readme', 'US', 'desktop'],
      doubles: [1],
    })
  })

  it('is a no-op without the binding and swallows a failing write', () => {
    expect(() => recordEvent({}, { metric: 'pageview', placement: 'all', countryCode: 'unknown', deviceCategory: 'unknown' })).not.toThrow()
    const writeDataPoint = vi.fn(() => { throw new Error('quota') })
    expect(() => recordEvent({ ANALYTICS_EVENTS: { writeDataPoint } }, { metric: 'pageview', placement: 'all', countryCode: 'unknown', deviceCategory: 'unknown' })).not.toThrow()
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
