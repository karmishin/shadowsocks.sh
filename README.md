# shadowsocks.sh

shadowsocks.sh is a simple shadowsocks server installer.

Some features:

- sets up a [shadowsocks-rust](https://github.com/shadowsocks/shadowsocks-rust) server
- optionally sets up a [cloak](https://github.com/cbeuw/Cloak) server for obfuscation (use the `-c` flag)
- sets up systemd/openrc services depending on your init system
- written in sh, designed to be portable and easy to audit
- requires an internet connection to download ssserver and cloak binaries

## Requirements

- `wget`

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
