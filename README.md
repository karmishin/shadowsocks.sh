# shadowsocks.sh

A POSIX-compliant shell script that configures a basic [shadowsocks-rust](https://github.com/shadowsocks/shadowsocks-rust) server and generates a client configuration file.

**NOTE**: this script makes a GET request to ident.me to determine your server's public IP address. This may have privacy implications.

## Quick guide

On your server:

```shell
# download
wget https://raw.githubusercontent.com/karmishin/shadowsocks.sh/master/shadowsocks.sh

# check the contents
less shadowsocks.sh

# mark as executable
chmod +x shadowsocks.sh

# run (as root)
./shadowsocks.sh
```
