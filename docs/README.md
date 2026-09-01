# What is in `docs/`

Three things. `guide/` is written for people using the app; the other two are
references for anyone reading or changing the code. The rest of the user-facing
documentation is the repository README and the site.

| path | what it is |
|---|---|
| `guide/` | The user guides: resolutions, OLED care, the checkup, diagnostics, and the settings that have no user interface. `guide/index.md` is the entry point, and the repository README links to it. |
| `ADVANCED-SETTINGS.md` | Settings with no user interface, driven by `defaults write`, plus the reserved key names that deliberately do nothing yet. |
| `conformance/` | Committed baselines for the platform-conformance and regression suites. Diff a fresh run against these after a macOS update. |

Hardware verification is not published here. Every feature is checked on the
development panels before it merges, and the maintainers keep the measured
records. `CONTRIBUTING.md` says what a change is expected to state about its own
verification, and `tools/hardware-pass/` holds the scripts that drive a run.

## A note on the ruling IDs and the `#N` numbers

Short tags like `D26`, `A1` and `SS10` appear in a few files here and under
`tools/`. Each is a handle for one design decision, named so a line of reasoning
can be traced back to where it was settled. The documents they point into are
not public.

Issue numbers written as `#94` or `#53` turn up the same way, mostly under
`tools/`. **They refer to the project's private development tracker**, which is
frozen, and they do not resolve against this repository's issue tracker, whose
numbering starts again at 1.

Both kinds are kept rather than stripped because they are the provenance of
measured results: a line saying a display's power register took a panel offline
for twenty minutes is worth more when the record of that session still has a
name. Nothing here requires following one to be understood, and where a citation
was carrying a fact rather than a pointer, the fact has been written out in
place.
