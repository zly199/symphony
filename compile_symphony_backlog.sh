#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

cd "$SCRIPT_DIR/elixir"
MIX_ENV=prod /opt/homebrew/bin/mise exec -- mix compile

echo "Symphony production code compiled successfully."
