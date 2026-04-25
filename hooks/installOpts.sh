
# Tribblix live ISO → hard-drive install driver.
#
# The live image boots to a `tribblix login:` prompt with user jack /
# password jack. We log in, `su -` to root (password "tribblix"), and
# run Tribblix's installer:
#
#     ./live_install.sh -G <disk> <overlay>
#
# `kitchen-sink` pulls in a practical desktop-ish set of packages; we
# use `base` for a smaller server-style install to keep the qcow2
# compact. Adjust in the conf if a fatter image is wanted.
#
# The VM's virtual disk shows up as c2t0d0 on this qemu/libvirt config
# (virtio-blk would be different; we use SATA by default).
#
# Installer finishes with a "reboot now" message. We chain `poweroff`
# so build.sh's isRunning loop sees shutdown and moves on.

# Live ISO asks for a keyboard layout first ("To select the keyboard
# layout, enter a number [default 47]:"). Default 47 = US-English; just
# press Enter to accept it, then fall through to the login prompt.
waitForText "keyboard layout" 60
sleep 2
inputKeys "enter"

waitForText "login:" 60

sleep 3

inputKeys "string jack; enter"
sleep 3

# live image has password jack for user jack
inputKeys "string jack; enter"
sleep 5

# Become root — password is "tribblix". Quote `su -` as a single
# payload so vbox.sh's `input` doesn't eval-split "su" and "-" into
# two args (the `-` would get lost, leaving us in jack's home and
# unable to find /root/live_install.sh via `./`).
inputKeys "string 'su -'; enter"
sleep 3
inputKeys "string $VM_ROOT_PASSWORD; enter"
sleep 5

# Dump disk inventory first so if the install target is wrong we can
# read the right device name off the console log. `format` without
# input just lists disks then prompts; we pipe an empty stdin via `< /dev/null`
# to make it exit after listing.
inputKeys "string 'format < /dev/null; echo DISK_LIST_DONE'; enter"
waitForText "DISK_LIST_DONE" 30
sleep 3

# Kick the installer and chain `poweroff` so build.sh's isRunning loop
# sees the shutdown even if live_install.sh returns non-zero. Tee the
# installer output for post-mortem if boot later fails.
# `base` isn't a recognized Tribblix overlay — omit the overlay arg to
# get a minimal install (just the ISO's own contents laid onto disk).
# Chain `; poweroff` so build.sh's isRunning poll moves on once the
# installer returns, regardless of its exit status.
# Use the absolute path — `./live_install.sh` only resolves if we're
# in /root, which relies on `su -` having worked.
inputKeys "string '/root/live_install.sh -G c2t0d0; /usr/sbin/poweroff'; enter"
