// Every image and video the page renders. Components import from here and
// build no paths of their own, so the capture session has one file to edit.
//
// One of the five assets is a real capture of the shipped app: the checkup
// report still, from a live run against the DELL U2725QE on the development
// rig (2026-08-28). The tour, setup, menu-bar-panel and health walkthroughs
// are produced recordings of the real app (2026-08-31) with its measured
// data on screen, re-encoded here. The dim and accumulation figures are not
// assets at all: DimDemo.tsx and ExposureDemo.tsx draw them live.

import tourPoster from '../assets/captures/tour-poster.webp'
import healthFlowPoster from '../assets/captures/health-flow-poster.webp'
import setupFlowPoster from '../assets/captures/setup-flow-poster.webp'
import panelFlowPoster from '../assets/captures/panel-flow-poster.webp'
import checkupReportCapture from '../assets/captures/checkup-report.webp'

export type Asset = {
  kind: 'image' | 'video'
  src: string
  // An HEVC variant of the same cut, offered first where it is actually
  // smaller (panel's HEVC came out larger than its H.264, so it has none).
  // Tagged hvc1, which is the one tag Safari accepts; browsers that cannot
  // decode HEVC fall through to src.
  srcHevc?: string
  poster?: string
  width: number
  height: number
  alt: string
  // Set on an above-the-fold image that is the page's largest paint, which must
  // not wait for the lazy pass.
  eager?: boolean
}

type AssetKey =
  | 'hero'
  | 'healthFlow'
  | 'setupFlow'
  | 'panelFlow'
  | 'checkupReport'

// A poster is what MediaFrame shows whenever the video is not playing, which
// under reduced motion is always, so a video without one renders as a blank
// box. Asset leaves poster optional because consumers read a single type; these
// two make the manifest itself refuse a video that has no poster.
type ImageAsset = Asset & { kind: 'image' }
type VideoAsset = Asset & { kind: 'video'; poster: string }

export const assets: Record<AssetKey, Asset> = {
  hero: {
    kind: 'video',
    // VP9, not H.264: every H.264 export of this cut artifacted on the
    // hero's dark gradients. HEVC still serves Safari; everything else
    // takes the webm.
    src: './media/tour.webm',
    srcHevc: './media/tour-hevc.mp4',
    poster: tourPoster,
    width: 2080,
    height: 1524,
    alt: "A tour of Candela's settings: General, the OLED care pane with a display's measured hours and hottest area, and the menu bar and indicator options.",
  },
  healthFlow: {
    kind: 'video',
    src: './media/health-flow.mp4',
    srcHevc: './media/health-flow-hevc.mp4',
    poster: healthFlowPoster,
    width: 1920,
    height: 1080,
    alt: "The Health page in motion: both displays with their hours and hottest areas, the provenance export, the measurement switches, and the Heat Map window opening on the live exposure map.",
  },
  setupFlow: {
    kind: 'video',
    src: './media/setup-flow.mp4',
    srcHevc: './media/setup-flow-hevc.mp4',
    poster: setupFlowPoster,
    width: 1520,
    height: 1184,
    alt: "Candela's guided setup: it finds both connected displays, reports what each answers over DDC, asks about keyboard access, and flags the OLED for protection.",
  },
  panelFlow: {
    kind: 'video',
    src: './media/panel-flow.mp4',
    poster: panelFlowPoster,
    width: 1920,
    height: 1080,
    alt: "Candela's menu bar panel in use: brightness dragged for every connected display, the volume slider, HDR switching on, and the resolution menu opening with its scaled sizes.",
  },
  checkupReport: {
    kind: 'image',
    src: checkupReportCapture,
    width: 2080,
    height: 1524,
    alt: 'A finished checkup report, one line per check, each line saying how the result was known: observed, refused, not observed, or self-reported.',
  },
} satisfies Record<AssetKey, ImageAsset | VideoAsset>
