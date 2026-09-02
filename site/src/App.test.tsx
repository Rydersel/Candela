// @vitest-environment jsdom

import { cleanup, render, within } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import App from './App'

vi.mock('./components/HeroBackdropSwirl', () => ({
  HeroBackdropSwirl: () => null,
}))

class ObserverStub {
  observe() {}
  disconnect() {}
}

describe('App navigation', () => {
  afterEach(() => {
    cleanup()
    vi.unstubAllGlobals()
  })

  it('keeps the primary landmarks reachable while holding downloads for 1.0', () => {
    vi.stubGlobal('IntersectionObserver', ObserverStub)
    vi.stubGlobal('matchMedia', () => ({
      matches: true,
      addEventListener() {},
      removeEventListener() {},
    }))

    const { container, getAllByRole, getByRole } = render(<App />)
    expect(getByRole('navigation', { name: 'Primary' })).toBeTruthy()
    const downloads = [
      ...getAllByRole('link', { name: 'Download for macOS' }),
      ...getAllByRole('link', { name: 'Download' }),
    ]

    expect(downloads).toHaveLength(3)
    expect(downloads.map((link) => link.getAttribute('href')).sort()).toEqual([
      '/download?placement=footer',
      '/download?placement=header',
      '/download?placement=hero',
    ])
    expect(container.querySelector('a[href="/download"]')).toBeNull()
    expect(getByRole('link', { name: 'Skip to content' }).getAttribute('href')).toBe('#content')
    expect(getByRole('main').id).toBe('content')
  })

  it('leads the feature narrative with protection and checkup', () => {
    vi.stubGlobal('IntersectionObserver', ObserverStub)
    vi.stubGlobal('matchMedia', () => ({
      matches: true,
      addEventListener() {},
      removeEventListener() {},
    }))

    const { getByRole } = render(<App />)
    const protection = getByRole('heading', { name: 'Protection that adapts while you work.' })
    const checkup = getByRole('heading', { name: 'Checks your display for defects and wear.' })
    const controls = getByRole('heading', { name: 'Every control, for every display.' })

    expect(protection.compareDocumentPosition(checkup) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
    expect(checkup.compareDocumentPosition(controls) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
  })

  it('keeps the feature overview aligned with the page narrative', () => {
    vi.stubGlobal('IntersectionObserver', ObserverStub)
    vi.stubGlobal('matchMedia', () => ({
      matches: true,
      addEventListener() {},
      removeEventListener() {},
    }))

    const { getByRole } = render(<App />)
    const overview = getByRole('navigation', { name: 'What Candela does' })
    const destinations = Array.from(overview.querySelectorAll('a'), (link) => link.getAttribute('href'))

    expect(destinations).toEqual([
      '#protection',
      '#checkup',
      '#controls',
      '#sizes',
      '#setup',
      '#more',
    ])
  })

  it('keeps the header brand text-only while the hero carries the mark', () => {
    vi.stubGlobal('IntersectionObserver', ObserverStub)
    vi.stubGlobal('matchMedia', () => ({
      matches: true,
      addEventListener() {},
      removeEventListener() {},
    }))

    const { getByRole } = render(<App />)
    const navigation = getByRole('navigation', { name: 'Primary' })
    const brand = getByRole('link', { name: 'Candela' })

    expect(navigation.contains(brand)).toBe(true)
    expect(brand.querySelector('img')).toBeNull()
  })

  it('places product evidence before supporting proof in the document order', () => {
    vi.stubGlobal('IntersectionObserver', ObserverStub)
    vi.stubGlobal('matchMedia', () => ({
      matches: true,
      addEventListener() {},
      removeEventListener() {},
    }))

    const { getByRole } = render(<App />)
    const sizesFigure = getByRole('figure', {
      name: 'Measured on the Dell U2725QE, shown in landscape orientation.',
    })
    const sizesProof = getByRole('heading', { name: 'Sharper HiDPI' })
    const checkupReport = getByRole('img', { name: /finished checkup report/i })
    const checkupProof = getByRole('heading', { name: 'Monitor reports' })
    const exposureMap = getByRole('img', { name: /animated concept grid/i })
    const exposureProof = getByRole('heading', { name: 'Maps cumulative exposure' })

    expect(sizesFigure.compareDocumentPosition(sizesProof) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
    expect(checkupReport.compareDocumentPosition(checkupProof) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
    expect(exposureMap.compareDocumentPosition(exposureProof) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
  })

  it('focuses the measured sizes figure on five landscape HiDPI examples', () => {
    vi.stubGlobal('IntersectionObserver', ObserverStub)
    vi.stubGlobal('matchMedia', () => ({
      matches: true,
      addEventListener() {},
      removeEventListener() {},
    }))

    const { getByRole } = render(<App />)
    const figure = getByRole('figure', {
      name: 'Measured on the Dell U2725QE, shown in landscape orientation.',
    })
    const hiddenSizes = within(figure).getByRole('list', {
      name: 'Five landscape HiDPI size examples',
    })

    expect(within(hiddenSizes).getAllByRole('listitem')).toHaveLength(5)
    expect(hiddenSizes.textContent).toContain('2560 × 1440')
    expect(hiddenSizes.textContent).not.toContain('1440 × 2560')
  })

  it('keeps repository-only implementation caveats off the landing page', () => {
    vi.stubGlobal('IntersectionObserver', ObserverStub)
    vi.stubGlobal('matchMedia', () => ({
      matches: true,
      addEventListener() {},
      removeEventListener() {},
    }))

    const { queryByText } = render(<App />)

    expect(queryByText(/private macOS APIs/i)).toBeNull()
    expect(queryByText(/power command/i)).toBeNull()
  })

  it('surfaces panel history in the protection story', () => {
    vi.stubGlobal('IntersectionObserver', ObserverStub)
    vi.stubGlobal('matchMedia', () => ({
      matches: true,
      addEventListener() {},
      removeEventListener() {},
    }))

    const { container } = render(<App />)
    const protection = container.querySelector('#protection')

    expect(protection).not.toBeNull()
    expect(within(protection as HTMLElement).getByRole('heading', { name: 'Attributes display time by app' })).toBeTruthy()
    expect(within(protection as HTMLElement).getByRole('heading', { name: 'Exports a portable panel record' })).toBeTruthy()
  })

  it('keeps the toolbox focused on shipped user controls', () => {
    vi.stubGlobal('IntersectionObserver', ObserverStub)
    vi.stubGlobal('matchMedia', () => ({
      matches: true,
      addEventListener() {},
      removeEventListener() {},
    }))

    const { container } = render(<App />)
    const toolbox = container.querySelector('#more')

    expect(toolbox).not.toBeNull()
    expect(within(toolbox as HTMLElement).getAllByRole('heading', { level: 3 }).map((heading) => heading.textContent)).toEqual([
      'Virtual displays',
      'Dim past the hardware minimum',
      'Keep every display in sync',
      'Mirroring, arrangement, rotation and refresh rate',
      'Keep Display Awake',
      'Keyboard shortcuts',
    ])
    expect(within(toolbox as HTMLElement).queryByRole('heading', { name: 'A menu bar app, properly' })).toBeNull()
  })

  it('groups the trust pledge and its supporting evidence in a named region', () => {
    vi.stubGlobal('IntersectionObserver', ObserverStub)
    vi.stubGlobal('matchMedia', () => ({
      matches: true,
      addEventListener() {},
      removeEventListener() {},
    }))

    const { getByRole } = render(<App />)
    const trust = getByRole('region', { name: 'The record is yours, and only yours.' })

    expect(trust.querySelectorAll('.trust-item')).toHaveLength(3)
  })
})
