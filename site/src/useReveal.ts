import { useLayoutEffect, useRef } from 'react'

// Adds .in once the element scrolls into view; CSS handles the fade-up.
export function useReveal<T extends HTMLElement>() {
  const ref = useRef<T>(null)
  useLayoutEffect(() => {
    const el = ref.current
    if (!el) return
    if (typeof window.IntersectionObserver !== 'function') return
    if (window.matchMedia?.('(prefers-reduced-motion: reduce)').matches) return

    // App.tsx positions a fragment after mount. Keep that initial target
    // readable without waiting on an observer callback during the jump.
    const initialTarget = document.getElementById(window.location.hash.slice(1))
    if (initialTarget?.contains(el)) return

    el.classList.add('reveal-ready')
    const io = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) {
          el.classList.add('in')
          io.disconnect()
        }
      },
      { threshold: 0.15 },
    )
    io.observe(el)
    return () => io.disconnect()
  }, [])
  return ref
}
