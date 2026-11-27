Vamp Sync 0.1.0 for Linux

Install on Debian 12, Ubuntu 24.04, or a newer compatible release using an
active Xorg desktop. This archive contains amd64 (x86-64) and arm64 packages.
Unzip the archive and run:

    ./install.sh

The script checks both installers against the included SHA-256 manifest and
asks apt to install the one for your architecture. The packages can also be
installed individually with apt install ./vamp-sync-linux_<version>_<arch>.deb.

Open Vamp Sync from the desktop app menu, or run vamp-sync as your regular
desktop user. Click Start host. Use the Remote control switch if you want to
permit pointer and keyboard input. Pair in Vamp Control or Vamp Stream and
compare the complete fingerprints on both devices before approving.

To send a tester report, reproduce the problem and choose Export diagnostics
from the gear menu. Include the Linux distribution, desktop, iOS app build,
approximate time, and steps to reproduce. The installed tester specification
is at /usr/share/doc/vamp-sync-linux/TESTING.md.

The Linux release supports X11. See the installed README for feature scope,
Tailscale setup, and optional clipboard and application launch support.
The software is distributed under the Apache License 2.0.
