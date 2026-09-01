# What is in `docs/`

Candela's engineering record. These are working documents rather than user
documentation: measured facts about macOS display behaviour, the hardware passes
that produced them, and the findings from the spikes that decided what got built.
The user guides in `guide/` are the exception: they are written for people using
the app. The rest of the user-facing documentation is the repository README and
the site.

## A note on the `#N` numbers and the ruling IDs

Almost every file here, and several under `tools/`, cites issues as `#94`, `#53`,
`#186`, and so on. **Those numbers refer to the project's private development
tracker**, which is archived as `Rydersel/candela-dev` and frozen. They do not
resolve against the public repository's issue tracker, whose numbering starts
again at 1.

They are kept rather than stripped because they are the provenance of measured
results: a line saying a display's power register took a panel offline for twenty
minutes is worth more when the record of that session still has a name. Nothing in
these documents requires following one to be understood, and where a citation was
carrying a fact rather than a pointer, the fact has been written out in place.

Short tags like `D29`, `AR12` and `SS1` are the same kind of handle for design
decisions rather than issues. Each names one ruling in the design document for
that feature, kept so a line of reasoning can be traced back to where it was
settled. They are internal, and, like the issue numbers, nothing here needs one
followed to be read.

## User guides

| folder | what it is |
|---|---|
| `guide/` | The user guides: resolutions, OLED care, the checkup, diagnostics, and the settings that have no user interface. `guide/index.md` is the entry point, and the repository README links to it. |

## Hardware verification

| file | what it is |
|---|---|
| `VERIFICATION-STATUS.md` | The register of what is and is not verified against real panels, feature by feature, with the date and method for each. Start here. |
| `CHECKPOINT-1-HARDWARE.md` | The first consolidated hardware checklist: 133 items grouped by physical action. Completed 2026-08-13. |
| `CHECKPOINT-1-RESULTS.md` | What each of those items actually measured, session by session. |
| `CHECKPOINT-2-HARDWARE.md` | The 1.0 release audit: everything about the release that only a person and real monitors can settle. Named for the checkpoint numbering so it reads beside Checkpoint 1. |
| `M5-HARDWARE-CHECKLIST.md` | The predecessor checklist, from the settings and preferences milestone that ran before the consolidated checkpoints existed. Its unrun items were folded into Checkpoint 1. |
| `verification-ledger/` | One JSON record per automated regression run against the rig, plus a README explaining the format. |
| `conformance/` | Committed baselines for the platform-conformance and regression suites. Diff a fresh run against these after a macOS update. |
| `exposure-probe-run-card.md` | The run card for the exposure-model measurement probe. |

## Measured facts and techniques

| file | what it is |
|---|---|
| `ENGINEERING-NOTES.md` | Hard-won display-control technique: what works, what silently does not, and what must never be sent to a panel. |
| `ADVANCED-SETTINGS.md` | Settings with no user interface, driven by `defaults write`, plus the reserved key names that deliberately do nothing yet. |
| `FEATURE-INVENTORY.html` | A rendered inventory of the app's features. |

## Investigations

| folder | what it is |
|---|---|
| `spikes/` | Time-boxed investigations, each closing on a findings document with a verdict: go, cut, conditional, or needs-hardware. Several carry raw data and scratch harnesses alongside the writeup. |
| `research/` | Background surveys written before a feature was designed, mostly about how macOS actually behaves in an area. |
