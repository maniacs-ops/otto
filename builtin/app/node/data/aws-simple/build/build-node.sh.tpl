#!/bin/bash

set -o nounset -o errexit -o pipefail -o errtrace

error() {
   local sourcefile=$1
   local lineno=$2
   echo "ERROR at ${sourcefile}:${lineno}; Last logs:"
   grep otto /var/log/syslog | tail -n 20
}
trap 'error "${BASH_SOURCE}" "${LINENO}"' ERR

oe() { "$@" 2>&1 | logger -t otto > /dev/null; }
ol() { echo "[otto] $@"; }

# cloud-config can interfere with apt commands if it's still in progress
ol "Waiting for cloud-config to complete..."
until [[ -f /var/lib/cloud/instance/boot-finished ]]; do
  sleep 0.5
done

ol "Adding apt repositories and updating..."
oe sudo apt-get update -y
oe sudo apt-get install -y software-properties-common
oe sudo apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 561F9B9CAC40B2F7
echo 'deb https://oss-binaries.phusionpassenger.com/apt/passenger trusty main' | sudo tee /etc/apt/sources.list.d/passenger.list > /dev/null
oe sudo apt-get update

ol "Downloading Node {{ node_version }}..."
oe wget -q -O /home/vagrant/node.tar.gz https://nodejs.org/dist/v{{ node_version }}/node-v{{ node_version }}-linux-x64.tar.gz

ol "Untarring Node..."
oe sudo tar -C /opt -xzf /home/vagrant/node.tar.gz

ol "Setting up PATH..."
oe sudo ln -s /opt/node-v{{ node_version }}-linux-x64/bin/node /usr/local/bin/node
oe sudo ln -s /opt/node-v{{ node_version }}-linux-x64/bin/npm /usr/local/bin/npm

ol "Installing Passenger, Nginx, and other supporting packages..."
export DEBIAN_FRONTEND=noninteractive
oe sudo apt-get install -y bzr git mercurial build-essential \
  libpq-dev zlib1g-dev software-properties-common \
  apt-transport-https \
  nginx-extras passenger

ol "Extracting app..."
sudo mkdir -p /srv/otto-app
sudo tar zxf /tmp/otto-app.tgz -C /srv/otto-app

ol "Adding application user..."
oe sudo adduser --disabled-password --gecos "" otto-app

ol "Setting permissions..."
oe sudo chown -R otto-app: /srv/otto-app

ol "Configuring nginx..."

# This is required for passenger to get a reasonable environment where it can
# find executables like /usr/bin/env, /usr/bin/curl, etc. It also apparently
# needs to occur high in the config. Appending it is insufficient. :-|
sudo sed -i '1s/^/env PATH;\n/' /etc/nginx/nginx.conf
sudo sed -i '1s/^/# Otto: set PATH so passenger can see binaries\n/' /etc/nginx/nginx.conf

# Need to remove this so nginx reads our site
sudo rm /etc/nginx/sites-enabled/default

# These lines are present as comments in the passenger-packaged nginx.conf, but
# it's easier to drop a separate config than to sed out an uncomment.
cat <<NGINXCONF | sudo tee /etc/nginx/conf.d/passenger.conf > /dev/null
# Generated by Otto
passenger_root /usr/lib/ruby/vendor_ruby/phusion_passenger/locations.ini;
NGINXCONF

cat <<NGINXCONF | sudo tee /etc/nginx/sites-enabled/otto-app.conf > /dev/null
# Generated by Otto
server {
    listen 80;
    root /srv/otto-app/public;
    passenger_enabled on;
}
NGINXCONF

ol "Running npm..."
sudo -u otto-app -i /bin/bash -lc "cd /srv/otto-app && npm install --production"

ol "...done!"
