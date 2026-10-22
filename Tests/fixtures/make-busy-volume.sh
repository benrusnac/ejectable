#!/bin/bash
# Fixture: a small disk image mounted at /Volumes/DUTEST_<FS> with holder processes keeping it busy.
#
#   make-busy-volume.sh <apfs|exfat|hfs> [--holders fd,fdw,cwd,mmap,mmapw,mmapp,mmapwc,evtonly] [--name DUTEST_X]
#                       [--second-volume DUTEST_Y [--holders2 fd,cwd,…]]
#                       default names: DUTEST_APFS, DUTEST_HFS, DUTESTEXFAT (newfs_exfat rejects '_')
#                       --second-volume (APFS only): a second APFS volume in the same container, i.e. one physical disk
#                       with two volumes. The image is then a 1.1 GB sparse image (~10 MB on disk; APFS refuses a
#                       second volume in a smaller container). Holders on it are recorded as <mode>2 (fd2, cwd2, …).
#   make-busy-volume.sh --kill-holders <name>    kill only this fixture's holders, keep the image attached
#   make-busy-volume.sh --cleanup <name>         kill holders and detach this fixture's image
#
# Holders: fd = `tail -f` (read fd) · fdw = duhold fdw (write fd) · cwd = `sleep` with cwd on the volume ·
#          mmap / mmapw = duhold read-only / writable shared mapping, fd closed · mmapp = duhold private (copy-on-write)
#          writable mapping, one page copied · mmapwc = duhold writable shared mapping with inheritance COPY ·
#          evtonly = duhold O_EVTONLY.
# State: .build/fixtures/<name>.state (key=value). The image lives in .build/fixtures/<name>.dmg (.sparseimage with
# --second-volume).
#
# Wrong-disk guard (S5): this script only ever detaches the device node that `hdiutil info` reports for
# OUR image file (.build/fixtures/<name>.dmg), re-checked immediately before each detach, and only kills pids it
# recorded whose command AND start time (ps lstart) still match. It never touches any other disk, and refuses names
# that are not DUTEST followed by A-Z, 0-9 or _ only.
set -euo pipefail
export LC_ALL=C

ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
FIX="$ROOT/.build/fixtures"
mkdir -p "$FIX"

die() { echo "make-busy-volume: $*" >&2; exit 1; }
note() { echo "make-busy-volume: $*" >&2; }

# Explicit character lists (bracket ranges are locale-dependent); the first pattern rejects '/', '.', '*', spaces, …
check_name() {
  case "$1" in
    DUTEST*[!ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_]*) die "refusing fixture name '$1' (must be DUTEST + A-Z 0-9 _ only)";;
    DUTEST?*) ;;
    *) die "refusing fixture name '$1' (must be DUTEST + A-Z 0-9 _ only)";;
  esac
}

state_get() { grep -E "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2- || true; }

# Device node hdiutil currently reports for this exact image file, or nothing. Never trust a recorded node:
# after an eject the node may already belong to a different disk.
attached_device() {
  local img="$1" plist="$FIX/.hdiutil-info.$$.plist" i=0 n path dev
  hdiutil info -plist > "$plist"
  n=$(plutil -extract images raw -o - "$plist" 2>/dev/null || echo 0)
  while [ "$i" -lt "$n" ]; do
    path=$(plutil -extract "images.$i.image-path" raw -o - "$plist" 2>/dev/null || true)
    if [ "$path" = "$img" ]; then
      dev=$(plutil -extract "images.$i.system-entities.0.dev-entry" raw -o - "$plist" 2>/dev/null || true)
      rm -f "$plist"
      case "$dev" in /dev/disk[0-9]*) echo "$dev";; esac
      return 0
    fi
    i=$((i + 1))
  done
  rm -f "$plist"
}

# Kill recorded holders whose command AND start time still match what we spawned (no recycled pids).
kill_holders() {
  local state="$1" line mode pid comm actual started now
  { grep -E '^holder\.[a-z0-9]+=' "$state" 2>/dev/null || true; } | while IFS= read -r line; do
    mode=${line%%=*}; mode=${mode#holder.}
    pid=${line#*=}
    case "$pid" in ''|*[!0-9]*) continue;; esac
    comm=$(state_get "$state" "comm.$mode")
    started=$(state_get "$state" "start.$mode")
    actual=$(ps -o comm= -p "$pid" 2>/dev/null || true)
    now=$(ps -o lstart= -p "$pid" 2>/dev/null || true)
    if [ -n "$actual" ] && [ "$(basename "$actual")" = "$comm" ] && [ -n "$started" ] && [ "$now" = "$started" ]; then
      kill "$pid" 2>/dev/null || true
      note "killed $mode holder $pid ($comm)"
    elif [ -n "$actual" ]; then
      note "not killing pid $pid: it is no longer our $mode holder ($actual, started $now)"
    fi
  done
  # wait until they are gone (max ~2 s)
  local tries=0
  while [ $tries -lt 20 ]; do
    local alive=0
    for pid in $(grep -E '^holder\.[a-z0-9]+=' "$state" 2>/dev/null | cut -d= -f2); do
      kill -0 "$pid" 2>/dev/null && alive=1
    done
    [ $alive -eq 0 ] && break
    sleep 0.1; tries=$((tries + 1))
  done
  # mark holders as gone in the state file
  sed -i '' -E '/^(holder|comm|start)\./d' "$state"
}

detach_image() {
  local state="$1" img dev tries=0
  img=$(state_get "$state" image)
  [ -n "$img" ] || die "no image recorded in $state"
  case "$img" in "$FIX"/DUTEST*.dmg|"$FIX"/DUTEST*.sparseimage) ;; *) die "refusing: recorded image $img is not a fixture image";; esac
  while :; do
    dev=$(attached_device "$img")
    if [ -z "$dev" ]; then note "image not attached (already ejected/detached)"; return 0; fi
    if [ $tries -ge 4 ]; then die "could not detach $dev"; fi
    case "$dev" in /dev/disk[0-9]|/dev/disk[0-9][0-9]|/dev/disk[0-9][0-9][0-9]) ;; *) die "refusing: '$dev' is not a whole disk node";; esac
    # Re-check right before acting: after an eject the node may already belong to a different disk.
    if [ "$(attached_device "$img")" != "$dev" ]; then tries=$((tries + 1)); continue; fi
    if [ $tries -lt 2 ]; then hdiutil detach "$dev" -quiet && { note "detached $dev"; return 0; }
    else
      [ "$(attached_device "$img")" = "$dev" ] || { tries=$((tries + 1)); continue; }   # -force only on a fresh match
      hdiutil detach "$dev" -force -quiet && { note "force-detached $dev (our image $img)"; return 0; }
    fi
    tries=$((tries + 1)); sleep 1
  done
}

case "${1:-}" in
  --kill-holders|--cleanup)
    [ $# -ge 2 ] || die "usage: $0 $1 <name>"
    name="$2"; check_name "$name"
    state="$FIX/$name.state"
    [ -f "$state" ] || die "no state file $state"
    kill_holders "$state"
    if [ "$1" = "--cleanup" ]; then
      detach_image "$state"
      rm -f "$state" "$FIX/$name.dmg" "$FIX/$name.sparseimage" "$FIX/$name".*.log
    fi
    exit 0
    ;;
  apfs|exfat|hfs) fs="$1"; shift ;;
  *) die "usage: $0 <apfs|exfat|hfs> [--holders fd,fdw,cwd,mmap,mmapw,mmapp,mmapwc,evtonly] [--name DUTEST_X] [--second-volume DUTEST_Y [--holders2 …]] | --kill-holders <name> | --cleanup <name>" ;;
esac

holders="fd,cwd,mmap"
holders2=""
name=""
name2=""
while [ $# -gt 0 ]; do
  case "$1" in
    --holders) holders="$2"; shift 2 ;;
    --holders2) holders2="$2"; shift 2 ;;
    --name) name="$2"; shift 2 ;;
    --second-volume) name2="$2"; shift 2 ;;
    *) die "unknown option $1" ;;
  esac
done
if [ -n "$name2" ]; then
  [ "$fs" = apfs ] || die "--second-volume needs apfs"
  check_name "$name2"
fi
[ -z "$holders2" ] || [ -n "$name2" ] || die "--holders2 needs --second-volume"
FSU=$(echo "$fs" | tr '[:lower:]' '[:upper:]')
# newfs_exfat (FSKit) rejects '_' and '-' and names over 11 chars, so exFAT gets DUTESTEXFAT.
if [ -z "$name" ]; then
  if [ "$fs" = exfat ]; then name="DUTESTEXFAT"; else name="DUTEST_$FSU"; fi
fi
if [ "$fs" = exfat ]; then
  case "$name" in *[!A-Z0-9]*) die "exFAT volume names must be A-Z0-9 only ($name)";; esac
  [ ${#name} -le 11 ] || die "exFAT volume names are at most 11 characters ($name)"
fi
check_name "$name"
MNT="/Volumes/$name"
MNT2=""
[ -n "$name2" ] && MNT2="/Volumes/$name2"
state="$FIX/$name.state"
img="$FIX/$name.dmg"
[ -n "$name2" ] && img="$FIX/$name.sparseimage"

[ -e "$MNT" ] && die "$MNT already exists; run: $0 --cleanup $name"
[ -n "$MNT2" ] && [ -e "$MNT2" ] && die "$MNT2 already exists"
[ -f "$state" ] && die "$state exists; run: $0 --cleanup $name"

case "$fs" in
  apfs) hfs_fs="APFS" ;;
  exfat) hfs_fs="ExFAT" ;;
  hfs) hfs_fs="HFS+J" ;;
esac

# Helper binary (rebuilt when the source is newer)
HOLD="$FIX/duhold"
if [ ! -x "$HOLD" ] || [ "$ROOT/Tests/fixtures/duhold.c" -nt "$HOLD" ]; then
  clang -O1 -Wall -o "$HOLD" "$ROOT/Tests/fixtures/duhold.c" || die "could not build duhold"
fi

rm -f "$img"
if [ -n "$name2" ]; then
  hdiutil create -quiet -size 1100m -fs "$hfs_fs" -volname "$name" -type SPARSE -ov "${img%.sparseimage}" || die "hdiutil create failed"
else
  hdiutil create -quiet -size 32m -fs "$hfs_fs" -volname "$name" -type UDIF -ov "$img" || die "hdiutil create failed"
fi
img=$(cd "$(dirname "$img")" && pwd -P)/$(basename "$img")

# Browsable mount (no -nobrowse): skipHiddenVolumes must keep it so the app/`ejectctl volumes` see it.
attach_plist="$FIX/$name.attach.plist"
hdiutil attach -plist -noverify -noautofsck -noautoopen "$img" > "$attach_plist" || die "hdiutil attach failed"
dev=$(attached_device "$img")
[ -n "$dev" ] || die "attached, but hdiutil info does not list $img"
mounted=""
for i in 0 1 2 3 4 5 6 7; do
  m=$(plutil -extract "system-entities.$i.mount-point" raw -o - "$attach_plist" 2>/dev/null || true)
  [ -n "$m" ] && mounted="$m"
done
rm -f "$attach_plist"
if [ "$mounted" != "$MNT" ]; then
  hdiutil detach "$dev" -quiet || true
  die "mounted at '$mounted', expected $MNT (detached our image $dev)"
fi

# Second APFS volume in the same container (our own image only: the container's physical store must be our device).
if [ -n "$name2" ]; then
  container=$(diskutil info -plist "$MNT" | plutil -extract APFSContainerReference raw -o - - 2>/dev/null || true)
  store=$(diskutil info -plist "$MNT" | plutil -extract APFSPhysicalStores.0.APFSPhysicalStore raw -o - - 2>/dev/null || true)
  case "$store" in "${dev#/dev/}"s[0-9]*) ;; *) hdiutil detach "$dev" -quiet || true; die "container store '$store' is not on our image $dev";; esac
  diskutil apfs addVolume "$container" APFS "$name2" > /dev/null || { hdiutil detach "$dev" -quiet || true; die "addVolume failed"; }
  for _ in $(seq 1 50); do [ -d "$MNT2" ] && break; sleep 0.1; done
  [ -d "$MNT2" ] || { hdiutil detach "$dev" -quiet || true; die "$MNT2 did not mount"; }
fi

# Test files, plus Spotlight/fseventsd opt-outs so system daemons are less likely to hold the volume.
for m in "$MNT" ${MNT2:+"$MNT2"}; do
  mkdir -p "$m/cwd"
  touch "$m/.metadata_never_index" "$m/.metadata_never_index_unless_rootfs" 2>/dev/null || true
  [ -d "$m/.fseventsd" ] && touch "$m/.fseventsd/no_log" 2>/dev/null || true
  for f in fd.txt fdw.txt evt.txt mmap.bin mmapw.bin mmapp.bin mmapwc.bin; do
    dd if=/dev/zero of="$m/$f" bs=4096 count=16 2>/dev/null
  done
done
sync

{
  echo "name=$name"
  echo "fs=$fs"
  echo "image=$img"
  echo "device=$dev"
  echo "mount=$MNT"
  [ -n "$MNT2" ] && echo "mount2=$MNT2"
} > "$state"

cd /    # holders must not inherit a cwd on the volume (except the cwd holder)
spawn_hold() {  # mode file mount suffix
  "$HOLD" "$1" "$3/$2" > "$FIX/$name.$1$4.log" 2>&1 < /dev/null &
  record "$1$4" $! duhold
}
record() {  # mode pid comm: pid, command and start time (kill_holders requires all three to match)
  echo "holder.$1=$2" >> "$state"; echo "comm.$1=$3" >> "$state"
  echo "start.$1=$(ps -o lstart= -p "$2" 2>/dev/null || true)" >> "$state"
}
spawn_holders() {  # list mount suffix
  local list="$1" m="$2" sfx="$3" h
  IFS=',' read -r -a wanted <<< "$list"
  for h in ${wanted[@]+"${wanted[@]}"}; do
    case "$h" in
      fd)
        tail -f "$m/fd.txt" > /dev/null 2>&1 < /dev/null &
        record "fd$sfx" $! tail ;;
      cwd)
        (cd "$m/cwd" && exec sleep 86400) > /dev/null 2>&1 < /dev/null &
        record "cwd$sfx" $! sleep ;;
      fdw) spawn_hold fdw fdw.txt "$m" "$sfx" ;;
      mmap) spawn_hold mmap mmap.bin "$m" "$sfx" ;;
      mmapw) spawn_hold mmapw mmapw.bin "$m" "$sfx" ;;
      mmapp) spawn_hold mmapp mmapp.bin "$m" "$sfx" ;;
      mmapwc) spawn_hold mmapwc mmapwc.bin "$m" "$sfx" ;;
      evtonly) spawn_hold evtonly evt.txt "$m" "$sfx" ;;
      "") ;;
      *) die "unknown holder '$h'" ;;
    esac
  done
}
rm -f "$FIX/$name".*.log
spawn_holders "$holders" "$MNT" ""
[ -n "$MNT2" ] && spawn_holders "$holders2" "$MNT2" "2"

# Wait for duhold holders to report ready (files open / mapped), tail/sleep need a moment too.
for log in "$FIX/$name".*.log; do
  [ -e "$log" ] || continue
  for _ in $(seq 1 50); do grep -q '^ready' "$log" 2>/dev/null && break; sleep 0.05; done
  grep -q '^ready' "$log" || die "holder did not start: $log: $(cat "$log")"
done
sleep 0.3

echo "fixture $name: $MNT${MNT2:+ + $MNT2} on $dev ($fs), holders: $holders${MNT2:+ / $holders2}"
cat "$state"
