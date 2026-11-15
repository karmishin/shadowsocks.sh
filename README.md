# shadowsocks.sh

shadowsocks.sh is a simple shadowsocks server installer.

Some features:

- sets up a [shadowsocks-rust](https://github.com/shadowsocks/shadowsocks-rust) server
- optionally sets up a [cloak](https://github.com/cbeuw/Cloak) server for obfuscation (use the `-c` flag)
- sets up systemd/openrc services depending on your init system, running as unprivileged `shadowsocks`/`cloak` users
- opens the required port in firewalld or ufw if one of them is active
- written in sh, designed to be portable and easy to audit
- requires an internet connection to download ssserver and cloak binaries

## Requirements

- an x86_64 or aarch64 Linux server with glibc or musl
- systemd or OpenRC (0.45 or newer for Cloak)
- `wget`
- `tar` with xz support (e.g. the `xz-utils` package on Debian/Ubuntu)
- `sha256sum`, `od`, `mktemp`, `install`, `awk` (coreutils or busybox)
- `useradd` or busybox `adduser`

## Usage

```
./shadowsocks.sh [-c]

Flags:
  -c    Install Cloak (https://github.com/cbeuw/Cloak)
```

## Quick start

SSH into your server and run the following commands (as root).

1. Download the script:

```shell
wget https://raw.githubusercontent.com/karmishin/shadowsocks.sh/master/shadowsocks.sh
```

2. Optionally examine the contents with your favorite text editor

3. Mark as executable:

```
chmod +x shadowsocks.sh
```

4. Run the script:

```
# remove the '-c' flag if you are not planning to use Cloak
./shadowsocks.sh -c
```
