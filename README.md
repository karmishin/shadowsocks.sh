# shadowsocks.sh

shadowsocks.sh is a single-command shadowsocks installer.

- sets up a [shadowsocks-rust](https://github.com/shadowsocks/shadowsocks-rust) server
- optionally sets up a [cloak](https://github.com/cbeuw/Cloak) server for shadowsocks obfuscation
- supports systemd and OpenRC

## Requirements

- `wget`

## Usage

```
./shadowsocks.sh [-c]

Flags:
  -c    Install Cloak (https://github.com/cbeuw/Cloak)
```

## Quick start

SSH into your server and run the following commands (as root):

```shell
# download
wget https://raw.githubusercontent.com/karmishin/shadowsocks.sh/master/shadowsocks.sh

# optionally examine the contents with your favorite text editor

# mark as executable
chmod +x shadowsocks.sh

# execute the actual script
# remove the '-c' flag if you are not planning to use Cloak
./shadowsocks.sh -c
```
