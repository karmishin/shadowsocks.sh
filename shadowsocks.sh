#!/bin/sh -e

# Download options
shadowsocks_version="1.14.3"

# Server configuration options
password=$(tr -dc A-Za-z0-9 < /dev/urandom | head -c 60)
method="aes-256-gcm"

# Directories
shadowsocks_directory="/opt/shadowsocks"
systemd_service_directory="/etc/systemd/system"
openrc_script="/etc/init.d/shadowsocks"
tmp_directory="/tmp/shadowsocks-sh"

main() {
	prepare
	download
	extract_files
	create_server_config
	install_service
	cleanup
	create_client_config
}

generate_port() {
	port=$(shuf -i 1024-65535 -n 1 -z)

	# Skip checking on minimal systems without ss (e.g. busybox)
	if ! command -v ss > /dev/null 2>&1; then
		return
	fi

	# Check if port is already in use
	if ss -tln "( sport = :${port} )" | grep -q LISTEN; then
		generate_port
	fi
}

prepare() {
    # Check if running as root
	if [ "$(id -u)" -ne 0 ]; then
		echo "This script must be run as root."
		exit 1
	fi

	# Try to detect a libc implementation
	ldd_version=$(ldd --version 2>&1 | head -n 1)
	if echo "$ldd_version" | grep -q -e GNU -e GLIBC; then
		libc="gnu"
	elif echo "$ldd_version" | grep -q musl; then
		libc="musl"
	else
		echo "Unknown libc implementation. Only glibc and musl are supported. Aborting..."
		exit 1
	fi

	generate_port

	mkdir -p $tmp_directory
	mkdir -p $shadowsocks_directory/bin
}

download() {
	echo "Downloading shadowsocks-rust ${shadowsocks_version}..."

	download_link="https://github.com/shadowsocks/shadowsocks-rust/releases/download/v${shadowsocks_version}/shadowsocks-v${shadowsocks_version}.x86_64-unknown-linux-${libc}.tar.xz"
	if ! wget $download_link -P $tmp_directory 2> $tmp_directory/wget.log; then
		echo "Download failed. Check ${tmp_directory}/wget.log for more information."
		exit 1
	fi
}

extract_files() {
	echo "Extracting files..."

	tar --extract -f ${tmp_directory}/shadowsocks-v${shadowsocks_version}.x86_64-unknown-linux-${libc}.tar.xz \
		--directory ${shadowsocks_directory}/bin
}

create_server_config() {
	echo "Generating config.json..."

	cat > $shadowsocks_directory/config.json <<- EOF
		{
		    "server": "::",
		    "server_port": ${port},
		    "password": "${password}",
		    "method": "${method}"
		}
	EOF
}

install_systemd_service() {
    echo "Installing the systemd service at ${systemd_service_directory}/shadowsocks.service..."

	cat > $systemd_service_directory/shadowsocks.service <<- EOF
		[Unit]
		Description=shadowsocks-rust server
		After=network.target

		[Service]
		Type=simple
		DynamicUser=yes
		ProtectHome=yes
		ExecStart=${shadowsocks_directory}/bin/ssserver -c ${shadowsocks_directory}/config.json --log-without-time

		[Install]
		WantedBy=multi-user.target
	EOF

	systemctl daemon-reload
	systemctl enable --now shadowsocks.service > /dev/null 2>&1
}

install_openrc_service() {
	cat > $openrc_script <<-EOF
		#!/sbin/openrc-run

		name="shadowsocks-rust server"
		command="${shadowsocks_directory}/bin/ssserver"
		command_args="-c ${shadowsocks_directory}/config.json --log-without-time"
		command_background="yes"
		pidfile="/var/run/shadowsocks.pid"
	EOF

	chmod +x $openrc_script
	rc-update add shadowsocks default
	rc-service shadowsocks start
}

install_service() {
	if systemctl is-system-running > /dev/null 2>&1; then
		install_systemd_service
	elif rc-service --version; then
		install_openrc_service
	else
		echo "Unable to detect the init system. Skipping..."
	fi
}

create_client_config() {
	public_ip_address=$(wget -4qO- https://v4.ident.me/)
	client_config_path="${tmp_directory}/client.json"

	cat > $client_config_path <<- EOF
	{
	    "server": "${public_ip_address}",
	    "server_port": ${port},
	    "password": "${password}",
	    "method": "${method}",
	    "local_address": "127.0.0.1",
	    "local_port": 1080
	}
	EOF

	ssurl=$($shadowsocks_directory/bin/ssurl --encode $client_config_path)

	cat <<- EOF

		############################
		# Installation successful! #
		############################

		Here's how you can connect:

		IP: ${public_ip_address}
		Port: ${port}
		Password: ${password}
		Encryption method: ${method}
		Server URL (SIP002):
		${ssurl}
	EOF
}

cleanup() {
	echo "Cleaning up..."
	rm ${tmp_directory}/shadowsocks-v${shadowsocks_version}.x86_64-unknown-linux-${libc}.tar.xz
}

main
