// Every user-visible string on candela.fyi. Components import from here and
// hold no copy of their own, so the two gates run in one place: the product's
// copy filter on every lead, and an editing pass on all of it (SR15).
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
  ctaPrimary: "Download for macOS",
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
  guides: "Guides",
  faq: "FAQ",
  github: "GitHub",
  download: "Download",
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
    line: "Dims an idle OLED and records where it gets lit.",
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
    line: "Every sharp HiDPI size macOS does not list.",
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
  h2: "The sizes macOS does not list.",
  lead: "A 4K panel can run at many scaled sizes. System Settings offers a handful per display, and Candela finds the rest.",
  proofs: [
    {
      title: "Sharper HiDPI",
      body: "See every scaled size your panel can render, including sharp HiDPI modes System Settings does not list.",
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
  lead: "Candela dims an enrolled OLED when you step away, and records where it has been lit. Switch on automatic static-region dimming and it also eases down bright, unchanged regions in place while you work, leaving active content at full brightness.",
  actProofs: [
    {
      title: "Targets static hotspots",
      body: "With that switch on, toolbars, sidebars and other bright regions ease down after they stop changing, without dimming the rest of your display.",
    },
    {
      title: "Responds as content moves",
      body: "Move a window or update a region and Candela restores it to full brightness immediately.",
    },
  ],
  watchProofs: [
    {
      title: "Maps cumulative exposure",
      body: "A local exposure grid tracks where the panel has been lit and for how long. Turn on measurement and it records how brightly, from real screen readings.",
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
      body: "No account, no app telemetry and no upload. Screen samples are discarded after Candela makes the local exposure reading. First-party website analytics are explained and controllable on Privacy.",
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
    q: "My monitor has its own OLED care. Isn't that enough?",
    a: "Keep it on; Candela never touches it. Pixel shift, static-screen dimming and the refresh cycle are the only protections that run inside the panel. But the monitor only sees a video signal. It cannot tell your Dock from a still photo, whether you are at the desk, or which display you are looking at, so it has to dim cautiously, and it keeps no record you can read. Candela works from what the Mac knows, so it can protect harder without getting in your way, and it shows you where the wear is going. Seatbelt and airbag: different situations, and you want both.",
  },
  {
    q: "What do I need to run it?",
    a: "macOS 14 Sonoma or later on an Apple Silicon Mac. Most DisplayPort, HDMI and USB-C connections carry the display controls Candela needs, but some docks and adapters block them. Diagnostics shows what each connected display supports.",
  },
  {
    q: "What permissions does it ask for, and why?",
    a: "Accessibility lets your keyboard's brightness and volume keys control external displays. Screen Recording is optional and is what turns on measured exposure sampling. Without it, a display you enroll still records its hours and which app held which part of it, and the heat map waits for real readings rather than drawing an estimate. Nothing is uploaded.",
  },
  {
    q: "My monitor ignores every read. Does it still work?",
    a: "Yes. Some monitors accept changes but report no useful values. Candela keeps the last value it successfully wrote and labels it as last written, never measured. Checkup marks unanswered questions as not observed instead of inventing a result.",
  },
]

export const footer: { note: string } = {
  note: "Candela is free and open source, MIT licensed.",
}

// Guides: for people who arrive with a question and no idea Candela exists. The
// lead is the section's first sentence, so the copy filter binds it.
export const guides: {
  kicker: string
  h1: string
  lead: string
  listLabel: string
  updated: string
  tryPillars: string[]
  more: string
} = {
  kicker: "Candela",
  h1: "Guides",
  lead: "What wears a panel, how to check a display for defects, and how to get the controls macOS leaves out. Written for anyone with a display on a Mac, whether or not they ever install Candela.",
  listLabel: "Guides",
  updated: "Updated",
  tryPillars: ["Panel health", "Burn-in protection", "Monitor checkup", "Every control"],
  more: "More guides",
}

export const privacy = {
  h1: "Privacy, without the vague parts.",
  lead: "Candela's website analytics are anonymous to Candela and first-party only. A random, short-lived cookie distinguishes one browser for 24 hours so we can count visits and whether that browser chooses Download or GitHub. There are no cross-site cookies.",
  control: "Website analytics are enabled by default. Opting out stops both Candela's first-party funnel and Cloudflare Web Analytics in this browser. You can opt back in at any time.",
  app: "The Candela app performs display analysis locally. It requires no account, sends no screen samples to Candela, and uploads no display-health record. Its one request to candela.fyi is the update check, which names the app's version and nothing about you or your display. The site counts those checks by app version and day, keeps no address and sets no cookie. The browser opt-out above does not reach the app. Turning off automatic checks in the app's About pane stops the scheduled request; pressing Check for Updates still fetches the feed, and that check is counted too.",
  does: [
    "Counts pageviews and anonymous 24-hour browser windows.",
    "Counts the app's update checks by app version and day. That is the request Sparkle already makes for the update feed; nothing is added to it, and the version is the only thing read from it.",
    "Counts Download attempts and GitHub clicks, including which header, hero, footer or guide link was used, or whether the download came from the GitHub README's button.",
    "Records coarse country, device category and external referrer hostname.",
    "Produces anonymous daily statistics and operational counts.",
    "Keeps a charting copy of the same counts (event, placement, country and device category for the website; app version alone for update checks) in Cloudflare's Workers Analytics Engine, which expires on its own after about 90 days.",
    "Uses one host-only measurement cookie restricted to candela.fyi.",
  ],
  doesNot: [
    "Identify a human or create an account or personal profile.",
    "Store IP addresses, full user agents, fingerprints or advertising identifiers.",
    "Record full URLs, query strings, referrer paths, scrolling or interaction histories.",
    "Follow a browser across websites, sell data, share it for advertising or use cross-site cookies.",
    "Upload display information collected by the Candela app.",
  ],
  retention: [
    "The random measurement cookie expires after 24 hours. It contains no name, account, email, IP address, fingerprint or advertising identifier, and it is never sent to another website.",
    "A one-way derived browser-window key is retained for seven days so completed visit-to-action cohorts can be counted. The raw random cookie value is never stored in the database. After seven days, linkable rows are deleted and only thresholded anonymous totals remain. Groups smaller than ten browser windows are folded into other.",
    "A 24-hour browser window is not a person. Two browsers on one Mac count separately, and a returning browser receives a new random window after the prior one expires. Anonymous totals already produced cannot be traced back to a browser and cannot be selectively removed.",
    "The app's update checks are daily totals by version and nothing else: no address, no cookie, no browser-window key, so nothing in them points back to a particular install. The charting copy expires after about 90 days; the daily totals are anonymous and are kept.",
  ],
  source: "Candela is public, including the analytics implementation. The Functions, schema, retention Worker, report command and this disclosure can all be inspected in the source code.",
}

// Terms: for a stranger deciding whether to trust a download from an
// independent developer.
export const terms = {
  kicker: "Candela website and app",
  h1: "Terms, in plain words.",
  lead: "Candela is made and published by Ryder Selikow, an independent developer. These terms cover candela.fyi, the downloads it links to, and the update feed the app checks. The app itself is open source under the MIT license, which is the document that governs copying, changing and redistributing it.",
  effective: "Effective 2 September 2026.",
  who: {
    h2: "Who is behind Candela",
    body: [
      "Ryder Selikow, working independently, not a company. The source code, the release history and every hardware finding behind the app are public at github.com/Rydersel/Candela.",
      "Questions, problems and requests go to ryder@candela.fyi. Security reports have their own path, described in the repository's SECURITY.md.",
    ],
  },
  license: {
    h2: "The software is MIT licensed",
    body: [
      "Candela is free. There is no paid tier, no account and no subscription, and nothing on this site asks you to create one. You may use, copy, modify and redistribute the app under the MIT license, whose full text ships with every download and sits in the repository as LICENSE. Portions derived from other open source projects are credited in THIRD-PARTY-LICENSES.md.",
      "The MIT license is the legal document for the software. Where these terms and the license say different things about the software, the license wins.",
    ],
  },
  hardware: {
    h2: "Your display hardware",
    body: [
      "Candela changes settings on your monitor. It sends DDC/CI commands over the display cable to adjust brightness, contrast, volume, input and related controls, applies software dimming, can create virtual displays, and records how your panel is used so it can report wear. By running it, you accept that it will change what your display is doing.",
      "Monitors implement DDC/CI inconsistently. Some ignore commands, some report values they do not honour, and some misbehave. Candela is built to verify what actually happened and to be reversible: Safe Mode exists, risky changes ask for confirmation and revert on their own, and one feature was removed before release because it could blank a panel with no recovery from inside the app. That is care, not a guarantee. Candela cannot promise how a given display will respond, and you use it with your own hardware at your own risk.",
    ],
  },
  countOn: {
    h2: "What you can count on",
    items: [
      "No account, no sign-in and no payment, on this site or in the app.",
      "Display analysis runs on your Mac. The app uploads no screen content and no display-health record.",
      "Downloads come only from the GitHub release page and the Homebrew tap, signed with a Developer ID and notarized by Apple.",
      "The website's analytics are first-party and anonymous, and you can turn them off. The Privacy page describes exactly what is recorded.",
    ],
  },
  agreeTo: {
    h2: "What you agree to",
    items: [
      "You use the app and the site as they are, with your own hardware, at your own risk.",
      "You follow the MIT license when you copy, change or redistribute the software.",
      "You do not present a modified build as the official Candela release, and you do not use the site or the app to break the law or someone else's rights.",
      "You do not attack, scrape or overload candela.fyi, including its analytics and update endpoints.",
    ],
  },
  updates: {
    h2: "Updates",
    body: [
      "The app checks candela.fyi for new versions. That request carries no account and no information about your display. The site counts those checks by app version and day so it can see which versions are still in use; the Privacy page describes it in full. Each update is signed with a key the app verifies before installing, is notarized by Apple before it is published, and the app asks before installing one.",
    ],
  },
  warranty: {
    h2: "No warranty, and the limits of liability",
    body: [
      "Candela and candela.fyi are provided as they are, without warranty of any kind, express or implied, including any warranty of merchantability, fitness for a particular purpose and non-infringement. To the extent the law allows, Ryder Selikow is not liable for any claim, damage or other liability arising from the software or the site, including damage to a display or other hardware, whether in contract, tort or otherwise. This restates the MIT license's disclaimer in plain words; the license text controls for the software.",
    ],
  },
  site: {
    h2: "The website",
    body: [
      "candela.fyi exists to describe the app, link to its downloads and host the update feed. Its pages, guides and images are written by the developer and may change or be removed at any time. The Candela name and icon identify this project and its official releases.",
    ],
  },
  changes: {
    h2: "Changes to these terms",
    body: [
      "This page can change. The effective date above moves when it does, and because the site lives in the public repository, every revision is in the commit history with its reason. Continuing to use the site or the app after a change means the current terms apply.",
    ],
  },
  source: "This page is part of the public repository, next to the license, the third-party credits and the security policy it refers to.",
}
