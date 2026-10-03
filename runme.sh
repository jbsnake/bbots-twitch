#!/usr/bin/env bash
#
#    FILE: runme.sh
#    bbots (Twitch port) - Bash Bot Scripts Configuration and Control Utility
#    AUTHORS: Joshua Bailey and Dave Crouse, 2007. Reworked for Twitch, 2026.
#
#    Copyright (C) 2007 Joshua Bailey and Dave Crouse
#    Licensed under the GNU GPL, version 2 or (at your option) any later version.
#
#    The menu-driven front end. Run it from anywhere:  ./runme.sh
#    The bot it starts runs in the background and keeps running after you
#    leave the menu; its output goes to logs/startbot.out.

cd "$(dirname "$(readlink -f "$0")")" || exit 1

# A fresh copy has no config yet: start one from the example
if [[ ! -e files/config && -r files/config.example ]]
then
	cp files/config.example files/config
	echo "This looks like a fresh copy of bbots, so files/config has been"
	echo "created from files/config.example."
	echo
	echo "Before the bot can start it needs CHANNEL, NICK and CLIENT_ID set"
	echo "(option 4), and a Twitch login (option 12). The ReadMe has the steps."
	echo
	read -r -p "Hit RETURN to continue" temp
fi
if [[ ! -r files/config ]]
then
	echo "files/config is missing. runme.sh must sit in the bbots folder."
	exit 1
fi
mkdir -p logs bin/modules bin/inactivemodules files/lists
source files/config
source bin/libs/.functions

revision_date="Twitch port, October 2026"
author="Created by: Joshua Bailey and Dave Crouse"
runDir="run"
esc=$'\033'
redf="${esc}[31m"
reset="${esc}[0m"

####################################
#            HELPERS               #
####################################

pause ()        { read -r -p "Hit RETURN to continue" temp; }

clearScreen ()  { clear 2> /dev/null || printf '\n\n'; }

# botPid -> prints the pid of a running startbot.sh, or nothing
botPid ()
{
	local p=""
	[[ -s "${runDir}/startbot.pid" ]] && p="$(< "${runDir}/startbot.pid")"
	if [[ "$p" =~ ^[0-9]+$ ]] && grep -qs "startbot" "/proc/${p}/cmdline"
	then
		echo "$p"
	fi
}

# pickEditor -> makes sure EDITOR names a program that exists
pickEditor ()
{
	while ! command -v "${EDITOR%% *}" > /dev/null 2>&1
	do
		echo "It appears that you do not have a text editor set in EDITOR."
		read -r -p "What editor would you like to use? " EDITOR
		echo
	done
}

# reloads files/config so the header shows what is in the file now
readConfig ()   { source files/config; }

headerfile ()
{
	local state channelList
	clearScreen
	echo "    __    __          __
   / /_  / /_  ____  / /______
  / __ \\/ __ \\/ __ \\/ __/ ___/
 / /_/ / /_/ / /_/ / /_(__  )
/_.___/_.___/\\____/\\__/____/

"
	readConfig
	if [[ -n "$(botPid)" ]]
	then
		state="running (pid $(botPid))"
	else
		state="stopped"
	fi
	channelList="$CHANNEL"
	[[ -s files/lists/channels.lst ]] && channelList="$(paste -sd' ' files/lists/channels.lst)"
	echo "------------ Current Bot Configuration ------------"
	echo
	echo "Bot Name: ${redf}${NICK}${reset}  Bot Trigger: ${redf}${trig}${reset}  Bbots Version: ${redf}${version}${reset}"
	echo "Home Channel: ${redf}${CHANNEL}${reset} on ${redf}${SERVER}${reset}"
	echo "Channels: ${redf}${channelList}${reset}"
	echo "Bot is: ${redf}${state}${reset}"
	echo "---------------------------------------------------"
	echo
	echo "-----------------------------------------------------"
	echo "Bash Bot Scripts Configuration and Control Utility"
	echo "-----------------------------------------------------"
	echo
}

####################################
#          MENU ACTIONS            #
####################################

startbot ()
{
	local waited=0
	headerfile
	if [[ -z "$NICK" || "$NICK" == "BBOT" ]]
	then
		echo "It appears that you have not modified your \"config\" file yet."
		echo "You must edit your config file before starting your bot for the first time."
		pause
		return
	fi
	if [[ -n "$(botPid)" ]]
	then
		echo "Bash bot is already running (pid $(botPid))."
		echo
		pause
		return
	fi
	echo "Starting Bash Bot"
	echo
	mkdir -p logs
	# setsid: the bot gets a session of its own, so it outlives this menu
	# and the terminal it was started from
	setsid bin/startbot.sh >> logs/startbot.out 2>&1 < /dev/null &
	while [[ -z "$(botPid)" ]] && (( waited < 30 ))
	do
		sleep 0.1
		waited=$(( waited + 1 ))
	done
	sleep 2
	if [[ -n "$(botPid)" ]]
	then
		echo "Bash bot started (pid $(botPid))"
		echo "Its output goes to logs/startbot.out"
	else
		echo "Bash bot did not stay up. The last lines of logs/startbot.out:"
		echo
		tail -n 8 logs/startbot.out
		echo
		echo "If it says there is no usable token, use the Twitch login option."
	fi
	echo
	pause
}

stopbot ()
{
	local p waited=0
	headerfile
	p="$(botPid)"
	if [[ -z "$p" ]]
	then
		echo "Bash bot is not running."
		echo
		pause
		return
	fi
	echo "Stopping Bash Bot"
	echo
	# startbot.sh cleans up after itself once it and its children are told to stop
	kill -TERM "$p" 2> /dev/null
	pkill -TERM -P "$p" 2> /dev/null
	while [[ -d "/proc/${p}" ]] && (( waited < 50 ))
	do
		sleep 0.1
		waited=$(( waited + 1 ))
	done
	if [[ -d "/proc/${p}" ]]
	then
		pkill -KILL -P "$p" 2> /dev/null
		kill -KILL "$p" 2> /dev/null
		rm -f "${runDir}/startbot.pid"
	fi
	echo "Bash bot stopped"
	echo
	pause
}

helpfile ()
{
	headerfile
	echo "             Configuration Help File"
	echo
	echo "The bot's settings live in files/config. The ones that matter:"
	echo
	echo "CHANNEL ${redf}(The bot's home channel, lowercase, with the #. IE: #bbots)${reset}"
	echo "NICK ${redf}(The Twitch login of the bot's own account, lowercase)${reset}"
	echo "CLIENT_ID ${redf}(From the app you registered at dev.twitch.tv/console)${reset}"
	echo "TOKEN_FILE ${redf}(Where the bot's Twitch token is kept. The Twitch login option fills it in)${reset}"
	echo "GREETING ${redf}(Said when the bot joins a channel. Leave empty to join silently)${reset}"
	echo "trig ${redf}(The command trigger. IE: !)${reset}"
	echo "ascii ${redf}(What the bot puts in front of its replies)${reset}"
	echo "CONSOLE_NAME ${redf}(The name console commands run under. IE: bot-handler)${reset}"
	echo "SERVER, PORT ${redf}(Twitch's chat server. Leave these alone)${reset}"
	echo
	echo "Owners are in files/lists/owners.lst and channels in files/lists/channels.lst."
	echo "Change those with the bot's own commands (owner, join, part), not by hand."
	echo "A changed config takes effect the next time the bot is started."
	echo
	pause
}

botconfig ()
{
	clearScreen
	pickEditor
	$EDITOR files/config
	readConfig
}

listmodules ()
{
	local f names
	headerfile
	echo "ACTIVE MODULES (bin/modules):"
	for f in umod amod omod
	do
		names="$(cd bin/modules 2> /dev/null && ls -- *."$f" 2> /dev/null | paste -sd' ')"
		echo "   .${f}  ${names:-(none)}"
	done
	echo
	echo "INACTIVE MODULES (bin/inactivemodules):"
	for f in umod amod omod
	do
		names="$(cd bin/inactivemodules 2> /dev/null && ls -- *."$f" 2> /dev/null | paste -sd' ')"
		echo "   .${f}  ${names:-(none)}"
	done
	echo
	echo ".umod = anyone, .amod = channel admins, .omod = owners"
	echo "Load and unload them from the console: load <module>, unload <module>"
	echo
	pause
}

viewmodules ()
{
	local choice file
	headerfile
	echo "These files are built from the active modules. They are for reading:"
	echo "anything changed here is overwritten at the next load or unload."
	echo
	echo -e "\t1)\tanyuser-modules\n\t2)\tadmin-modules\n\t3)\towner-modules"
	echo
	read -r -p "Which one? " choice
	case "$choice" in
		1)	file="bin/anyuser-modules" ;;
		2)	file="bin/admin-modules" ;;
		3)	file="bin/owner-modules" ;;
		*)	return ;;
	esac
	if [[ -e "$file" ]]
	then
		less "$file"
	else
		echo "$file has not been built yet. Use Reload All Modules."
		pause
	fi
}

viewbotlog ()
{
	local logremove
	touch logs/botlog
	headerfile
	echo "*************** READING BOT LOG ****************************"
	echo "                HIT Q (for quit) to exit log"
	sleep 2
	less +G logs/botlog
	echo "Your bot log size is $(du -h logs/botlog | cut -f1)"
	read -r -p "Would you like to remove your bot log at this time ? (yes/no): " logremove
	if [[ "$logremove" == "yes" ]]
	then
		: > logs/botlog
		echo "Bot log emptied."
	fi
	pause
}

viewfile ()
{
	clearScreen
	if [[ -r "$1" ]]
	then
		less "$1"
	else
		echo "$1 is not here yet."
		echo
		pause
	fi
}

reloadmodules ()
{
	createANYUSERmodule
	createADMINmodule
	createOWNERmodule
	echo "All modules reloaded !"
	pause
}

console ()
{
	clearScreen
	if [[ -z "$(botPid)" ]]
	then
		echo "Bash bot is not running. Start it first."
		echo
		pause
		return
	fi
	bin/bbots-ctl
}

twitchlogin ()
{
	local choice
	headerfile
	echo -e "\t1)\tCheck the saved Twitch token\n\t2)\tLog the bot account in again\n\t0)\tBack"
	echo
	read -r -p "Please choose one of the options above : " choice
	echo
	case "$choice" in
		1)	bin/gettoken.sh check ;;
		2)	bin/gettoken.sh login ;;
		*)	return ;;
	esac
	echo
	pause
}

####################################
#           MAIN MENU              #
####################################

Main_Menu ()
{
	local option
	local mainmenu="\t1)\tStart Bash Bot\n\t2)\tStop Bash Bot\n\t3)\tBot Configuration Help\n\t4)\tView or Edit Bash Bot \"config\" file\n\t5)\tList Modules\n\t6)\tView the built module files\n\t7)\tView Bash Bot Log\n\t8)\tView Changelog\n\t9)\tView bbots License\n\t10)\tReload All Modules\n\t11)\tBot Console (commands without chat)\n\t12)\tTwitch Login and Token\n\t0)\tExit"
	while true
	do
		headerfile
		echo "        ---------- Main Menu -----------"
		echo
		echo -e "$mainmenu"
		echo
		read -r -p "Please choose one of the options above : " option || option=0
		case "$option" in
			1)	startbot ;;
			2)	stopbot ;;
			3)	helpfile ;;
			4)	botconfig ;;
			5)	listmodules ;;
			6)	viewmodules ;;
			7)	viewbotlog ;;
			8)	viewfile files/changelog ;;
			9)	viewfile files/License ;;
			10)	reloadmodules ;;
			11)	console ;;
			12)	twitchlogin ;;
			0)	clearScreen
				if [[ -n "$(botPid)" ]]
				then
					echo "Leaving the menu. The bot is still running; option 2 stops it."
				fi
				exit 0
				;;
			*)	echo "That choice was invalid!!"
				sleep 1
				;;
		esac
	done
}

Main_Menu
