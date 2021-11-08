#!/usr/bin/sh
pacman -Qs easy-rsa || (sudo pacman -S --noconfirm easy-rsa)
mkdir ~/easy-rsa
ln -s /etc/easy-rsa/[x,o]* ~/easy-rsa/
cp /etc/easy-rsa/vars ~/easy-rsa/
cd ~/easy-rsa
export EASYRSA=$(pwd)
export EASYRSA_VARS_FILE=$(pwd)/vars
#nano vars (этот пункт не потребуется, если использовать значение по-умолчанию: set_var EASYRSA_DN "cn_only")
easyrsa init-pki
easyrsa build-ca nopass
