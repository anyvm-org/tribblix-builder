
bootadm set-menu timeout=1

svcadm disable svc:/system/filesystem/autofs:default


# Tribblix uses NWAM by default. NWAM tracks NICs by their install-time
# instance name (e1000g0); at runtime under anyvm/QEMU, the AHCI
# controller takes a PCI slot ahead of the NIC, so the e1000 ends up at
# instance 1 and NWAM does not auto-DHCP it -- the VM boots without an
# IP and SSH is unreachable.
#
# IMPORTANT: do NOT touch network/physical:nwam from this script. Doing so
# tears down the NIC that this SSH session is riding on, the parent
# `ssh tribblix sh<postBuild.sh` then hangs forever waiting for EOF, and
# build.sh stalls. Tried it -- it raced inconsistently and locked up
# ~half the runs.
#
# Instead, ship a tiny rc3.d/S99 script that, at every boot, walks every
# physical link the kernel found and `ifconfig plumb up; ifconfig dhcp
# start`s it. NWAM only manages NICs whose instance name matches its
# stored profile (e1000g0); a NIC at e1000g1 is invisible to NWAM, so
# our `ifconfig` doesn't fight anyone for it.

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


# DNS resolvers. anyvm.py runs the QEMU user-mode network with no DNS
# advertised over DHCP; without a static resolv.conf, name lookups fail
# and NTP / package fetches hang for the full timeout each call.
rm -f /etc/resolv.conf
echo "nameserver 8.8.8.8" >> /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf
echo "nameserver 9.9.9.9" >> /etc/resolv.conf


# anyvm.py builds the netdev with `ipv6=off`. If dhcpagent still requests
# option 6 (DNS) over IPv6 or accepts an IPv6 lease, it can wait the full
# IPv6 negotiation timeout (~30s) per boot before the IPv4 lease lands and
# sshd becomes reachable -- anyvm.py's SSH wait loop sees that as "VM
# never came up". Strip option 6 from the request list and add IPv6 to
# the ignore list (same pattern as omnios-builder/hooks/postBuild.sh).
sed -i 's/^PARAM_REQUEST_LIST=\(.*\),6\(,.*\)$/PARAM_REQUEST_LIST=\1\2/; s/^PARAM_REQUEST_LIST=6,\(.*\)$/PARAM_REQUEST_LIST=\1/; s/^PARAM_REQUEST_LIST=\(.*\),6$/PARAM_REQUEST_LIST=\1/' /etc/default/dhcpagent 2>/dev/null || true
sed -i 's/^PARAM_IGNORE_LIST=$/PARAM_IGNORE_LIST=6/' /etc/default/dhcpagent 2>/dev/null || true
