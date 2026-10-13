#!/usr/bin/env bash
# Deploys the proxy as a Cloudflare Worker (free plan, no card needed).
#
# Prerequisites: `npx wrangler login` done; Yandex Rasp key in ~/.config/mcd-garmin/yandex_key.
set -euo pipefail

KEY_FILE=~/.config/mcd-garmin/yandex_key
cd "$(dirname "$0")"

[[ -s $KEY_FILE ]] || { echo "No API key in $KEY_FILE" >&2; exit 1; }

# Station names -> codes; Yandex data, built here and never committed.
YANDEX_API_KEY=$(cat "$KEY_FILE") node scripts/build-stations.mjs

npx wrangler secret put YANDEX_API_KEY < "$KEY_FILE"
npx wrangler deploy
