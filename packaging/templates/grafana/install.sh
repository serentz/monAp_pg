#!/usr/bin/env bash
# monAp_pg : point d'entrée de l'installation (appelle scripts/install-grafana.sh).
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/install-grafana.sh" "$@"
