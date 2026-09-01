// @vitest-environment jsdom

import { act, cleanup, render } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { useReveal } from './useReveal'

function RevealedContent() {
  const ref = useReveal<HTMLDivElement>()
  return (
    <div ref={ref} className="reveal">
      Always readable
    </div>
  )
}

describe('useReveal', () => {
  afterEach(() => {
    cleanup()
    vi.unstubAllGlobals()
    window.history.replaceState(null, '', '/')
  })

  it('leaves content visible when IntersectionObserver is unavailable', () => {
    vi.stubGlobal('IntersectionObserver', undefined)

    const { getByText } = render(<RevealedContent />)

    expect(getByText('Always readable').classList.contains('reveal-ready')).toBe(false)
  })

  it('arms the reveal before marking intersecting content as visible', () => {
    let notify: IntersectionObserverCallback | undefined
    const disconnect = vi.fn()
    const observe = vi.fn()

    class ObserverStub {
      constructor(callback: IntersectionObserverCallback) {
        notify = callback
      }

      observe = observe
      disconnect = disconnect
    }

    vi.stubGlobal('IntersectionObserver', ObserverStub)
    const { getByText } = render(<RevealedContent />)
    const content = getByText('Always readable')

    expect(content.classList.contains('reveal-ready')).toBe(true)
    expect(content.classList.contains('in')).toBe(false)

    act(() => {
      notify?.([{ isIntersecting: true } as IntersectionObserverEntry], {} as IntersectionObserver)
    })

    expect(content.classList.contains('in')).toBe(true)
    expect(disconnect).toHaveBeenCalledOnce()
  })

  it('leaves content visible when reduced motion is requested', () => {
    class ObserverStub {
      observe() {}
      disconnect() {}
    }

    vi.stubGlobal('IntersectionObserver', ObserverStub)
    vi.stubGlobal('matchMedia', () => ({ matches: true }))

    const { getByText } = render(<RevealedContent />)

    expect(getByText('Always readable').classList.contains('reveal-ready')).toBe(false)
  })

  it('leaves the initially deep-linked section visible during fragment positioning', () => {
    class ObserverStub {
      observe() {}
      disconnect() {}
    }

    vi.stubGlobal('IntersectionObserver', ObserverStub)
    window.history.replaceState(null, '', '#sizes')

    const { getByText } = render(
      <section id="sizes">
        <RevealedContent />
      </section>,
    )

    expect(getByText('Always readable').classList.contains('reveal-ready')).toBe(false)
  })
})
