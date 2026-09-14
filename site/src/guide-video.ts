// Guide HTML is prerendered; attach media behavior without hydrating React.
export function startGuideVideos(root: ParentNode = document) {
  const videos = [...root.querySelectorAll<HTMLVideoElement>('.guide-video')]
  if (!videos.length || !('IntersectionObserver' in window)) return () => {}

  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)')
  const states = new Map(videos.map((video) => [video, {
    visible: false,
    userPaused: false,
    pendingPause: false,
  }]))

  const pause = (video: HTMLVideoElement) => {
    if (video.paused) return
    states.get(video)!.pendingPause = true
    video.pause()
  }

  const update = (video: HTMLVideoElement) => {
    const state = states.get(video)!
    if (!state.visible || document.hidden) {
      pause(video)
    } else if (!reducedMotion.matches && !state.userPaused && video.paused) {
      // Autoplay can still be blocked by a browser preference. Native controls
      // remain available, and an interrupted play request is harmless.
      void video.play().catch(() => {})
    }
  }

  const onPause = (event: Event) => {
    const state = states.get(event.currentTarget as HTMLVideoElement)!
    if (state.pendingPause) state.pendingPause = false
    else state.userPaused = true
  }
  const onPlay = (event: Event) => {
    states.get(event.currentTarget as HTMLVideoElement)!.userPaused = false
  }
  const onVisibility = () => videos.forEach(update)
  const onMotion = () => {
    if (reducedMotion.matches) videos.forEach(pause)
    else videos.forEach(update)
  }

  const observer = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      const video = entry.target as HTMLVideoElement
      states.get(video)!.visible = entry.isIntersecting && entry.intersectionRatio >= 0.25
      update(video)
    }
  }, { threshold: [0, 0.25] })

  for (const video of videos) {
    video.muted = true
    video.addEventListener('pause', onPause)
    video.addEventListener('play', onPlay)
    observer.observe(video)
  }
  document.addEventListener('visibilitychange', onVisibility)
  reducedMotion.addEventListener('change', onMotion)

  return () => {
    observer.disconnect()
    document.removeEventListener('visibilitychange', onVisibility)
    reducedMotion.removeEventListener('change', onMotion)
    for (const video of videos) {
      video.removeEventListener('pause', onPause)
      video.removeEventListener('play', onPlay)
      video.pause()
    }
  }
}
