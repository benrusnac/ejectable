# Contributing

Thanks for helping. Ejectable is small on purpose: one menu-bar app, one engine (`EjectKit`), one CLI harness
(`ejectctl`). Bug reports with an `actions.log` excerpt (`~/Library/Logs/Ejectable/`) and the output of
`build/ejectctl scan /Volumes/NAME` are the most useful thing you can send.

## Build and test

```sh
swift build                 # debug
swift test                  # all tests (a few minutes; creates and detaches small disk images)
ARCHS=arm64 ./build.sh run  # release app bundle, launched from build/
```

Requirements: macOS 14 or later, Xcode 26 / Swift 6.2 or later.

## Tests use fixtures only

Every test that mounts, ejects, signals or quits something works on throwaway disk images and processes it created
itself (`Tests/fixtures/make-busy-volume.sh`, `Tests/fixtures/make-test-app.sh`). Tests must never unmount, eject or
write to a real disk or a network share, and never signal a process they did not spawn. Tests that only *read* a real
external disk skip when none is mounted. On CI (`CI=true`) the DiskArbitration timing tests and the GUI test-app tests
skip as well; run the full suite locally before sending a change to those areas.

## Safety rules

The app can lose people's footage if it gets this wrong, so the safety rules in [docs/PLAN.md §4b](docs/PLAN.md#4b-safety-rules-non-negotiable-every-builder-and-reviewer-checks-these)
(S1–S10) are not negotiable: soft eject is the only automatic action, Force Eject is always a separate confirmed step,
nothing is forced without a click, system daemons are never signalled (Quick Look excepted), pids are re-verified before
any signal, and every action is logged.

## Pull requests

- Keep each PR to one change, with a short description of what and why.
- A change to any guard (anything that decides whether to eject, force, quit or signal) comes with a test that fails
  without it.
- `swift build -c release` must stay at 0 warnings (Swift 6 language mode, strict concurrency).
- No SwiftUI (it adds about 30 MB to a menu-bar app), no third-party dependencies, no sandbox (a sandboxed app can't
  see other processes).
- User-facing text: short, plain, no jargon; say what will happen and what it costs.
