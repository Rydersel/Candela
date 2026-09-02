# What is in `docs/`

`guide/` and `HARDWARE.md` are written for people using the app;
`ADVANCED-SETTINGS.md` is a reference for anyone reading or changing the code.
The rest of the user-facing documentation is the repository README and the
site.

| path | what it is |
|---|---|
| `guide/` | The user guides: resolutions, OLED care, the checkup, diagnostics, and the settings that have no user interface. `guide/index.md` is the entry point, and the repository README links to it. |
| `ADVANCED-SETTINGS.md` | Settings with no user interface, driven by `defaults write`, plus the reserved key names that deliberately do nothing yet. |
| `HARDWARE.md` | The tested hardware table: monitors, connections and Macs, one row per hardware report, with what worked on each. |

Hardware verification is not published here. Every feature is checked on real
displays before it merges, and `CONTRIBUTING.md` says what a change is expected
to state about its own verification. `tools/hardware-pass/` holds the scripts
that drive a run.
