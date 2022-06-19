# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure("2") do |config|
  config.vm.provision "shell", path: "shadowsocks.sh", args: "-c"

  config.vm.define "debian.shadowsocks" do |deb|
    deb.vm.hostname = "debian.shadowsocks"
    deb.vm.box = "debian/bullseye64"
  end

  config.vm.define "alpine.shadowsocks" do |alp|
    alp.vm.hostname = "alpine.shadowsocks"
    alp.vm.box = "generic/alpine316"
  end
end
