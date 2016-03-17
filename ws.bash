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

	local remote="tcp:"
	if [ "$wsb_scheme" = 'wss' ]; then
		remote="openssl:"
	fi
	remote+="$wsb_host:$wsb_port"

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

### ws.bash ends here
