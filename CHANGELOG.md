# Changelog

All notable changes to Ejectable are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-10-22

Initial public release. (Developed under the working name DriveUser.)

### Added

- Menu-bar app (pure AppKit, no SwiftUI, about 50 MB idle, 0% CPU) listing external drives and disk images; click one
  to eject the whole disk, Eject All, and a Network section to disconnect SMB/AFP shares.
- Its own holder scan of every process (open files, working directories and memory-mapped files, about 130 ms),
  including the mmap holders that Apple's dialog and `proc_listpidspath` miss on APFS and exFAT.
- In-use alert with one row per holder: the app or process, the file it holds, an orange "writing" tag for writers,
  and the row's own action (Quit, Stop, Open Spotlight Settings, Open Time Machine, Quit Photos…).
- Per-kind quit grace with a countdown (apps 60 s, helpers 15 s, app extensions 3 s, command-line tools 5 s); the
  row's Force Quit / Force Stop / Kill is revealed on hover or Tab during the grace and becomes the row's button after.
- Automatic soft-eject retry every second while the alert is open; "Ejected NAME" in the menu bar when done, with a
  reminder when a video editor is still running.
- Finder-companion mode ("Watch Finder ejects"): when another app's eject or unmount fails, Ejectable shows its alert
  beside Apple's without taking focus, and finishes only what was asked (an unmount stays an unmount).
- Remedies for holders that can't be quit: Spotlight, Time Machine, Quick Look, Finder's AirDrop / share sheet,
  terminal working directories, Photos and Music helpers, sync and backup agents, antivirus scanners.
- Force Eject as a separate, confirmed step with a safe / risky / unavailable rating; disabled while anything writes
  to the disk, while Time Machine backs up to it (or its state is unknown), or when the scan is incomplete.
- Launch at Login (`SMAppService`), About window with the log folder.
- Action log at `~/Library/Logs/Ejectable/actions.log` (0600, rotated at 1 MB) and in the unified log
  (subsystem `com.benrusnac.ejectable`).
- `ejectctl` command-line harness: `volumes`, `scan`, `eject` (disk images only unless `--real`), `topology`, `disk`,
  `state`, `watch`.
- 130 tests against small APFS, HFS+ and exFAT disk images created by `Tests/fixtures/make-busy-volume.sh`.

[Unreleased]: https://github.com/benrusnac/ejectable/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/benrusnac/ejectable/releases/tag/v0.1.0
