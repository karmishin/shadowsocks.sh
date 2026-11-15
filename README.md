# shadowsocks.sh

shadowsocks.sh is a simple shadowsocks server installer.

Some features:

- sets up a [shadowsocks-rust](https://github.com/shadowsocks/shadowsocks-rust) server
- optionally sets up a [cloak](https://github.com/cbeuw/Cloak) server for obfuscation (use the `-c` flag)
- sets up systemd/openrc services depending on your init system, running as unprivileged `shadowsocks`/`cloak` users
- opens the required port in firewalld or ufw if one of them is active
- prints an `ss://` link for clients (with the Cloak plugin settings included when using `-c`), plus a QR code if `qrencode` is installed
- keeps your credentials when run again, so it can be used to update the binaries
- written in sh, designed to be portable and easy to audit
- requires an internet connection to download ssserver and cloak binaries

## Requirements

- an x86_64 or aarch64 Linux server with glibc or musl
- systemd or OpenRC (0.45 or newer for Cloak)
- `wget`
- `tar` with xz support (e.g. the `xz-utils` package on Debian/Ubuntu)
- `sha256sum`, `od`, `mktemp`, `install`, `awk` (coreutils or busybox)
- `useradd` or busybox `adduser`

## Quick start

SSH into your server and run as root (remove `-c` if you don't want Cloak):

```shell
wget -qO- https://raw.githubusercontent.com/karmishin/shadowsocks.sh/master/shadowsocks.sh | sh -s -- -c
```

If you'd rather read the script before running it:

```shell
wget https://raw.githubusercontent.com/karmishin/shadowsocks.sh/master/shadowsocks.sh
less shadowsocks.sh
sh shadowsocks.sh -c
```

## Usage

```
shadowsocks.sh [-c] [-r] | -s | -u

  -c    Also install Cloak (https://github.com/cbeuw/Cloak)
  -r    Generate new credentials instead of keeping the existing ones
  -s    Show the client configuration of the existing installation
  -u    Uninstall
  -h    Show this help
```

Running the script again updates the binaries and keeps the existing credentials, so clients keep working. Running it without `-c` on a server with Cloak removes Cloak.
