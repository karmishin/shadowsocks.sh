#!/bin/sh

set -e

# Download options
shadowsocks_version="1.25.0"
cloak_version="2.12.0"

# gh release view -R cbeuw/Cloak v<version> --json assets --jq '.assets[] | "\(.name) \(.digest)"'
cloak_sha256_amd64="f2bea92c99195ac26cd5749e80d07339d5582c103f73934b414150c6070dae4e"
cloak_sha256_arm64="9b26306639e60a73e6b2bdae4876fa72f833a47e5fab31dcea9f3ebe22aa7cfb"

# Server configuration options
password=$(tr -dc A-Za-z0-9 < /dev/urandom | head -c 32)
method="aes-256-gcm"

# Cloak configuration options
cloak_port=443
# Used both as the redirect target for non-cloak traffic and as the client SNI
cloak_server_name="ya.ru"
cloak_stream_timeout=300

# Directories
shadowsocks_dir="/opt/shadowsocks"
cloak_dir="/opt/cloak"
cloak_state_dir="/var/lib/cloak"
systemd_dir="/etc/systemd/system"
openrc_dir="/etc/init.d"

# Unprivileged users the services run as
shadowsocks_user="shadowsocks"
cloak_user="cloak"

# Defaults
cloak=false
services_installed=false

usage() {
	printf "Usage: %s [-c]\n" "$0" >&2
	exit 2
}

# Command-line options
while getopts "c" o; do case $o in
	c) cloak=true ;;
	*) usage ;;
esac done

check_priv() {
	if [ "$(id -u)" -ne 0 ]; then
		echo "This script must be run as root." >&2
		exit 1
	fi
}

detect_arch() {
	machine=$(uname -m)

	case $machine in
		x86_64|amd64)
			ss_arch="x86_64"
			cloak_arch="amd64"
			cloak_sha256=$cloak_sha256_amd64
			;;
		aarch64|arm64)
			ss_arch="aarch64"
			cloak_arch="arm64"
			cloak_sha256=$cloak_sha256_arm64
			;;
		*)
			echo "Unsupported architecture: ${machine}. Only x86_64 and aarch64 are supported. Aborting..." >&2
			exit 1
			;;
	esac
}

detect_libc() {
	ldd_version=$(ldd --version 2>&1 | head -n 1)

	if echo "$ldd_version" | grep -q -e GNU -e GLIBC; then
		libc="gnu"
	elif echo "$ldd_version" | grep -q musl; then
		libc="musl"
	else
		echo "Unknown libc implementation. Only glibc and musl are supported. Aborting..." >&2
		exit 1
	fi
}

has_ss() {
	command -v ss > /dev/null 2>&1
}

generate_port() {
	attempts=0

	while :; do
		# Random port in the 1024-65535 range
		random=$(od -An -N2 -tu2 /dev/urandom | tr -d ' ')
		port=$((random % 64512 + 1024))

		# Skip checking on minimal systems without ss (e.g. busybox)
		if ! has_ss; then
			return 0
		fi

		# Check if the port is already used (TCP or UDP)
		if ! ss -Htuln "sport = :${port}" | grep -q .; then
			return 0
		fi

		attempts=$((attempts + 1))
		if [ "$attempts" -ge 20 ]; then
			echo "Unable to find a free port. Aborting..." >&2
			exit 1
		fi
	done
}

check_cloak_port() {
	if ! has_ss; then
		return 0
	fi

	# A cloak server left over from a previous run is fine
	if ss -Htlnp "sport = :${cloak_port}" | grep -v '"ck-server"' | grep -q .; then
		echo "Port ${cloak_port} is already used by another process, but cloak needs it. Aborting..." >&2
		exit 1
	fi
}

cleanup() {
	rm -rf "$tmp_dir"
}

create_tmp_dir() {
	tmp_dir=$(mktemp -d)
	trap cleanup EXIT
	trap 'exit 1' HUP INT TERM
}

create_user() {
	if id "$1" > /dev/null 2>&1; then
		return 0
	fi

	nologin=$(command -v nologin || echo /bin/false)

	if ! grep -q "^${1}:" /etc/group; then
		if command -v groupadd > /dev/null 2>&1; then
			groupadd --system "$1"
		else
			addgroup -S "$1"
		fi
	fi

	if command -v useradd > /dev/null 2>&1; then
		useradd --system --gid "$1" --no-create-home --shell "$nologin" "$1"
	else
		adduser -S -D -H -G "$1" -s "$nologin" "$1"
	fi
}

write_secret_file() {
	rm -f "$1"
	(umask 077 && cat > "$1")
	chgrp "$2" "$1"
	chmod 640 "$1"
}

download() {
	if ! wget -T 30 -O "$2" "$1" 2>> "${tmp_dir}/wget.log"; then
		echo "Download of $1 failed:" >&2
		tail -n 20 "${tmp_dir}/wget.log" >&2
		exit 1
	fi
}

verify_checksum() {
	actual=$(sha256sum "$1" | cut -d ' ' -f 1)

	if [ "$actual" != "$2" ]; then
		echo "Checksum mismatch for $(basename "$1") (expected $2, got ${actual}). Aborting..." >&2
		exit 1
	fi
}

download_shadowsocks() {
	echo "Downloading shadowsocks-rust ${shadowsocks_version}..."

	archive="shadowsocks-v${shadowsocks_version}.${ss_arch}-unknown-linux-${libc}.tar.xz"
	base_url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/v${shadowsocks_version}"

	download "${base_url}/${archive}" "${tmp_dir}/${archive}"
	download "${base_url}/${archive}.sha256" "${tmp_dir}/${archive}.sha256"
	verify_checksum "${tmp_dir}/${archive}" "$(cut -d ' ' -f 1 < "${tmp_dir}/${archive}.sha256")"

	echo "Extracting shadowsocks..."
	tar -xf "${tmp_dir}/${archive}" -C "${shadowsocks_dir}/bin"
}

download_cloak() {
	echo "Downloading cloak ${cloak_version}..."

	download "https://github.com/cbeuw/Cloak/releases/download/v${cloak_version}/ck-server-linux-${cloak_arch}-v${cloak_version}" \
		"${tmp_dir}/ck-server"
	verify_checksum "${tmp_dir}/ck-server" "$cloak_sha256"

	install -m 755 "${tmp_dir}/ck-server" "${cloak_dir}/bin/ck-server.new"
	mv -f "${cloak_dir}/bin/ck-server.new" "${cloak_dir}/bin/ck-server"
}

create_ss_config() {
	echo "Generating shadowsocks config..."

	if [ "$cloak" = true ]; then
		address="127.0.0.1"
		mode="tcp_only"
	else
		address="::"
		mode="tcp_and_udp"
	fi

	write_secret_file "${shadowsocks_dir}/config.json" "$shadowsocks_user" <<- EOF
		{
		    "server": "${address}",
		    "server_port": ${port},
		    "password": "${password}",
		    "method": "${method}",
		    "mode": "${mode}"
		}
	EOF
}

create_cloak_config() {
	echo "Generating cloak config..."

	ck_key_output=$("${cloak_dir}/bin/ck-server" -key)
	cloak_public_key=$(echo "$ck_key_output" | head -n 1 | awk '{print $5}')
	cloak_private_key=$(echo "$ck_key_output" | tail -n 1 | awk '{print $8}')
	cloak_uid=$("${cloak_dir}/bin/ck-server" -uid | awk '{print $4}')

	if [ -z "$cloak_public_key" ] || [ -z "$cloak_private_key" ] || [ -z "$cloak_uid" ]; then
		echo "Unable to parse the keys generated by ck-server. Aborting..." >&2
		exit 1
	fi

	write_secret_file "${cloak_dir}/config.json" "$cloak_user" <<- EOF
		{
		    "ProxyBook": {
		        "shadowsocks": [
		            "tcp",
		            "127.0.0.1:${port}"
		        ]
		    },
		    "BindAddr": [
		        ":${cloak_port}"
		    ],
		    "BypassUID": [
		        "${cloak_uid}"
		    ],
		    "RedirAddr": "${cloak_server_name}",
		    "PrivateKey": "${cloak_private_key}",
		    "DatabasePath": "${cloak_state_dir}/userinfo.db",
		    "StreamTimeout": ${cloak_stream_timeout}
		}
	EOF
}

fix_selinux() {
	if ! command -v getenforce > /dev/null 2>&1; then
		return 0
	fi

	if [ "$(getenforce)" != "Enforcing" ]; then
		return 0
	fi

	echo "Fixing SELinux context..."

	if command -v semanage > /dev/null 2>&1; then
		semanage fcontext -a -t bin_t "${cloak_dir}/bin/ck-server" 2> /dev/null ||
			semanage fcontext -m -t bin_t "${cloak_dir}/bin/ck-server"
		restorecon "${cloak_dir}/bin/ck-server"
	else
		chcon -t bin_t "${cloak_dir}/bin/ck-server"
	fi
}

service_failed() {
	echo "Failed to start $1. $2 Aborting..." >&2
	exit 1
}

start_systemd_service() {
	systemctl daemon-reload

	if ! systemctl enable --quiet "$1" || ! systemctl restart "$1"; then
		service_failed "$1" "Run 'journalctl -u $1' for details."
	fi

	sleep 1
	if ! systemctl is-active --quiet "$1"; then
		service_failed "$1" "Run 'journalctl -u $1' for details."
	fi
}

install_ss_systemd_service() {
	cat > "${systemd_dir}/shadowsocks.service" <<- EOF
		[Unit]
		Description=shadowsocks-rust server
		After=network.target

		[Service]
		Type=simple
		User=${shadowsocks_user}
		Group=${shadowsocks_user}
		NoNewPrivileges=yes
		ProtectSystem=strict
		ProtectHome=yes
		PrivateTmp=yes
		Restart=on-failure
		ExecStart=${shadowsocks_dir}/bin/ssserver -c ${shadowsocks_dir}/config.json --log-without-time

		[Install]
		WantedBy=multi-user.target
	EOF

	start_systemd_service shadowsocks.service
}

install_cloak_systemd_service() {
	cat > "${systemd_dir}/cloak-server.service" <<- EOF
		[Unit]
		Description=cloak server
		After=network.target

		[Service]
		Type=simple
		User=${cloak_user}
		Group=${cloak_user}
		AmbientCapabilities=CAP_NET_BIND_SERVICE
		NoNewPrivileges=yes
		ProtectSystem=strict
		ProtectHome=yes
		PrivateTmp=yes
		Restart=on-failure
		StateDirectory=$(basename "$cloak_state_dir")
		ExecStart=${cloak_dir}/bin/ck-server -c ${cloak_dir}/config.json

		[Install]
		WantedBy=multi-user.target
	EOF

	start_systemd_service cloak-server.service
}

start_openrc_service() {
	chmod +x "${openrc_dir}/$1"

	if [ ! -e "/etc/runlevels/default/$1" ]; then
		rc-update add "$1" default > /dev/null
	fi

	# restart (not start) so that a re-run picks up the new config
	if ! rc-service "$1" restart; then
		service_failed "$1" "Run 'rc-service $1 status' for details."
	fi
}

install_ss_openrc_service() {
	cat > "${openrc_dir}/shadowsocks" <<- EOF
		#!/sbin/openrc-run

		name="shadowsocks-rust server"
		command="${shadowsocks_dir}/bin/ssserver"
		command_args="-c ${shadowsocks_dir}/config.json --log-without-time"
		command_user="${shadowsocks_user}:${shadowsocks_user}"
		command_background="yes"
		pidfile="/run/shadowsocks.pid"

		depend() {
		    need net
		}
	EOF

	start_openrc_service shadowsocks
}

install_cloak_openrc_service() {
	# capabilities= needs OpenRC 0.45 or newer
	cat > "${openrc_dir}/cloak-server" <<- EOF
		#!/sbin/openrc-run

		name="cloak server"
		command="${cloak_dir}/bin/ck-server"
		command_args="-c ${cloak_dir}/config.json"
		command_user="${cloak_user}:${cloak_user}"
		capabilities="^cap_net_bind_service"
		command_background="yes"
		pidfile="/run/cloak-server.pid"

		depend() {
		    need net
		}

		start_pre() {
		    checkpath --directory --owner ${cloak_user}:${cloak_user} --mode 0700 ${cloak_state_dir}
		}
	EOF

	start_openrc_service cloak-server
}

install_services() {
	if [ -d /run/systemd/system ]; then
		install_ss_systemd_service
		if [ "$cloak" = true ]; then
			install_cloak_systemd_service
		fi
	elif command -v rc-service > /dev/null 2>&1; then
		install_ss_openrc_service
		if [ "$cloak" = true ]; then
			install_cloak_openrc_service
		fi
	else
		echo "Unable to detect the init system (only systemd and OpenRC are supported). Skipping service setup..."
		if [ "$cloak" = true ]; then
			# Normally created by the service manager
			mkdir -p "$cloak_state_dir"
			chown "${cloak_user}:${cloak_user}" "$cloak_state_dir"
			chmod 700 "$cloak_state_dir"
		fi
		return 0
	fi

	services_installed=true
}

open_firewall() {
	if [ "$cloak" = true ]; then
		ports="${cloak_port}/tcp"
	else
		ports="${port}/tcp ${port}/udp"
	fi

	if command -v firewall-cmd > /dev/null 2>&1 && firewall-cmd --state > /dev/null 2>&1; then
		echo "Opening ${ports} in firewalld..."
		for p in $ports; do
			firewall-cmd --quiet --permanent --add-port="$p"
		done
		firewall-cmd --quiet --reload
	elif command -v ufw > /dev/null 2>&1 && ufw status 2> /dev/null | grep -q "Status: active"; then
		echo "Opening ${ports} in ufw..."
		for p in $ports; do
			ufw allow "$p" > /dev/null
		done
	fi
}

get_public_ip() {
	public_ip_address=$(wget -T 10 -qO- https://4.ident.me/ 2> /dev/null ||
		wget -T 10 -qO- https://6.ident.me/ 2> /dev/null || true)

	# Discard anything that doesn't look like an IP address
	case $public_ip_address in
		''|*[!0-9A-Fa-f.:]*) public_ip_address="" ;;
	esac
}

print_header() {
	if [ "$services_installed" = true ]; then
		cat <<- EOF

			############################
			# Installation successful! #
			############################

		EOF
	else
		cat <<- EOF

			Installation finished, but no service was set up. Start the server manually:

			    ${shadowsocks_dir}/bin/ssserver -c ${shadowsocks_dir}/config.json
		EOF
		if [ "$cloak" = true ]; then
			echo "    ${cloak_dir}/bin/ck-server -c ${cloak_dir}/config.json"
		fi
		echo
	fi

	if [ -z "$public_ip_address" ]; then
		echo "WARNING: unable to determine the public IP address of this server, fill it in yourself."
		echo
		public_ip_address="<server IP>"
		ip_known=false
	else
		ip_known=true
	fi
}

print_ss_config() {
	cat <<- EOF
		SHADOWSOCKS configuration:

		Server IP: ${public_ip_address}
		Port: ${port}
		Password: ${password}
		Encryption method: ${method}
	EOF

	if [ "$ip_known" = false ]; then
		return 0
	fi

	client_config_path="${tmp_dir}/client.json"
	cat > "$client_config_path" <<- EOF
		{
		    "server": "${public_ip_address}",
		    "server_port": ${port},
		    "password": "${password}",
		    "method": "${method}"
		}
	EOF

	ssurl=$("${shadowsocks_dir}/bin/ssurl" --encode "$client_config_path")

	cat <<- EOF
		Server URL (SIP002):
		${ssurl}
	EOF
}

print_cloak_config() {
	cat <<- EOF
		SHADOWSOCKS configuration:

		Password: ${password}
		Encryption method: ${method}

		CLOAK configuration:

		Address: ${public_ip_address}
		Port: ${cloak_port}
		Encryption method: plain
		Browser: chrome
		Transport: direct
		Proxy method: shadowsocks
		Server name: ${cloak_server_name}
		UID: ${cloak_uid}
		Public key: ${cloak_public_key}
		Stream timeout: ${cloak_stream_timeout}
	EOF
}

# Check if running as root
check_priv

# Detect which binaries to download
detect_arch
detect_libc

# Generate a random free port and check that cloak's port is available
generate_port
if [ "$cloak" = true ]; then
	check_cloak_port
fi

# Private temporary directory
create_tmp_dir

# Create the necessary directories and users
mkdir -p "${shadowsocks_dir}/bin"
create_user "$shadowsocks_user"
if [ "$cloak" = true ]; then
	mkdir -p "${cloak_dir}/bin"
	create_user "$cloak_user"
fi

# Download and extract shadowsocks binaries
download_shadowsocks

# Generate config.json for shadowsocks
create_ss_config

if [ "$cloak" = true ]; then
	download_cloak
	create_cloak_config
	fix_selinux
fi

install_services
open_firewall
get_public_ip

# Print client configuration
print_header
if [ "$cloak" = true ]; then
	print_cloak_config
else
	print_ss_config
fi
