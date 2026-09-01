## What

<!-- What this changes, in a sentence or two. -->

## Why

<!-- The problem it solves. Link the issue if there is one. -->

## Hardware verification

<!--
Anything that touches display behaviour needs to say how it was checked on a
real display: which monitor, which connection, and what you observed. A DDC
write acknowledgement is not evidence; state the achieved state you read back
or saw. If the change is hardware-free, say so and name the tests that cover it.
-->

## Checks

- [ ] `make check` passes (engine and app suites)
- [ ] Tests cover the new logic, or it is hardware-only and says so above
- [ ] No ticket numbers in source comments, and no em dashes in user-visible
      text or new comments
