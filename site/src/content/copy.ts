// Every user-visible string on candela.fyi. Components import from here and
// hold no copy of their own, so the two gates run in one place: the NORTHSTAR
// copy filter on every lead, and an unslop pass on all of it (SR15).
//
// Rules that bind edits to this file:
// - No em dashes anywhere, site copy included. scripts/check-copy.sh enforces it.
// - Competitor names appear in exactly one place, the FAQ entry below, question
//   and answer both (SR5).
// - Measured claims only. Estimates are labeled as estimates in the sentence
//   that makes them, not in a footnote. The idle dim is described as the
//   shipped staged dim, not the wear-weighted dim, until that feature lands;
//   when it does, the protection body is where the claim upgrades.
// - The idle-cost sentence currently claims the budget discipline without a
//   figure: the spec's sanctioned fallback while the measured number does not
//   exist. When the performance-budget work lands its figure, the sentence
//   gains the number. It never becomes a guess.

export const hero: {
  h1: string
  sub: string
  ctaPrimary: string
  ctaSecondary: string
  foss: string
} = {
  h1: "The display software Apple forgot to ship.",
  sub: "Candela watches your display's health, protects OLED panels from burn-in, checks for defects and wear, and gives every monitor the controls macOS should have.",
  ctaPrimary: "Download at 1.0",
  ctaSecondary: "View on GitHub",
  foss: "Free and open source, forever.",
}

// The hero's click-to-copy Homebrew pill. The tap repo does not exist yet:
// creating Rydersel/homebrew-tap with the candela cask is a recorded deploy
// gate, because the command must work on the day the site does.
export const brew: {
  cmd: string
  hint: string
  copied: string
  failed: string
  copyLabel: string
} = {
  cmd: "brew install --cask rydersel/tap/candela",
  hint: "copy",
  copied: "copied",
  failed: "Copy failed. Select manually.",
  copyLabel: "Copy the Homebrew install command",
}

// Accessible name for the feature band's nav landmark; screen readers speak it.
export const glanceLabel = "What Candela does"

// MediaFrame's pause control labels.
export const mediaPause = "Pause"
export const mediaResume = "Play"

export const navigation = {
  label: "Primary",
  brand: "Candela",
  faq: "FAQ",
  github: "GitHub",
  download: "Download at 1.0",
  skip: "Skip to content",
}

// The five-second read: every key feature, one line each, in the order the
// deep sections tell them. Most visitors never scroll past this band, so it
// has to be the whole app in miniature.
export const glance: Array<{
  id: "controls" | "sizes" | "setup" | "protection" | "checkup" | "more"
  title: string
  line: string
}> = [
  {
    id: "protection",
    title: "Protection",
    line: "Dims static OLED regions and maps their exposure.",
  },
  {
    id: "checkup",
    title: "Checkup",
    line: "Checks for defects and records what it found.",
  },
  {
    id: "controls",
    title: "Controls",
    line: "Brightness, volume and contrast from your keys.",
  },
  {
    id: "sizes",
    title: "Sizes",
    line: "Every sharp HiDPI size macOS hides.",
  },
  {
    id: "setup",
    title: "Setup",
    line: "Learns what each connected display can do.",
  },
  {
    id: "more",
    title: "And more",
    line: "Virtual displays, HDR, mirroring, arrangement and shortcuts.",
  },
]

export type ProofItem = { title: string; body: string }

export const controls: { h2: string; lead: string; proofs: ProofItem[] } = {
  h2: "Every control, for every display.",
  lead: "Candela treats external displays like the built-in one: brightness, volume, contrast and mute from the menu bar or the keys you already use.",
  proofs: [
    {
      title: "Everyday controls",
      body: "Control every panel from one menu, with native brightness wherever the display supports it.",
    },
    {
      title: "Verified at the display",
      body: "Candela checks what the monitor actually did instead of trusting an acknowledgement.",
    },
    {
      title: "HDR-aware",
      body: "Switch HDR in one click and see why a control is unavailable.",
    },
  ],
}

export const sizes: { h2: string; lead: string; proofs: ProofItem[] } = {
  h2: "The sizes macOS will not show you.",
  lead: "A 4K panel can run at many scaled sizes. System Settings offers a handful per display and hides the rest.",
  proofs: [
    {
      title: "Sharper HiDPI",
      body: "See every scaled size your panel can render, including crisp HiDPI modes System Settings hides.",
    },
    {
      title: "Safe rollback",
      body: "If a new size leaves the screen wrong, Candela restores the previous one unless you keep it.",
    },
  ],
}

// The sizes figure is measured data, not an illustration. The Dell capture
// found 177 HiDPI modes across 27 distinct logical sizes while the panel was
// rotated. These five examples transpose that record into landscape geometry.
export const sizesFigure: {
  panel: string
  sizeCount: number
  stat: string
  hiddenNote: string
  hiddenListLabel: string
  foot: string
  caption: string
  examples: string[]
} = {
  panel: "DELL U2725QE",
  sizeCount: 27,
  stat: "177 measured HiDPI modes across refresh rates.",
  hiddenNote: "distinct HiDPI sizes found",
  hiddenListLabel: "Five landscape HiDPI size examples",
  foot: "Five landscape examples. Each renders at double resolution.",
  caption: "Measured on the Dell U2725QE, shown in landscape orientation.",
  examples: [
    "3360 × 1890",
    "3200 × 1800",
    "3008 × 1692",
    "2560 × 1440",
    "2304 × 1296",
  ],
}

export const setup: { h2: string; lead: string; proofs: ProofItem[] } = {
  h2: "It configures itself to your setup.",
  lead: "On first launch Candela finds every display, asks each one what it can do, and builds the controls around the answers.",
  proofs: [
    {
      title: "Learns each panel",
      body: "Candela asks every display what it supports and builds its controls around the answers.",
    },
    {
      title: "Explains what works",
      body: "Setup shows which controls each display accepts, in plain language.",
    },
    {
      title: "Restores your setup",
      body: "Brightness, resolution and arrangement return after sleep, replugging or reboot.",
    },
  ],
}

// Two animated concept figures, not recordings. Both grids are 240 cells
// because that is what the app keeps (the trust section says so). The
// exposure figure shows the record accumulating; the dim figure shows live
// local dimming: static high-risk regions ease down, the rest stays lit,
// and a moved window lifts its old spot at once.
export const exposureDemo: {
  figureLabel: string
} = {
  figureLabel: "An animated concept grid: cells brighten over time where the screen's static habits sit, building the exposure record.",
}

export const dimDemo: {
  phases: { lit: string; settled: string }
  figureLabel: string
} = {
  phases: {
    lit: "you move the window",
    settled: "the static parts dim, the rest stays lit",
  },
  figureLabel: "An animated demonstration of live local dimming: the static regions of a screen ease down while the active window stays bright, and moving the window restores its old region immediately.",
}

// The flagship differentiator, told as one section: the record (watches), then
// the protection spending it (adapts). The old four-station loop lives on in
// here as the section's internal story.
export const protection: {
  h2: string
  lead: string
  actProofs: ProofItem[]
  watchProofs: ProofItem[]
  recordTitle: string
} = {
  h2: "Protection that adapts while you work.",
  lead: "Candela's Adaptive Pixel Dimming detects bright, unchanged regions and eases them down in place, while active content stays at full brightness.",
  actProofs: [
    {
      title: "Targets static hotspots",
      body: "Toolbars, sidebars and other bright regions ease down after they stop changing, without dimming the rest of your display.",
    },
    {
      title: "Responds as content moves",
      body: "Move a window or update a region and Candela restores it to full brightness immediately.",
    },
  ],
  watchProofs: [
    {
      title: "Maps cumulative exposure",
      body: "A local exposure grid tracks where the panel has been lit, how brightly and for how long.",
    },
    {
      title: "Attributes display time by app",
      body: "See which apps have occupied the most panel area, without Candela reading window titles or contents.",
    },
    {
      title: "Exports a portable panel record",
      body: "Take lifetime hours, exposure history and checkup runs with the display in one integrity-checked file.",
    },
  ],
  recordTitle: "See what your panel has been through.",
}

export const checkup: {
  h2: string
  lead: string
  proofs: ProofItem[]
} = {
  h2: "Checks your display for defects and wear.",
  lead: "A checkup ends in a report you keep: what the monitor claims, what Candela observes, and what your eyes confirm.",
  proofs: [
    {
      title: "Monitor reports",
      body: "Candela records the identity and capabilities the display reports about itself.",
    },
    {
      title: "Candela observes",
      body: "Mode changes and other checks are labeled by how the result was known.",
    },
    {
      title: "You confirm",
      body: "Visual tests can be missed and recorded as inconclusive. A test you cannot fail is not a test.",
    },
  ],
}

// The toolbox: real shipped features that earn a line each, not a section
// each. Set as a ledger like the trust section, never as cards.
export const more: {
  h2: string
  items: Array<{ title: string; body: string }>
} = {
  h2: "And the rest of the toolbox.",
  items: [
    {
      title: "Virtual displays",
      body: "Create a display that is not physically there, for a headless Mac or for testing.",
    },
    {
      title: "Dim past the hardware minimum",
      body: "When a monitor reaches its lowest hardware setting, Candela can keep dimming in software, all the way to black.",
    },
    {
      title: "Keep every display in sync",
      body: "Adjust every display together or keep external panels matched to the built-in display automatically.",
    },
    {
      title: "Mirroring, arrangement, rotation and refresh rate",
      body: "Mirror, rearrange and rotate displays, then choose their refresh rates without opening System Settings.",
    },
    {
      title: "Keep Display Awake",
      body: "Prevent display sleep from the menu bar until you turn it off or quit Candela.",
    },
    {
      title: "Keyboard shortcuts",
      body: "Put brightness, volume and mute on the keys you choose, including a keyboard Apple never made.",
    },
  ],
}

export const trust: {
  h2: string
  items: Array<{ title: string; body: string }>
} = {
  h2: "The record is yours, and only yours.",
  items: [
    {
      title: "Stays on your Mac",
      body: "No account, no server and no upload. Screen samples are discarded as soon as Candela has the local exposure reading. The website records only page views and downloads.",
    },
    {
      title: "Measured overhead",
      body: "Every background feature has a measured performance budget. If it misses, it ships turned off.",
    },
    {
      title: "Free and open source, forever",
      body: "Candela is MIT licensed, and the entire app is public. There is no paid tier waiting behind a later version.",
    },
  ],
}

// Heading for the FAQ section: a wayfinding label, not a lead.
export const faqH2 = "FAQ"

export const faq: Array<{ q: string; a: string }> = [
  {
    q: "How is this different from MonitorControl or BetterDisplay?",
    a: "MonitorControl handles daily controls well, while BetterDisplay is a deeper display toolbox. Candela's difference is the care layer: exposure maps, active OLED protection, checkups, and a record of panel use. If you run two display utilities, let only one control a panel's hardware settings.",
  },
  {
    q: "What do I need to run it?",
    a: "macOS 14 Sonoma or later on an Apple Silicon Mac. Most DisplayPort, HDMI and USB-C connections carry the display controls Candela needs, but some docks and adapters block them. Diagnostics shows what each connected display supports.",
  },
  {
    q: "What permissions does it ask for, and why?",
    a: "Accessibility lets your keyboard's brightness and volume keys control external displays. Screen Recording is optional and makes the exposure map more precise. Without it, the map still builds from other inputs and Candela labels which reading you are seeing. Nothing is uploaded.",
  },
  {
    q: "My monitor ignores every read. Does it still work?",
    a: "Yes. Some monitors accept changes but report no useful values. Candela keeps the last value it successfully wrote and labels it as last written, never measured. Checkup marks unanswered questions as not observed instead of inventing a result.",
  },
]

export const footer: { note: string } = {
  note: "Candela is free and open source, MIT licensed.",
}
