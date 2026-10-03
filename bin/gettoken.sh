#!/usr/bin/env bash
#
#    FILE: gettoken.sh
#    bbots (Twitch port) - gets and renews the bot's own Twitch token
#
#    Copyright (C) 2007 Joshua Bailey and Dave Crouse
#    Licensed under the GNU GPL, version 2 or (at your option) any later version.
#
#    Needs CLIENT_ID in files/config (from the app registered at
#    dev.twitch.tv/console), plus curl and jq.
#
#    Usage:
#      bin/gettoken.sh login     log the bot account in. Shows a code to enter
#                                on a Twitch page; run it once, or again if
#                                the saved login has lapsed.
#      bin/gettoken.sh check     show whose token is saved and how long it lasts
#      bin/gettoken.sh refresh   swap the saved refresh token for a new token
#      bin/gettoken.sh ensure    refresh only if the token is invalid or about
#                                to expire (startbot.sh runs this)
#
#    Files (both readable by you alone):
#      files/.token      oauth:<access token>, what the bot logs in with
#      files/.refresh    the refresh token
#
#    Exit codes: 0 = a usable token is saved, 1 = it is not,
#                2 = Twitch could not be reached (worth trying again later)

cd "$(dirname "$(readlink -f "$0")")/.." || exit 1
source files/config

TOKEN_FILE="${TOKEN_FILE:-files/.token}"
REFRESH_FILE="${REFRESH_FILE:-files/.refresh}"
TOKEN_SCOPES="${TOKEN_SCOPES:-chat:read chat:edit}"
AUTH="https://id.twitch.tv/oauth2"
umask 077

for needed in curl jq
do
	if ! command -v "$needed" > /dev/null
	then
		echo "gettoken: $needed is not installed" >&2
		exit 1
	fi
done
if [[ ! "$CLIENT_ID" =~ ^[a-z0-9]{20,40}$ ]]
then
	echo "gettoken: set CLIENT_ID in files/config first" >&2
	exit 1
fi

# field json name -> prints one top-level field of a JSON reply, or nothing
field ()        { jq -r ".$2 // empty" <<< "$1" 2> /dev/null; }

# saveTokens json -> writes the access and refresh tokens from a token reply
saveTokens ()
{
	local access refresh
	access="$(field "$1" access_token)"
	refresh="$(field "$1" refresh_token)"
	[[ -n "$access" && -n "$refresh" ]] || return 1
	printf 'oauth:%s\n' "$access" > "${TOKEN_FILE}.new" && mv "${TOKEN_FILE}.new" "$TOKEN_FILE"
	printf '%s\n' "$refresh" > "${REFRESH_FILE}.new" && mv "${REFRESH_FILE}.new" "$REFRESH_FILE"
}

# validate -> asks Twitch about the saved token; sets tokenLogin and tokenLeft
validate ()
{
	local token reply
	tokenLogin=""
	tokenLeft=0
	[[ -s "$TOKEN_FILE" ]] || return 1
	token="$(< "$TOKEN_FILE")"
	reply="$(curl -sS --max-time 15 -H "Authorization: OAuth ${token#oauth:}" "${AUTH}/validate" 2> /dev/null)"
	tokenLogin="$(field "$reply" login)"
	tokenLeft="$(field "$reply" expires_in)"
	[[ "$tokenLeft" =~ ^[0-9]+$ ]] || tokenLeft=0
	[[ -n "$tokenLogin" ]]
}

doRefresh ()
{
	local reply
	if [[ ! -s "$REFRESH_FILE" ]]
	then
		echo "gettoken: no saved login. Run: bin/gettoken.sh login" >&2
		return 1
	fi
	reply="$(curl -sS --max-time 15 -X POST "${AUTH}/token" \
		--data-urlencode "grant_type=refresh_token" \
		--data-urlencode "refresh_token=$(< "$REFRESH_FILE")" \
		--data-urlencode "client_id=${CLIENT_ID}" 2> /dev/null)"
	if [[ -z "$reply" ]]
	then
		echo "gettoken: could not reach Twitch to renew the token" >&2
		return 2
	fi
	if saveTokens "$reply"
	then
		return 0
	fi
	echo "gettoken: Twitch would not renew the token ($(field "$reply" message))." >&2
	echo "gettoken: the saved login has lapsed. Run: bin/gettoken.sh login" >&2
	return 1
}

doLogin ()
{
	local reply deviceCode userCode uri interval expires waited message
	reply="$(curl -sS --max-time 15 -X POST "${AUTH}/device" \
		--data-urlencode "client_id=${CLIENT_ID}" \
		--data-urlencode "scopes=${TOKEN_SCOPES}" 2> /dev/null)"
	deviceCode="$(field "$reply" device_code)"
	userCode="$(field "$reply" user_code)"
	uri="$(field "$reply" verification_uri)"
	interval="$(field "$reply" interval)"
	expires="$(field "$reply" expires_in)"
	[[ "$interval" =~ ^[0-9]+$ ]] || interval=5
	[[ "$expires" =~ ^[0-9]+$ ]] || expires=1800
	if [[ -z "$deviceCode" || -z "$userCode" ]]
	then
		echo "gettoken: Twitch would not start a login ($(field "$reply" message))." >&2
		echo "gettoken: check CLIENT_ID in files/config" >&2
		return 1
	fi
	echo
	echo "  1. In a browser, log in to Twitch as the BOT account: ${NICK}"
	echo "  2. Open:  ${uri}"
	echo "  3. Enter this code if it asks:  ${userCode}"
	echo
	echo "Waiting for you to approve it (Ctrl-C to give up)..."
	waited=0
	while (( waited < expires ))
	do
		sleep "$interval"
		waited=$(( waited + interval ))
		reply="$(curl -sS --max-time 15 -X POST "${AUTH}/token" \
			--data-urlencode "client_id=${CLIENT_ID}" \
			--data-urlencode "scopes=${TOKEN_SCOPES}" \
			--data-urlencode "device_code=${deviceCode}" \
			--data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:device_code" 2> /dev/null)"
		if saveTokens "$reply"
		then
			echo "Approved. Token saved to ${TOKEN_FILE}"
			doCheck
			return 0
		fi
		message="$(field "$reply" message)"
		case "$message" in
			authorization_pending|"")	;;
			slow_down)	interval=$(( interval + 5 )) ;;
			*)	echo "gettoken: login failed (${message})" >&2
				return 1
				;;
		esac
	done
	echo "gettoken: the code expired before it was approved. Run login again." >&2
	return 1
}

doCheck ()
{
	if validate
	then
		echo "Token belongs to: ${tokenLogin}"
		echo "Good for another: $(( tokenLeft / 3600 ))h $(( tokenLeft % 3600 / 60 ))m"
		if [[ "$tokenLogin" != "$NICK" ]]
		then
			echo "WARNING: NICK in files/config is '${NICK}', but this token is for '${tokenLogin}'."
			echo "         They must match, or Twitch will refuse the bot's login."
		fi
		return 0
	fi
	echo "The saved token is missing, expired or not valid."
	return 1
}

case "${1:-}" in
	login)		doLogin ;;
	check)		doCheck ;;
	refresh)	doRefresh && doCheck ;;
	ensure)		# quiet unless something needs attention
			if validate && (( tokenLeft > 900 ))
			then
				exit 0
			fi
			doRefresh
			;;
	*)		echo "Usage: $(basename "$0") {login|check|refresh|ensure}"
			exit 1
			;;
esac
