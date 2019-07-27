#!/bin/bash

#
# MIT License
#
# Copyright (c) 2019 Rémi Ducceschi
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE
#

# script used to change VPN server used by OpenVPN, based on NordVPN servers.

set -efu

# OpenVPN configuration server file
SERVERCONF_FILE='/etc/openvpn/nordvpn.conf'
# Authentication file to log in VPN server
AUTHFILE='nordvpn_authentication'
# network interface to use
NET_INTERFACE='enp1s0'
# URL where to download the list of servers
URL='https://downloads.nordcdn.com/configs/archives/servers'
# Name of the downloaded file
ZIPFILE='ovpn.zip'

# Public: Write how to use the script in the console.
#
# List all the acceptable parameters and generic ways of how to call this script.
#
# This function is called with the `[--]help` parameter, or when bad parameters
# have been detected.
function show_help()
{
	echo "NAME
    vpn-mgr.sh - helps to use VPN with UFW rules. It creates a kill switch and can
    manage NordVPN servers.

SYNOPSIS
    vpn-mgr.sh help | restart | set SERVER_NAME | start [SERVER_NAME] | status | stop

DESCRIPTION 
    To run VPN Manager, you need to give it the action you want to do. Possible
    actions are:

      -h, --help, help
          Show this help and quit

      restart
          Restart OpenVPN and reload UFW. This can be useful
          when the connection with the VPN server is lost.
          You must be root to run this.

      set SERVER_NAME
          Update the NordVPN server used. SERVER_NAME must be of
          the form 'se203'. This is the name of the server, with
          the suffix '.nordvpn.com' removed.
          You can find which server to use at the following URL:
          https://nordvpn.com/servers/tools/
          You must be root to run this.

      start [SERVER_NAME]
          Start the VPN management. It starts OpenVPN with the
          provided SERVER_NAME. See 'set' option for more
          information about SERVER_NAME.
          If SERVER_NAME is not provided, it will use the last
          used one if any, otherwise the command will fail.
          This actually starts OpenVPN and add rules in UFW.
          You must be root to run this.

      status
          Show the status of OpenVPN and UFW, and if the
          connection to Internet works.
          Only this function can be run without root
          priviledges.

      stop
          Stop OpenVPN and remove rules from UFW created
          previously. Thus, you can use Internet normally.
          You must be root to run this.

RETURN VALUES
    vpn-mgr.sh uses the following exit codes:

    - -1: No actions provided

    - 0: Everything went alright

    - 1: Unknown action provided

    - 2: Parameter for given action is missing or wrong

    - 5: Trying to start VPN without any servers

    - 10: Internal error

    - 100: The script was not invoked with root priviledges

AUTHOR
    Written by Rémi Ducceschi <remi.ducceschi@gmail.com>

COPYRIGHT
     Copyright © 2019 Rémi Ducceschi. MIT License
     This is free software: you are free to change and redistribute it.
"
}

# Public: Tells the status of OpenVPN, UFW and your Internet connection.
#
# Also print the name of the current server in used.
function show_status()
{
	# OpenVPN
	local tmp
	tmp="$(systemctl status openvpn | grep 'Active:')"
	[[ "$tmp" =~ [[:space:]]*Active:[[:space:]]([[:alpha:]]+) ]]
	echo " OpenVPN status: ${BASH_REMATCH[1]}"
	# UFW
	tmp="$(systemctl status ufw.service | grep 'Active:')"
	[[ "$tmp" =~ [[:space:]]*Active:[[:space:]]([[:alpha:]]+) ]]
	echo "     UFW status: ${BASH_REMATCH[1]}"
	# Internet
	if wget -q --spider -T 2 'http://google.com'; then
		tmp='online'
	else
		tmp='offline'
	fi
	echo "Internet status: $tmp"
	# Current server
	if [ -e "$SERVERCONF_FILE" ] && [ -r "$SERVERCONF_FILE" ]; then
		tmp="$(tail -n 1 "$SERVERCONF_FILE")"
		tmp="${tmp:2}" # remove first 2 characters (comment char)
	else
		tmp='none'
	fi
	echo " Current server: $tmp"
}

# Public: start the VPN management.
#
# Start OpenVPN and add the correct rules to UFW.
#
# If a server name is provided, it will use it. Otherwise,
# it uses the last configured server. See https://nordvpn.com/servers/tools/
#
# $1 - the server name. Can be empty or of the form `se203`
function vpn_start()
{
	if [ -z "$1" ]; then
		if [ -e "$SERVERCONF_FILE" ] && [ -r "$SERVERCONF_FILE" ]; then
			# start OpenVPN
			service openvpn start
			# add UFW rules
			_update_ufw 'add'
			ufw reload
		else
			echo "No server have been set yet. Please provide a server name."
			exit 5
		fi
	else
		vpn_set "$1"
	fi
}

# Public: Stop VPN management.
#
# Stop OpenVPN and remove kill switch rules from UFW so you can use your
# Internet connection normally.
function vpn_stop()
{
	# stop OpenVPN
	service openvpn stop
	# remove UFW rules
	_update_ufw 'delete'
	ufw reload
}

# Public: Restart OpenVPN and reload UFW.
#
# This can be useful when connection to VPN server has been lost.
function vpn_restart()
{
	service openvpn restart
	ufw reload
}

# Public: Change the VPN server used.
#
# Update the list of available servers if possible, and change the server in use.
#
# Takes the server name as a parameter. See https://nordvpn.com/servers/tools/
#
# $1 - the server name. Must be of the form `se203`
function vpn_set()
{
	_download-serverlist
	_update_ufw 'delete'
	_select_server "$1"
	_update_ufw 'add'
	vpn_restart
}

# Internal: update UFW rules.
#
# IP address to add or remove is taken from `SERVERCONF_FILE`.
#
# The first parameter tells if rules should be added or removed.
#
# $1 - possible values: `add` or `delete`, tells if we should allow or forbid
#      IP address from `SERVERCONF_FILE`.
#
# Examples
#
#    _update_ufw 'delete'
function _update_ufw()
{
	if [ -z "${1+x}" ]; then
		echo 'Missing parameter to function "_update_ufw"' 1>&2
		exit 10
	fi

	local action
	local naction
	case "$1" in
		'add')
			action=''
			naction='delete'
			;;
		'delete')
			action='delete'
			naction=''
			;;
		*)
			echo "Wrong parameter to function \"_update_ufw\": '$1'" 1>&2
			exit 10
	esac

	# Update rules if `SERVERCONF_FILE` exists
	if [ -e "$SERVERCONF_FILE" ] && [ -r "$SERVERCONF_FILE" ]; then
		declare -a ipaddr
		mapfile -t ipaddr <<< "$(grep "remote " "$SERVERCONF_FILE" | grep -Poe '\d+')"
		ufw $action allow in on "$NET_INTERFACE" from "${ipaddr[0]}.${ipaddr[1]}.${ipaddr[2]}.${ipaddr[3]}"/24 port "${ipaddr[4]}" proto udp
		ufw $action allow out on "$NET_INTERFACE" to "${ipaddr[0]}.${ipaddr[1]}.${ipaddr[2]}.${ipaddr[3]}"/24 port "${ipaddr[4]}" proto udp
	fi
	ufw $naction allow in on "$NET_INTERFACE"
	ufw $naction allow out on "$NET_INTERFACE"
}

# Internal: Download the list of NordVPN servers
function _download-serverlist()
{(
	# run in a subshell because of `cd`
	cd /etc/openvpn
	local f
	declare -a vpndirs=("ovpn_tcp" "ovpn_udp")
	if wget -T 5 -q "$URL/$ZIPFILE"; then
		for f in "${vpndirs[@]}"; do
			rm -rf "$f"
		done
		unzip "$ZIPFILE" > /dev/null
		rm "$ZIPFILE"
		echo "server list updated"
	fi
)}

# Internal: Select the given server.
#
# This function copy the given server to provide it to OpenVPN.
# In addition, it updates the server configuration to automatically
# authenticate.
#
# Takes the new server name as a parameter. See https://nordvpn.com/servers/tools/
#
# $1 - the new server name. Must be of the form `se203`
function _select_server()
{(
	# run in a subshell because of `cd`
	cd /etc/openvpn
	local server="$1"
	cp "ovpn_udp/$server.nordvpn.com.udp.ovpn" "$SERVERCONF_FILE"
	sed -i "s{auth-user-pass{auth-user-pass $AUTHFILE{" nordvpn.conf
	{
		echo 'script-security 2'
		echo 'up /etc/openvpn/update-resolv-conf'
		echo 'down /etc/openvpn/update-resolv-conf'
		echo "# $server.nordvpn.com.udp.ovpn"
	} >> "$SERVERCONF_FILE"
	echo "server selected: $server.nordvpn.com.udp.ovpn"
)}

# Internal: Check whether the user has root priviledges.
#
# If user doesn't have root priviledges, it calls `exit 100`.
function _check_root()
{
	if [ "$EUID" -ne 0 ]; then
		echo "Please run as root"
		exit 100
	fi
}

#
# BEGINNING OF THE SCRIPT
#

if [ -z "${1+x}" ]; then
	show_help
	exit -1
fi

case "$1" in
	# show help
	'help'|'--help'|'-h')
		show_help
		;;
	# show status
	'status')
	show_status
	;;
	# start OpenVPN and update ufw
	'start')
		_check_root
		if [ -z "${2+x}" ]; then
			vpn_start ''
		else
			vpn_start "$2"
		fi
		;;
	# stop OpenVPN and update ufw
	'stop')
		_check_root
		vpn_stop
		;;
	# restart OpenVPN and ufw
	'restart')
		_check_root
		vpn_restart
		;;
	# Change VPN server
	'set')
		_check_root
		if [ -z "${2+x}" ]; then
			show_help
			exit 2
		fi
		vpn_set "$2"
		;;
	# unknown
	*)
		show_help
		exit 1
		;;
esac
