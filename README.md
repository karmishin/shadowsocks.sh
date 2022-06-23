# shadowsocks.sh

shadowsocks.sh is a shell script that installs and configures a [shadowsocks-rust](https://github.com/shadowsocks/shadowsocks-rust) server and (optionally) a [Cloak](https://github.com/cbeuw/Cloak) server.

## Usage

```
./shadowsocks.sh [-c]

Flags:
  -c    Install Cloak (learn more at https://github.com/cbeuw/Cloak)
```

## Quick start

SSH into your server and run the following commands (as root):

```shell
# download
wget https://raw.githubusercontent.com/karmishin/shadowsocks.sh/master/shadowsocks.sh

# check the contents
less shadowsocks.sh

# mark as executable
chmod +x shadowsocks.sh

# execute the actual script
# remove the '-c' flag if you are not planning to use Cloak
./shadowsocks.sh -c
```
