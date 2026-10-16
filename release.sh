#!/usr/bin/env bash
# Release builds of the watch app, into bin/release/.
#
#   ./release.sh iq                      store package for every device in the manifest
#   ./release.sh prg <device> [options]  one device, to copy onto the watch by USB
#   ./release.sh install <device> [options]
#                                        the same, copied to GARMIN/APPS on a connected watch
#
# Options for prg/install (default values of the settings, baked into the
# build): Garmin Connect cannot edit the settings of an app that was not
# installed from the Connect IQ Store.
#   --home <station> --work <station> --switch <hour> --walk <minutes> --hide-express
#
# Example: ./release.sh install fenix6 --home Одинцово --work Беговая --walk 7
set -euo pipefail
cd "$(dirname "$0")"

SDK=${CIQ_SDK:-$(cat ~/.Garmin/ConnectIQ/current-sdk.cfg 2>/dev/null || true)}
KEY=${CIQ_KEY:-~/.Garmin/ConnectIQ/keys/developer_key.der}
OUT=bin/release
NAME=Elektrichki
DEVICES=$(grep -oP 'product id="\K[^"]+' watch/manifest.xml)

usage() { sed -n '2,15s/^# \{0,1\}//p' "$0"; exit 1; }
die() { echo "$*" >&2; exit 1; }

[[ -x $SDK/bin/monkeyc ]] || die "Connect IQ SDK not found: set CIQ_SDK"
[[ -f $KEY ]] || die "Developer key not found: $KEY"
mkdir -p "$OUT"

# Replaces the default of one property in a copy of properties.xml.
set_default() { # <file> <id> <value>
  ID="$2" VALUE="$3" perl -0pi -e '
    my %xml = ("&" => "&amp;", "<" => "&lt;", ">" => "&gt;");
    (my $v = $ENV{VALUE}) =~ s/([&<>])/$xml{$1}/g;
    s{(<property id="\Q$ENV{ID}\E"[^>]*>)[^<]*(</property>)}{$1$v$2} or die "no property $ENV{ID}\n"' "$1"
}

build_iq() {
  local iq=$OUT/$NAME.iq
  "$SDK/bin/monkeyc" -e -r -f watch/monkey.jungle -o "$iq" -y "$KEY" -l 3 2>&1 | grep -v 'WARNING\|DEVICES BUILT' || true
  [[ -s $iq ]] || die "Export failed"
  echo "Store package: $iq"
  echo "Upload it at https://apps.garmin.com/developer/upload (see store/README.md)."
}

build_prg() { # <device> [options]
  local device=$1; shift
  grep -qx "$device" <<<"$DEVICES" || die "Unknown device '$device'. One of: ${DEVICES//$'\n'/ }"
  local src; src=$(mktemp -d)
  trap 'rm -rf "$src"' RETURN
  cp -r watch/. "$src"
  local props=$src/resources/settings/properties.xml
  while (($#)); do
    case $1 in
      --home) set_default "$props" HomeStation "$2"; shift 2 ;;
      --work) set_default "$props" WorkStation "$2"; shift 2 ;;
      --switch) set_default "$props" SwitchHour "$2"; shift 2 ;;
      --walk) set_default "$props" WalkMinutes "$2"; shift 2 ;;
      --hide-express) set_default "$props" HideExpress true; shift ;;
      *) usage ;;
    esac
  done
  PRG=$OUT/$NAME-$device.prg
  "$SDK/bin/monkeyc" -r -f "$src/monkey.jungle" -d "$device" -o "$PRG" -y "$KEY" -l 3 2>&1 | grep -v WARNING || true
  [[ -s $PRG ]] || die "Build failed"
  echo "Built $PRG"
}

# GARMIN/APPS of a watch mounted as a USB drive (fenix 6) or over MTP (gvfs).
find_apps_dir() {
  local d
  for d in /run/media/"$USER"/*/GARMIN/APPS /media/"$USER"/*/GARMIN/APPS \
           /run/user/"$(id -u)"/gvfs/mtp*/*/GARMIN/APPS /run/user/"$(id -u)"/gvfs/mtp*/GARMIN/APPS; do
    [[ -d $d ]] && { printf '%s\n' "$d"; return; }
  done
  return 1
}

case ${1:-} in
  iq) build_iq ;;
  prg) [[ -n ${2:-} ]] || usage; build_prg "${@:2}" ;;
  install)
    [[ -n ${2:-} ]] || usage
    build_prg "${@:2}"
    apps=$(find_apps_dir) || die "No watch found. Connect it by USB and unlock it; for MTP watches open it once in the file manager (or: gio mount -li). Then copy $PRG to GARMIN/APPS yourself or run this again."
    cp "$PRG" "$apps/$NAME.prg"
    sync
    echo "Copied to $apps/$NAME.prg. Disconnect the watch: the widget appears in the widget loop."
    ;;
  *) usage ;;
esac
