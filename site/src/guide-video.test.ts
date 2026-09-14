// @vitest-environment jsdom
import { afterEach, expect, it, vi } from 'vitest'
import { startGuideVideos } from './guide-video'

let dispose = () => {}

afterEach(() => {
  dispose()
  document.body.innerHTML = ''
  vi.restoreAllMocks()
  vi.unstubAllGlobals()
})

function setup(reduce = false) {
  document.body.innerHTML = '<video class="guide-video" muted loop controls playsinline></video>'
  const video = document.querySelector('video')!
  let paused = true
  Object.defineProperty(video, 'paused', { get: () => paused })
  const play = vi.spyOn(video, 'play').mockImplementation(async () => {
    paused = false
    video.dispatchEvent(new Event('play'))
  })
  const pause = vi.spyOn(video, 'pause').mockImplementation(() => {
    if (paused) return
    paused = true
    video.dispatchEvent(new Event('pause'))
  })
  const motion = Object.assign(new EventTarget(), { matches: reduce })
  vi.stubGlobal('matchMedia', () => motion)
  let notify: IntersectionObserverCallback
  vi.stubGlobal('IntersectionObserver', class {
    constructor(callback: IntersectionObserverCallback) { notify = callback }
    observe() {}
    disconnect() {}
  })
  vi.spyOn(document, 'hidden', 'get').mockReturnValue(false)
  dispose = startGuideVideos()
  const visible = (value: boolean) => notify([
    { target: video, isIntersecting: value, intersectionRatio: value ? 1 : 0 } as unknown as IntersectionObserverEntry,
  ], {} as IntersectionObserver)
  return { video, play, pause, motion, visible }
}

it('starts silently on entry, pauses offscreen, and resumes on return', () => {
  const { video, play, visible } = setup()
  expect(play).not.toHaveBeenCalled()
  visible(true)
  expect(video.paused).toBe(false)
  expect(video.muted).toBe(true)
  visible(false)
  expect(video.paused).toBe(true)
  visible(true)
  expect(play).toHaveBeenCalledTimes(2)
})

it('preserves a reader pause across scrolling until the reader presses play', async () => {
  const { video, play, visible } = setup()
  visible(true)
  video.pause()
  visible(false)
  visible(true)
  expect(play).toHaveBeenCalledTimes(1)
  await video.play()
  visible(false)
  visible(true)
  expect(video.paused).toBe(false)
})

it('allows manual playback with reduced motion and responds to preference changes', async () => {
  const { video, play, motion, visible } = setup(true)
  visible(true)
  expect(play).not.toHaveBeenCalled()
  await video.play()
  expect(video.paused).toBe(false)
  visible(false)
  visible(true)
  expect(video.paused).toBe(true)
  motion.matches = false
  motion.dispatchEvent(new Event('change'))
  expect(video.paused).toBe(false)
  motion.matches = true
  motion.dispatchEvent(new Event('change'))
  expect(video.paused).toBe(true)
})

it('suspends playback in a hidden tab and resumes when it becomes visible', () => {
  const { video, visible } = setup()
  visible(true)
  vi.spyOn(document, 'hidden', 'get').mockReturnValue(true)
  document.dispatchEvent(new Event('visibilitychange'))
  expect(video.paused).toBe(true)
  vi.spyOn(document, 'hidden', 'get').mockReturnValue(false)
  document.dispatchEvent(new Event('visibilitychange'))
  expect(video.paused).toBe(false)
})

it('leaves native controls usable when a browser refuses autoplay', async () => {
  const { video, play, visible } = setup()
  play.mockRejectedValueOnce(new DOMException('Autoplay blocked', 'NotAllowedError'))
  visible(true)
  await Promise.resolve()
  expect(video.controls).toBe(true)
  expect(video.paused).toBe(true)
  await video.play()
  expect(video.paused).toBe(false)
})
