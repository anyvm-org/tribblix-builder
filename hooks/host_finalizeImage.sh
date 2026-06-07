# shellcheck shell=bash
# host_finalizeImage.sh -- host-side build hook (run by build.py as a plain
# `bash` subprocess AFTER the build VM has shut down, BEFORE the ISO is removed
# and the image is exported). The conf's VM_* env vars are inherited; the VM
# name comes from $VM_OS_NAME (NOT $osname -- that is a build.py global, not
# exported to this subprocess).
#
# Purpose: restore the generic, CPU-neutral /lib/libc.so.1 in the freshly built
# image so it boots under KVM on ANY x86-64 CPU.
#
# Background: tribblix's live_install hardlinks a CPU-hwcap-optimized libc
# variant onto /lib/libc.so.1 -- libc_hwcap1 (requires Intel SEP / SYSENTER) on
# an Intel build host, or libc_hwcap2 (requires AMD_SYSC / SYSCALL) on an AMD
# build host. ld.so.1 hard-rejects that variant on a CPU lacking the capability,
# so init cannot load libc and the box crash-loops ("init(8) exited on fatal
# signal 9"). The generic libc declares no .SUNW_cap requirement and runs
# everywhere; illumos then re-optimizes per-CPU at boot on its own.
#
# A running illumos cannot replace its own /lib/libc.so.1 (mapped text is busy),
# and the Linux build host cannot write illumos ZFS (no zfs kmod), so the swap is
# done offline by a throwaway helper VM: boot the tribblix ISO live, attach the
# built image as a data disk, import its rpool, fetch the generic libc from the
# package repo, and copy it over the frozen one. Raw qemu (no libvirt); the live
# ISO is driven over VNC with vncdotool, syncing on screen text (OCR) at the two
# slow/variable points (boot->login, package download) and short sleeps elsewhere.
#
# Standalone test:  FZ_ISO=x.iso FZ_QCOW=y.qcow2 bash host_finalizeImage.sh
finalizeImage() {
  local iso="${FZ_ISO:-${VM_OS_NAME}.iso}"
  local qcow="${FZ_QCOW:-${VM_OS_NAME}.qcow2}"
  local disp="${FZ_VNCDISP:-58}"            # VNC display N -> TCP 5900+N
  local monport="${FZ_MONPORT:-55571}"
  local vmname="${VM_OS_NAME:-tribblix}-finalize"
  local vnc="127.0.0.1:${disp}"
  # This hook runs qemu DIRECTLY (not via libvirt's sudo), so the build user must
  # be able to reach /dev/kvm (default root:kvm 0660). Make it accessible if we
  # can (the build already relies on passwordless sudo); fall back to TCG only if
  # KVM is truly unavailable, so the swap still works (just slower).
  if [ -e /dev/kvm ] && [ ! -w /dev/kvm ]; then sudo -n chmod 0666 /dev/kvm 2>/dev/null || true; fi
  local accel="kvm"; [ -w /dev/kvm ] 2>/dev/null || accel="tcg"
  local serlog="/tmp/${vmname}.serial.log"
  local cap="/tmp/${vmname}.cap.png"

  if [ ! -e "$iso" ] || [ ! -e "$qcow" ]; then
    echo "finalizeImage: need ISO ($iso) and qcow2 ($qcow); skipping"
    return 0
  fi
  command -v qemu-system-x86_64 >/dev/null || { echo "finalizeImage: no qemu, skip"; return 0; }
  command -v vncdotool >/dev/null || { echo "finalizeImage: no vncdotool, skip"; return 0; }

  echo "finalizeImage: restoring generic libc via ISO helper (accel=$accel vnc=$vnc qcow=$qcow)"
  pkill -9 -f "$vmname" 2>/dev/null || true
  sleep 1
  rm -f "$serlog"
  qemu-system-x86_64 -name "$vmname" \
    -machine pc,accel="$accel" -cpu host -smp 2 -m 4096 \
    -cdrom "$iso" -boot d \
    -drive file="$qcow",format=qcow2,if=none,id=tgt \
    -device ich9-ahci,id=ahci0 -device ide-hd,bus=ahci0.0,drive=tgt,serial=FZTGT01 \
    -netdev user,id=net0 -device e1000,netdev=net0 \
    -vnc "$vnc" \
    -serial file:"$serlog" \
    -monitor "telnet:127.0.0.1:${monport},server,nowait" \
    -daemonize
  echo "finalizeImage: qemu rc=$?"

  local V="vncdotool -s ${vnc}"
  _fzt(){ $V --force-caps type "$1" >/dev/null 2>&1; $V key enter >/dev/null 2>&1; }
  # OCR the current VNC screen to stdout; rc=2 => no OCR available, rc=1 => capture failed
  _fzscreen(){
    command -v tesseract >/dev/null 2>&1 || return 2
    rm -f "$cap"                       # never OCR a stale frame
    $V capture "$cap" >/dev/null 2>&1
    [ -s "$cap" ] || return 1          # capture must have produced a frame
    tesseract "$cap" - 2>/dev/null
  }
  # wait until screen text matches $1 (up to $2 s); fall back to a plain sleep if
  # OCR is unavailable, so the hook still works (just less adaptively).
  _fzwait(){
    local text="$1" max="${2:-120}" t=0 out rc
    echo "finalizeImage: waiting for '$text' (<=${max}s)"
    while [ "$t" -lt "$max" ]; do
      out=$(_fzscreen); rc=$?
      if [ "$rc" -eq 2 ]; then echo "finalizeImage: no OCR; sleeping ${max}s"; sleep "$max"; return 0; fi
      if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qi -- "$text"; then
        echo "finalizeImage: matched '$text' (~${t}s)"; return 0
      fi
      sleep 4; t=$((t + 4))
    done
    echo "finalizeImage: TIMEOUT for '$text' after ${max}s (continuing)"; return 1
  }

  # --- drive the live ISO ---
  # Floor sleep first: booting the ISO to the keyboard-layout prompt is ~90s, and
  # we must NOT capture/match during early boot. Then OCR-wait on "layout" (the
  # prompt says "keyboard layout"; matching "layout" avoids the earlier
  # "USB keyboard" boot message).
  sleep 60
  _fzwait "layout" 200             # keyboard-layout prompt
  $V key enter >/dev/null 2>&1     # accept default (US) layout
  _fzwait "login" 120              # login prompt
  _fzt "jack";     sleep 3         # live user
  _fzt "jack";     sleep 7         # live password (MOTD + shell)
  _fzt "su -";     sleep 3         # become root
  _fzt "tribblix"; sleep 6         # root password (root shell)

  # --- the swap (typed as root in the live ISO) ---
  # NB: the live ISO's own /lib/libc.so.1 is NOT generic -- illumos re-optimizes
  # it to the helper's CPU at boot. Pull the GENERIC libc from the tribblix repo
  # (zap uses the live system's own repo/version), which ships /lib/libc.so.1 with
  # no .SUNW_cap requirement, then unzip + copy it in. The live ISO root is a tiny
  # RAM disk, so redirect zap's cache onto the imported target pool (/a, ~190G).
  # The boot-environment dataset name is discovered dynamically (not hard-coded).
  _fzt "echo FZ_BEGIN; uname -a";                                     sleep 2
  _fzt "zpool import -f -N -R /a rpool";                              sleep 5
  _fzt 'BE=$(zfs list -H -o name -r rpool/ROOT | grep /ROOT/ | head -1); echo FZ_BE=$BE; zfs mount "$BE"'; sleep 4
  _fzt "echo FZ_OLD; digest -a md5 /a/lib/libc.so.1";                sleep 3
  _fzt "rm -rf /var/zap/cache; mkdir -p /a/fzc; ln -s /a/fzc /var/zap/cache"; sleep 2
  _fzt "zap retrieve TRIBsys-library"
  _fzwait "verified" 240           # package download + checksum (slow, variable)
  _fzt "rm -rf /a/fzg; mkdir -p /a/fzg; unzip -o -j /a/fzc/TRIBsys-library.*.zap '*reloc/lib/libc.so.1' -d /a/fzg"; sleep 5
  _fzt "echo FZ_GEN; digest -a md5 /a/fzg/libc.so.1";                sleep 3
  _fzt "rm -f /a/lib/libc.so.1; cp /a/fzg/libc.so.1 /a/lib/libc.so.1"; sleep 4
  _fzt "chmod 0755 /a/lib/libc.so.1; chown root:bin /a/lib/libc.so.1"; sleep 3
  _fzt "echo FZ_NEW; digest -a md5 /a/lib/libc.so.1";                sleep 3
  _fzt "rm -f /var/zap/cache; rm -rf /a/fzc /a/fzg";                 sleep 3
  _fzt "zpool export rpool; echo FZ_DONE";                           sleep 6

  # capture the result screen (FZ_ markers + md5s) for the build log, via
  # vncdotool (the monitor screendump proved unreliable) and OCR the FZ_ lines.
  local rpng="/tmp/${vmname}.result.png"
  rm -f "$rpng"
  $V capture "$rpng" >/dev/null 2>&1
  if [ -s "$rpng" ] && command -v tesseract >/dev/null 2>&1; then
    echo "===== finalizeImage result (OCR of FZ_ markers; saved $rpng) ====="
    tesseract "$rpng" - 2>/dev/null | grep -aiE 'FZ_|[0-9a-f]{32}' || echo "(no FZ_ markers OCR'd; inspect $rpng)"
    echo "================================================================"
  else
    echo "finalizeImage: result capture unavailable (no vncdotool frame / tesseract)"
  fi

  echo "finalizeImage: powering off helper"
  _fzt "poweroff"
  local i
  for i in $(seq 1 24); do
    sleep 5
    pgrep -f "$vmname" >/dev/null 2>&1 || { echo "finalizeImage: helper off"; break; }
  done
  pkill -9 -f "$vmname" 2>/dev/null || true
  echo "finalizeImage: done"
  return 0
}

# Isolate the hook so a transient failure here (the image is already built)
# cannot abort the build. Runs with errexit off.
( set +e; finalizeImage )
