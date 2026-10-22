# Recon findings (2026-10-21)

Verified on the development Mac: macOS 26.6.2 (25G83), Xcode 26.2, Swift 6.2.3, arm64. Three recon agents (API deep-dive, app shell, domain research). Everything marked **[V]** was compiled/run here; **[S]** sourced; **[I]** inference.

Reference code (tested): `reference/EjectKit.swift` (holder scan + eject-like-Finder), `reference/scaffold/` (SwiftPM status-item app that builds with one script).

## 1. The Apple dialog, and why it says "one or more programs"

- Dialog is drawn by `/System/Library/CoreServices/UnmountAssistantAgent.app` (per-user LaunchAgent, root helper `UASysAgent`), not Finder. Protected by SIP. **Cannot be modified or suppressed.** [V]
- It names an app only when a holder (or an ancestor in its process chain) is a GUI app. Variants: "because "X" is using it", ""X" and "Y"", "the Finder is using it", "a remote process", "another user". [V strings]
- Generic "one or more programs may be using it" = fallback when holders are non-GUI: daemons with PPID 1 (`mds`, `mds_stores`, `fseventsd`, `backupd`, `systemmigrationd`, `revisiond`), app extensions / XPC helpers (`QuickLookUIService`, `QuickLookSatellite`, `AirDrop.appex`, `photolibraryd`, `mediaanalysisd`, Adobe CC helpers, Backblaze `bztransmit`). [V+S]
- **Live example during recon:** `AirDrop.appex` ("AirDrop (Finder)", pid 79275) had two JPEG stills memory-mapped on the test SSD (one in a `Stills/` folder, one in `.Trashes/501/`). Stock `proc_listpidspath` returned 0 pids for the drive; `lsof` saw them. This was the cause of the generic dialog that started the project. [V]

## 2. Finding holders (libproc)

- `proc_listpidspath(PROC_ALL_PIDS, 0, vol, PROC_LISTPIDSPATH_PATH_IS_VOLUME | PROC_LISTPIDSPATH_EXCLUDE_EVTONLY, …)`: works unprivileged, 86-90 ms over ~1050 pids, **but misses mmap-only holders on APFS and exFAT**. Cause: libproc passes 32-bit `st_dev` to `PROC_PIDREGIONPATHINFO3` (23); kernel compares 64-bit `f_fsid.val[0] | val[1]<<32` → EINVAL → "no regions". HFS+ unaffected. Repro: `reference/libproc-fsid-bug-repro.c`. [V]
- mmap-only holders DO block unmount (EBUSY until killed). [V]
- **Use the custom scan** (`scanVolumeHolders` in EjectKit.swift): `proc_listallpids` → per pid `PROC_PIDVNODEPATHINFO` (cwd/root), `PROC_PIDREGIONPATHINFO3` with fsid64 then st_dev (mmap), `PROC_PIDLISTFDS` + `PROC_PIDFDVNODEPATHINFO` (open files, skip `O_EVTONLY`). 120-140 ms. Catches fd / cwd / mmap on APFS, exFAT(FSKit), HFS+. Returns reason + file path per holder. [V]
- `O_EVTONLY` handles never block (kernel revokes them); without the exclusion you get false positives. [V]
- `lsof +f -- /Volumes/X`: 150-180 ms, needs process spawn, same visibility. Not needed. [V]
- **Root / other-uid processes are invisible** to an unprivileged scan (EPERM on `PROC_PIDVNODEPATHINFO` / `PROC_PIDLISTFDS`): ~330 of 1050 pids incl. `mds`, `mds_stores` (uid 308), `fseventsd`, `backupd`, `revisiond`. Same for `lsof` and for Apple's own agent. [V]
- pid → name/path: `proc_pidpath` works for every pid incl. root. `proc_name` returns EPERM on root pids on macOS 26; use `PROC_PIDT_SHORTBSDINFO` (gives uid + comm). [V]
- `NSRunningApplication(processIdentifier:)`: non-nil for GUI apps and app extensions (AirDrop.appex → "AirDrop (Finder)", policy `.prohibited`); nil for daemons/CLI. For helpers inside nested bundles (e.g. `Google Chrome Helper`), take the **outermost** `.app` path component, icon via `NSWorkspace.shared.icon(forFile:)`, and match bundle URL against `NSWorkspace.shared.runningApplications` to get a quit-able app. [V]
- Writer detection: `vnode_fdinfowithpath.pfi.fi_openflags` has `O_WRONLY`/`O_RDWR` → classify holder as writer vs read-only. (Not yet exercised in reference code; flags are present in the struct.) [I]
- Swift gotchas: `PROC_PIDPATHINFO_MAXSIZE` not imported (use `4*MAXPATHLEN`); fixed C char arrays need `withMemoryRebound`; `String(cString: &tuple.0)` crashes on Swift 6.2; `kDAReturnBusy` imports as negative Int → use `DAReturn(truncatingIfNeeded:)`. [V]
- **App Sandbox breaks everything**: scan finds 0 processes (`statfs` denied), `kill()` EPERM even same-user. Ship non-sandboxed. [V]

## 3. DiskArbitration

- `DARegisterDiskUnmountApprovalCallback` fires in our process for unmounts requested by **other** processes (`diskutil`/storagekitd, `NSWorkspace.unmountAndEjectDevice`, raw `DADiskUnmount`, force). Fires once per volume; separate eject-approval callback for the physical disk. Carries no requester info. Finder is also an approver. [V] (Finder's own Eject UI not driven; needs Automation prompt.)
- Approval callback blocks the eject while it runs; DA drops approvers after ~10 s (observed: "PhotosPosterProvider [13576] not responding" made a `diskutil unmount` take 10.8 s). **Return nil immediately, scan on a background queue** (scan finished ~130 ms after approval, usually before the failure arrived). [V]
- Dissenter on busy: `DADissenterGetStatus` = `0xC010` = `unix_err(EBUSY)`, not `kDAReturnBusy` (0xF8DA0002). Test `status & 0x3fff == EBUSY`. `DADissenterGetStatusString` is nil. Dissenter is really a dict `{DAProcessID = <pid>; DAStatus = 49168}`: read `"DAProcessID"` (or private `DADissenterGetProcessID`). Only ONE pid (first found); **0 when the only holder is mmap on APFS/exFAT** (DA has the same libproc bug). DA runs as root so it may name root holders (untested). [V]
- `FileManager.default.unmountVolume(at:options:[.withoutUI, .allPartitionsAndEjectDisk])`: best high-level soft eject; busy → `NSCocoaErrorDomain` 769, `userInfo[NSFileManagerUnmountDissentingProcessIdentifierErrorKey]` = one pid, underlying `NSMachErrorDomain` 49168. `NSWorkspace.unmountAndEjectDevice` only throws `NSOSStatusErrorDomain -47`, no pid. [V]
- **No DA callback on a failed unmount.** Sequence on failure: approval callback → `NSWorkspace.willUnmountNotification` → nothing. On success: + description-changed (volume path nil) + `didUnmountNotification`. `willUnmount` fires on every attempt incl. failed ones (5× for 5 blocked attempts). [V]
- Detecting failure: (1) private `DARegisterIdleCallback(session, cb, ctx)` (exported, not in headers) fires when DA's queue drains; if approved volume still mounted → failed. Fired 0.1-2.6 s after approval = exactly at failure. (2) Public-only fallback: poll mount state after approval, 15-20 s timeout; predict early if scan found holders. [V]
- **Eject like Finder, correct order** [V]:
  1. Find physical whole disk: walk IOKit parents of `DADiskCopyIOMedia(volume)`, outermost `IOMedia` with `Whole=true` (the test SSD: disk9s1 → container disk9 → physical disk8). exFAT/HFS: `DADiskCopyWholeDisk` suffices.
  2. For each distinct whole disk with mounted volumes on that physical disk: `DADiskUnmount(whole, kDADiskUnmountOptionWhole)` (APFS container: 178 ms).
  3. `DADiskEject(physical, kDADiskEjectOptionDefault)` (38 ms).
  - Wrong order (unmount physical first) returns OK as a no-op, then eject fails 0xC010 pid 0.
  - exFAT (FSKit userspace) same but 400-500 ms.
- `kDADiskUnmountOptionForce` (0x80000) + eject succeeded with holders present (78 + 64 ms). Effects on holders: open-fd holder → EBADF on next read; cwd holder unaffected; **mmap holder crashed with SIGBUS on next page touch**. A force eject can crash an editing app with media mapped. Last resort only, with warning. [V]
- The test SSD (a USB SSD, `disk8`, USB "Fixed") reports `Ejectable=0`, `Removable=0`. `DADiskEject` on it not tested (recon rule). First real-drive eject must be done with the user present.

## 4. Unified log

- `/usr/bin/log show` (note: `log` is a zsh builtin) works as admin user, ~1.9 s per 15 min window; `OSLogStore(scope: .system)` in-process ~1.2 s, poll only. [V]
- diskarbitrationd logs who asked (`storagekitd [pid] queued solicitation … kind = disk unmount`), approvers notified, non-responders, "unable to unmount … (status code 0x…10)". **Never logs the holder pid** (`vfs.generic.print_busy_vnodes` ENOENT). Only use: identify requester (Finder vs diskutil). Not needed for v1. [V]

## 5. Terminating processes

- `NSRunningApplication.terminate()`: no TCC prompt; **returns true even if the app refuses** (`applicationShouldTerminate` cancel) — watch `isTerminated` with timeout, then offer force. `forceTerminate()` 53 ms. [V]
- `kill(pid, SIGTERM)`: works for same-user, no entitlement; on a Cocoa app it skips `applicationShouldTerminate` (effectively force, no save prompt) → use `terminate()` for GUI, SIGTERM→SIGKILL for CLI. [V]
- Root/other-uid daemons: `kill` EPERM, `NSRunningApplication` nil. Needs a privileged helper (SMAppService daemon) → v2. [V]

## 6. App shell

- No `xcodegen`/`tuist` installed. **SwiftPM executable + `build.sh`** assembling `.app` (Info.plist `LSUIElement=true`, ad-hoc `codesign --sign -`) verified: builds in ~3 s warm, 84 KB binary, launches via `open`, `lsappinfo` shows `UIElement`. Use `swift build`, not `swift run` (no bundle → no bundle id / SMAppService). [V]
- Measured (3 runs each, RSS / ready warm / idle CPU): AppKit `NSStatusItem`+`NSMenu` 45 MB / 76 ms / 0%; AppKit + `NSPopover` 46 MB / 72-100 ms; SwiftUI `MenuBarExtra` .menu 75 MB / 105 ms; .window 75 MB / 98 ms. **Linking SwiftUI alone adds ~30 MB. Pure AppKit, no SwiftUI import anywhere.** [V]
- macOS 26: AppKit chrome is already Liquid Glass (`NSAlert` tree contains `NSGlassView`, buttons are `_NSCoreHostingView<AppKitButton>`). `NSGlassEffectView` exists if a custom panel is ever needed. Status item windows have placeholder window number 4294967296 (invisible to `CGWindowListCopyWindowInfo`). Set `autosaveName` on the status item. [V]
- **NSAlert on macOS 26 layout**: 64 px icon top-left ABOVE title (not beside), title bold 13 pt, body regular 13 pt, buttons 228×28 stacked vertically, window 332 pt wide (= accessory width + 32, min 332), ~28 pt corners. `alert.icon = NSWorkspace.shared.icon(forFile: volumePath)` gives the orange external-drive icon. `hasDestructiveAction = true` → red button. `accessoryView` = `NSStackView` rows (icon, name, Quit `NSButton`); row buttons don't dismiss the alert; live updates work during `runModal()` (remove row, set stack height, `alert.layout()`, window resizes top-pinned). Timers on `.common` mode + `DispatchQueue.main.async` fire during modal. Alert costs ~4 MB. [V]
- Non-modal NSAlert: retarget `alert.buttons[i].target/action`, then `alert.window.makeKeyAndOrderFront(nil)` — works, undocumented. With app inactive the window shows but isn't key (default button not accent-tinted). Activation is cooperative since macOS 14; `NSApp.activate()` in headless test did not steal front. [V]
- Custom `NSPanel` alternative (`[.borderless, .nonactivatingPanel]`, `level = .floating`, `orderFrontRegardless()`, `NSGlassEffectView` cornerRadius 28): works, becomes key without stealing focus, but 25-35 MB vs 4 MB and hand-built layout/a11y. Only if NSAlert's activation behaviour proves bad in real use. [V]
- Icons: GUI app → `NSRunningApplication.icon`; daemon → `NSWorkspace.shared.icon(forFile: execPath)` = generic exec icon (same as `.icon(for: .unixExecutable)`); helper → outermost `.app`. Drive → `NSWorkspace.shared.icon(forFile: volumePath)` (orange external for the test SSD). `NSWorkspace.shared.icon(for: .volume)` is a folder icon — useless. [V]
- Login item: `SMAppService.mainApp.register()` needs a real `.app` with `CFBundleIdentifier`, installed in `/Applications` or `~/Applications`; ad-hoc signing OK for `mainApp` (status read returned `.notFound` pre-registration, as expected). After register, `.requiresApproval` is normal (System Settings › Login Items). Not called during recon. [V/S]
- Volume filtering [V]: on the development Mac `volumeIsRemovableKey` and `volumeIsEjectableKey` are **false** for the test USB SSD — a removable/ejectable filter would miss it. Use `!(volumeIsInternal ?? false) && volumeIsLocal && !volumeIsRootFileSystem` (`volumeIsInternal` is nil for disk images and SMB → treat nil as not-internal). `.skipHiddenVolumes` drops `/System/Volumes/*`, simulator runtimes and `nobrowse` volumes. SMB (a NAS share under `/Volumes`): `volumeIsLocal == false`, fs `smbfs`, no BSD disk (DA returns nothing) → separate "Network" section, action "Disconnect" (plain unmount).
- `NSWorkspace.shared.notificationCenter`: `didMountNotification`, `willUnmountNotification`, `didUnmountNotification`, `didRenameVolumeNotification`; userInfo `NSDevicePath`, `NSWorkspaceVolumeURLKey`, `NSWorkspaceVolumeLocalizedNameKey`. Only `didUnmount` means gone. [V]
- Distribution: local ad-hoc build has no quarantine attr, launches with no Gatekeeper prompt. Notarization needs paid Developer ID — only if sharing with other Macs (Sequoia+ removed Control-click-Open; use Privacy & Security › Open Anyway or `xattr -dr com.apple.quarantine`). [V/S]

## 7. Common holders on a video editor's Mac (ranked) [S/I]

| Holder | What | Visible unprivileged? | Safe action |
|---|---|---|---|
| `mds`, `mds_stores`, `mdworker_shared` | Spotlight indexing fresh media; writes `.Spotlight-V100` | No (root / uid 308) | Wait; `sudo mdutil -i off /Volumes/X` (needs admin) or Spotlight Privacy list. Don't kill. |
| Finder (window / column preview / AirDrop share sheet `AirDrop.appex`) | Dialog says "the Finder" or generic (appex) | Yes | Close windows / share sheet; `killall Finder` safe |
| `QuickLookUIService`, `QuickLookSatellite`, `QLPreviewGenerationExtension`, `com.apple.quicklook.ThumbnailsAgent` | Holds previewed file for hours | Yes | `killall QuickLookUIService` (respawns, harmless). `qlmanage -r` does NOT free handles. |
| `backupd`, `backupd-helper`, `systemmigrationd` (Tahoe dissenter), `revisiond` | Time Machine | No | Wait / stop backup in TM menu. Never kill `backupd` mid-backup. |
| `fseventsd` | FSEvents log on volume; DA approver | No | Retry; releases on unmount normally |
| `photolibraryd`, `photoanalysisd`, `mediaanalysisd`, `AMPLibraryAgent`, Photos | Library on drive / card import | Yes (user) | Quit Photos + helpers (relaunch) |
| Terminal / shell cwd, `tail -f`, `ffmpeg`, `rsync` | Named "Terminal" by Apple | Yes | `cd ~`; cwd-only holds are read-only / risk-free |
| Premiere Pro, Media Encoder, After Effects, Bridge, `CCXProcess`, Adobe Crash Process, Creative Cloud | Home screen counts as running; Bridge holds until quit; cache may be on drive | Yes | Cmd+Q apps, then CC menu-bar app. Don't force-kill mid-write. |
| DaVinci Resolve (+ `postgres`) | `CacheClip`, `.gallery` on first media storage location | Yes | Quit Resolve; never kill postgres |
| Final Cut Pro | Library DB on drive; background tasks | Yes | Let tasks finish, close library, quit |
| Backblaze `bztransmit` (root), Dropbox, Google Drive, CCC, AV (`BDLDaemon`, `virusbarriers`) | Post-copy scans; usually clear in 1-2 min | Partly | Pause agent; retry |
| Music / `AMPDevicesAgent` | Library on drive | Yes | Quit Music |
| Parallels `prl_vm_app`, Docker, Xcode | VM / container paths | Yes | Stop VM / containers |

Sources: UnmountAssistantAgent strings (local), `man diskutil`/`umount`, eclecticlight.co (2025-01-24, 2026-05-21, 2025-12-22), alexwlchan.net/til/2024/why-cant-i-eject-a-disk, mjtsai.com 2023-02-16, bombich.com CCC KB, community.adobe.com threads, Puget Systems cache article.

## 8. Force Eject semantics [V/S/I]

- Finder "Force Eject…" → confirmation ("Ejecting the disk might cause problems…") → agent tries `terminateAutomaticallyTerminableApplications` → forced unmount (`kDADiskUnmountOptionForce | Whole`) → eject.
- `umount -f`: open files return errors on further access. Open-for-write files (render, export, copy, cache) end up truncated/inconsistent; apps hit I/O errors, may crash (mmap → SIGBUS, verified). APFS metadata itself is robust; file data is the exposure. Unplugging without unmount is worse.
- Effectively safe when: every holder is read-only (fd open flags `O_RDONLY`), or cwd/directory-only, or writers are only rebuildable metadata (Spotlight, fseventsd, QL cache); and no active copy/render/export/backup/sync.
- Not safe while Premiere/AME/Resolve/FCP/TM/CCC/Backblaze/Dropbox may be writing.
- Escalation ladder: soft unmount (read dissenter pid) → remove cause (quit apps, kill QL, `cd ~`, pause sync) → SIGTERM holders → force unmount one volume → force eject whole disk → shut down and unplug.

## 9. Existing tools (gap) [S]

Jettison ($6.95; lsof+fuser, helper for root, inconsistent on Tahoe), Ejectify (€6.99; no culprit detection), Ejecta ($9.99; names holder, needs FDA), Sloth (free lsof GUI, no eject), Ejection Seat (Raycast; lsof, blind to root), EjectBar/MountMate/DriveBar (plain eject). Nobody: classifies read-only vs writing to rate force safety; knows editor apps/caches; shows DA dissenter + full scan together; fixes causes persistently (Spotlight/TM exclusions); reacts to a Finder eject failure.

## 10. Gotchas

- APFS: must unmount the synthesized container (`Whole`) before ejecting the physical disk. A holder on a sibling volume of the same physical disk blocks eject → scan all volumes on the physical disk.
- Multi-volume disks: Finder offers Eject All vs Eject only "X". `diskutil eject` acts on the whole disk.
- exFAT on Tahoe runs through FSKit (`userfsd`, root). Slower; behaviour otherwise same.
- Thunderbolt dock / display-sleep drops cause many "not ejected properly" reports — different problem, out of scope.
- Many approvers (PhotosPosterProvider etc.) can stall a DA unmount up to ~10 s; our UI must tolerate slow ejects.
