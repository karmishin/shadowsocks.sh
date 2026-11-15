#!/bin/sh

set -e

# Download options
shadowsocks_version="1.25.0"
cloak_version="2.12.0"

# gh release view -R cbeuw/Cloak v<version> --json assets --jq '.assets[] | "\(.name) \(.digest)"'
cloak_sha256_amd64="f2bea92c99195ac26cd5749e80d07339d5582c103f73934b414150c6070dae4e"
cloak_sha256_arm64="9b26306639e60a73e6b2bdae4876fa72f833a47e5fab31dcea9f3ebe22aa7cfb"

# Server configuration options
method="aes-256-gcm"

# Cloak configuration options
cloak_port=443
# Used both as the redirect target for non-cloak traffic and as the client SNI
cloak_server_name="ya.ru"
cloak_stream_timeout=300
cloak_browser="chrome"
cloak_num_conn=4

# Directories
shadowsocks_dir="/opt/shadowsocks"
cloak_dir="/opt/cloak"
cloak_state_dir="/var/lib/cloak"
systemd_dir="/etc/systemd/system"
openrc_dir="/etc/init.d"

# Saved credentials, used by re-runs, -s and -u
state_file="${shadowsocks_dir}/install.conf"

# Unprivileged users the services run as
shadowsocks_user="shadowsocks"
cloak_user="cloak"

# Defaults
action="install"
cloak=false
regenerate=false
services_installed=false
kept_credentials=false

usage() {
	cat >&2 <<- EOF
		Usage: $0 [-c] [-r] | -s | -u

		  -c    Also install Cloak (https://github.com/cbeuw/Cloak)
		  -r    Generate new credentials instead of keeping the existing ones
		  -s    Show the client configuration of the existing installation
		  -u    Uninstall
		  -h    Show this help
	EOF
	exit "$1"
}

# Command-line options
while getopts "crsuh" o; do case $o in
	c) cloak=true ;;
	r) regenerate=true ;;
	s) action="show" ;;
	u) action="uninstall" ;;
	h) usage 0 ;;
	*) usage 2 ;;
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

generate_password() {
	password=$(tr -dc A-Za-z0-9 < /dev/urandom | head -c 32)
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

json_value() {
	sed -n "s/.*\"$1\": *\"*\([^\",]*\).*/\1/p" "$2"
}

load_state() {
	saved_port=""
	saved_password=""
	saved_method=""
	saved_cloak=false
	saved_cloak_uid=""
	saved_cloak_public_key=""
	saved_cloak_private_key=""

	if [ -f "$state_file" ]; then
		# shellcheck source=/dev/null
		. "$state_file"
	elif [ -f "${shadowsocks_dir}/config.json" ]; then
		# Installed by an older version, which didn't save the cloak public key
		saved_port=$(json_value server_port "${shadowsocks_dir}/config.json")
		saved_password=$(json_value password "${shadowsocks_dir}/config.json")
		saved_method=$(json_value method "${shadowsocks_dir}/config.json")
		if [ -f "${cloak_dir}/config.json" ]; then
			saved_cloak=true
		fi
	fi
}

save_state() {
	(umask 077 && cat > "$state_file") <<- EOF
		saved_port='${port}'
		saved_password='${password}'
		saved_method='${method}'
		saved_cloak='${cloak}'
		saved_cloak_uid='${cloak_uid}'
		saved_cloak_public_key='${cloak_public_key}'
		saved_cloak_private_key='${cloak_private_key}'
	EOF
}

cloak_installed() {
	[ "$saved_cloak" = true ] || [ -d "$cloak_dir" ]
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

delete_user() {
	if id "$1" > /dev/null 2>&1; then
		if command -v userdel > /dev/null 2>&1; then
			userdel "$1"
		else
			deluser "$1"
		fi
	fi

	if grep -q "^${1}:" /etc/group; then
		if command -v groupdel > /dev/null 2>&1; then
			groupdel "$1"
		else
			delgroup "$1"
		fi
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
	elif [ -e /proc/net/if_inet6 ]; then
		address="::"
		mode="tcp_and_udp"
	else
		# IPv6 is disabled
		address="0.0.0.0"
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

generate_cloak_keys() {
	ck_key_output=$("${cloak_dir}/bin/ck-server" -key)
	cloak_public_key=$(echo "$ck_key_output" | head -n 1 | awk '{print $5}')
	cloak_private_key=$(echo "$ck_key_output" | tail -n 1 | awk '{print $8}')
	cloak_uid=$("${cloak_dir}/bin/ck-server" -uid | awk '{print $4}')

	if [ -z "$cloak_public_key" ] || [ -z "$cloak_private_key" ] || [ -z "$cloak_uid" ]; then
		echo "Unable to parse the keys generated by ck-server. Aborting..." >&2
		exit 1
	fi
}

create_cloak_config() {
	echo "Generating cloak config..."

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

remove_service() {
	if [ -d /run/systemd/system ]; then
		systemctl disable --now --quiet "$1.service" 2> /dev/null || true
		rm -f "${systemd_dir}/$1.service"
		systemctl daemon-reload
	elif command -v rc-service > /dev/null 2>&1; then
		rc-service "$1" stop 2> /dev/null || true
		rc-update del "$1" default > /dev/null 2>&1 || true
		rm -f "${openrc_dir}/$1"
	fi
}

# firewall add|remove "443/tcp ..."
firewall() {
	if command -v firewall-cmd > /dev/null 2>&1 && firewall-cmd --state > /dev/null 2>&1; then
		echo "Updating firewalld rules (${1} ${2})..."
		for p in $2; do
			if [ "$1" = add ]; then
				firewall-cmd --quiet --permanent --add-port="$p"
			else
				firewall-cmd --quiet --permanent --remove-port="$p" 2> /dev/null || true
			fi
		done
		firewall-cmd --quiet --reload
	elif command -v ufw > /dev/null 2>&1 && ufw status 2> /dev/null | grep -q "Status: active"; then
		echo "Updating ufw rules (${1} ${2})..."
		for p in $2; do
			if [ "$1" = add ]; then
				ufw allow "$p" > /dev/null
			else
				ufw delete allow "$p" > /dev/null 2>&1 || true
			fi
		done
	fi
}

# public_ports <cloak: true|false> <shadowsocks port>
public_ports() {
	if [ "$1" = true ]; then
		echo "${cloak_port}/tcp"
	else
		echo "${2}/tcp ${2}/udp"
	fi
}

remove_cloak() {
	remove_service cloak-server
	firewall remove "${cloak_port}/tcp"

	if command -v semanage > /dev/null 2>&1; then
		semanage fcontext -d "${cloak_dir}/bin/ck-server" 2> /dev/null || true
	fi

	# /var/lib/private/cloak is from older versions
	rm -rf "${cloak_dir:?}" "${cloak_state_dir:?}" /var/lib/private/cloak
	delete_user "$cloak_user"
}

get_public_ip() {
	public_ip_address=$(wget -T 10 -qO- https://4.ident.me/ 2> /dev/null ||
		wget -T 10 -qO- https://6.ident.me/ 2> /dev/null || true)

	# Discard anything that doesn't look like an IP address
	case $public_ip_address in
		''|*[!0-9A-Fa-f.:]*) public_ip_address="" ;;
	esac

	if [ -z "$public_ip_address" ]; then
		public_ip_address="<server IP>"
		ip_known=false
	else
		ip_known=true
	fi
}

# The script may have been piped into sh
script_command() {
	if [ -n "$SUDO_USER" ]; then
		sudo="sudo "
	else
		sudo=""
	fi

	case $0 in
		*shadowsocks.sh) echo "${sudo}sh $0" ;;
		*) echo "wget -qO- https://raw.githubusercontent.com/karmishin/shadowsocks.sh/master/shadowsocks.sh | ${sudo}sh -s --" ;;
	esac
}

print_status() {
	versions="shadowsocks-rust ${shadowsocks_version}"
	if [ "$cloak" = true ]; then
		versions="${versions} and Cloak ${cloak_version}"
	fi

	echo
	if [ "$services_installed" = false ]; then
		echo "! ${versions} installed, but no service was set up. Start the servers manually:"
		echo
		echo "  ${shadowsocks_dir}/bin/ssserver -c ${shadowsocks_dir}/config.json"
		if [ "$cloak" = true ]; then
			echo "  ${cloak_dir}/bin/ck-server -c ${cloak_dir}/config.json"
		fi
	elif [ "$kept_credentials" = true ]; then
		echo "✓ Updated to ${versions}."
	elif [ "$cloak" = true ]; then
		echo "✓ ${versions} are running."
	else
		echo "✓ ${versions} is running."
	fi
}

print_link() {
	if [ "$ip_known" = false ]; then
		echo "Couldn't determine the public IP address of this server, so there's no link to"
		echo "import. Use the settings below and fill in the server address yourself."
		return 0
	fi

	if [ "$cloak" = true ]; then
		url_port=$cloak_port
		plugin_opts="Transport=direct;ProxyMethod=shadowsocks;EncryptionMethod=plain;UID=${cloak_uid};PublicKey=${cloak_public_key};ServerName=${cloak_server_name};BrowserSig=${cloak_browser};NumConn=${cloak_num_conn};StreamTimeout=${cloak_stream_timeout}"
		plugin_fields=$(printf ',\n    "plugin": "ck-client",\n    "plugin_opts": "%s"' "$plugin_opts")
	else
		url_port=$port
		plugin_fields=""
	fi

	client_config_path="${tmp_dir}/client.json"
	cat > "$client_config_path" <<- EOF
		{
		    "server": "${public_ip_address}",
		    "server_port": ${url_port},
		    "password": "${password}",
		    "method": "${method}"${plugin_fields}
		}
	EOF

	ssurl=$("${shadowsocks_dir}/bin/ssurl" --encode "$client_config_path")

	if [ "$cloak" = true ]; then
		echo "Import this link in your client app (shadowsocks-android with the Cloak"
		echo "plugin, Shadowrocket, ...):"
	else
		echo "Import this link in your client app (shadowsocks-android, Shadowrocket, ...):"
	fi
	echo
	echo "  ${ssurl}"
	echo

	if command -v qrencode > /dev/null 2>&1; then
		qrencode -t ansiutf8 "$ssurl" | sed 's/^/  /'
	else
		echo "  (Install qrencode and run with -s to see a QR code.)"
	fi
}

row() {
	printf '  %-15s %s\n' "$1" "$2"
}

print_settings() {
	echo "Or enter the settings by hand:"
	echo

	row "Server" "$public_ip_address"
	if [ "$cloak" = true ]; then
		row "Port" "$cloak_port"
	else
		row "Port" "$port"
	fi
	row "Password" "$password"
	row "Method" "$method"

	if [ "$cloak" = false ]; then
		return 0
	fi

	row "Plugin" "Cloak (Transport: direct, Proxy method: shadowsocks,"
	row "" "Encryption: plain, Browser: ${cloak_browser}, Stream timeout: ${cloak_stream_timeout})"
	row "Server name" "$cloak_server_name"
	row "UID" "$cloak_uid"
	row "Public key" "$cloak_public_key"

	echo
	echo "ck-client config (for desktop):"
	sed 's/^/  /' <<- EOF
		{
		    "Transport": "direct",
		    "ProxyMethod": "shadowsocks",
		    "EncryptionMethod": "plain",
		    "UID": "${cloak_uid}",
		    "PublicKey": "${cloak_public_key}",
		    "ServerName": "${cloak_server_name}",
		    "BrowserSig": "${cloak_browser}",
		    "NumConn": ${cloak_num_conn},
		    "StreamTimeout": ${cloak_stream_timeout}
		}
	EOF
}

print_config() {
	get_public_ip

	echo
	print_link
	echo
	print_settings
	echo
	printf '%-18s %s\n' "Show this again:" "$(script_command) -s"
	printf '%-18s %s\n' "Uninstall:" "$(script_command) -u"
}

do_install() {
	detect_arch
	detect_libc
	load_state

	if [ "$regenerate" = false ] && [ -n "$saved_port" ] && [ -n "$saved_password" ]; then
		echo "Keeping the existing credentials (use -r to generate new ones)..."
		kept_credentials=true
		port=$saved_port
		password=$saved_password
		method=${saved_method:-$method}
	else
		generate_port
		generate_password
	fi

	if [ "$cloak" = true ]; then
		check_cloak_port
	fi

	# Switching from cloak to plain shadowsocks
	if [ "$cloak" = false ] && cloak_installed; then
		echo "Removing cloak (run with -c to keep it)..."
		remove_cloak
	fi

	# Close the old port
	if [ -n "$saved_port" ] && [ "$saved_cloak" = false ] &&
		{ [ "$cloak" = true ] || [ "$port" != "$saved_port" ]; }; then
		firewall remove "$(public_ports false "$saved_port")"
	fi

	mkdir -p "${shadowsocks_dir}/bin"
	create_user "$shadowsocks_user"
	download_shadowsocks
	create_ss_config

	cloak_uid=""
	cloak_public_key=""
	cloak_private_key=""

	if [ "$cloak" = true ]; then
		mkdir -p "${cloak_dir}/bin"
		create_user "$cloak_user"
		download_cloak

		if [ "$regenerate" = false ] && [ -n "$saved_cloak_uid" ]; then
			cloak_uid=$saved_cloak_uid
			cloak_public_key=$saved_cloak_public_key
			cloak_private_key=$saved_cloak_private_key
		else
			generate_cloak_keys
		fi

		create_cloak_config
		fix_selinux
	fi

	save_state
	install_services
	firewall add "$(public_ports "$cloak" "$port")"

	print_status
	print_config
}

do_show() {
	if [ ! -f "$state_file" ]; then
		echo "No saved configuration found in ${state_file}. Run the installer first." >&2
		exit 1
	fi

	load_state
	port=$saved_port
	password=$saved_password
	method=$saved_method
	cloak=$saved_cloak
	cloak_uid=$saved_cloak_uid
	cloak_public_key=$saved_cloak_public_key

	print_config
}

do_uninstall() {
	load_state

	if cloak_installed; then
		echo "Removing cloak..."
		remove_cloak
	fi

	echo "Removing shadowsocks..."
	remove_service shadowsocks
	if [ -n "$saved_port" ] && [ "$saved_cloak" = false ]; then
		firewall remove "$(public_ports false "$saved_port")"
	fi
	rm -rf "${shadowsocks_dir:?}"
	delete_user "$shadowsocks_user"

	echo "Uninstalled."
}

check_priv
create_tmp_dir

case $action in
	install) do_install ;;
	show) do_show ;;
	uninstall) do_uninstall ;;
esac
