#!/usr/bin/env bash
# monAp_pg : point d'entrée de l'installation (appelle scripts/install-monitoring.sh).
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/install-monitoring.sh" "$@"
