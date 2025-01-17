#!/bin/sh
# Copyright 2016-2017 Dan Luedtke <mail@danrl.com>
# Licensed to the public under the Apache License 2.0.

WG=/usr/bin/wg_obf
SH=/usr/bin/shuf
if [ ! -x $WG ]; then
	logger -t "wireguard_obf" "error: missing wireguard_obf-tools (${WG})"
	exit 0
fi

if [ ! -x $SH ]; then
	logger -t "wireguard_obf" "error: missing coreutils-shuf (${SH})"
	exit 0
fi

[ -n "$INCLUDE_ONLY" ] || {
	. /lib/functions.sh
	. ../netifd-proto.sh
	init_proto "$@"
}

proto_wireguard_obf_init_config() {
	proto_config_add_string "private_key"
	proto_config_add_int "listen_port"
	proto_config_add_int "mtu"
	proto_config_add_string "fwmark"
	available=1
	no_proto_task=1
}

proto_wireguard_obf_setup_peer() {
	local peer_config="$1"

	local disabled
	local public_key
	local preshared_key
	local allowed_ips
	local route_allowed_ips
	local endpoint_host
	local endpoint_port
	local persistent_keepalive

	config_get_bool disabled "${peer_config}" "disabled" 0
	config_get public_key "${peer_config}" "public_key"
	config_get preshared_key "${peer_config}" "preshared_key"
	config_get allowed_ips "${peer_config}" "allowed_ips"
	config_get_bool route_allowed_ips "${peer_config}" "route_allowed_ips" 0
	config_get endpoint_host "${peer_config}" "endpoint_host"
	config_get endpoint_port "${peer_config}" "endpoint_port"
	config_get persistent_keepalive "${peer_config}" "persistent_keepalive"

	if [ "${disabled}" -eq 1 ]; then
		# skip disabled peers
		return 0
	fi

	if [ -z "$public_key" ]; then
		echo "Skipping peer config $peer_config because public key is not defined."
		return 0
	fi

	echo "[Peer]" >> "${wg_cfg}"
	echo "PublicKey=${public_key}" >> "${wg_cfg}"
	if [ "${preshared_key}" ]; then
		echo "PresharedKey=${preshared_key}" >> "${wg_cfg}"
	fi
	for allowed_ip in $allowed_ips; do
		echo "AllowedIPs=${allowed_ip}" >> "${wg_cfg}"
	done
	if [ "${endpoint_host}" ]; then
		case "${endpoint_host}" in
			*:*)
				endpoint="[${endpoint_host}]"
				;;
			*)
				endpoint="${endpoint_host}"
				;;
		esac
		if [ "${endpoint_port}" ]; then
			if [ "`echo ${endpoint_port} | grep -c '-'`" == "1" ]; then
				endpoint="${endpoint}:`shuf -i ${endpoint_port} -n 1`"
			else
				endpoint="${endpoint}:${endpoint_port}"
			fi
		else
			endpoint="${endpoint}:51820"
		fi
		echo "Endpoint=${endpoint}" >> "${wg_cfg}"
	fi
	if [ "${persistent_keepalive}" ]; then
		echo "PersistentKeepalive=${persistent_keepalive}" >> "${wg_cfg}"
	fi

	if [ ${route_allowed_ips} -ne 0 ]; then
		for allowed_ip in ${allowed_ips}; do
			case "${allowed_ip}" in
				*:*/*)
					proto_add_ipv6_route "${allowed_ip%%/*}" "${allowed_ip##*/}"
					;;
				*.*/*)
					proto_add_ipv4_route "${allowed_ip%%/*}" "${allowed_ip##*/}"
					;;
				*:*)
					proto_add_ipv6_route "${allowed_ip%%/*}" "128"
					;;
				*.*)
					proto_add_ipv4_route "${allowed_ip%%/*}" "32"
					;;
			esac
		done
	fi
}

ensure_key_is_generated() {
	local private_key
	private_key="$(uci get network."$1".private_key)"

	if [ "$private_key" == "generate" ]; then
		local ucitmp
		oldmask="$(umask)"
		umask 077
		ucitmp="$(mktemp -d)"
		private_key="$("${WG}" genkey)"
		uci -q -t "$ucitmp" set network."$1".private_key="$private_key" && \
			uci -q -t "$ucitmp" commit network
		rm -rf "$ucitmp"
		umask "$oldmask"
	fi
}

proto_wireguard_obf_setup() {
	local config="$1"
	local wg_dir="/tmp/wireguard_obf"
	local wg_cfg="${wg_dir}/${config}"

	local private_key
	local listen_port
	local mtu

	ensure_key_is_generated "${config}"

	config_load network
	config_get private_key "${config}" "private_key"
	config_get listen_port "${config}" "listen_port"
	config_get addresses "${config}" "addresses"
	config_get mtu "${config}" "mtu"
	config_get fwmark "${config}" "fwmark"
	config_get ip6prefix "${config}" "ip6prefix"
	config_get metric "${config}" "metric"
	config_get metric6 "${config}" "metric6"
	config_get gateway "${config}" "gateway"
	config_get delay "${config}" "delay"
	config_get ip6gw "${config}" "ip6gw"
	config_get ip6subnet "${config}" "ip6subnet"
	config_get nohostroute "${config}" "nohostroute"
	config_get defaultroute "${config}" "defaultroute"
	config_get tunlink "${config}" "tunlink"
	config_get defaultip6gw "${config}" "defaultip6gw"

	ip link del dev "${config}" 2>/dev/null
	ip link add dev "${config}" type wireguard_obf

	if [ "${mtu}" ]; then
		ip link set mtu "${mtu}" dev "${config}"
	fi

	proto_init_update "${config}" 1

	umask 077
	mkdir -p "${wg_dir}"
	echo "[Interface]" > "${wg_cfg}"
	echo "PrivateKey=${private_key}" >> "${wg_cfg}"
	if [ "${listen_port}" ]; then
		echo "ListenPort=${listen_port}" >> "${wg_cfg}"
	fi
	if [ "${fwmark}" ]; then
		echo "FwMark=${fwmark}" >> "${wg_cfg}"
	fi
	config_foreach proto_wireguard_obf_setup_peer "wireguard_obf_${config}"

	# apply configuration file
	${WG} setconf ${config} "${wg_cfg}"
	WG_RETURN=$?

	rm -f "${wg_cfg}"

	if [ ${WG_RETURN} -ne 0 ]; then
		sleep 5
		proto_setup_failed "${config}"
		exit 1
	fi

	for address in ${addresses}; do
		case "${address}" in
			*:*/*)
				proto_add_ipv6_address "${address%%/*}" "${address##*/}"
				;;
			*.*/*)
				proto_add_ipv4_address "${address%%/*}" "${address##*/}"
				;;
			*:*)
				proto_add_ipv6_address "${address%%/*}" "128"
				;;
			*.*)
				proto_add_ipv4_address "${address%%/*}" "32"
				;;
		esac
	done

	for prefix in ${ip6prefix}; do
		proto_add_ipv6_prefix "$prefix"
	done

	# endpoint dependency
	if [ "${nohostroute}" != "1" ]; then
		wg_obf show "${config}" endpoints | \
		sed -E 's/\[?([0-9.:a-f]+)\]?:([0-9]+)/\1 \2/' | \
		while IFS=$'\t ' read -r key address port; do
			[ -n "${port}" ] || continue
			proto_add_host_dependency "${config}" "${address}" "${tunlink}"
		done
	fi

	# Delay ifup the interface if delay time configured.
	if [ "${delay}" ] && [ ! -f "/tmp/wireguard_obf/$1_first" ]; then
		logger -t "wireguard_obf" "Delay up detected, delay ifup the interface..."
		touch /tmp/wireguard_obf/$1_first
		sleep ${delay}
	fi

	proto_send_update "${config}"

	# Add default route to main routing table.
	if [ "${defaultroute}" != "0" ] && [ "${gateway}" != "" ] && [ "${metric}" != "" ] ; then
		ip route add default via "${gateway}" dev "${config}" proto static metric "${metric}"
	fi

	# Add default ipv6 route to main routing table.
	if [ "${defaultip6gw}" = "1" ] && [ "${ip6gw}" != "" ] && [ "${ip6subnet}" != "" ] && [ "${metric6}" != "" ] ; then
		ip -6 route add default from ${ip6subnet} via "${ip6gw}" dev "${config}" proto static metric "${metric6}" pref medium
	fi
}

proto_wireguard_obf_teardown() {
	local config="$1"
	ip link del dev "${config}" >/dev/null 2>&1
}

[ -n "$INCLUDE_ONLY" ] || {
	add_protocol wireguard_obf
}
