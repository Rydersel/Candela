import { useEffect, useRef, useState } from 'react'
import type { Asset } from '../content/assets'
import { mediaPause, mediaResume } from '../content/copy'
import './MediaFrame.css'

// The one way the page puts a capture on screen. Images load lazily at their
// stated size, unless the manifest marks one eager; videos are decoration, so
// they carry no native controls and start only for a visitor who has not asked
// for less motion. Most wait until they are on screen; the hero can opt into a
// desktop page-load start. Everything else falls back to the poster, including
// a video whose file is not there.
//
// A looping video still needs a way to be stopped (WCAG 2.2.2), so each one
// carries a minimal pause control. A pause from the visitor outranks the
// observer: scrolling away and back does not restart a video someone stopped,
// only their own resume does. Under reduced motion the videos never play, so
// the control hides (MediaFrame.css).
export function MediaFrame({ asset, className }: { asset: Asset; className?: string }) {
  const videoRef = useRef<HTMLVideoElement>(null)
  const onScreenRef = useRef(false)
  const userPausedRef = useRef(false)
  const startTimerRef = useRef(0)
  // The ref is the truth the callbacks read; the state only relabels the button.
  const [userPaused, setUserPaused] = useState(false)
  const [playing, setPlaying] = useState(false)
  // media-frame is the hook a caller styles when it does not care which element
  // the asset turned out to be; the caller's own class comes after it.
  const classes = className ? `media-frame ${className}` : 'media-frame'

  useEffect(() => {
    const el = videoRef.current
    if (!el) return

    const reduced = window.matchMedia('(prefers-reduced-motion: reduce)')
    const startsOnDesktopLoad =
      asset.autoplayOnDesktopLoad && window.matchMedia('(min-width: 768px)').matches
    const start = (immediate = false) => {
      window.clearTimeout(startTimerRef.current)
      const play = () => {
        if (!onScreenRef.current || reduced.matches || userPausedRef.current) return
        // Autoplay runs only on a muted element, and the muted attribute seeds
        // defaultMuted rather than this property. Asserted here so playback does
        // not rest on how React chooses to apply the prop.
        el.muted = true
        // Rejects when the file is missing or undecodable; the poster stays up,
        // which is what a visitor sees before any video starts anyway.
        el.play().catch(() => {})
      }
      if (asset.autoplayDelay && !immediate) {
        startTimerRef.current = window.setTimeout(play, asset.autoplayDelay)
      }
      else play()
    }

    let io: IntersectionObserver | undefined
    if (startsOnDesktopLoad) {
      // The hero is the page's primary demonstration. Start it from the page
      // lifecycle instead of making playback depend on how much of its tall
      // frame happens to fit below the fold in a particular desktop window.
      onScreenRef.current = true
      if (!reduced.matches && !userPausedRef.current) start(true)
    } else {
      io = new IntersectionObserver(
        (entries) => {
          // Last record wins: a batch can carry earlier crossings that are already history.
          onScreenRef.current = entries[entries.length - 1].isIntersecting
          if (onScreenRef.current && !reduced.matches && !userPausedRef.current) start()
          else {
            window.clearTimeout(startTimerRef.current)
            el.pause()
          }
        },
        { threshold: 0.15 },
      )
      io.observe(el)
    }

    const onReducedChange = () => {
      if (!reduced.matches) {
        if (onScreenRef.current && !userPausedRef.current) start()
        return
      }
      window.clearTimeout(startTimerRef.current)
      if (el.paused) return
      el.pause()
      // Pausing alone leaves the last frame frozen on screen, which is not what
      // someone who just asked for less motion should be left looking at.
      // load() drops back to the poster. Confined to this path on purpose: it
      // discards the buffer, so on an ordinary scroll-out it would throw away a
      // download the visitor already paid for.
      el.load()
    }
    reduced.addEventListener('change', onReducedChange)

    return () => {
      window.clearTimeout(startTimerRef.current)
      io?.disconnect()
      reduced.removeEventListener('change', onReducedChange)
    }
  }, [asset])

  const toggle = () => {
    const el = videoRef.current
    if (!el) return
    if (userPausedRef.current || !playing) {
      window.clearTimeout(startTimerRef.current)
      userPausedRef.current = false
      setUserPaused(false)
      if (
        onScreenRef.current &&
        !window.matchMedia('(prefers-reduced-motion: reduce)').matches
      ) {
        el.muted = true
        el.play().catch(() => {})
      }
    } else {
      userPausedRef.current = true
      setUserPaused(true)
      el.pause()
    }
  }

  const showsPlay = userPaused || !playing

  if (asset.kind === 'image') {
    return (
      <img
        className={classes}
        src={asset.src}
        srcSet={asset.srcSet}
        sizes={asset.sizes}
        alt={asset.alt}
        width={asset.width}
        height={asset.height}
        loading={asset.eager ? 'eager' : 'lazy'}
        fetchPriority={asset.eager ? 'high' : undefined}
        decoding="async"
      />
    )
  }

  return (
    <div className="media-shell" data-playing={playing || undefined}>
      <img
        className={`${classes} media-poster`}
        src={asset.poster}
        srcSet={asset.posterSrcSet}
        sizes={asset.sizes}
        alt={asset.alt}
        width={asset.width}
        height={asset.height}
        loading={asset.eager ? 'eager' : 'lazy'}
        fetchPriority={asset.eager ? 'high' : undefined}
        decoding="async"
      />
      <video
        ref={videoRef}
        className={`${classes} media-video`}
        // With an HEVC variant the browser picks from the source children;
        // a src attribute would override them, so it is only set when the
        // H.264 file is the sole option.
        src={asset.srcHevc ? undefined : asset.src}
        width={asset.width}
        height={asset.height}
        aria-hidden="true"
        muted
        loop
        playsInline
        preload="none"
        onPlaying={() => setPlaying(true)}
      >
        {asset.srcHevc && (
          <>
            <source src={asset.srcHevc} type='video/mp4; codecs="hvc1"' />
            <source
              src={asset.src}
              type={asset.src.endsWith('.webm') ? 'video/webm' : 'video/mp4'}
            />
          </>
        )}
      </video>
      <button
        type="button"
        className="media-toggle"
        data-paused={showsPlay || undefined}
        aria-label={showsPlay ? mediaResume : mediaPause}
        onClick={toggle}
      >
        {showsPlay ? (
          <svg width="10" height="10" viewBox="0 0 10 10" aria-hidden="true">
            <path d="M2 1l7 4-7 4z" fill="currentColor" />
          </svg>
        ) : (
          <svg width="10" height="10" viewBox="0 0 10 10" aria-hidden="true">
            <path d="M2 1h2v8H2zM6 1h2v8H6z" fill="currentColor" />
          </svg>
        )}
      </button>
    </div>
  )
}
