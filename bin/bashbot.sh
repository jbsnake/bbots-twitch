#!/usr/bin/env bash
#
#    FILE: bashbot.sh
#    bbots (Twitch port) - the bot's main loop
#    AUTHORS: Joshua Bailey and Dave Crouse, 2005-2007. Reworked for Twitch, 2026.
#
#    Copyright (C) 2007 Joshua Bailey and Dave Crouse
#    Licensed under the GNU GPL, version 2 or (at your option) any later version.
#
#    Started by startbot.sh with the Twitch connection on two file descriptors:
#    IFD (6) is what the server sends us, OFD (5) is what we send the server.
#
#    Three tiers of people, checked on every message:
#      owner   - on files/lists/owners.lst. System level: load and unload
#                modules, manage owners, send the bot to other channels.
#      admin   - the broadcaster and moderators of the channel the message
#                came from, plus anyone on that channel's admin list.
#                Admin modules only, and only for their own channel.
#      anyone  - anyuser modules.
#
#    Exit codes: 1 = disconnected (startbot.sh reconnects), 2 = fatal (it stops)

cd "$(dirname "$(readlink -f "$0")")/.." || exit 2

source bin/libs/.functions
source files/config

IFD="${IFD:-6}"
OFD="${OFD:-5}"
consoleReply=""
owners="files/lists/owners.lst"
channels="files/lists/channels.lst"
adminDir="files/lists/admins"
HOME_CHANNEL="$CHANNEL"
BROADCASTER="${CHANNEL#\#}"

if [[ ! -r "$TOKEN_FILE" ]]
then
	echo "No readable token file at $TOKEN_FILE" >&2
	exit 2
fi
if ! validChannel "$HOME_CHANNEL"
then
	echo "CHANNEL in files/config must look like #name, in lowercase" >&2
	exit 2
fi

# the home channel's broadcaster is always an owner
[[ -e "$owners" ]] || echo "$BROADCASTER" > "$owners"

# the home channel is always on the channel list
[[ -e "$channels" ]] || echo "$HOME_CHANNEL" > "$channels"
[[ -n "$(onList "$channels" "$HOME_CHANNEL")" ]] || echo "$HOME_CHANNEL" >> "$channels"
mkdir -p "$adminDir"

createOWNERmodule
createADMINmodule
createANYUSERmodule

####################################
#          TWITCH LOGIN            #
####################################

sendRaw "CAP REQ :twitch.tv/tags twitch.tv/commands"
sendRaw "PASS $(< "$TOKEN_FILE")"
botlog "<o> PASS ********"
sendCom "NICK" "$NICK"

while IFS= read -r joinChannel
do
	validChannel "$joinChannel" || continue
	sendCom "JOIN" "$joinChannel"
	sleep 0.6	# Twitch limits how fast a bot may join channels
done < "$channels"

####################################
#           MAIN LOOP              #
####################################

# Twitch pings every few minutes, so a long silence means the connection
# has died without telling us. IDLE_LIMIT seconds of nothing ends the loop.
while IFS= read -r -t "${IDLE_LIMIT:-600}" cur_line <&"${IFD}"
do
	cur_line="${cur_line%$'\r'}"
	[[ -z "$cur_line" ]] && continue
	if [[ "$cur_line" == ":console CONSOLE "* ]]
	then
		# logged without the key that proves it came from this machine
		botlog "<console> ${cur_line#:console CONSOLE * } <end>"
	else
		botlog "<input> ${cur_line} <end>"
	fi

	# split the line into: @tags  :prefix  COMMAND  params
	tags=""
	prefix=""
	rest="$cur_line"
	if [[ "$rest" == @* ]]
	then
		tags="${rest%% *}"
		tags="${tags#@}"
		rest="${rest#* }"
	fi
	if [[ "$rest" == :* ]]
	then
		prefix="${rest%% *}"
		prefix="${prefix#:}"
		rest="${rest#* }"
	fi
	serverCommand="${rest%% *}"
	params=""
	[[ "$rest" == *" "* ]] && params="${rest#* }"

	case "$serverCommand" in
		PING)	sendRaw "PONG ${params}"
			botlog "<o> PONG ${params}"
			;;
		366)	# end of a names list: we are in that channel
			joined="${params#* }"
			joined="${joined%% *}"
			if [[ -n "$GREETING" ]] && validChannel "$joined"
			then
				sendCM "$joined" "$GREETING"
				botlog "<o> $joined $GREETING"
			fi
			;;
		USERSTATE)
			# Twitch tells us our own standing in a channel. Where the bot
			# is the broadcaster or a moderator it may talk faster.
			stateChannel="${params%% *}"
			if validChannel "$stateChannel"
			then
				badges="$(getTag badges)"
				if [[ ",${badges}" == *",broadcaster/"* || ",${badges}" == *",moderator/"* || "$(getTag mod)" == "1" ]]
				then
					botPriv[$stateChannel]=1
				else
					unset "botPriv[$stateChannel]"
				fi
			fi
			;;
		NOTICE)	if [[ "$params" == *"Login authentication failed"* || "$params" == *"Improperly formatted auth"* ]]
			then
				botlog "<error> Twitch rejected the token: ${params}"
				echo "Twitch rejected the token (see logs/botlog)" >&2
				exit 2
			fi
			;;
		RECONNECT)
			botlog "<info> Twitch asked us to reconnect"
			exit 1
			;;
		CLOSED)	# startbot.sh's relay says the connection to Twitch has gone
			[[ "$prefix" == "relay" ]] || continue
			botlog "<info> connection to Twitch closed"
			exit 1
			;;
		CONSOLE)
			# A command typed into bin/bbots-ctl on this machine, not sent by
			# Twitch. startbot.sh stamps each one with a key it makes fresh at
			# every start; a line without that key is ignored.
			read -r conKey conTime conId conMode conChannel conName conRest <<< "$params"
			[[ "$prefix" == "console" && -n "$BBOTS_CONSOLE_KEY" && "$conKey" == "$BBOTS_CONSOLE_KEY" ]] || continue
			[[ "$conId" =~ ^[A-Za-z0-9]{1,40}$ ]] || continue
			consoleReply="run/reply.${conId}"
			: >> "$consoleReply"
			if [[ ! "$conTime" =~ ^[0-9]{1,12}$ ]] || (( EPOCHSECONDS - conTime > 30 ))
			then
				echo "That command waited too long for the bot and was dropped." >> "$consoleReply"
			elif ! validChannel "$conChannel" || [[ -z "$(onList "$channels" "$conChannel")" ]]
			then
				echo "The bot is not in ${conChannel}." >> "$consoleReply"
			else
				channel="$conChannel"
				# The name console commands run under. It shows wherever a
				# module addresses whoever asked, which matters when the
				# reply is sent loud. The default has a hyphen in it, which
				# no Twitch name can, so it can never ping a real person.
				conName="${conName,,}"
				[[ "$conName" =~ ^[a-z0-9_-]{1,25}$ ]] || conName="${CONSOLE_NAME:-bot-handler}"
				whoSaid="$conName"
				displayName="$conName"
				tags=""
				msgId=""
				badges=""
				pm=no
				isBroadcaster=no
				isMod=no
				isOwner=yes
				isAdmin=yes
				admins="${adminDir}/${channel#\#}.lst"
				whatSaid="${conRest#:}"
				# the trigger is optional at the console
				if [[ "$whatSaid" != "${trig}"* && "$whatSaid" != "?trig" && "$whatSaid" != "!trig "* ]]
				then
					whatSaid="${trig}${whatSaid}"
				fi
				# L = loud: replies go to the channel as usual
				[[ "$conMode" == "L" ]] && consoleReply=""
				source bin/libs/.core
				source bin/owner-modules
				source bin/libs/.admincore
				source bin/admin-modules
				source bin/anyuser-modules
			fi
			consoleReply=""
			: > "run/reply.${conId}.done"
			;;
		PRIVMSG)
			channel="${params%% *}"
			validChannel "$channel" || continue
			whoSaid="${prefix%%!*}"
			whoSaid="${whoSaid,,}"
			whatSaid="${params#* :}"
			# drop Chatterino's invisible duplicate-message marker and trailing spaces
			whatSaid="${whatSaid%$'\U000E0000'}"
			while [[ "$whatSaid" == *" " ]]
			do
				whatSaid="${whatSaid% }"
			done
			pm=no
			displayName="$(getTag display-name)"
			[[ -z "$displayName" ]] && displayName="$whoSaid"
			msgId="$(getTag id)"
			badges="$(getTag badges)"
			isBroadcaster=no
			[[ ",${badges}" == *",broadcaster/"* ]] && isBroadcaster=yes
			isMod=no
			[[ "$(getTag mod)" == "1" ]] && isMod=yes
			admins="${adminDir}/${channel#\#}.lst"

			isOwner=no
			[[ -n "$(onList "$owners" "$whoSaid")" ]] && isOwner=yes
			isAdmin=no
			if [[ "$isOwner" == yes || "$isBroadcaster" == yes || "$isMod" == yes || -n "$(onList "$admins" "$whoSaid")" ]]
			then
				isAdmin=yes
			fi
			channellog "<${whoSaid}> ${whatSaid}"

			if [[ "$isOwner" == yes ]]
			then
				source bin/libs/.core
				source bin/owner-modules
			fi
			if [[ "$isAdmin" == yes ]]
			then
				source bin/libs/.admincore
				source bin/admin-modules
			fi
			source bin/anyuser-modules
			;; # end message portion
		*)	;;
	esac
done

botlog 'DISCONNECTED! (connection lost, or nothing heard from Twitch for too long)'
exit 1
