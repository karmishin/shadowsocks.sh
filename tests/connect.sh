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

# Prints a value from the settings table ("Server" won't match "Server name")
field() {
	sed -n "s/^  $1   *//p" "$log"
}

fetch_through() {
	curl -fsS -o /dev/null --max-time 10 --retry 10 --retry-delay 1 --retry-all-errors \
		--socks5-hostname "127.0.0.1:$1" https://example.com/
}

# The runner can't reach its own public IP
url=$(sed -n 's/^  \(ss:\/\/.*\)/\1/p' "$log" | sed 's/@[^:]*:/@127.0.0.1:/')

if grep -q "^ck-client config" "$log"; then
	cloak=true
	version=$(sed -n 's/^cloak_version="\(.*\)"$/\1/p' "${repo_dir}/shadowsocks.sh")
	case $(uname -m) in
		x86_64) arch="amd64" ;;
		aarch64) arch="arm64" ;;
	esac

	curl -fsSL -o "${work_dir}/ck-client" \
		"https://github.com/cbeuw/Cloak/releases/download/v${version}/ck-client-linux-${arch}-v${version}"
	chmod +x "${work_dir}/ck-client"

	# sslocal looks for the ck-client plugin in PATH
	PATH="${work_dir}:${PATH}"
else
	cloak=false
fi

echo "Testing the ss:// URL..."
/opt/shadowsocks/bin/sslocal -b 127.0.0.1:1080 --server-url "$url" &
pids="$pids $!"
fetch_through 1080

if [ "$cloak" = true ]; then
	echo "Testing the ck-client config..."
	sed -n '/^ck-client config/,/^  }/p' "$log" | sed '1d; s/^  //' > "${work_dir}/ckclient.json"

	ck-client -c "${work_dir}/ckclient.json" -s 127.0.0.1 -p "$(field "Port")" -l 1984 &
	pids="$pids $!"
	/opt/shadowsocks/bin/sslocal -b 127.0.0.1:1081 -s 127.0.0.1:1984 \
		-k "$(field "Password")" -m "$(field "Method")" &
	pids="$pids $!"
	fetch_through 1081
fi

echo "Connection works."
