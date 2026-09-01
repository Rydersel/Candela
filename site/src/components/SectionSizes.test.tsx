// @vitest-environment jsdom

import { cleanup, render, within } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { SectionSizes } from './SectionSizes'

class ObserverStub {
  observe() {}
  unobserve() {}
  disconnect() {}
}

describe('SectionSizes', () => {
  beforeEach(() => {
    vi.stubGlobal('IntersectionObserver', ObserverStub)
  })

  afterEach(() => {
    cleanup()
    vi.unstubAllGlobals()
  })

  it('presents the measured Dell examples in landscape orientation', () => {
    const { getByRole } = render(<SectionSizes />)
    const figure = getByRole('figure', {
      name: 'Measured on the Dell U2725QE, shown in landscape orientation.',
    })
    const examples = within(figure).getByRole('list', {
      name: 'Five landscape HiDPI size examples',
    })

    expect(within(examples).getAllByRole('listitem')).toHaveLength(5)
    expect(examples.textContent).toContain('2560 × 1440')
    expect(examples.textContent).not.toContain('1440 × 2560')
    expect(figure.textContent).toContain('27')
    expect(figure.textContent).toContain('27')
    expect(figure.textContent).toContain('distinct HiDPI sizes found')
    expect(figure.textContent).toContain('177 measured HiDPI modes across refresh rates')
  })
})
