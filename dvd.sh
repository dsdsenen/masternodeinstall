#!/bin/bash

CONFIG_FILE='dividendcash.conf'
CONFIGFOLDER='/root/.dividendcash'
COIN_DAEMON='/usr/local/bin/dividendcashd'
COIN_CLI='/usr/local/bin/dividendcash-cli'
COIN_REPO='https://github.com/dividendcash/dividendcash/releases/download/v1.0.0/dividendcash-1.0.0-x86_64-linux-gnu.tar.gz'
COIN_NAME='DividendCash'
COIN_PORT=19997

NODEIP=$(curl -s4 icanhazip.com)

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

progressfilt () {
  local flag=false c count cr=$'\r' nl=$'\n'
  while IFS='' read -d '' -rn 1 c
  do
    if $flag
    then
      printf '%c' "$c"
    else
      if [[ $c != $cr && $c != $nl ]]
      then
        count=0
      else
        ((count++))
        if ((count > 1))
        then
          flag=true
        fi
      fi
    fi
  done
}

function compile_node() {
  echo -e "Prepare to download DividendCash"
  TMP_FOLDER=$(mktemp -d)
  cd $TMP_FOLDER
  wget --progress=bar:force $COIN_REPO 2>&1 | progressfilt
  compile_error
  COIN_ZIP=$(echo $COIN_REPO | awk -F'/' '{print $NF}')
  COIN_VER=$(echo $COIN_ZIP | awk -F'/' '{print $NF}' | sed -n 's/.*\([0-9]\.[0-9]\.[0-9]\).*/\1/p')
  COIN_DIR=$(echo ${COIN_NAME,,}-$COIN_VER)
  tar xvzf $COIN_ZIP --strip=2 ${COIN_DIR}/bin/${COIN_NAME,,}d ${COIN_DIR}/bin/${COIN_NAME,,}-cli>/dev/null 2>&1
  compile_error
  rm -f $COIN_ZIP >/dev/null 2>&1
  cp dividendcash* /usr/local/bin
  compile_error
  strip /usr/local/bin/dividendcashd /usr/local/bin/dividendcash-cli
  cd -
  rm -rf $TMP_FOLDER >/dev/null 2>&1
  clear
}

function configure_systemd() {
  cat << EOF > /etc/systemd/system/DividendCash.service
[Unit]
Description=DividendCash service
After=network.target

[Service]
User=root
Group=root

Type=forking
#PIDFile=/root/.dividendcash/DividendCash.pid

ExecStart=/usr/local/bin/dividendcashd -daemon -conf=/root/.dividendcash/dividendcash.conf -datadir=/root/.dividendcash
ExecStop=-/usr/local/bin/dividendcash-cli -conf=/root/.dividendcash/dividendcash.conf -datadir=/root/.dividendcash stop

Restart=always
PrivateTmp=true
TimeoutStopSec=60s
TimeoutStartSec=10s
StartLimitInterval=120s
StartLimitBurst=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  sleep 3
  systemctl start DividendCash.service
  systemctl enable DividendCash.service >/dev/null 2>&1

  if [[ -z "$(ps axo cmd:100 | egrep /usr/local/bin/dividendcashd)" ]]; then
    echo -e "DividendCash is not running, please investigate. You should start by running the following commands as root:"
    echo -e "systemctl start DividendCash.service"
    echo -e "systemctl status DividendCash.service"
    echo -e "less /var/log/syslog"
    exit 1
  fi
}

function configure_startup() {
  cat << EOF > /etc/init.d/DividendCash
#! /bin/bash
### BEGIN INIT INFO
# Provides: DividendCash
# Required-Start: $remote_fs $syslog
# Required-Stop: $remote_fs $syslog
# Default-Start: 2 3 4 5
# Default-Stop: 0 1 6
# Short-Description: DividendCash
# Description: This file starts and stops DividendCash MN server
#
### END INIT INFO

case "\$1" in
 start)
   /usr/local/bin/dividendcashd -daemon
   sleep 5
   ;;
 stop)
   /usr/local/bin/dividendcash-cli stop
   ;;
 restart)
   /usr/local/bin/dividendcash-cli stop
   sleep 10
   /usr/local/bin/dividendcashd -daemon
   ;;
 *)
   echo "Usage: DividendCash {start|stop|restart}" >&2
   exit 3
   ;;
esac
EOF
chmod +x /etc/init.d/DividendCash >/dev/null 2>&1
update-rc.d DividendCash defaults >/dev/null 2>&1
/etc/init.d/DividendCash start >/dev/null 2>&1
if [ "$?" -gt "0" ]; then
 sleep 5
 /etc/init.d/DividendCash start >/dev/null 2>&1
fi
}


function create_config() {
  mkdir /root/.dividendcash >/dev/null 2>&1
  RPCUSER=$(tr -cd '[:alnum:]' < /dev/urandom | fold -w10 | head -n1)
  RPCPASSWORD=$(tr -cd '[:alnum:]' < /dev/urandom | fold -w22 | head -n1)
  cat << EOF > /root/.dividendcash/dividendcash.conf
rpcuser=$RPCUSER
rpcpassword=$RPCPASSWORD
rpcallowip=127.0.0.1
listen=1
server=1
daemon=1
port=19997
EOF
}

function create_key() {
  #if [[ -z "$COINKEY" ]]; then
  /usr/local/bin/dividendcashd -daemon
  sleep 10
  if [ -z "$(ps axo cmd:100 | grep /usr/local/bin/dividendcashd)" ]; then
   echo -e "DividendCash server couldn not start. Check /var/log/syslog for errors.{$NC}"
   exit 1
  fi
  COINKEY=$(/usr/local/bin/dividendcash-cli masternode genkey)
  if [ "$?" -gt "0" ];
    then
    echo -e "Wallet not fully loaded. Let us wait and try again to generate the Private Key"
    sleep 10
    COINKEY=$(/usr/local/bin/dividendcash-cli masternode genkey)
  fi
  #/usr/local/bin/dividendcash-cli stop
  #fi
  clear
}

function update_config() {
  sed -i 's/daemon=1/daemon=0/' /root/.dividendcash/dividendcash.conf
  cat << EOF >> /root/.dividendcash/dividendcash.conf
logintimestamps=1
maxconnections=64
#bind=$NODEIP
masternode=1
externalip=$NODEIP:19997
masternodeprivkey=$COINKEY
EOF
}

function enable_firewall() {
  echo -e "Installing and setting up firewall to allow ingress on port 19997"
  ufw allow ssh >/dev/null 2>&1
  ufw allow 19997 >/dev/null 2>&1
  ufw default allow outgoing >/dev/null 2>&1
  echo "y" | ufw enable >/dev/null 2>&1
}

function get_ip() {
  declare -a NODE_IPS
  for ips in $(netstat -i | awk '!/Kernel|Iface|lo/ {print $1," "}')
  do
    NODE_IPS+=($(curl --interface $ips --connect-timeout 2 -s4 icanhazip.com))
  done

  if [ ${#NODE_IPS[@]} -gt 1 ]
    then
      echo -e "More than one IP. Please type 0 to use the first IP, 1 for the second and so on..."
      INDEX=0
      for ip in "${NODE_IPS[@]}"
      do
        echo ${INDEX} $ip
        let INDEX=${INDEX}+1
      done
      read -e choose_ip
      NODEIP=${NODE_IPS[$choose_ip]}
  else
    NODEIP=${NODE_IPS[0]}
  fi
}

function compile_error() {
if [ "$?" -gt "0" ];
 then
  echo -e "Failed to compile DividendCash. Please investigate."
  exit 1
fi
}

function detect_ubuntu() {
 if [[ $(lsb_release -d) == *16.04* ]]; then
   UBUNTU_VERSION=16
 elif [[ $(lsb_release -d) == *14.04* ]]; then
   UBUNTU_VERSION=14
else
   echo -e "You are not running Ubuntu 14.04 or 16.04 Installation is cancelled."
   exit 1
fi
}

function checks() {
 detect_ubuntu
if [[ $EUID -ne 0 ]]; then
   echo -e "$0 must be run as root."
   exit 1
fi

if [ -n "$(pidof /usr/local/bin/dividendcashd)" ] || [ -e "/usr/local/bin/dividendcashd" ] ; then
  echo -e "DividendCash is already installed."
  exit 1
fi
}

function prepare_system() {
echo -e "Prepare the system to install DividendCash master node."
apt-get update >/dev/null 2>&1
apt-get install -y wget curl binutils >/dev/null 2>&1
}

function important_information() {
 echo -e "$NODEIP:19997"
 echo -e "$COINKEY"
}

function setup_node() {
  get_ip
  create_config
  create_key
  update_config
  enable_firewall
  important_information
  if (( $UBUNTU_VERSION == 16 )); then
    configure_systemd
  else
    configure_startup
  fi
}


##### Main #####
clear

checks
prepare_system
compile_node
setup_node
