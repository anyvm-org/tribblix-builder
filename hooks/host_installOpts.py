# Tribblix live ISO -> hard-drive install driver (host-side hook).
#
# Ported from the old hooks/installOpts.sh. Run by base-builder/build.py via
# exec() into its module globals, so waitForText / inputKeys / time / log / env
# are bare names (the VM-abstraction API) -- mirroring how build.sh used to
# source the shell hook. It MUST be a .py host hook (not host_*.sh): a plain
# bash subprocess would not have waitForText / inputKeys defined.
#
# The live image boots to a `tribblix login:` prompt with user jack /
# password jack. We log in, `su -` to root (password "tribblix"), and run
# Tribblix's installer:
#
#     ./live_install.sh -G <disk> <overlay>
#
# We omit the overlay arg to get a minimal install (just the ISO's own
# contents laid onto disk), keeping the qcow2 compact.
#
# The VM's virtual disk shows up as c2t0d0 on this qemu SATA/AHCI config
# (virtio-blk would enumerate differently; we use VM_DISK=sata by default).
#
# The installer finishes with a "reboot now" message; we chain `poweroff`
# so build.py's _wait_vm_down() sees the shutdown and the pipeline moves on.

# Live ISO asks for a keyboard layout first ("To select the keyboard layout,
# enter a number [default 47]:"). Default 47 = US-English; press Enter to
# accept it, then fall through to the login prompt.
waitForText("keyboard layout", "300")
time.sleep(2)
inputKeys("enter")

waitForText("login:", "300")
time.sleep(3)

inputKeys("string jack; enter")
time.sleep(3)

# live image has password jack for user jack
inputKeys("string jack; enter")
time.sleep(5)

# Become root -- password is "tribblix". Quote `su -` as a single payload so
# input's tokenizer does not split "su" and "-" into two args (the `-` would
# get lost, leaving us in jack's home, unable to find /root/live_install.sh
# via `./`).
inputKeys("string 'su -'; enter")
time.sleep(3)
inputKeys("string %s; enter" % env("VM_ROOT_PASSWORD"))
time.sleep(5)

# Dump disk inventory first so if the install target is wrong we can read the
# right device name off the console log. `format < /dev/null` lists disks then
# exits (empty stdin makes it quit after the listing).
inputKeys("string 'format < /dev/null; echo DISK_LIST_DONE'; enter")
waitForText("DISK_LIST_DONE", "30")
time.sleep(3)

# Kick the installer and chain `; poweroff` so build.py's isRunning /
# _wait_vm_down poll moves on once live_install.sh returns, regardless of its
# exit status. Use the absolute path -- ./live_install.sh only resolves if
# `su -` actually put us in /root.
inputKeys("string '/root/live_install.sh -G c2t0d0; /usr/sbin/poweroff'; enter")
