
bootadm set-menu timeout=1

svcadm disable svc:/system/filesystem/autofs:default


# Tribblix uses NWAM by default. NWAM tracks NICs by their install-time
# instance name (e1000g0); at runtime under anyvm/QEMU, the AHCI
# controller takes a PCI slot ahead of the NIC, so the e1000 ends up at
# instance 1 and NWAM does not auto-DHCP it -- the VM boots without an
# IP and SSH is unreachable.
#
# IMPORTANT: do NOT touch network/physical:nwam from this script. Doing so
# tears down the NIC that this SSH session is riding on; the parent
# `ssh tribblix sh<postBuild.sh` then hangs waiting for EOF and build.sh
# stalls.
#
# Instead, ship a tiny rc3.d/S99 script. NWAM only manages NICs whose
# instance name matches its stored profile (e1000g0); a NIC at e1000g1
# is invisible to NWAM, so plain `ifconfig` doesn't fight anyone for it.
#
# The script also rewrites /etc/resolv.conf with public resolvers AFTER
# `ifconfig dhcp start`, because dhcpagent overwrites resolv.conf with
# whatever the lease's DNS option (6) says. On some hosts (notably
# GitHub-Actions runners) libvirt's dnsmasq -> host-DNS forwarding chain
# is broken, leaving the guest with `nameserver 192.168.122.1` that
# cannot resolve anything; zap then fails with "Download ... has wrong
# size" because the fetch lands on nothing.

cat > /etc/init.d/anyvm-net <<'EOF'
#!/bin/sh
case "$1" in
start)
    for link in $(/usr/sbin/dladm show-link -p -o link 2>/dev/null); do
        case "$link" in
            lo*) continue ;;
        esac
        /usr/sbin/ifconfig "$link" plumb up 2>/dev/null
        /usr/sbin/ifconfig "$link" dhcp start 2>/dev/null
    done
    # Give dhcpagent a moment to touch resolv.conf, then clobber it with
    # public resolvers we control. Idempotent across reboots.
    sleep 5
    cat > /etc/resolv.conf <<RESOLV
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 9.9.9.9
RESOLV
    ;;
stop)
    ;;
*)
    echo "Usage: $0 {start|stop}"
    exit 1
    ;;
esac
exit 0
EOF
chmod +x /etc/init.d/anyvm-net
ln -sf /etc/init.d/anyvm-net /etc/rc3.d/S99anyvm-net


# Static resolv.conf right now (this SSH session and the next one before
# the first reboot use it). The init script above keeps it correct on
# every subsequent boot.
rm -f /etc/resolv.conf
echo "nameserver 8.8.8.8" >> /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf
echo "nameserver 9.9.9.9" >> /etc/resolv.conf


# anyvm.py builds the netdev with `ipv6=off`. If dhcpagent still requests
# option 6 over IPv6 or accepts an IPv6 lease, it can wait the full IPv6
# negotiation timeout (~30s) per boot before the IPv4 lease lands.
#
# illumos /usr/bin/sed has no -i and /usr/bin/awk is old-awk (no gsub).
# Use /usr/bin/nawk explicitly, which has been on illumos forever.
if [ -f /etc/default/dhcpagent ]; then
    /usr/bin/nawk '
        /^PARAM_REQUEST_LIST=/ {
            gsub(/,6,/, ",", $0)
            sub(/=6,/, "=", $0)
            sub(/,6$/, "", $0)
            sub(/=6$/, "=", $0)
        }
        /^PARAM_IGNORE_LIST=$/ { $0 = "PARAM_IGNORE_LIST=6" }
        { print }
    ' /etc/default/dhcpagent > /tmp/dhcpagent.new \
        && cp /tmp/dhcpagent.new /etc/default/dhcpagent \
        && rm -f /tmp/dhcpagent.new
fi
