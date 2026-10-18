# monAp_pg : paquet « instance monitoring » ({{VERSION}})

Installe sur **VM-Monitoring** le repository de supervision : un PostgreSQL avec la base `monitoring` (schéma `asemon`), ses rôles, et les tâches planifiées qui l'entretiennent.

| Composant | Rôle | Fréquence |
|---|---|---|
| base `monitoring`, schéma `asemon` | stocke les mesures des instances surveillées | — |
| rollup (`asemon.rollup_hourly`, `asemon.compute_kpi_values`) | résumé horaire et valeurs des seuils | toutes les 5 min |
| maintenance (`asemon.maintain_samples`) | création et purge des partitions `snap_samples` | toutes les heures |
| `retention.py` | purge des données anciennes, réduction des points de capacity planning | une fois par jour |

Grafana n'est **pas** dans ce paquet : voir `monAp_pg_grafana` (sur cette machine ou une autre). À installer **en premier**, avant `monAp_pg_instance_cible`.

## Contenu

| Fichier | Rôle |
|---|---|
| `install.sh` | installation complète (rejouable) ; `./install.sh --sql-only` applique seulement le SQL |
| `verify.sh` | contrôles après installation |
| `manifeste.txt` | paquets Python du venv (`psycopg[binary]`, pour `retention.py`) |
| `python/retention.py` | rétention quotidienne |
| `sql/` | scripts SQL numérotés, appliqués dans l'ordre (`01` à `17`, sans le brouillon `07`) |
| `systemd/` | services et timers rollup, maintenance, rétention |
| `cron/asemon-monitoring.cron` | équivalent cron des timers (option) |
| `scripts/` | scripts appelés par `install.sh` et `asemon.env.example` |
| `SHA256SUMS`, `VERSION` | contrôle d'intégrité, version |

## 1. Prérequis

- Ubuntu Server 24.04 ou plus récent, accès Internet (`apt`, PyPI, dépôt PostgreSQL PGDG), `sudo`.
- IP stable (réservation DHCP ou IP fixe) : les instances surveillées s'y connectent.
- RAM fixe sous Hyper-V (pas de mémoire dynamique).

## 2. Installation

```bash
tar xzf monAp_pg_instance_monitoring.tgz
cd monAp_pg_instance_monitoring
sha256sum -c SHA256SUMS --quiet && echo "paquet intact"

cp scripts/asemon.env.example scripts/asemon.env
nano scripts/asemon.env          # voir « Paramètres » ci-dessous

sudo ./install.sh
```

### Paramètres (`scripts/asemon.env`)

| Variable | À renseigner |
|---|---|
| `COLLECTOR_PASSWORD` | mot de passe de `collector_writer` (à reprendre dans le paquet cible) |
| `GRAFANA_RO_PASSWORD` | mot de passe de `grafana_ro` (à reprendre dans le paquet Grafana) |
| `GRAFANA_THRESHOLDS_PASSWORD` | mot de passe de `grafana_thresholds` ; vide = page des seuils en lecture seule |
| `SUBNET` | réseau autorisé à joindre le repository (collecteurs et Grafana), ex. `192.168.1.0/24` |
| `POSTGRES_PASSWORD` | facultatif : mot de passe du superutilisateur `postgres` |
| `PG_VERSION`, `INSTALL_DIR` | facultatifs |

Mots de passe : 8 caractères minimum, lettres, chiffres et `. _ @ % + = -` seulement. `install.sh` fixe lui-même ces mots de passe dans PostgreSQL : les valeurs `CHANGEME_*` des fichiers SQL ne sont jamais utilisées telles quelles.

## 3. Ce que fait `install.sh`, et son équivalent à la main

**Composants**

```bash
sudo apt install -y postgresql-17 python3 python3-venv python3-pip
# (dépôt apt PGDG à ajouter avant si besoin : https://www.postgresql.org/download/linux/ubuntu/)
```

**Réseau PostgreSQL** : `listen_addresses = '*'` dans `conf.d/asemon.conf`, et dans `pg_hba.conf` :

```
host    monitoring      collector_writer   <SUBNET>   scram-sha-256
host    monitoring      grafana_ro         <SUBNET>   scram-sha-256
```

puis `sudo systemctl restart postgresql@17-main`.

**SQL** : base `monitoring`, puis les scripts de `sql/` **dans l'ordre**, deux fois `02-roles-and-grants.sql` (la seconde passe couvre les tables créées après la première) :

```bash
sudo -u postgres psql -c "CREATE DATABASE monitoring"
for f in sql/*.sql; do sudo -u postgres psql -X -v ON_ERROR_STOP=1 -d monitoring < "$f"; done
sudo -u postgres psql -c "ALTER USER collector_writer WITH PASSWORD '<mdp>';"
sudo -u postgres psql -c "ALTER USER grafana_ro WITH PASSWORD '<mdp>';"
sudo -u postgres psql -c "ALTER USER grafana_thresholds LOGIN PASSWORD '<mdp>';"      # facultatif
sudo -u postgres psql -X -d monitoring < sql/02-roles-and-grants.sql
sudo -u postgres psql -d monitoring -c "SELECT asemon.maintain_samples();"
```

(Les fichiers `sql/` sont numérotés : l'ordre alphabétique est l'ordre d'application.)

**Venv Python** (pour `retention.py`)

```bash
sudo mkdir -p /opt/asemon/app
sudo python3 -m venv /opt/asemon/venv
sudo /opt/asemon/venv/bin/pip install -r manifeste.txt
sudo install -m 0644 python/retention.py /opt/asemon/app/
```

## 4. Planification (systemd, ou cron)

`install.sh` installe et active trois **timers systemd** :

```bash
sudo cp systemd/asemon-rollup.* systemd/asemon-samples-maintenance.* systemd/asemon-retention.* /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now asemon-rollup.timer asemon-samples-maintenance.timer asemon-retention.timer
systemctl list-timers 'asemon-*'                 # prochaines exécutions
journalctl -u asemon-rollup -n 5 --no-pager      # dernière exécution
```

**Équivalent cron** (si vous préférez, à la place des timers, jamais en plus) : le fichier `cron/asemon-monitoring.cron` contient les trois lignes prêtes à l'emploi.

```bash
sudo systemctl disable --now asemon-rollup.timer asemon-samples-maintenance.timer asemon-retention.timer
sudo cp cron/asemon-monitoring.cron /etc/cron.d/asemon-monitoring
```

Les trois lignes, pour mémoire :

```cron
*/5 * * * * postgres psql -X -q -At -v ON_ERROR_STOP=1 -d monitoring -c "SELECT asemon.rollup_hourly();" -c "SELECT asemon.compute_kpi_values();" 2>&1 | logger -t asemon-rollup
7 * * * *   postgres psql -X -q -At -v ON_ERROR_STOP=1 -d monitoring -c "SELECT asemon.maintain_samples();" 2>&1 | logger -t asemon-samples-maintenance
17 3 * * *  postgres /opt/asemon/venv/bin/python3 /opt/asemon/app/retention.py 2>&1 | logger -t asemon-retention
```

## 5. Vérification

```bash
sudo ./verify.sh          # tous les contrôles doivent être verts
```

Les compteurs de lignes affichés en fin de contrôle restent à 0 tant qu'aucune instance cible n'envoie de données (paquet `monAp_pg_instance_cible`).

## 6. Mise à jour et désinstallation

- **Mise à jour du schéma ou du code** : extraire le nouveau paquet, recopier `scripts/asemon.env`, relancer `sudo ./install.sh` (ou `sudo ./install.sh --sql-only` pour le SQL seul). Tous les scripts SQL sont rejouables.
- **Désinstallation** (⚠ détruit les mesures) :

```bash
sudo systemctl disable --now asemon-rollup.timer asemon-samples-maintenance.timer asemon-retention.timer
sudo rm /etc/systemd/system/asemon-{rollup,samples-maintenance,retention}.{service,timer} && sudo systemctl daemon-reload
sudo rm -r /opt/asemon
sudo -u postgres psql -c "DROP DATABASE monitoring;"          # perte définitive des données
```

## 7. Dépannage

| Symptôme | Piste |
|---|---|
| Une instance cible n'arrive pas à se connecter | `SUBNET` trop étroit, pare-feu, IP de VM-Monitoring ; `sudo -u postgres psql -c "SHOW listen_addresses"` doit donner `*` |
| `verify.sh` : `retention.py --dry-run` en échec | venv absent ou `psycopg` non installé : relancer `install.sh` |
| Mot de passe d'un rôle à changer | modifier `asemon.env`, relancer `install.sh`, puis relancer `install.sh` du paquet cible avec `FORCE_CONFIG=1` |
