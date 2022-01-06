#!/bin/sh -e

# Download options
shadowsocks_version="1.12.5"
download_link="https://github.com/shadowsocks/shadowsocks-rust/releases/download/v${shadowsocks_version}/shadowsocks-v${shadowsocks_version}.x86_64-unknown-linux-gnu.tar.xz"

# Server configuration options
port=$(shuf -i 1024-60999 -n 1 -z)
password=$(tr -dc A-Za-z0-9 < /dev/urandom | head -c 60)

# Directories
shadowsocks_directory="/opt/shadowsocks"
systemd_service_directory="/etc/systemd/system"
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

prepare() {
	if [ `id -u` -ne 0 ]; then
		echo "This script must be run as root."
		exit 1
	fi

	mkdir -p $tmp_directory
	mkdir -p $shadowsocks_directory
	mkdir -p $shadowsocks_directory/bin
}

download() {
	echo "Downloading shadowsocks-rust ${shadowsocks_version}..."

	if ! wget $download_link -P $tmp_directory 2> $tmp_directory/wget.log; then
		echo "Download failed. Check ${tmp_directory}/wget.log for more information."
		exit 1
	fi
}

extract_files() {
	echo "Extracting files..."
	tar --extract -f $tmp_directory/shadowsocks-v${shadowsocks_version}.x86_64-unknown-linux-gnu.tar.xz \
		--directory $shadowsocks_directory/bin
}

create_server_config() {
	echo "Generating config.json..."

	cat > $shadowsocks_directory/config.json <<- EOF
		{
		    "server": "::",
		    "server_port": ${port},
		    "password": "${password}",
		    "method": "chacha20-ietf-poly1305"
		}
	EOF
}

install_systemd_service() {
	cat > ${systemd_service_directory}/shadowsocks.service <<- EOF
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
}

install_service() {
	if [ `systemctl is-system-running` = "running" ]; then
		echo "Installing systemd service at ${systemd_service_directory}/shadowsocks.service..."
		install_systemd_service
		echo "Starting the service..."
		systemctl daemon-reload
		systemctl enable --now shadowsocks.service
	else
		# Don't do anything if an alternative init system is used.
		# TODO: add support for OpenRC
		echo "Unable to detect init system. Skipping..."
	fi
}

create_client_config() {
	public_ip_address=$(wget -qO- https://v4.ident.me/)

	cat <<- EOF
		--------------------------------------------
		Shadowsocks has been successfully installed!
		The client config is below:

		{
		    "server": "${public_ip_address}",
		    "server_port": ${port},
		    "password": "${password}",
		    "method": "chacha20-ietf-poly1305"
		    "local_address": "127.0.0.1",
		    "local_port": 1080
		}

	EOF
}

cleanup() {
	echo "Cleaning up..."
	rm $tmp_directory/shadowsocks-v${shadowsocks_version}.x86_64-unknown-linux-gnu.tar.xz
}

main
