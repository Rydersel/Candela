// @vitest-environment jsdom

import { cleanup, render, within } from '@testing-library/react'
import { afterEach, describe, expect, it } from 'vitest'
import App from './App'
import { formatGuideDate, type Guide } from './guides'

const burnIn: Guide = {
  slug: 'oled-burn-in-mac',
  path: '/guides/oled-burn-in-mac/',
  title: 'How to prevent OLED burn-in on a Mac',
  description: 'What wears, what macOS offers, and where software fills the gap.',
  published: '2026-09-02',
  updated: '2026-09-03',
  checkedOn: 'macOS 26',
  html: '<p>An OLED panel wears where bright, unchanging content sits.</p>\n<h2 id="what-wears">What wears</h2>\n<p>The menu bar.</p>\n',
}

const brightness: Guide = {
  ...burnIn,
  slug: 'external-monitor-brightness-mac',
  path: '/guides/external-monitor-brightness-mac/',
  title: "How to control an external monitor's brightness from a Mac",
  description: 'Why the slider is missing and what works over the cable.',
}

// Every accessible name the site gives a Download or GitHub control, so no
// chrome escapes the placement sweep.
const actionNames = ['Download', 'Download for macOS', 'GitHub', 'View on GitHub']

function actionHrefs(queryAllByRole: ReturnType<typeof render>['queryAllByRole']) {
  return actionNames.flatMap((name) =>
    queryAllByRole('link', { name }).map((link) => link.getAttribute('href') ?? ''),
  )
}

describe('guide pages', () => {
  afterEach(cleanup)

  it('formats a frontmatter date as a calendar day, whatever the zone', () => {
    expect(formatGuideDate('2026-09-03')).toBe('September 3, 2026')
    expect(formatGuideDate('2026-12-31')).toBe('December 31, 2026')
  })

  it('renders one guide with its dates, its body and the guide placement on every action', () => {
    const { container, getByRole, queryAllByRole } = render(
      <App pathname="/guides/oled-burn-in-mac/" guides={[burnIn, brightness]} />,
    )

    expect(getByRole('heading', { level: 1 }).textContent).toBe(burnIn.title)
    expect(container.querySelector('time')?.getAttribute('datetime')).toBe('2026-09-03')
    expect(container.textContent).toContain('Updated September 3, 2026')
    expect(getByRole('heading', { level: 2, name: 'What wears' }).id).toBe('what-wears')
    expect(container.textContent).toContain('An OLED panel wears where bright, unchanging content sits.')

    // Header, closing card and footer. One action left in a landing bucket and
    // the section cannot be measured on its own.
    const actions = actionHrefs(queryAllByRole)
    expect(actions).toHaveLength(6)
    expect(actions.filter((href) => !href.endsWith('placement=guide'))).toEqual([])

    const more = getByRole('navigation', { name: 'More guides' })
    expect(within(more).getByRole('link', { name: brightness.title }).getAttribute('href')).toBe(brightness.path)
    expect(within(more).queryByRole('link', { name: burnIn.title })).toBeNull()

    const primary = getByRole('navigation', { name: 'Primary' })
    expect(within(primary).getByRole('link', { name: 'Guides' }).getAttribute('href')).toBe('/guides/')
    expect(within(primary).getByRole('link', { name: 'FAQ' }).getAttribute('href')).toBe('/#faq')
    expect(getByRole('main').id).toBe('content')
  })

  it('omits the more-guides block when there is nothing else to read', () => {
    const { queryByRole } = render(<App pathname="/guides/oled-burn-in-mac/" guides={[burnIn]} />)
    expect(queryByRole('navigation', { name: 'More guides' })).toBeNull()
  })

  it('lists every guide on the index with its description and date', () => {
    const { getByRole, getAllByRole, queryAllByRole } = render(<App pathname="/guides/" guides={[burnIn, brightness]} />)

    expect(getByRole('heading', { level: 1 }).textContent).toBe('Guides')
    const list = getByRole('list', { name: 'Guides' })
    const links = within(list).getAllByRole('link')
    expect(links.map((link) => link.getAttribute('href'))).toEqual([burnIn.path, brightness.path])
    expect(list.textContent).toContain(burnIn.description)
    expect(list.textContent).toContain('September 3, 2026')
    expect(getAllByRole('heading', { level: 2 }).map((heading) => heading.textContent)).toEqual([burnIn.title, brightness.title])

    const actions = actionHrefs(queryAllByRole)
    expect(actions).toHaveLength(4)
    expect(actions.filter((href) => !href.endsWith('placement=guide'))).toEqual([])
  })

  it('accepts the section paths with or without a trailing slash', () => {
    expect(render(<App pathname="/guides" guides={[burnIn]} />).getByRole('heading', { level: 1 }).textContent).toBe('Guides')
    cleanup()
    expect(render(<App pathname="/guides/oled-burn-in-mac" guides={[burnIn]} />).getByRole('heading', { level: 1 }).textContent).toBe(burnIn.title)
  })

  it('puts the Guides link in the footer of a guide page', () => {
    const { getByRole } = render(<App pathname="/guides/oled-burn-in-mac/" guides={[burnIn]} />)
    const footer = getByRole('contentinfo')
    expect(within(footer).getByRole('link', { name: 'Guides' }).getAttribute('href')).toBe('/guides/')
    expect(within(footer).getByRole('link', { name: 'Privacy' }).getAttribute('href')).toBe('/privacy/')
  })
})
