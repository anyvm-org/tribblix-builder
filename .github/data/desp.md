How the images are built:

Each image is built automatically in the
[anyvm-org/tribblix-builder](https://github.com/anyvm-org/tribblix-builder)
repo's GitHub Actions: it downloads the official Tribblix installer
ISO, boots it in QEMU, runs the installation unattended, enables ssh,
pre-installs the packages listed in the conf, and exports the installed
disk as a compressed qcow2 image.

Upstream install media: the official Tribblix ISOs listed on
http://www.tribblix.org/download.html (served from iso.tribblix.org).
