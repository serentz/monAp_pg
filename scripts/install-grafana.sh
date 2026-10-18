#!/usr/bin/env bash
# ============================================================
# monAp_pg : installation de Grafana, de ses plugins, de la source de données et des dashboards
#
#   sudo ./scripts/install-grafana.sh
#
# Appelé par install-monitoring.sh (dépôt Git : tout sur VM-Monitoring) ; fait partie du paquet
# monAp_pg_grafana (Grafana sur VM-Monitoring ou sur une autre machine).
# Prérequis : le repository (VM-Monitoring) doit exister et accepter le rôle grafana_ro depuis cette
# machine (SUBNET de install-monitoring.sh). Si Grafana n'est pas sur VM-Monitoring, renseigner
# GRAFANA_DB_HOST (IP de VM-Monitoring) dans asemon.env.
# Rejouable : l'import des dashboards remplace les versions existantes (même uid).
# ============================================================
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need_root
load_env

PLUGINS_FILE="$REPO_DIR/grafana/plugins.txt"

if ! command -v grafana-server >/dev/null 2>&1; then
    log "Installation de Grafana"
    apt_install apt-transport-https software-properties-common wget gnupg curl python3
    mkdir -p /etc/apt/keyrings
    wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor -o /etc/apt/keyrings/grafana.gpg --yes
    echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list
    _APT_UPDATED=""
    apt_install grafana
fi

# Plugins : « identifiant [version] » par ligne de grafana/plugins.txt.
install_plugin() {
    local id="$1" ver="${2:-}"
    [ -d "/var/lib/grafana/plugins/$id" ] && { ok "plugin $id déjà présent"; return; }
    log "Installation du plugin Grafana $id ${ver}"
    # shellcheck disable=SC2086
    if grafana cli plugins install "$id" $ver >/dev/null 2>&1; then
        chown -R grafana:grafana /var/lib/grafana/plugins 2>/dev/null || true
        PLUGINS_CHANGED=1
        ok "plugin $id installé"
    else
        warn "Plugin $id non installé (accès à grafana.com ?). Plus tard : grafana cli plugins install $id puis systemctl restart grafana-server."
    fi
}
PLUGINS_CHANGED=0
if [ -f "$PLUGINS_FILE" ]; then
    while read -r id ver _; do
        case "$id" in ''|'#'*) continue ;; esac
        install_plugin "$id" "$ver"
    done < "$PLUGINS_FILE"
else
    warn "$PLUGINS_FILE absent : plugins non installés."
fi

systemctl enable grafana-server >/dev/null 2>&1
if [ "$PLUGINS_CHANGED" -eq 1 ]; then systemctl restart grafana-server; else systemctl start grafana-server; fi
ok "Grafana installé et démarré (port 3000)"

if [ -z "$GRAFANA_ADMIN_PASSWORD" ]; then
    warn "GRAFANA_ADMIN_PASSWORD vide : source de données et dashboards non configurés."
    warn "Renseigner le mot de passe dans scripts/asemon.env puis relancer, ou configurer à la main (docs/01-VM-Monitoring-repository-grafana.md §5)."
else
    check_password GRAFANA_ADMIN_PASSWORD
    "$SCRIPT_DIR/grafana-provision.sh"
fi

log "Terminé. Vérification : sudo ./scripts/verify.sh grafana"
