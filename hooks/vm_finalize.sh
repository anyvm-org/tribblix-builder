# Run last in the guest over SSH, after vm_postBuild.sh and the post-install
# reboot (build.py: run_hook("finalize") -> ssh osname sh < this file).
#
# omnios-builder clears the root password here so the later SSH-key install
# (which runs as root over the existing key auth) doesn't trip over
# `PASSREQ=YES` if anything switches to password auth. We do the same for
# symmetry across the illumos family.
sed 's/^PASSREQ=YES/PASSREQ=NO/' /etc/default/login > /tmp/login.new
cat /tmp/login.new > /etc/default/login
passwd -d root
rm -f /tmp/login.new

# Drop any shell history captured during build (root password, install
# transcripts) -- mirrors openindiana-builder/hooks/finalize.sh.
rm -f "$HISTFILE" || rm -f ~/.sh_history

cat /etc/resolv.conf
