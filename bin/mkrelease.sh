#!/usr/bin/env bash
#
#    FILE: mkrelease.sh
#    bbots (Twitch port) - builds a clean copy of bbots for publishing
#
#    Copyright (C) 2007 Joshua Bailey and Dave Crouse
#    Licensed under the GNU GPL, version 2 or (at your option) any later version.
#
#    Usage:
#      bin/mkrelease.sh [--update] [--with-sniglets] [output folder]
#
#    The first time, it makes, in the output folder (default: ~/bbots-release):
#      bbots/                 a clean tree, ready for "git init"
#      bbots-<version>.tgz    the same tree as a tarball
#
#    --update is for every time after that. It refreshes an existing bbots/
#    that is already a git repository: the published files are replaced with
#    the ones from this working copy, modules that no longer exist are
#    removed, and .git, LICENSE and anything else you added at the top of
#    the repository are left alone. Then it shows what changed, ready for
#    you to commit and push.
#
#    Left OUT, because they belong to this install and not to the project:
#      files/.token, files/.refresh, files/config    (secrets and settings)
#      files/lists/owners.lst, channels.lst, admins/ (who and where)
#      files/pig2/                                   (games and win records)
#      logs/, run/, the built module files
#    Left out unless you pass --with-sniglets:
#      files/lists/sniglets.lst. Only publish a list you have the right to.
#
#    Every module is shipped inactive, as the 2007 release did.
#    Nothing in your working copy is changed.

cd "$(dirname "$(readlink -f "$0")")/.." || exit 1
source files/config

withSniglets=no
update=no
while [[ "$1" == --* ]]
do
	case "$1" in
		--with-sniglets)	withSniglets=yes ;;
		--update)		update=yes ;;
		*)	echo "mkrelease: unknown option $1" >&2
			echo "Usage: bin/mkrelease.sh [--update] [--with-sniglets] [output folder]" >&2
			exit 1
			;;
	esac
	shift
done
out="${1:-$HOME/bbots-release}"
target="${out}/bbots"

# BETA 3.0 (twitch) -> beta_3_0
tag="${version%% (*}"
tag="${tag,,}"
tag="${tag//[ .]/_}"
[[ "$tag" =~ ^[a-z0-9_]{1,30}$ ]] || tag="release"
tarball="${out}/bbots-${tag}.tgz"

if [[ "$update" == yes ]]
then
	if [[ ! -d "${target}/.git" || ! -e "${target}/runme.sh" ]]
	then
		echo "mkrelease: ${target} is not a bbots git repository, so there is" >&2
		echo "           nothing to update. Run without --update to make it first." >&2
		exit 1
	fi
elif [[ -e "$target" ]]
then
	echo "mkrelease: ${target} already exists."
	echo "           To refresh it from this working copy:  bin/mkrelease.sh --update"
	echo "           To build somewhere else:               bin/mkrelease.sh /some/other/folder"
	exit 1
fi

# The clean tree is always built in a scratch folder first, and only put
# in place once it has passed the check for secrets.
scratch="$(mktemp -d)" || exit 1
stage="${scratch}/bbots"

# fail message -> removes the half-built tree and stops
fail ()
{
	echo "mkrelease: $1" >&2
	rm -rf "$scratch"
	exit 1
}

mkdir -p "${stage}/bin/libs" "${stage}/bin/modules" "${stage}/bin/inactivemodules" \
	"${stage}/files/lists" "${stage}/logs" || fail "could not create ${stage}"

cp runme.sh ReadMe "${stage}/" || fail "runme.sh or ReadMe is missing"
cp bin/startbot.sh bin/bashbot.sh bin/bbots-ctl bin/gettoken.sh bin/mkrelease.sh "${stage}/bin/" || fail "a script is missing from bin/"
cp bin/libs/.functions bin/libs/.core bin/libs/.admincore "${stage}/bin/libs/" || fail "a library is missing from bin/libs/"
cp files/License files/changelog "${stage}/files/" || fail "files/License or files/changelog is missing"

# every module, active or not here, ships inactive
for module in bin/modules/*.?mod bin/inactivemodules/*.?mod
do
	[[ -e "$module" ]] && cp "$module" "${stage}/bin/inactivemodules/"
done

[[ -e files/lists/smack.lst ]] && cp files/lists/smack.lst "${stage}/files/lists/"
if [[ "$withSniglets" == yes && -e files/lists/sniglets.lst ]]
then
	cp files/lists/sniglets.lst "${stage}/files/lists/"
else
	cat > "${stage}/files/lists/sniglets.lst.example" << 'EOF'
1|Yourword (yor' werd) - n. One entry per line: a number, a bar, then the text.
2|Anotherword (uh nuth' er werd) - n. Save your own list as sniglets.lst in this folder.
EOF
fi

# git does not keep empty folders, and the bot needs these two
: > "${stage}/bin/modules/.gitkeep"
: > "${stage}/logs/.gitkeep"

cat > "${stage}/files/config.example" << 'EOF'
####################################
#         SET VARIABLES            #
####################################
# Copy this file to files/config and fill it in. runme.sh does the copy
# for you the first time it runs.

SERVER="irc.chat.twitch.tv"   # Twitch chat server
PORT="6697"                   # TLS port
version="@VERSION@"
CHANNEL="#yourchannel"        # the bot's home channel: lowercase, with the #
NICK=""                       # the bot account's Twitch login, lowercase
TOKEN_FILE="files/.token"     # holds the OAuth token, kept out of this file
CLIENT_ID=""                  # from your app at https://dev.twitch.tv/console
GREETING=""                   # said on joining; leave empty to join silently
trig="!"                      # command trigger
ascii="(>'-')> "              # prefix on the bot's replies
CONSOLE_NAME="bot-handler"   # the name bbots-ctl commands run under

####################################
#     END OF VARIABLES             #
####################################
EOF

# the example config carries whatever version this working copy is at
exampleText="$(< "${stage}/files/config.example")"
printf '%s\n' "${exampleText//@VERSION@/"$version"}" > "${stage}/files/config.example"

{
	cat << 'EOF'
# secrets and settings: never publish these
files/.token
files/.token.new
files/.refresh
files/.refresh.new
files/config

# made while the bot runs
logs/*
!logs/.gitkeep
run/
bin/anyuser-modules
bin/admin-modules
bin/owner-modules
bin/*-modules.*

# belongs to one install: who owns the bot, where it sits, its games
files/lists/owners.lst
files/lists/channels.lst
files/lists/admins/
files/pig2/
EOF
	if [[ "$withSniglets" != yes ]]
	then
		echo
		echo "# supply your own; see sniglets.lst.example"
		echo "files/lists/sniglets.lst"
	fi
} > "${stage}/.gitignore"

# last line of defence: nothing secret may be in the clean tree
leak=no
for secretFile in files/.token files/.refresh
do
	if [[ -s "$secretFile" ]]
	then
		secret="$(< "$secretFile")"
		secret="${secret#oauth:}"
		if [[ -n "$secret" ]] && grep -rqF -- "$secret" "$stage"
		then
			leak=yes
		fi
	fi
done
if [[ -n "$CLIENT_ID" ]] && grep -rqF -- "$CLIENT_ID" "$stage"
then
	leak=yes
fi
if [[ "$leak" == yes ]]
then
	echo "mkrelease: STOPPED. A token or your Client ID is in one of the files" >&2
	echo "           being published (ReadMe, runme.sh, a script or a module)." >&2
	fail "nothing was packed"
fi

mkdir -p "$out" || fail "could not create ${out}"
tar -czf "$tarball" -C "$scratch" bbots || fail "could not write ${tarball}"

fileCount="$(find "$stage" -type f | wc -l)"
moduleCount="$(find "${stage}/bin/inactivemodules" -name '*.?mod' | wc -l)"

if [[ "$update" == yes ]]
then
	# bin, files and logs are replaced whole, so a module that was deleted
	# here disappears there too. Everything else at the top of the
	# repository (.git, LICENSE, anything you added) is not touched.
	rm -rf "${target}/bin" "${target}/files" "${target}/logs"
	cp -a "${stage}/." "${target}/" || fail "could not copy into ${target}"
	rm -rf "$scratch"
	echo "Updated:     ${target}"
	echo "Tarball:     ${tarball}"
	echo
	echo "${fileCount} files, ${moduleCount} modules, all shipped inactive."
	echo
	if command -v git > /dev/null
	then
		changes="$(git -C "$target" status --short)"
		if [[ -z "$changes" ]]
		then
			echo "Nothing changed: the repository already matches this working copy."
		else
			echo "What changed (M = modified, D = deleted, ?? = new):"
			echo "$changes"
			echo
			echo "To publish it:"
			echo "  cd ${target}"
			echo "  git add -A"
			echo "  git commit -m \"describe the change\""
			echo "  git push"
		fi
	fi
else
	mv "$stage" "$target" || fail "could not move the clean tree to ${target}"
	rm -rf "$scratch"
	echo "Clean tree:  ${target}"
	echo "Tarball:     ${tarball}"
	echo
	echo "${fileCount} files, ${moduleCount} modules, all shipped inactive."
fi
if [[ "$withSniglets" != yes ]]
then
	echo "sniglets.lst was left out; an example of the format is included."
fi
