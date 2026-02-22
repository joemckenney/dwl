#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_H="$SCRIPT_DIR/config.h"

# --- Parse config.h for tag arrays and monitor rules ---

# Extract tag array definitions: name -> space-separated tag names
declare -A TAG_ARRAYS
while IFS= read -r line; do
    if [[ $line =~ ^static[[:space:]]+const[[:space:]]+char[[:space:]]+\*(tags_[a-zA-Z_]+)\[\][[:space:]]*= ]]; then
        arr_name="${BASH_REMATCH[1]}"
        tags=()
        # Extract all quoted strings from the initializer
        rest="$line"
        while [[ $rest =~ \"([^\"]+)\" ]]; do
            tags+=("${BASH_REMATCH[1]}")
            rest="${rest#*\"${BASH_REMATCH[1]}\"}"
        done
        if ((${#tags[@]} > 0)); then
            TAG_ARRAYS[$arr_name]="${tags[*]}"
        fi
    fi
done < "$CONFIG_H"

# Extract monitor rules: description -> tag array name, and the default
declare -A MON_TAGS
DEFAULT_TAGS=""
in_monrules=0
while IFS= read -r line; do
    if [[ $line =~ ^static[[:space:]]+const[[:space:]]+MonitorRule[[:space:]]+monrules ]]; then
        in_monrules=1
        continue
    fi
    if ((in_monrules)); then
        [[ $line =~ ^\}\; ]] && break
        # Rule with a description: { "SERIAL", ...  tags_name, ... }
        if [[ $line =~ \{[[:space:]]*\"([^\"]+)\".*[,[:space:]](tags_[a-zA-Z_]+) ]]; then
            MON_TAGS["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
        # Default rule: { NULL, NULL, ... tags_name, ... }
        elif [[ $line =~ \{[[:space:]]*NULL.*[,[:space:]](tags_[a-zA-Z_]+) ]]; then
            DEFAULT_TAGS="${BASH_REMATCH[1]}"
        fi
    fi
done < "$CONFIG_H"

# --- Determine current monitor's tags at runtime ---

selmon=$(dwlmsg -g -o | awk '/selmon 1/{print $1}')
serial=$(wlr-randr | awk -v mon="$selmon" '$1 == mon {found=1; next} found && /Serial:/{print $2; exit}')

tag_arr_name=""
if [[ -n "$serial" && -n "${MON_TAGS[$serial]:-}" ]]; then
    tag_arr_name="${MON_TAGS[$serial]}"
elif [[ -n "$DEFAULT_TAGS" ]]; then
    tag_arr_name="$DEFAULT_TAGS"
else
    echo "error: could not determine tags for monitor $selmon" >&2
    exit 1
fi

IFS=' ' read -ra tag_names <<< "${TAG_ARRAYS[$tag_arr_name]}"
ntags=${#tag_names[@]}
all_mask=$(( (1 << ntags) - 1 ))

# --- Generate Tags and Move-to-Tag YAML ---

tags_yaml=""
for ((i=0; i<ntags; i++)); do
    key=$((i+1))
    tags_yaml+="      - key: \"$key\"
        desc: \"${tag_names[$i]}\"
        cmd: dwlmsg -s -t $i
"
done
tags_yaml+="      - key: \"0\"
        desc: All tags
        cmd: dwlmsg -s -t $all_mask
      - key: Tab
        desc: Previous tag
        cmd: wtype -M alt -k Tab -m alt"

move_yaml=""
for ((i=0; i<ntags; i++)); do
    key=$((i+1))
    mask=$((1 << i))
    move_yaml+="      - key: \"$key\"
        desc: \"${tag_names[$i]}\"
        cmd: dwlmsg -s -c 0 $mask"
    if ((i < ntags - 1)); then
        move_yaml+=$'\n'
    fi
done

# --- Write full config and launch ---

tmpconfig=$(mktemp /tmp/wlr-which-key-XXXXXX.yaml)
trap 'rm -f "$tmpconfig"' EXIT

cat > "$tmpconfig" << EOF
font: Fira Code SemiBold 12
background: "#222222"
color: "#bbbbbb"
border: "#444444"
border_width: 10
padding: 10
corner_r: 0
separator: " → "
anchor: center

menu:
  - key: w
    desc: Windows
    submenu:
      - key: j
        desc: Focus next
        cmd: wtype -M alt -k j -m alt
      - key: k
        desc: Focus prev
        cmd: wtype -M alt -k k -m alt
      - key: Return
        desc: Zoom master
        cmd: wtype -M alt -k Return -m alt
      - key: c
        desc: Kill client
        cmd: wtype -M alt -M shift -k c -m shift -m alt
      - key: space
        desc: Toggle float
        cmd: wtype -M alt -M shift -k space -m shift -m alt
      - key: e
        desc: Toggle fullscreen
        cmd: wtype -M alt -k e -m alt
      - key: i
        desc: Inc master count
        cmd: wtype -M alt -k i -m alt
      - key: d
        desc: Dec master count
        cmd: wtype -M alt -k d -m alt
      - key: h
        desc: Shrink master
        cmd: wtype -M alt -k h -m alt
      - key: l
        desc: Grow master
        cmd: wtype -M alt -k l -m alt

  - key: l
    desc: Layouts
    submenu:
      - key: t
        desc: "[]=  Tile"
        cmd: dwlmsg -s -l 0
      - key: f
        desc: "><>  Float"
        cmd: dwlmsg -s -l 1
      - key: m
        desc: "[M]  Monocle"
        cmd: dwlmsg -s -l 2
      - key: u
        desc: "TTT  Bstack"
        cmd: dwlmsg -s -l 3
      - key: o
        desc: "===  Bstack horiz"
        cmd: dwlmsg -s -l 4

  - key: t
    desc: Tags
    submenu:
$tags_yaml

  - key: m
    desc: Move to Tag
    submenu:
$move_yaml

  - key: o
    desc: Monitors
    submenu:
      - key: h
        desc: Focus left
        cmd: wtype -M alt -k comma -m alt
      - key: l
        desc: Focus right
        cmd: wtype -M alt -k period -m alt
      - key: H
        desc: Move to left
        cmd: wtype -M alt -M shift -k comma -m shift -m alt
      - key: L
        desc: Move to right
        cmd: wtype -M alt -M shift -k period -m shift -m alt

  - key: a
    desc: Apps
    submenu:
      - key: Return
        desc: Terminal (foot)
        cmd: foot
      - key: p
        desc: Launcher (fuzzel)
        cmd: fuzzel

  - key: s
    desc: Session
    submenu:
      - key: q
        desc: Quit dwl
        cmd: wtype -M alt -M shift -k q -m shift -m alt
      - key: b
        desc: Toggle bar
        cmd: wtype -M alt -k b -m alt
      - key: g
        desc: Toggle gaps
        cmd: wtype -M alt -k g -m alt
EOF

exec wlr-which-key "$tmpconfig"
