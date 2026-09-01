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
  sub: "Your monitor is the most expensive thing on your desk that nothing takes care of. Candela watches its health, protects it from burn-in, checks it for defects and wear, and handles the everyday controls the way macOS should have.",
  ctaPrimary: "Download Candela",
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
  copyLabel: string
} = {
  cmd: "brew install --cask rydersel/tap/candela",
  hint: "click to copy",
  copied: "copied",
  copyLabel: "Copy the Homebrew install command",
}

// Accessible name for the feature band's nav landmark; screen readers speak it.
export const glanceLabel = "What Candela does"

// MediaFrame's pause control labels.
export const mediaPause = "Pause"
export const mediaResume = "Play"

// The five-second read: every key feature, one line each, in the order the
// deep sections tell them. Most visitors never scroll past this band, so it
// has to be the whole app in miniature.
export const glance: Array<{
  id: "controls" | "sizes" | "setup" | "protection" | "checkup" | "more"
  title: string
  line: string
}> = [
  {
    id: "controls",
    title: "Controls",
    line: "Brightness, volume and contrast for every display, from the menu bar or your keys.",
  },
  {
    id: "sizes",
    title: "Sizes",
    line: "The scaled resolutions macOS hides, for crisper text on 4K panels.",
  },
  {
    id: "setup",
    title: "Setup",
    line: "Finds your displays and learns what each one can do.",
  },
  {
    id: "protection",
    title: "Protection",
    line: "Maps every hour on your panel and dims what sits static, live.",
  },
  {
    id: "checkup",
    title: "Checkup",
    line: "Checks a display for defects and wear, on the record.",
  },
  {
    id: "more",
    title: "And more",
    line: "Virtual displays, HDR, mirroring, arrangement, shortcuts.",
  },
]

export const controls: { h2: string; lead: string; body: string[] } = {
  h2: "Every control, for every display.",
  lead: "macOS gives an external monitor almost nothing: no brightness key, no volume key, no mute. Candela treats your external displays the way macOS treats the built-in one.",
  body: [
    "Brightness, volume, contrast and mute over DDC, from the menu bar or the keys already on your keyboard; native brightness where the panel supports it. Careful means checked: Candela verifies what the display achieved instead of trusting the acknowledgement it got back, because monitors do acknowledge commands they then ignore.",
    "HDR is a first-class state, not an error. Candela shows when HDR has the panel, switches it in one click, and tells you why a control went quiet instead of leaving you guessing. Most display utilities act as if HDR does not exist.",
  ],
}

export const sizes: { h2: string; lead: string; body: string[] } = {
  h2: "The sizes macOS will not show you.",
  lead: "A 4K panel can run at many scaled sizes. System Settings offers a handful per display and hides the rest.",
  body: [
    "On a high-density display the difference between sizes is not just how big things are, it is how sharp: a HiDPI size renders at double resolution and scales down, so text comes out crisp where a plain low-resolution mode comes out soft. The size you actually want is often one macOS never offers.",
    "Candela lists every size your display can do, including HiDPI sizes macOS synthesizes for its own displays but withholds from yours, and applies them with a way back: if a change leaves the screen wrong, it reverts on its own unless you keep it.",
  ],
}

// The sizes figure is measured data, not an illustration: the probe's curated
// picker list for the MAG, read 2026-08-31 (95 modes -> 16 rows, 5 revealed).
// Every row and framebuffer below is transcribed from that run. If the list
// is ever re-measured, update the caption's date with it.
export const sizesFigure: {
  panel: string
  stat: string
  hiddenNote: string
  foot: string
  caption: string
  rows: Array<{ size: string; hidden?: boolean }>
} = {
  panel: "MAG 341C OLED",
  stat: "16 sizes from 95 modes",
  hiddenNote: "hidden by macOS",
  foot: "The lit sizes render at double resolution.",
  caption: "The real size list for the MAG 341C OLED.",
  rows: [
    { size: "3440 × 1440" },
    { size: "2560 × 1440" },
    { size: "2048 × 858", hidden: true },
    { size: "1920 × 1080" },
    { size: "1920 × 804", hidden: true },
    { size: "1720 × 720" },
    { size: "1680 × 1050" },
    { size: "1600 × 1200" },
    { size: "1600 × 670", hidden: true },
    { size: "1440 × 900" },
    { size: "1344 × 1008" },
    { size: "1344 × 562", hidden: true },
    { size: "1280 × 1024" },
    { size: "1280 × 960" },
    { size: "1280 × 720" },
    { size: "1280 × 536", hidden: true },
  ],
}

export const setup: { h2: string; lead: string; body: string[] } = {
  h2: "It configures itself to your setup.",
  lead: "On first launch Candela finds every display, asks each one what it can do, and builds the controls around the answers.",
  body: [
    "The setup says what it found in plain terms: which panel takes brightness and volume, which display refuses a control, which one is an OLED that deserves protection. When a monitor answers nothing at all, Candela says that too, and still drives it.",
    "It also keeps your setup configured: brightness, resolution and arrangement come back after a sleep, a replug or a reboot, instead of resetting to whatever macOS remembered.",
  ],
}

// Two animated concept figures, not recordings. Both grids are 240 cells
// because that is what the app keeps (the trust section says so). The
// exposure figure shows the record accumulating; the dim figure shows live
// local dimming: static high-risk regions ease down, the rest stays lit,
// and a moved window lifts its old spot at once.
export const exposureDemo: {
  caption: string
  figureLabel: string
} = {
  caption: "Weeks of use, cell by cell: the regions your habits keep lit build the brightest record.",
  figureLabel: "An animated concept grid: cells brighten over time where the screen's static habits sit, building the exposure record.",
}

export const dimDemo: {
  phases: { lit: string; settled: string }
  caption: string
  figureLabel: string
} = {
  phases: {
    lit: "you move the window",
    settled: "the static parts dim, the rest stays lit",
  },
  caption: "What sits still eases down: the menu bar, a title bar, the dock. What you are using stays at full brightness, and any change lifts its region back at once.",
  figureLabel: "An animated demonstration of live local dimming: the static regions of a screen ease down while the active window stays bright, and moving the window restores its old region immediately.",
}

// The flagship differentiator, told as one section: the record (watches), then
// the protection spending it (adapts). The old four-station loop lives on in
// here as the section's internal story.
export const protection: {
  h2: string
  lead: string
  actBody: string[]
  watchBody: string[]
  recordTitle: string
  sideClause: string
} = {
  h2: "Protection that works while you do.",
  lead: "OLED wear happens where the picture does not move. Candela's answer is live and local: the static, high-risk parts of the screen ease down while everything you are using stays at full brightness.",
  actBody: [
    "The parts of the screen that sit static and high risk, a menu bar untouched for an hour, a window's title bar, the dock, ease down on their own. Everything you are actually using stays exactly as bright as you set it.",
    "The moment those pixels change, moving the window is enough, the region lifts back at once. It is the part other display apps do not have.",
    "And protection that could hurt the panel does not ship: one power command was built, hardware tested, and cut after it took a real monitor down.",
  ],
  watchBody: [
    "Underneath sits the record your monitor will never keep for you: which regions of the panel have been lit, how brightly, and for how long. The exposure map is a grid laid over the panel, and every cell accumulates the light it has actually shown.",
    "A menu bar that never moves, a dock, the window that lives in the same corner every day: give it a few weeks and your own habits are sitting there on the map. No monitor firmware will hand you this; if the record is going to exist, something on your Mac has to keep it.",
  ],
  recordTitle: "See what your panel has been through.",
  sideClause: "Dimming while you are away also trims the power draw.",
}

export const checkup: {
  h2: string
  lead: string
  body: string[]
} = {
  h2: "Checks your display for defects and wear.",
  lead: "A checkup is a scripted run across the panel that ends in a report you keep: what the monitor claims, what it actually does, and what your eyes confirm.",
  body: [
    "The run works through what can be checked: DDC readbacks, mode changes, a refresh-rate sweep, the identity block where the monitor names its own make and model, and test fields for the things only your eyes can judge. Every line in the report carries how it was known: observed, refused, not observed, or self-reported.",
    "For the checks that need your eyes, the run plants something faint that is definitely there. Miss it and the session records as inconclusive. A test you cannot fail is not a test.",
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
      title: "Mirroring and arrangement",
      body: "Mirror one display onto another and rearrange the layout without opening System Settings.",
    },
    {
      title: "Keyboard shortcuts",
      body: "Put brightness, volume and mute on the keys you choose, including a keyboard Apple never made.",
    },
    {
      title: "A menu bar app, properly",
      body: "Lives in the menu bar, launches at login if you ask, and puts nothing in the Dock.",
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
      title: "The exposure data never leaves your Mac",
      body: "No account, no server, nothing to opt out of. When Candela samples the screen it keeps 240 numbers, one brightness per cell, and discards the frame inside the function that asked for it. This page holds the same line: the site keeps two totals, page views and downloads, and that is the whole of it.",
    },
    {
      title: "Light on the machine",
      body: "Every background feature in Candela carries a measured budget it has to hit, and a feature that misses its budget ships turned off. The receipts are ten seconds away: open Activity Monitor and look.",
    },
    {
      title: "Free and open source, forever",
      body: "MIT licensed, and the whole repository is public: the engine, the hardware notes, the arguments about what to cut and why. No paid tier waiting behind a later version.",
    },
    {
      title: "Some of this rests on private macOS APIs",
      body: "Parts of Candela go through interfaces Apple does not document and can change in any macOS release. Every release gets a conformance run over those paths, and the built-in updater turns a break into a fix that reaches you.",
    },
  ],
}

// Heading for the FAQ section: a wayfinding label, not a lead.
export const faqH2 = "Questions"

export const faq: Array<{ q: string; a: string }> = [
  {
    q: "How is this different from MonitorControl or BetterDisplay?",
    a: "Both are good, and neither is trying to do this. BetterDisplay is the deepest display toolbox on the Mac, and if virtual screens and resolution surgery are what you need, that is the app to use; Candela sits beside it. MonitorControl stands on the same free and open source ground Candela does, and it does the daily controls well. The difference is the care layer: the exposure map, the protection, the checkup, the record of what your panel has been through. Other display apps adjust settings in the moment. Candela stewards your display over its lifetime, and does the settings too. One caution whichever pair you run: only one app should write DDC to a panel at a time, so leave the controls on in one of them and off in the other.",
  },
  {
    q: "What do I need to run it?",
    a: "macOS 14 Sonoma or later, on an Apple Silicon Mac. The build ships arm64 only. External displays are what Candela is for, and it reaches their hardware controls over DDC, which most DisplayPort, HDMI and USB-C connections carry; some docks and adapters drop it, and the Diagnostics page tells you which path each display is actually on and what it answered. The built-in display gets its own pane for the parts that apply to it.",
  },
  {
    q: "What permissions does it ask for, and why?",
    a: "Accessibility, if you want the brightness and volume keys on your keyboard to reach an external display. Screen Recording is optional: it lets Candela sample what the panel is showing, which makes the exposure map sharper. Decline it and the map still builds from inputs that need no permission, and the app says which reading you are looking at. Nothing is uploaded under either answer.",
  },
  {
    q: "My monitor ignores every read. Does it still work?",
    a: "Yes, and it is one of the cases the app was designed around. One of the two panels this app is developed on takes every DDC write and answers every read with zeros: no brightness readback, no capabilities string, nothing at all. Candela tracks what it wrote, keeps it across restarts, and labels it a last-written value instead of dressing it up as a measurement. In a checkup, Candela records the questions your panel cannot answer as not observed, in those words, never as a blank and never as an invented number.",
  },
]

export const footer: { note: string } = {
  note: "Candela is free and open source, MIT licensed.",
}
