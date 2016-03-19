#!/usr/bin/env bash

### ws.bash --- websocket lib for bash

## Copyright (c) 2016 Zachary Elliott
##
## Authors: Zachary Elliott <contact@zell.io>
## URL: https://github.com/zellio/ws.bash
## Version: 0.1.0

### Commentary:

##

### License:

## Permission is hereby granted, free of charge, to any person obtaining a
## copy of this software and associated documentation files (the “Software”),
## to deal in the Software without restriction, including without limitation
## the rights to use, copy, modify, merge, publish, distribute, sublicense,
## and/or sell copies of the Software, and to permit persons to whom the
## Software is furnished to do so, subject to the following conditions:

## The above copyright notice and this permission notice shall be included in
## all copies or substantial portions of the Software.

## THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
## IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
## FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
## AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
## LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
## FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
## DEALINGS IN THE SOFTWARE.

### Code:

function is_function
{
	declare -Ff "$1" >/dev/null
}

function wsb__parse_uri
{
	local uri="$1"

	local scheme hier_part query fragment
	local authority path
	local user_info username password host port

	scheme="${uri%%:*}"
	hier_part="${uri#*:}"

	if [[ "$hier_part" =~ '#' ]]; then
		fragment="${hier_part#*#}"
		hier_part="${hier_part%%#*}"
	fi

	if [[ "$hier_part" =~ '?' ]]; then
		query="${hier_part#*\?}"
		hier_part="${hier_part%%\?*}"
	fi

	if [[ "$hier_part" =~ ^// ]]; then
		hier_part="${hier_part#//}"
		authority="${hier_part%%/*}"
		path="/${hier_part#*/}"
	fi

	if [[ "$authority" =~ '@' ]]; then
		user_info="${authority%%@*}"
		username="${user_info%%:*}"
		password="${user_info##*:}"
		authority="${authority/$user_info@/}"
	fi

	if [[ "$authority" =~ ':' ]]; then
		host="${authority%%:*}"
		port="${authority##*:}"
	else
		host="$authority"
	fi

	wsb_scheme="$scheme"
	wsb_username="$username"
	wsb_password="$password"
	wsb_host="$host"
	wsb_port="$port"
	wsb_path="$path"
	wsb_query="$query"
	wsb_fragment="$fragment"
}

function wsb__socket_connect
{
	local -r in_sock="${wsb_buffer_dir}/socat.stdin"
	local -r out_sock="${wsb_buffer_dir}/socket.stdout"
	local -i socat_pid

	local protocol port remote
	if [ "$wsb_scheme" = 'wss' ]; then
		protocol="openssl"
		port="${wsb_port:-443}"
	else
		protocol="tcp"
		port="${wsb_port:-80}"
	fi
	remote="$protocol:$wsb_host:$port"

	echo "$remote"

	mkfifo "$in_sock" "$out_sock"

	socat "$remote" stdio,ignoreeof,nonblock <"$in_sock" >"$out_sock" &
	socat_pid="$!"

	wsb_socket_in="$in_sock"
	wsb_socket_out="$out_sock"
	wsb_socat_pid="$socat_pid"
}

function wsb__build_header
{
	local -r socket_key="${wsb_socket_key:-$(head --bytes=16 /dev/urandom | base64)}"
	local -r socket_version="${wsb_socket_version:-13}"

	echo -e "\
GET /$wsb_path HTTP/1.1\r
Host: $wsb_host\r
Origin: $wsb_origin\r
Connection: Upgrade\r
Upgrade: websocket\r
Sec-WebSocket-Key: $socket_key\r
Sec-WebSocket-Version: $socket_version\r
\r"
}

function wsb__handshake
{
	local handshake_response

	echo -e "$(wsb__build_header)" >"$wsb_socket_in"

	while IFS= read -r line;
		  line="$(tr -d '\r\n' <<<"$line")";
		  test -n "$line"; do {
		handshake_response+="$line\n"
	}; done <"$wsb_socket_out"

	is_function wsb__handshake_callback &&
		wsb__handshake_callback "$handshake_response"
}

function wsb__read_bytes
{
	head --bytes="${1:-1}"
}

function wsb__read_bytes_as_int
{
	wsb__read_bytes "$1" | hexdump --format '"%u"'
}

function wsb__read_bytes_hex
{
	wsb__read_bytes "$1" | xxd --plain
}

function ord
{
	echo -n "${1:-0}" | hexdump --no-squeezing --format '"%u"'
}

function wsb__apply_mask
{
	local -r mask="$1"
	local -r hex_payload="$2"

	local masked_data
	local -a masked_bytes
	local -i index=0

	while IFS= read c; do
		masking_bytes[$index]="$(ord "$c")"
		(( index += 1 ))
	done < <(echo "$mask" | fold --bytes --width=1)

	index=0
	while IFS= read -r c; do
		(( _mb = 0x$c ^ masking_bytes[index],
		   index = (index + 1) % 4 ))
		masked_data+="$(printf "%.02x" "$_mb")"
	done < <(echo "$hex_payload" | fold --bytes --width=2)

	echo "$masked_data"
}

function wsb__frame_read
{
	exec 3<&0
	exec 0<"$wsb_socket_out"

	local -i fin
	local -i rsv1
	local -i rsv2
	local -i rsv3
	local -i opcode
	local -i mask
	local -i length

	local payload byte

	byte="$(wsb__read_bytes_as_int 1)"
	((
		fin = byte >> 7 & 0x01,
		rsv1 = byte >> 6 & 0x01,
		rsv2 = byte >> 5 & 0x01,
		rsv3 = byte >> 4 & 0x01,
 		opcode = byte & 0x0f
	))

	byte="$(wsb__read_bytes_as_int 1)"
	((
		mask = byte >> 7 & 0x01,
		length = byte & 0x7f
	))

	if (( length == 126 )); then
		length="$(wsb__read_bytes_as_int 2)"
	elif (( length == 127 )); then
		length="$(wsb__read_bytes_as_int 4)"
	fi

	local masking_key
	if (( mask )); then
		masking_key="$(wsb__read_bytes 4)"
	fi

	local hex_payload="$(wsb__read_bytes_hex "$length")"
	if (( ${#masking_key} )); then
		unmasked_hex_payload="$(wsb__apply_mask "$masking_key" "$hex_payload")"
		payload="$(echo "$unmasked_hex_payload" | xxd --plain)"
	fi

	exec 0<&3
	exec 3<&-

	wsb__read_frame_fin="$fin"
	wsb__read_frame_rsv1="$rsv1"
	wsb__read_frame_rsv2="$rsv2"
	wsb__read_frame_rsv3="$rsv3"
	wsb__read_frame_opcode="$opcode"
	wsb__read_frame_mask="$mask"
	wsb__read_frame_length="$length"
	wsb__read_frame_payload="$payload"
}

function wsb__frame_loop_ping_callback
{

}

function wsb__frame_loop
{
	wsb__frame_loop_run=1
	while (( wsb__frame_loop_run )); do
		wsb__frame_read

		is_function wsb__frame_loop_callback &&
			wsb__frame_loop_callback

		wsb__frame_loop_ping_callback
	done
}

### ws.bash ends here
