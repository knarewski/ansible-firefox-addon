#!/usr/bin/env bats

# testing requirements: docker, ansible

readonly container_name="ansible-firefox-addon"
readonly addon_url=https://addons.mozilla.org/en-US/firefox/addon/adblock-plus

docker_exec() {
  docker exec $container_name $@ > /dev/null
}

docker_exec_d() {
  docker exec -d $container_name $@ > /dev/null
}

docker_exec_sh() {
  # workaround for https://github.com/sstephenson/bats/issues/89
  local IFS=' '
  docker exec $container_name sh -c "$*" > /dev/null
}

ansible_exec_module() {
  local _name=$1
  local _args=$2
  ANSIBLE_LIBRARY=../ ansible container -i hosts -u test -m $_name ${_args:+-a "$_args"}
}

container_startup() {
  local _container_name=$1
  local _container_image=$2
  local _ssh_host=localhost
  local _ssh_port=5555
  local _ssh_public_key=~/.ssh/id_rsa.pub
  docker run --name $_container_name -d -p $_ssh_port:22 \
    -e USERNAME=test -e AUTHORIZED_KEYS="$(< $_ssh_public_key)" -v $_container_name:/var/cache/dnf $_container_image
  ansible localhost -m wait_for -a "port=$_ssh_port host=$_ssh_host search_regex=OpenSSH delay=10"
}

container_cleanup() {
  local _container_name=$1
  docker stop $_container_name > /dev/null
  docker rm $_container_name > /dev/null
}

container_exec() {
  ansible container -i hosts -u test -m shell -a "$*" | tail -n +2
}

container_exec_sudo() {
  ansible container -i hosts -u test -s -m shell -a "$*" | tail -n +2
}

container_dnf_conf() {
  local _name=$1
  local _value=$2
  ansible container -i hosts -u test -s -m lineinfile -a \
    "dest=/etc/dnf/dnf.conf regexp='^$_name=\S+$' line='$_name=$_value'"
}

setup() {
  container_startup $container_name 'alzadude/fedora-ansible-test:23'
  container_dnf_conf keepcache 1
  container_dnf_conf metadata_timer_sync 0
  container_exec_sudo dnf -q -y install xorg-x11-server-Xvfb daemonize
  container_exec_sudo daemonize /usr/bin/Xvfb :1
}

@test "Module exec with url arg missing" {
  run ansible_exec_module firefox_addon
  [[ $output =~ "missing required arguments: url" ]]
}

@test "Module exec with state arg having invalid value" {
  run ansible_exec_module firefox_addon "url=$addon_url state=latest"
  [[ $output =~ "value of state must be one of: present,absent, got: latest" ]]
}

@test "Module exec with state arg having default value of present" {
  docker_exec yum -y install firefox unzip curl
  run ansible_exec_module firefox_addon "url=$addon_url display=:1"
  [[ $output =~ changed.*true ]]
  docker_exec_sh test -d "~/.mozilla/firefox/*.default/extensions/{d10d0bf8-f5b5-c8b4-a8b2-2b9879e08c5d}"
}

@test "Module exec with state present" {
  docker_exec yum -y install firefox unzip curl
  run ansible_exec_module firefox_addon "url=$addon_url state=present display=:1"
  [[ $output =~ changed.*true ]]
}

@test "Module exec with state absent" {
  docker_exec yum -y install firefox unzip curl
  run ansible_exec_module firefox_addon "url=$addon_url state=absent display=:1"
  [[ $output =~ changed.*false ]]
}

@test "Module exec with state absent and addon already installed" {
  docker_exec yum -y install firefox unzip curl
  run ansible_exec_module firefox_addon "url=$addon_url state=present display=:1"
  [[ $output =~ changed.*true ]]
  run ansible_exec_module firefox_addon "url=$addon_url state=absent display=:1"
  [[ $output =~ changed.*true ]]
  docker_exec_sh test ! -e "~/.mozilla/firefox/*.default/extensions/{d10d0bf8-f5b5-c8b4-a8b2-2b9879e08c5d}"
}

@test "Module exec with state present twice and check idempotent" {
  docker_exec yum -y install firefox unzip curl
  run ansible_exec_module firefox_addon "url=$addon_url display=:1"
  run ansible_exec_module firefox_addon "url=$addon_url display=:1"
  [[ $output =~ changed.*false ]]
}

@test "Module exec with complete theme addon and check selected skin pref" {
  local _addon_url=https://addons.mozilla.org/en-US/firefox/addon/fxchrome
  docker_exec yum -y install firefox unzip curl
  run ansible_exec_module firefox_addon "url=$_addon_url display=:1"
  [[ $output =~ changed.*true ]]
  docker_exec_sh grep FXChrome "~/.mozilla/firefox/*.default/user.js"
}

@test "Module exec with display arg missing when there is no DISPLAY environment" {
  docker_exec yum -y install firefox unzip curl
  run ansible_exec_module firefox_addon "url=$addon_url"
  [[ $output =~ 'Error: no display specified' ]]
}

teardown() {
  container_cleanup $container_name
}
