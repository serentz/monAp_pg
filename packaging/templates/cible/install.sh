#!/usr/bin/env bash
# monAp_pg : point d'entrée de l'installation (appelle scripts/install-target.sh).
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/install-target.sh" "$@"
