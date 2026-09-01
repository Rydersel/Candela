# Advanced settings

Candela's Settings window offers the decisions a person can actually make. A
handful of knobs exist for hardware that misbehaves in ways no sensible default
covers, and those are set with `defaults write` instead of a control. They are
not deprecated and they are not experimental: each one has an engine path,
tests, and a documented effect. Keeping them out of the window is a decision
about who they are for, not about whether they work.

The full reference, with every key, its type, its default and exactly what it
changes, is [`docs/ADVANCED-SETTINGS.md`](../ADVANCED-SETTINGS.md). Read that
page before setting anything; each entry states the conditions under which the
key does nothing, which is usually the reason a change looks ignored. Several
keys now also have a control in the settings window, and the reference names
which control owns each one. The key still works, and it remains the only way
to reach values the control deliberately does not offer.

Two things are worth knowing before you start. **Per-display keys end in a
persistence key**, the display's own identity, and the reference shows two ways
to find it (`swift run candela-probe list`, or `defaults read
com.rydersel.Candela` to see every key Candela has written). **Quit and
relaunch Candela after any `defaults write`.** Every setting is read fresh at
the moment it is used, so the running app can pick up an outside write on its
own; what it cannot do is react to one. Edits made in the settings window carry
a signal that re-arms the key tap, re-applies dimming and rebuilds the menu bar
as needed, and a write from the command line arrives with no such signal. A
relaunch removes the distinction.

A second list at the end of the reference covers names that are **reserved and
do nothing**. They are documented so that nobody sets one, sees no effect, and
concludes the app is broken.
