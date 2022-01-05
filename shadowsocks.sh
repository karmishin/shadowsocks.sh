#!/bin/sh -e

shadowsocks_version="1.12.5"
shadowsocks_directory="/opt/shadowsocks"
systemd_service_directory="/etc/systemd/system"
tmp_directory="/tmp/shadowsocks-sh"
download_link="https://github.com/shadowsocks/shadowsocks-rust/releases/download/v${shadowsocks_version}/shadowsocks-v${shadowsocks_version}.x86_64-unknown-linux-gnu.tar.xz"

main() {
    prepare
    download
    extract_files
    create_config
    install_service
    cleanup
    echo "All done!"
}

prepare() {
    if [ `id -u` -ne 0 ]; then
        echo "This script must be run as root."
        exit 1
    fi

    if [ -f $tmp_directory/err.log ]; then
        rm $tmp_directory/err.log || true
    fi

    mkdir -p $tmp_directory
    mkdir -p $shadowsocks_directory
}

detect_init_system() {
    if [ `systemctl is-system-running` = "running" ]; then
        init="systemd"
    fi
}

download() {
    echo "Downloading shadowsocks-rust ${shadowsocks_version}..."

    if ! wget $download_link -P $tmp_directory 2>> $tmp_directory/err.log; then
        echo "Download failed. Check ${tmp_directory}/err.log for more information."
        exit 1
    fi
}

extract_files() {
    echo "Extracting files..."
    tar --extract -f $tmp_directory/shadowsocks-v${shadowsocks_version}.x86_64-unknown-linux-gnu.tar.xz \
        --directory $shadowsocks_directory
}

echo_config() {
    echo "{"
    printf '\t"server": "::",\n'
    printf '\t"server_port": '; shuf -i 1024-60999 -n 1 -z; printf ',\n'
    printf '\t"password": "'; tr -dc A-Za-z0-9 < /dev/urandom | head -c 60; printf '",\n'
    printf '\t"method": "chacha20-ietf-poly1305"\n'
    echo "}"
}

create_config() {
    echo "Generating config.json..."
    echo_config > $shadowsocks_directory/config.json
}

echo_systemd_service() {
    echo "[Unit]"
    echo "Description=shadowsocks-rust server"
    echo "After=network.target"
    printf '\n'
    echo "[Service]"
    echo "Type=simple"
    echo "DynamicUser=yes"
    echo "ProtectHome=yes"
    echo "ExecStart=${shadowsocks_directory}/ssserver -c ${shadowsocks_directory}/config.json --log-without-time"
    printf '\n'
    echo "[Install]"
    echo "WantedBy=multi-user.target"
}

install_service() {
    detect_init_system

    if [ "$init" = "systemd" ]; then
        echo "Installing systemd service at ${systemd_service_directory}/shadowsocks.service"
        echo_systemd_service > ${systemd_service_directory}/shadowsocks.service
        echo "Starting the service..."
        systemctl daemon-reload
        systemctl enable --now shadowsocks.service
    else
        echo "Unable to detect init system. Skipping..."
    fi
}

cleanup() {
    echo "Cleaning up..."
    rm $tmp_directory/shadowsocks-v${shadowsocks_version}.x86_64-unknown-linux-gnu.tar.xz
}

main
