// @vitest-environment jsdom

import { cleanup, render } from '@testing-library/react'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'
import App from '../App'
import { GlanceBand } from './GlanceBand'
import { Hero } from './Hero'

const heroStyles = readFileSync(resolve(process.cwd(), 'src/components/Hero.css'), 'utf8')
const glanceStyles = readFileSync(resolve(process.cwd(), 'src/components/GlanceBand.css'), 'utf8')

vi.mock('./HeroBackdropSwirl', () => ({
  HeroBackdropSwirl: () => null,
}))

vi.mock('./MediaFrame', () => ({
  MediaFrame: () => null,
}))

class ObserverStub {
  observe() {}
  disconnect() {}
}

function mountStyles(css: string) {
  const style = document.createElement('style')
  style.textContent = css
  document.head.append(style)
  return style
}

describe('Landing-page motion hierarchy', () => {
  afterEach(() => {
    cleanup()
    document.head.querySelectorAll('style').forEach((style) => style.remove())
    vi.unstubAllGlobals()
  })

  it('introduces the hero copy as one restrained fade', () => {
    mountStyles(heroStyles)
    const { container } = render(<Hero />)
    const copy = container.querySelector('.hero-copy') as HTMLElement

    expect(window.getComputedStyle(copy).animation).toContain('hero-copy-fade')

    for (const child of copy.querySelectorAll<HTMLElement>(
      '.hero-mark, .hero-h1, .hero-sub, .hero-actions, .hero-brew, .hero-foss',
    )) {
      expect(window.getComputedStyle(child).animation).toBe('')
    }
  })

  it('keeps the glance band free of continuously looping animation', () => {
    mountStyles(glanceStyles)
    render(<GlanceBand />)

    expect(glanceStyles).not.toMatch(/animation:[^;{}]*\binfinite\b/)
  })

  it('renders page sections in place without generic scroll reveals', () => {
    vi.stubGlobal('IntersectionObserver', ObserverStub)
    vi.stubGlobal('matchMedia', () => ({
      matches: true,
      addEventListener() {},
      removeEventListener() {},
    }))

    const { container } = render(<App />)

    expect(container.querySelector('.reveal')).toBeNull()
    expect(container.querySelector('.deep-station-pulse')).toBeNull()
  })
})
