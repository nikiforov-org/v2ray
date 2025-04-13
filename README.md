# Automatic V2Ray VPN Serverside Installation on VPS

Features available via the interface:

- Generate multiple profiles and save them to files. Configuration files are saved to the v2ray-profiles folder
- Revoke profiles and delete their configuration files
- Full removal of V2Ray and related

Below is a list of operating systems where this script can be used "as is." The script uses apt-get for package management and systemctl for service management, so it is best suited for Linux distributions that use the APT package manager and systemd. Examples include:

- Ubuntu (all versions that use systemd, e.g. 16.04 LTS, 18.04 LTS, 20.04 LTS, 22.04 LTS)
- Debian (e.g. Debian 9 "Stretch", Debian 10 "Buster", Debian 11 "Bullseye")
- Linux Mint (Ubuntu-based distributions)
- Raspbian (or Raspberry Pi OS with systemd)
- Elementary OS (Ubuntu-based)
- Pop!\_OS (Ubuntu-based)
- Zorin OS (Ubuntu-based)

**You can use V2Box as a VPN client.**

## Installation

Run the script with root privileges:

```bash
wget -qO- https://v2ray.pages.dev/v2ray.sh | bash
```

This setup works over WebSocket and uses port 443. For stable operation, it is recommended to use a clean VPS instance that is not used to host web apps.

**Make sure to open TCP port 443 for inbound connections.**
