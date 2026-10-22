# Ejectable — design plan

The plan the app was built from: what is possible, product behaviour, architecture, phases and the safety rules (§4b) every change is checked against. Status notes at the end.

Lightweight native macOS menu-bar utility for video editors. When a big external drive won't eject, it shows exactly who is holding it (with file names), lets you quit those apps in place, re-tries the eject automatically, and when nothing quittable is holding it, tells you what is (Spotlight, Time Machine, Quick Look…) and offers a safe path down to Force Eject.

Full recon facts: [recon/RECON.md](recon/RECON.md). Verified reference code: [recon/reference/](recon/reference/).

## 1. What is and isn't possible

- **Apple's dialog cannot be edited or suppressed.** It is drawn by `UnmountAssistantAgent` (SIP-protected). We cannot "update this window".
- **We can react to it.** DiskArbitration tells our app the moment any process (Finder included) tries to unmount a volume. We scan holders in ~130 ms and show our own alert, styled like Apple's, right as Apple's appears. Apple's stays until dismissed; ours has the actions.
- **We can also own the eject.** Menu-bar list of drives → click → our flow. No Apple dialog at all.
- **Why Apple's dialog says "one or more programs":** the holder is not a GUI app. Usually a daemon (`mds`, `backupd`), an app extension (`AirDrop.appex`, `QuickLookUIService`) or a helper. During recon `AirDrop.appex` had two JPEG stills memory-mapped on the test SSD; that was the cause of the dialog that started this project. Apple's agent and stock `proc_listpidspath` both miss mmap holders on APFS (libproc 32/64-bit fsid bug). Our custom scan catches them.
- **v1 limit:** root-owned daemons (`mds`, `fseventsd`, `backupd`) are invisible to an unprivileged scan and cannot be killed. The DA dissenter pid may still name one (DA runs as root), and `proc_pidpath` works on root pids, so we can usually say "Spotlight is indexing" even when we can't act. Acting on them needs a privileged helper → v2.

## 2. Product behaviour

### Menu bar
- `NSStatusItem` with `externaldrive` SF Symbol. Menu rebuilt on open:
  - External drives (not internal, local, browsable): icon + name, click = eject. Shows "● 2 apps" suffix when holders known from last scan.
  - "Eject All"
  - Network shares (SMB) in a second section, action "Disconnect". Default on; toggle in menu.
  - Launch at Login (toggle), Quit.
- Idle: 0% CPU, ~47 MB (an eject without an alert stays there; the first NSAlert costs ~10 MB RSS for the life of the process on macOS 26). No polling; refresh on DiskArbitration disk notifications + kernel mount events (EVFILT_FS), never NSWorkspace notifications (S7).

### Eject flow (ours or Finder's)
1. Attempt soft eject: unmount every whole/container on the physical disk, then `DADiskEject(physical)`. Takes 0.2–10 s (other approvers can stall).
2. On busy: read dissenter pid, run holder scan on all volumes of that physical disk, show **the alert**.
3. Alert polls holders every 1 s. When zero holders remain → auto-retry eject → dismiss on success with a brief "Ejected EXAMPLE_SSD" confirmation (status-item title flash or small HUD; no notification permission needed).

### The alert (NSAlert + accessory view, mimics Apple's)
- Icon: the drive's real icon. Title: `"EXAMPLE_SSD" is in use`. Body: one line, e.g. `2 apps and 1 system process are using it.`
- Rows (accessory `NSStackView`), one per holder:
  - App icon, name, secondary line = why: `A001_still.jpg (open)`, `working directory`, `media mapped in memory`. Writers get an orange "writing" tag.
  - Button: **Quit** (GUI app; `terminate()`, then a per-kind grace with a countdown, during which the row's **Force Quit** / **Force Stop** is revealed only on hover or Tab focus and after which it becomes the row's button; see §4b S3), **Close** hint for Finder/AirDrop ("close the share sheet"), **Stop** (same-user CLI; SIGTERM, then **Kill** = SIGKILL on a separate click, same grace / reveal rules), or no button + explanation for root daemons.
- Buttons (stacked, Apple style): **Quit All & Eject** (default; only for quittable GUI/CLI holders, never daemons) · **Force Eject…** (red; confirmation sheet that lists writers and warns "apps with media mapped in memory may crash") · **Cancel**.
- "Nothing quittable" state (daemons only): rows show what it is + plain-English remedy from the knowledge table:
  - Spotlight → "Indexing new media. Usually clears in 1–2 min. Exclude this drive in System Settings › Spotlight to stop it for good." + button **Open Spotlight Settings**.
  - Time Machine → "Backup in progress." + **Open Time Machine**.
  - Quick Look → auto-offer **Stop Quick Look** (safe kill, respawns).
  - Unknown root pid → name + "system process; wait, then retry". Buttons: **Retry** · **Force Eject…**
  - Force Eject is marked **Safe** (green) when no writers are present and no mmap holders, else **Risky** (red) with reasons.
- Finder-companion mode: when the eject was requested by someone else (Finder), our alert appears non-modal, floating, without stealing focus, positioned just below Apple's (center screen, offset). Toggle in menu: "Watch Finder ejects" (default on).

## 3. Architecture

Pure AppKit, Swift 6, SwiftPM, no SwiftUI, no sandbox, ad-hoc signed, `LSUIElement`. One executable target plus a tiny CLI harness target for testing without UI.

```
Package.swift
build.sh                      # swift build -> .app -> codesign; ./build.sh run
Resources/Info.plist
Sources/EjectKit/             # library target, no AppKit UI (AppKit only for NSRunningApplication/NSWorkspace)
  HolderScanner.swift         # custom libproc scan (from recon), writer/mmap classification, denied pids
  HolderResolver.swift        # pid -> Holder model: kind (.app/.appExtension/.helper/.cli/.daemon/.root), name, icon, quittable, parent app
  DiskTopology.swift          # volume -> DADisk -> container/whole -> physical; all volumes on a physical disk
  Ejector.swift               # ejectLikeFinder(soft/force), dissenter pid, result enum
  EjectWatcher.swift          # DA unmount-approval callback (return nil fast) + DARegisterIdleCallback (private, dlsym) with poll fallback -> "foreign eject failed" event
  Terminator.swift            # terminate/forceTerminate/SIGTERM/SIGKILL with timeouts
  Remedies.swift              # knowledge table: process name/bundle id -> label, explanation, safe action, settings deep link
  VolumeMonitor.swift         # mount-table filter; own DA notification session + kqueue EVFILT_FS (no NSWorkspace observers: S7)
Sources/Ejectable/            # the app
  main.swift, AppDelegate.swift
  StatusMenuController.swift
  EjectCoordinator.swift      # state machine: idle -> ejecting -> blocked(holders) -> quitting -> retry -> ejected/forced/cancelled
  InUseAlert.swift            # NSAlert + accessory rows, live updates, modal + non-modal presentation
  HolderRowView.swift
  LoginItem.swift             # SMAppService
Sources/ejectctl/             # CLI harness: ejectctl scan <vol> | eject <vol> [--force] | watch
Tests/fixtures/make-busy-volume.sh   # creates APFS/exFAT/HFS dmg, mounts, spawns fd/cwd/mmap holders (from recon)
Tests/EjectKitTests/          # scan + topology tests against the fixture dmg
```

Key decisions (from recon, don't relitigate):
- Custom libproc scan, not `proc_listpidspath`, not `lsof`.
- Busy check is `status & 0x3fff == EBUSY`, dissenter pid from `"DAProcessID"` key.
- Unmount container(s) with `kDADiskUnmountOptionWhole`, then eject physical; physical found via IOKit `Whole=true` walk.
- Approval callback returns nil immediately; scan on background queue; never block DA.
- `terminate()` return value is meaningless; watch `isTerminated`.
- Never auto-kill daemons or any writer. Force Eject always behind explicit confirmation.
- External filter = not-internal (nil counts as external) + local + not root fs. Removable/ejectable flags are false on this USB SSD.

## 4. Phases, builders, acceptance

Orchestrator: one coordinating session. Builders: **Opus 5.5**, one agent per phase, each briefed with RECON.md + reference code + the interface contract below. Reviewer after each phase: Opus 5.5 (cavecrew-reviewer or general-purpose). Nothing touches a real drive; all eject tests use fixture dmgs until phase 6.

| # | Phase | Deliverable | Acceptance (I verify via Bash + fixture) |
|---|---|---|---|
| 0 | Scaffold | Package.swift (3 targets), build.sh, Info.plist, .gitignore, empty status item app launches | `./build.sh run` → status item visible, `lsappinfo` UIElement, binary < 300 KB, RSS < 50 MB |
| 1 | EjectKit core | HolderScanner, HolderResolver, DiskTopology, Ejector, VolumeMonitor, `ejectctl scan/eject`, fixture script, unit tests | `make-busy-volume.sh apfs` then `ejectctl scan` lists fd + cwd + mmap holders with reasons & writer flag in < 200 ms; `ejectctl eject` → busy with pid; after killing holders → ejected; `--force` works; exFAT + HFS same; `ejectctl scan` on the real test SSD (read-only) shows AirDrop |
| 2 | Menu + manual eject + alert | StatusMenuController, EjectCoordinator, InUseAlert, HolderRowView, Terminator | Click drive in menu on busy fixture → alert with rows, Quit works, auto-retry ejects when holders gone; Quit All & Eject; Force Eject confirmation; Cancel; screenshot via CGWindowListCreateImage for visual check |
| 3 | Finder-companion | EjectWatcher (approval + idle callback + poll fallback), non-modal alert presentation | `diskutil eject <fixture>` from Terminal while holders exist → our alert appears within ~1 s, non-modal, no focus steal; successful foreign eject → no alert |
| 4 | Remedies + safety rating | Remedies.swift table, daemon rows with explanations and deep links, Safe/Risky force rating, writer/mmap tags | Fixture with root-like daemon simulated via denied-pid path + dissenter pid; QL kill path; settings links open |
| 5 | Polish | Login item, autosave, menu toggles (network shares, watch Finder), ejected confirmation, logging (`os_log`), README, app icon | `SMAppService` register/unregister round-trip; cold launch < 300 ms; idle 0% over 10 min |
| 6 | Real-drive validation (user present) | — | Eject the test SSD with an AirDrop holder: alert names AirDrop, "close share sheet" hint, eject succeeds after. Then eject with Premiere open. |

Phases 1 and 2 can run in parallel after 0 if the interface contract is fixed first (EjectKit public API: `Holder`, `HolderKind`, `scanHolders(physicalDisk:)`, `EjectResult`, `Ejector.eject(volume:force:completion:)`, `EjectWatcher` events). I write that contract before spawning.

Each builder brief includes: goal, files owned, RECON.md pointer, reference code pointer, hard rules (never touch a real drive or a NAS share except read-only scans; fixtures only; no SwiftUI; no sandbox; Swift 6 strict concurrency clean), acceptance commands, and "report what you could not verify".

## 4b. Safety rules (non-negotiable, every builder and reviewer checks these)

Where media can actually be harmed, and the rule that prevents it. The soft eject path is kernel-enforced and exactly as safe as Finder's: the kernel refuses to unmount while any file is open, and a successful unmount has flushed everything. All risk is concentrated in three places: Force Eject, force-quitting or signalling processes, and targeting the wrong disk.

**S1. Soft eject is the only automatic action.** Auto-retry (when holders drop to zero), "Quit All & Eject", the menu click and the Finder-companion flow only ever call the non-forced unmount. Nothing in the app escalates to force on its own, ever.

**S2. Force Eject is always a separate, explicit, confirmed step.** It is never the default button, never reachable by Return, and its confirmation sheet lists every known holder with its file and read/write state. The button is disabled (not just warned) when any of these is true:
- a same-user holder has a file open for writing (`fi_openflags & FWRITE`; the field holds kernel FFLAGS, not O_* flags) or mapped writable (`pri_protection & VM_PROT_WRITE` on a shared mapping, so copy-on-write private mappings don't count; "shared" is read from `pri_inheritance` (mmap gives MAP_SHARED `VM_INHERIT_SHARE`, MAP_PRIVATE `VM_INHERIT_COPY`) and a COPY mapping only counts as private when `PROC_PIDREGIONPATHINFO` confirms `SM_COW`, because `pri_share_mode` is 0 in the PATHINFO2/3 calls the scanner uses and reports a single-mapper MAP_SHARED file as `SM_PRIVATE` (measured 2026-10-21));
- Time Machine reports a backup running (`tmutil status` → `Running = 1`) and this disk is a destination (`tmutil destinationinfo`);
- a known copy/render tool holds a writable file (`cp`, `rsync`, `ffmpeg`, Media Encoder, Compressor…).
The user clears these by quitting or stopping the writer first; the rows tell them which. Spotlight (`mds`), `fseventsd`, Quick Look and read-only holders do not disable it. Before a force unmount the app calls `sync_volume_np(path, SYNC_VOLUME_FULLSYNC | SYNC_VOLUME_WAIT)` on every volume of the disk (`sync()` returns before buffers are flushed). If the Time Machine state cannot be determined, Force Eject stays disabled (fail closed). The same holds when the holder scan is incomplete (2 s deadline, a process stuck in the kernel): holders may be missing, so Force Eject stays disabled.

**S3. Graceful first, force only per-app and per-click.** GUI apps are quit with `NSRunningApplication.terminate()`, which lets the app show its own "Save changes?" dialog; the app never sends SIGTERM/SIGKILL to a GUI app (SIGTERM skips the save prompt). CLI processes get SIGTERM, then SIGKILL only on a second click on the same process; a CLI holder tagged as a writer (an in-progress copy or encode) requires confirmation first. While a row waits it shows a spinner and a countdown ("Quitting… (59s)") for its kind's grace (`QuitGrace`, logged): `.app` 60 s (the user may be answering a save prompt), `.helper` 15 s (its quit goes to its parent app), `.appExtension` 3 s, `.cli` 5 s (no documents; extensions such as AirDrop.appex never answer `terminate()`, measured 2026-10-22). During the grace the row's force action is a small secondary button revealed only while the pointer is over that row or Tab focus reaches it: **Force Quit** for apps and helpers ("Unsaved changes in X will be lost"), **Force Stop** for app extensions ("Force Stop ends X immediately. Extensions rarely hold unsaved work."; a share extension such as Mail compose can hold a draft), **Kill** for CLI tools ("Stops X immediately; a copy or encode in progress will be incomplete"). When the grace passes the same action becomes the row's primary button. Revealing it does nothing by itself: every force is one process per click, explicitly labelled, through the same Terminator path (S6 re-check, logged), never automatic. Idle rows offer no force at all, Finder is never force-quit, and "Quit All & Eject" only quits gracefully / sends SIGTERM, never force-quits or SIGKILLs, whatever the grace.

**S4. Daemons are reported, not killed.** `mds`, `mds_stores`, `fseventsd`, `backupd`, `systemmigrationd`, `revisiond`, `postgres` (Resolve), `userfsd` and anything root-owned or not ours: show what it is and the clean remedy, never signal it. The single exception is Quick Look (`QuickLookUIService`, `QuickLookSatellite`, thumbnail agents): read-only, respawns, safe to stop.

**S5. Wrong-disk guard.** `Ejector` refuses, before calling DiskArbitration, unless the target physical disk is external (IOKit `Physical Interconnect Location == "External"` on its protocol characteristics, i.e. diskutil's "Device Location"; `DADeviceInternal == false` when that property is absent; disk images by `DADeviceProtocol == "Virtual Interface"`), is a single physical disk (RAID / Fusion / multi-store sets are refused as `multiMemberDisk` for now), and none of its mounted volumes (snapshot mounts included) is the root filesystem, `volumeIsInternal == true`, under `/System/Volumes`, or outside `/Volumes`. The check runs on the caller's snapshot and again on the freshly re-resolved disk, and each DA request re-checks the target's `DAAppearanceTime`. The CLI harness and tests additionally refuse any disk that is not a disk image (`DADeviceProtocol == "Virtual Interface"` / `Virtual: Yes`) unless `--real` is passed. Nothing in development ever ejects a real drive or a network share; phase 6 is done with the owner present.

**S6. Verify before acting on a pid.** Pids are re-resolved (`proc_pidpath` must still match the holder's recorded executable) immediately before terminate/kill, so a recycled pid can never hit the wrong process.

**S7. Observe-only DiskArbitration client.** The unmount-approval callback returns `nil` immediately, never a dissenter, and does no work inline. The app can therefore never block or veto an eject requested by Finder or anyone else, and a bug in the app cannot wedge the system's unmount path.

**S8. Whole-disk ejects are shown as such.** If the physical disk has more than one mounted volume, the alert and the menu say "Ejects all N volumes on this disk" before anything is unmounted.

**S9. Everything is logged.** Every scan result, quit, force-quit, eject and force-eject is written with `os_log` and to `~/Library/Logs/Ejectable/actions.log` with timestamps, pids and file paths, so any incident can be reconstructed.

**S10. Known blind spot, documented in the UI.** An NLE with a project on the drive but no file currently open (Premiere between autosaves, for example) is invisible to any scanner, including Apple's. A soft eject will succeed and the app's next write will fail with "media offline". This is identical to Finder today, not corruption, but the ejected-confirmation shows a one-line "Premiere Pro is still running" reminder when a known editor app (Premiere, Media Encoder, After Effects, Resolve, Final Cut, Compressor, Avid) is running at eject time.

Tests for each rule live in `Tests/EjectKitTests/SafetyTests.swift` and use the fixture disk images only.

## 5. Risks / open items

- **Private API**: `DARegisterIdleCallback` and the `DAProcessID` key. Both have public fallbacks (poll; pid nil). Guard with `dlsym`, degrade gracefully.
- **NSAlert non-modal activation** behaviour on a real click is unverified (headless recon). Fallback: custom `NSPanel` (recipe in RECON §6), costs ~25 MB more.
- **Physical eject of a USB SSD that reports `Ejectable=0`** not yet exercised. Phase 6, with the owner present.
- **Root daemons**: v1 shows + explains, can't act. v2: `SMAppService` privileged helper (scan as root, `mdutil -i off`, kill QL/mds_stores). Decide after v1 use.
- **Multiple volumes on one disk**: v1 ejects the whole physical disk (Finder "Eject All" semantics). Per-volume eject = later.
- **Apple's dialog still appears** in Finder-companion mode. Unavoidable. Ours sits beside it.

## 6. Defaults chosen

- Name `Ejectable`, bundle id `com.benrusnac.ejectable`.
- Network shares shown, in their own section.
- Watch Finder ejects: on.
- Force Eject always confirmed; never one click.
- Daemons never killed in v1, Quick Look excepted (safe, respawns).
- Install target `~/Applications/Ejectable.app` for login item.

## v2 ideas (not now)
Privileged helper · auto-eject before sleep · global hotkey · per-volume eject · Premiere/Resolve/FCP cache-location linting ("your Resolve cache lives on this drive") · Spotlight exclusion one-click via helper · menu-bar badge when a drive becomes busy.

## Status

Phases 0–5 built, two independent Opus reviews ([reviews/](reviews/)), two fix passes. 120 tests green, 0 warnings, release binary has no debug entry points. Idle 47 MB / 0% CPU. Phase 6 (real-drive test on the test SSD, owner present) pending.

2026-10-22: per-kind quit grace with hover / Tab reveal of the force action (S3), 130 tests; released publicly as Ejectable 0.1.0 (MIT).

**Companion-mode decision:** when Finder (or `diskutil eject`) fails, DiskArbitration only ever sends per-volume *unmount* approvals; the *eject* approval never arrives while busy. So a failed Finder eject is classified as an unmount attempt. After holders clear, Ejectable unmounts that volume only (never more than was asked) and, when nothing of the disk remains mounted, says "unmounted — safe to disconnect" instead of spinning the disk down. Menu-initiated ejects still do the full unmount-all + `DADiskEject`. Possible v1.1: read the requester from the diskarbitrationd log (Finder vs Disk Utility) to pick eject mode.

**Known limits for v1:** root daemons named but not actionable; RAID sets listed but not ejectable; `NSWorkspace.icon(forFile:)` on volume paths still runs on main (a wedged volume could stall the menu); a leftover mapping after a run of anonymous regions can end the region walk early (marked by measurement as transient).
