#!/usr/bin/env bash
# ============================================================
# monAp_pg : installation de VM-Monitoring (repository + Grafana)
#
#   sudo ./scripts/install-monitoring.sh              installation complète
#   sudo ./scripts/install-monitoring.sh --sql-only   applique seulement les scripts SQL
#                                                     (mise à jour du schéma, sans toucher au reste)
#
# Prérequis : Ubuntu installé, accès réseau (apt), scripts/asemon.env renseigné.
# La création de la VM et l'installation d'Ubuntu ne sont PAS couvertes.
# Le script est rejouable : chaque étape vérifie l'état avant d'agir.
# ============================================================
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SQL_ONLY=0
[ "${1:-}" = "--sql-only" ] && SQL_ONLY=1

need_root
load_env
require_vars COLLECTOR_PASSWORD GRAFANA_RO_PASSWORD
check_password COLLECTOR_PASSWORD
check_password GRAFANA_RO_PASSWORD
[ -n "${GRAFANA_THRESHOLDS_PASSWORD:-}" ] && check_password GRAFANA_THRESHOLDS_PASSWORD

# Ordre d'application. 07 est un brouillon et n'est jamais appliqué.
SQL_FILES=(01-schema-asemon 02-roles-and-grants 04-schema-extension 05-schema-sessions
           06-rollup-horaire 08-schema-samples 09-retention 10-plans-query-id 11-schema-kcache 12-plans-lisibles 13-capacity
           14-multi-instance 15-instance-id-cutover 16-internal-users 17-thresholds)

apply_schema() {
    log "Schéma du repository"
    if [ "$(psql_value postgres "SELECT 1 FROM pg_database WHERE datname = 'monitoring'")" != "1" ]; then
        $PSQL_CMD -d postgres -c "CREATE DATABASE monitoring"
        log "base monitoring créée"
    fi
    local f
    for f in "${SQL_FILES[@]}"; do
        psql_file monitoring "$REPO_DIR/sql/$f.sql"
    done
    # Les mots de passe sont fixés ici (les scripts SQL ne gardent que des valeurs d'exemple).
    set_role_password collector_writer COLLECTOR_PASSWORD
    set_role_password grafana_ro GRAFANA_RO_PASSWORD
    if [ -n "${GRAFANA_THRESHOLDS_PASSWORD:-}" ]; then
        open_role_login grafana_thresholds GRAFANA_THRESHOLDS_PASSWORD
    else
        warn "GRAFANA_THRESHOLDS_PASSWORD vide : le rôle grafana_thresholds reste sans connexion (seuils en lecture seule dans Grafana)"
    fi
    # Deuxième passe des droits : couvre les tables créées par les scripts suivants.
    psql_file monitoring "$REPO_DIR/sql/02-roles-and-grants.sql"
    psql_value monitoring "SELECT asemon.maintain_samples()" >/dev/null
    ok "schéma appliqué ($(psql_value monitoring "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'asemon'") tables et vues)"
}

if [ "$SQL_ONLY" -eq 1 ]; then
    apply_schema
    exit 0
fi

# --- 1. PostgreSQL -------------------------------------------------------------------
install_postgres
ensure_conf_d
check_auto_conf listen_addresses

# --- 2. Réseau : écoute et accès du collecteur et de Grafana ---------------------------
CHANGED=0
tmp="$(mktemp)"
cat > "$tmp" <<CONF
# Géré par monAp_pg (scripts/install-monitoring.sh) : ne pas modifier à la main.
listen_addresses = '*'
CONF
write_pg_conf "$tmp"; rm -f "$tmp"
set_hba_block monitoring \
    "host    monitoring      collector_writer   $SUBNET   scram-sha-256" \
    "host    monitoring      grafana_ro         $SUBNET   scram-sha-256"
if [ "$CHANGED" -eq 1 ]; then restart_postgres; else ok "configuration réseau inchangée"; fi

if [ -n "$POSTGRES_PASSWORD" ]; then
    check_password POSTGRES_PASSWORD
    set_role_password postgres POSTGRES_PASSWORD
fi

# --- 3. Schéma ---------------------------------------------------------------------
apply_schema

# --- 4. Timers : rollup, maintenance des partitions, rétention ---------------------------
# retention.py (Release 3) est le point d'entrée unique de la rétention : il remplace
# l'ancien asemon-purge.timer. Il a besoin de Python et de psycopg sur VM-Monitoring.
log "Environnement Python de la rétention ($INSTALL_DIR)"
apt_install python3 python3-venv python3-pip
mkdir -p "$INSTALL_DIR/app"
if [ ! -x "$INSTALL_DIR/venv/bin/python3" ]; then
    python3 -m venv "$INSTALL_DIR/venv"
fi
pip_install_manifest "$INSTALL_DIR/venv" -- "psycopg[binary]"
install -m 0644 -o root -g root "$REPO_DIR/python/retention.py" "$INSTALL_DIR/app/retention.py"
ok "retention.py installé"

log "Timers systemd"
install_units asemon-rollup.service asemon-rollup.timer \
              asemon-samples-maintenance.service asemon-samples-maintenance.timer
sed -e "s|/opt/asemon|$INSTALL_DIR|g" "$REPO_DIR/systemd/asemon-retention.service" > /etc/systemd/system/asemon-retention.service
install_file "$REPO_DIR/systemd/asemon-retention.timer" /etc/systemd/system/asemon-retention.timer 0644
if [ -f /etc/systemd/system/asemon-purge.timer ]; then
    log "Remplacement de l'ancien asemon-purge.timer par asemon-retention.timer"
    systemctl disable --now asemon-purge.timer >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/asemon-purge.timer /etc/systemd/system/asemon-purge.service
fi
systemctl daemon-reload
systemctl enable --now asemon-rollup.timer asemon-samples-maintenance.timer asemon-retention.timer >/dev/null
ok "timers actifs"

# --- 5. Grafana --------------------------------------------------------------------
# Installé par scripts/install-grafana.sh, présent dans le dépôt Git (tout sur une VM) et dans le
# paquet monAp_pg_grafana. Le paquet monAp_pg_instance_monitoring ne l'embarque pas : Grafana s'installe
# alors avec son propre paquet, sur cette VM ou sur une autre.
if [ -x "$SCRIPT_DIR/install-grafana.sh" ]; then
    "$SCRIPT_DIR/install-grafana.sh"
else
    log "Grafana non installé ici (paquet monAp_pg_grafana : ./install.sh sur la VM de Grafana)."
fi

log "Terminé. Vérification : sudo ./scripts/verify.sh monitoring"
