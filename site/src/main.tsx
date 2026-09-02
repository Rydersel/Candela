import { StrictMode } from 'react'
import { hydrateRoot } from 'react-dom/client'
import './theme.css'
import App from './App.tsx'
import { startAnalytics } from './analytics'

type IdleWindow = Window & {
  requestIdleCallback?: (callback: () => void, options?: { timeout: number }) => number
}

const root = document.getElementById('root')!
const hydrate = () => {
  hydrateRoot(
    root,
    <StrictMode>
      <App pathname={window.location.pathname} />
    </StrictMode>,
  )
}

// The production build already contains the full page. Let the browser paint
// that useful HTML before React attaches the clipboard, motion and media
// behavior; otherwise hydration of the two demonstration grids delays LCP.
//
// Guide pages are pre-rendered in full with nothing interactive on them, so
// React never mounts there at all; only the analytics bootstrap below runs.
const serverRenderedOnly = window.location.pathname.startsWith('/guides')
if (!serverRenderedOnly) {
  requestAnimationFrame(() => {
    const idleWindow = window as IdleWindow
    if (idleWindow.requestIdleCallback) idleWindow.requestIdleCallback(hydrate, { timeout: 1000 })
    else window.setTimeout(hydrate, 0)
  })
}

void startAnalytics()
