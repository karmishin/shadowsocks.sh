#!/bin/sh -e

# Download options
shadowsocks_version="1.15.2"
cloak_version="2.6.0"

# Server configuration options
password=$(tr -dc A-Za-z0-9 < /dev/urandom | head -c 32)
method="aes-256-gcm"

# Directories
shadowsocks_dir="/opt/shadowsocks"
cloak_dir="/opt/cloak"
systemd_dir="/etc/systemd/system"
openrc_dir="/etc/init.d/"
tmp_dir="/tmp/shadowsocks-sh"

# Command-line options
while getopts "c" o; do case $o in
	c) cloak=true ;;
	?) printf "Usage: %s: [-c]\n $0" && exit 2 ;;
esac done

generate_port() {
	port=$(shuf -i 1024-65535 -n 1 -z)

	# Skip checking on minimal systems without ss (e.g. busybox)
	if ! command -v ss > /dev/null 2>&1; then
		return
	fi

	# Check if port is already in use
	if ss -tln "( sport = :${port} )" | grep -q LISTEN; then
		echo "It appears that port ${port} is already used by another process. Aborting..."
		exit 1
	fi
}

check_priv() {
	if [ "$(id -u)" -ne 0 ]; then
		echo "This script must be run as root."
		exit 1
	fi
}

detect_libc() {
	ldd_version=$(ldd --version 2>&1 | head -n 1)

	if echo "$ldd_version" | grep -q -e GNU -e GLIBC; then
		libc="gnu"
	elif echo "$ldd_version" | grep -q musl; then
		libc="musl"
	else
		echo "Unknown libc implementation. Only glibc and musl are supported. Aborting..."
		exit 1
	fi
}

download_shadowsocks() {
	echo "Downloading shadowsocks-rust ${shadowsocks_version}..."

	download_link="https://github.com/shadowsocks/shadowsocks-rust/releases/download/v${shadowsocks_version}/shadowsocks-v${shadowsocks_version}.x86_64-unknown-linux-${libc}.tar.xz"
	if ! wget $download_link -P $tmp_dir 2> $tmp_dir/wget.log; then
		echo "Download failed. Check ${tmp_dir}/wget.log for more information."
		exit 1
	fi

	echo "Extracting shadowsocks..."
	tar --extract -f ${tmp_dir}/shadowsocks-v${shadowsocks_version}.x86_64-unknown-linux-${libc}.tar.xz \
		--directory ${shadowsocks_dir}/bin
}

download_cloak() {
	echo "Downloading Cloak ${cloak_version}..."

	download_link="https://github.com/cbeuw/Cloak/releases/download/v${cloak_version}/ck-server-linux-amd64-v${cloak_version}"
	if ! wget $download_link -P $tmp_dir 2>> $tmp_dir/wget.log; then
		echo "Download failed. Check ${tmp_dir}/wget.log for more information."
		exit 1
	fi

	mv $tmp_dir/ck-server-linux-amd64-v${cloak_version} $cloak_dir/bin/ck-server
	chmod +x $cloak_dir/bin/ck-server
}

create_ss_config() {
	echo "Generating shadowsocks config..."

	if [ "$cloak" = true ] ; then
		address="127.0.0.1"
	else
		address="::"
	fi

	cat > $shadowsocks_dir/config.json <<- EOF
		{
		    "server": "${address}",
		    "server_port": ${port},
		    "password": "${password}",
		    "method": "${method}"
		}
	EOF
}

create_cloak_config() {
	echo "Generating cloak config..."

	ck_key_output=$($cloak_dir/bin/ck-server -key)
	cloak_public_key=$(echo "$ck_key_output" | head -n 1 | awk '{print $5}')
	cloak_private_key=$(echo "$ck_key_output" | tail -n 1 | awk '{print $8}')
	cloak_uid=$($cloak_dir/bin/ck-server -uid | awk '{print $4}')

	cat > $cloak_dir/config.json <<- EOF
		{
			"ProxyBook": {
				"shadowsocks": [
					"tcp",
					"127.0.0.1:${port}"
				]
			},
			"BindAddr": [
				":443"
			],
			"BypassUID": [
				"${cloak_uid}"
			],
 			"RedirAddr": "yastatic.net",
			"PrivateKey": "${cloak_private_key}",
			"DatabasePath": "/var/lib/private/cloak/userinfo.db",
			"StreamTimeout": 300
		}
	EOF
}

install_ss_systemd_service() {
	cat > $systemd_dir/shadowsocks.service <<- EOF
		[Unit]
		Description=shadowsocks-rust server
		After=network.target

		[Service]
		Type=simple
		DynamicUser=yes
		ProtectHome=yes
		Restart=on-failure
		ExecStart=${shadowsocks_dir}/bin/ssserver -c ${shadowsocks_dir}/config.json --log-without-time

		[Install]
		WantedBy=multi-user.target
	EOF

	systemctl daemon-reload
	systemctl enable --now shadowsocks.service > /dev/null 2>&1
}

install_cloak_systemd_service() {
	cat > $systemd_dir/cloak-server.service <<- EOF
		[Unit]
		Description=cloak server
		After=network.target

		[Service]
		Type=simple
		DynamicUser=yes
		ProtectHome=yes
		AmbientCapabilities=CAP_NET_BIND_SERVICE
		Restart=on-failure
		StateDirectory=cloak
		ExecStart=${cloak_dir}/bin/ck-server -c ${cloak_dir}/config.json

		[Install]
		WantedBy=multi-user.target
	EOF

	systemctl daemon-reload
	systemctl enable --now cloak-server.service > /dev/null 2>&1
}

install_ss_openrc_service() {
	cat > $openrc_dir/shadowsocks <<-EOF
		#!/sbin/openrc-run

		name="shadowsocks-rust server"
		command="${shadowsocks_dir}/bin/ssserver"
		command_args="-c ${shadowsocks_dir}/config.json --log-without-time"
		command_background="yes"
		pidfile="/var/run/shadowsocks.pid"
	EOF

	chmod +x $openrc_dir/shadowsocks
	rc-update add shadowsocks default
	rc-service shadowsocks start
}

install_cloak_openrc_service() {
	cat > $openrc_dir/cloak-server <<-EOF
		#!/sbin/openrc-run

		name="cloak server"
		command="${cloak_dir}/bin/ck-server"
		command_args="-c ${cloak_dir}/config.json"
		command_background="yes"
		pidfile="/var/run/cloak.pid"
	EOF

	chmod +x $openrc_dir/cloak-server
	rc-update add cloak-server default
	rc-service cloak-server start
}

install_services() {
	if systemctl is-system-running > /dev/null 2>&1; then
		install_ss_systemd_service
		if [ "$cloak" = true ] ; then
			install_cloak_systemd_service
		fi
	elif rc-service --version > /dev/null 2>&1; then
		install_ss_openrc_service
		if [ "$cloak" = true ] ; then
			install_cloak_openrc_service
		fi
	else
		echo "Unable to detect the init system. Skipping..."
	fi
}

print_ss_config() {
	public_ip_address=$(wget -4qO- https://am.i.mullvad.net/ip | tr -d "\n")
	client_config_path="${tmp_dir}/client.json"

	cat > $client_config_path <<- EOF
	{
	    "server": "${public_ip_address}",
	    "server_port": ${port},
	    "password": "${password}",
	    "method": "${method}",
	}
	EOF

	ssurl=$($shadowsocks_dir/bin/ssurl --encode $client_config_path)

	cat <<- EOF

		############################
		# Installation successful! #
		############################

		SHADOWSOCKS configuration:

		Server IP: ${public_ip_address}
		Port: ${port}
		Password: ${password}
		Encryption method: ${method}
		Server URL (SIP002):
		${ssurl}
	EOF
}

print_cloak_config() {
	cat <<- EOF

		CLOAK configuration:

		Transport: direct
		ProxyMethod: shadowsocks
		EncryptionMethod: plain
		UID: ${cloak_uid}
		Public key: ${cloak_public_key}
		Server name: yandex.ru
		Browser signature: firefox
		Stream timeout: 300
	EOF
}

cleanup() {
	rm ${tmp_dir}/shadowsocks-v${shadowsocks_version}.x86_64-unknown-linux-${libc}.tar.xz
}

# Check if running as root
check_priv

# Try to detect a libc implementation
detect_libc

# Generate a random port and check if it's already used
generate_port

# Create the necessary directories
mkdir -p $tmp_dir $shadowsocks_dir/bin $cloak_dir/bin

# Download and extract shadowsocks binaries
download_shadowsocks

# Generate config.json for shadowsocks
create_ss_config

if [ "$cloak" = true ] ; then
	download_cloak
	create_cloak_config
fi

install_services

# Print shadowsocks client configuration
print_ss_config

# Print cloak client configuration
if [ "$cloak" = true ] ; then
	print_cloak_config
fi

# Remove temporary files
cleanup
