
bootadm set-menu timeout=1

svcadm disable svc:/system/filesystem/autofs:default


# Tribblix uses NWAM by default. NWAM tracks NICs by their install-time
# instance name (e1000g0); at runtime under anyvm/QEMU, the AHCI
# controller takes a PCI slot ahead of the NIC, so the e1000 ends up at
# instance 1 and NWAM does not auto-DHCP it -- the VM boots without an
# IP and SSH is unreachable.
#
# `ipadm` refuses to claim a NIC while NWAM is online ("Operation not
# supported on disabled object"). The legacy `ifconfig` command works
# regardless. Use the openindiana-builder pattern: a tiny /etc/init.d
# script linked from /etc/rc3.d that, at boot, plumbs and DHCPs every
# physical link the kernel found -- no matter what its instance name
# turned out to be.

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

