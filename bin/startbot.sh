#!/usr/bin/env bash
#
#    FILE: startbot.sh
#    bbots (Twitch port) - opens the connection and keeps the bot running
#    AUTHOR: Joshua Bailey, 2005-2007. Reworked for Twitch, 2026.
#
#    Copyright (C) 2007 Joshua Bailey and Dave Crouse
#    Licensed under the GNU GPL, version 2 or (at your option) any later version.
#
#    ncat holds the TLS connection (the job ntcpclient did in 2007).
#    bashbot.sh writes to it on file descriptor 5 and reads on 6.
#
#    What bashbot.sh reads comes through one pipe with two writers:
#      relay      passes on each line from Twitch, whole, and says CLOSED
#                 when the connection ends
#      forwarder  passes on commands typed into bin/bbots-ctl, each stamped
#                 with a key made fresh at every start
#
#    run/ holds the things bbots-ctl needs: the control pipe, this script's
#    pid, and the replies to console commands. Only you can read it.

cd "$(dirname "$(readlink -f "$0")")/.." || exit 2

source files/config
RETRY="${RETRY:-30}"
runDir="run"
pid=""
relayPid=""
forwardPid=""

mkdir -p "$runDir" && chmod 700 "$runDir" || exit 2
if [[ -s "${runDir}/startbot.pid" ]]
then
	oldPid="$(< "${runDir}/startbot.pid")"
	if [[ "$oldPid" =~ ^[0-9]+$ ]] && grep -qs "startbot" "/proc/${oldPid}/cmdline"
	then
		echo "bbots is already running (pid ${oldPid}). Stop that one first."
		exit 1
	fi
fi
echo "$$" > "${runDir}/startbot.pid"
rm -f "${runDir}"/reply.*
if [[ ! -p "${runDir}/control" ]]
then
	rm -f "${runDir}/control"
	mkfifo -m 600 "${runDir}/control" || exit 2
fi

pipes="$(mktemp -d)" || exit 2
mkfifo "${pipes}/in" "${pipes}/out" "${pipes}/raw" || exit 2

BBOTS_CONSOLE_KEY="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
export BBOTS_CONSOLE_KEY

cleanup ()
{
	kill "$pid" "$relayPid" "$forwardPid" 2>/dev/null
	rm -rf "$pipes"
	rm -f "${runDir}/startbot.pid" "${runDir}"/reply.*
}
trap cleanup EXIT
trap 'echo; echo "bbots stopped"; exit 0' INT TERM

# relay: Twitch's lines, one whole line at a time, then a closing note
relay ()
{
	local line
	while IFS= read -r line
	do
		printf '%s\n' "$line"
	done
	printf ':relay CLOSED\n'
}

# forwarder: console commands from bbots-ctl, for as long as startbot runs
forwarder ()
{
	local line
	while true
	do
		while IFS= read -r line
		do
			printf ':console CONSOLE %s %s\n' "$BBOTS_CONSOLE_KEY" "$line" > "${pipes}/in"
		done < "${runDir}/control"
	done
}
forwarder &
forwardPid="$!"

while true
do
	# With our own Twitch app (CLIENT_ID plus a saved login) the token is
	# checked, and renewed if needed, before every connection.
	if [[ -n "$CLIENT_ID" && -s "${REFRESH_FILE:-files/.refresh}" ]]
	then
		bin/gettoken.sh ensure
		case "$?" in
			0)	;;
			2)	echo "Retrying in ${RETRY} seconds (Ctrl-C to stop)"
				sleep "$RETRY"
				continue
				;;
			*)	echo "bbots has no usable token and will not retry."
				exit 2
				;;
		esac
	fi

	ncat --ssl "$SERVER" "$PORT" < "${pipes}/out" > "${pipes}/raw" &
	pid="$!"
	relay < "${pipes}/raw" > "${pipes}/in" &
	relayPid="$!"

	# out must come first. in is opened read-write so that writers coming
	# and going never look like the end of the connection to bashbot.sh.
	bin/bashbot.sh 5> "${pipes}/out" 6<> "${pipes}/in"
	RET="$?"

	kill "$pid" "$relayPid" 2>/dev/null
	wait "$pid" "$relayPid" 2>/dev/null

	if [[ "$RET" == "2" ]]
	then
		echo "bbots hit a fatal error and will not retry. See logs/botlog"
		exit 2
	fi
	echo "Disconnected from Twitch. Reconnecting in ${RETRY} seconds (Ctrl-C to stop)"
	sleep "$RETRY"
done
