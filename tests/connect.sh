#!/bin/sh

# Checks that a server set up by shadowsocks.sh actually relays traffic
#
# Usage: tests/connect.sh <file with the installer's output>

set -e

log=$1
repo_dir=$(cd "$(dirname "$0")/.." && pwd)
work_dir=$(mktemp -d)
pids=""

cleanup() {
	# shellcheck disable=SC2086
	[ -z "$pids" ] || kill $pids 2> /dev/null || true
	rm -rf "$work_dir"
}
trap cleanup EXIT

# Prints the value of a "Name: value" line from the installer output
field() {
	sed -n "s/^$1: //p" "$log"
}

password=$(field "Password")
method=$(field "Encryption method" | head -n 1)

if grep -q "^CLOAK configuration" "$log"; then
	version=$(sed -n 's/^cloak_version="\(.*\)"$/\1/p' "${repo_dir}/shadowsocks.sh")
	case $(uname -m) in
		x86_64) arch="amd64" ;;
		aarch64) arch="arm64" ;;
	esac

	echo "Starting ck-client ${version}..."
	curl -fsSL -o "${work_dir}/ck-client" \
		"https://github.com/cbeuw/Cloak/releases/download/v${version}/ck-client-linux-${arch}-v${version}"
	chmod +x "${work_dir}/ck-client"

	cat > "${work_dir}/ckclient.json" <<- EOF
		{
		    "Transport": "direct",
		    "ProxyMethod": "shadowsocks",
		    "EncryptionMethod": "$(field "Encryption method" | tail -n 1)",
		    "UID": "$(field "UID")",
		    "PublicKey": "$(field "Public key")",
		    "ServerName": "$(field "Server name")",
		    "BrowserSig": "$(field "Browser")",
		    "NumConn": 4,
		    "StreamTimeout": $(field "Stream timeout")
		}
	EOF

	"${work_dir}/ck-client" -c "${work_dir}/ckclient.json" -s 127.0.0.1 -p "$(field "Port")" -l 1984 &
	pids="$pids $!"
	ss_server="127.0.0.1:1984"
else
	ss_server="127.0.0.1:$(field "Port")"
fi

echo "Starting sslocal..."
/opt/shadowsocks/bin/sslocal -b 127.0.0.1:1080 -s "$ss_server" -k "$password" -m "$method" &
pids="$pids $!"

echo "Fetching a page through the proxy..."
curl -fsS -o /dev/null --max-time 10 --retry 10 --retry-delay 1 --retry-all-errors \
	--socks5-hostname 127.0.0.1:1080 https://example.com/

echo "Connection works."
