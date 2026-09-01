/// <reference types="node" />
// @vitest-environment jsdom

import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { act, cleanup, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { Asset } from '../content/assets'
import { MediaFrame } from './MediaFrame'

const mediaFrameCss = readFileSync(resolve('src/components/MediaFrame.css'), 'utf8')

let observe: IntersectionObserverCallback

class ObserverStub {
  constructor(callback: IntersectionObserverCallback) {
    observe = callback
  }
  observe() {}
  disconnect() {}
}

describe('MediaFrame playback', () => {
  afterEach(() => {
    cleanup()
    vi.restoreAllMocks()
    vi.unstubAllGlobals()
    vi.useRealTimers()
  })

  it('renders an eager video poster as a high-priority image', () => {
    vi.stubGlobal('IntersectionObserver', ObserverStub)
    vi.stubGlobal('matchMedia', () => ({
      matches: true,
      addEventListener() {},
      removeEventListener() {},
    }))
    const asset: Asset = {
      kind: 'video',
      src: '/tour.webm',
      poster: '/tour.webp',
      width: 1200,
      height: 630,
      alt: 'Candela product tour',
      eager: true,
    }

    render(<MediaFrame asset={asset} />)

    const poster = screen.getByRole('img', { name: 'Candela product tour' })
    expect(poster.getAttribute('src')).toBe('/tour.webp')
    expect(poster.getAttribute('loading')).toBe('eager')
    expect(poster.getAttribute('fetchpriority')).toBe('high')
  })

  it('keeps the video overlaid when a section also positions its capture', () => {
    vi.stubGlobal('IntersectionObserver', ObserverStub)
    vi.stubGlobal('matchMedia', () => ({
      matches: true,
      addEventListener() {},
      removeEventListener() {},
    }))
    const asset: Asset = {
      kind: 'video',
      src: '/tour.webm',
      poster: '/tour.webp',
      width: 1200,
      height: 630,
      alt: 'Candela product tour',
    }
    const styles = document.createElement('style')
    styles.textContent = `${mediaFrameCss}\n.hero-capture { position: relative; }`
    document.head.append(styles)

    try {
      const { container } = render(<MediaFrame asset={asset} className="hero-capture" />)
      const video = container.querySelector('video')

      expect(video).not.toBeNull()
      expect(window.getComputedStyle(video as HTMLVideoElement).position).toBe('absolute')
    } finally {
      styles.remove()
    }
  })

  it('holds an eager poster before starting its video', () => {
    vi.useFakeTimers()
    vi.stubGlobal('IntersectionObserver', ObserverStub)
    vi.stubGlobal('matchMedia', () => ({
      matches: false,
      addEventListener() {},
      removeEventListener() {},
    }))
    const play = vi.spyOn(HTMLMediaElement.prototype, 'play').mockResolvedValue(undefined)
    vi.spyOn(HTMLMediaElement.prototype, 'pause').mockImplementation(() => {})
    const asset: Asset & { autoplayDelay: number } = {
      kind: 'video',
      src: '/tour.webm',
      poster: '/tour.webp',
      width: 1200,
      height: 630,
      alt: 'Candela product tour',
      autoplayDelay: 1500,
    }

    render(<MediaFrame asset={asset} />)
    act(() => observe([{ isIntersecting: true }] as unknown as IntersectionObserverEntry[], {} as IntersectionObserver))

    expect(play).not.toHaveBeenCalled()
    act(() => vi.advanceTimersByTime(1499))
    expect(play).not.toHaveBeenCalled()
    act(() => vi.advanceTimersByTime(1))
    expect(play).toHaveBeenCalledTimes(1)
  })

  it('starts a desktop page-load video without waiting for an intersection', () => {
    vi.stubGlobal('IntersectionObserver', ObserverStub)
    vi.stubGlobal('matchMedia', (query: string) => ({
      matches: query === '(min-width: 768px)',
      addEventListener() {},
      removeEventListener() {},
    }))
    const play = vi.spyOn(HTMLMediaElement.prototype, 'play').mockResolvedValue(undefined)
    vi.spyOn(HTMLMediaElement.prototype, 'pause').mockImplementation(() => {})
    const asset: Asset & { autoplayOnDesktopLoad: true } = {
      kind: 'video',
      src: '/tour.webm',
      poster: '/tour.webp',
      width: 1200,
      height: 630,
      alt: 'Candela product tour',
      autoplayOnDesktopLoad: true,
    }

    render(<MediaFrame asset={asset} />)

    expect(play).toHaveBeenCalledTimes(1)
  })

  it('starts a delayed video immediately when the visitor presses play', () => {
    vi.useFakeTimers()
    vi.stubGlobal('IntersectionObserver', ObserverStub)
    vi.stubGlobal('matchMedia', () => ({
      matches: false,
      addEventListener() {},
      removeEventListener() {},
    }))
    const play = vi.spyOn(HTMLMediaElement.prototype, 'play').mockResolvedValue(undefined)
    vi.spyOn(HTMLMediaElement.prototype, 'pause').mockImplementation(() => {})
    const asset: Asset & { autoplayDelay: number } = {
      kind: 'video',
      src: '/tour.webm',
      poster: '/tour.webp',
      width: 1200,
      height: 630,
      alt: 'Candela product tour',
      autoplayDelay: 1500,
    }

    render(<MediaFrame asset={asset} />)
    act(() => observe([{ isIntersecting: true }] as unknown as IntersectionObserverEntry[], {} as IntersectionObserver))
    screen.getByRole('button', { name: 'Play' }).click()

    expect(play).toHaveBeenCalledTimes(1)
  })
})
