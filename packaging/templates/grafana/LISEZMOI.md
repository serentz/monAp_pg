# monAp_pg : paquet « grafana » ({{VERSION}})

Installe Grafana, ses deux plugins, la source de données vers le repository et les **dashboards monAp_pg**. Grafana peut tourner sur VM-Monitoring ou sur une autre machine.

## Contenu

| Fichier | Rôle |
|---|---|
| `install.sh` | installe Grafana, les plugins, la source de données, importe les dashboards (rejouable) |
| `verify.sh` | contrôles après installation |
| `grafana/asemon-*.json` | les {{NB_DASHBOARDS}} dashboards (fleet, instance, macro, intermédiaire, micro, session, requête, capacity, seuils, dashboard d'origine) |
| `grafana/plugins.txt` | plugins requis : `marcusolsson-dynamictext-panel` (boîtes SQL et plans), `volkovlabs-form-panel` (formulaire des seuils) |
| `scripts/` | scripts appelés par `install.sh` (dont `grafana-provision.sh`, rejouable seul) et `asemon.env.example` |
| `SHA256SUMS`, `VERSION` | contrôle d'intégrité, version |

## 1. Prérequis

- Ubuntu Server 24.04 ou plus récent, `sudo`, accès Internet (dépôt `apt.grafana.com`, `grafana.com` pour les plugins).
- Le paquet `monAp_pg_instance_monitoring` installé et joignable (port 5432). Le mot de passe de `grafana_ro` doit être le même des deux côtés.
- Si Grafana n'est **pas** sur VM-Monitoring : `SUBNET` (paquet monitoring) doit inclure l'IP de cette machine.

## 2. Installation

```bash
tar xzf monAp_pg_grafana.tgz
cd monAp_pg_grafana
sha256sum -c SHA256SUMS --quiet && echo "paquet intact"

cp scripts/asemon.env.example scripts/asemon.env
nano scripts/asemon.env          # voir « Paramètres » ci-dessous

sudo ./install.sh
```

### Paramètres (`scripts/asemon.env`)

| Variable | À renseigner |
|---|---|
| `GRAFANA_ADMIN_PASSWORD` | mot de passe admin voulu pour Grafana. **Vide = rien n'est configuré** (ni source de données ni dashboards) |
| `GRAFANA_RO_PASSWORD` | mot de passe de `grafana_ro` (celui du paquet monitoring) |
| `GRAFANA_THRESHOLDS_PASSWORD` | mot de passe de `grafana_thresholds` (celui du paquet monitoring) ; vide = seuils en lecture seule |
| `GRAFANA_DB_HOST` | `localhost` (défaut) si Grafana est sur VM-Monitoring, sinon **l'IP de VM-Monitoring** |

## 3. Ce que fait `install.sh`, et son équivalent à la main

**Composants**

```bash
sudo apt install -y apt-transport-https software-properties-common wget gnupg curl python3
wget -q -O - https://apt.grafana.com/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/grafana.gpg
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" | sudo tee /etc/apt/sources.list.d/grafana.list
sudo apt update && sudo apt install -y grafana
sudo grafana cli plugins install marcusolsson-dynamictext-panel
sudo grafana cli plugins install volkovlabs-form-panel
sudo systemctl enable --now grafana-server && sudo systemctl restart grafana-server
```

**Source de données et dashboards** : `install.sh` appelle l'API de Grafana (`scripts/grafana-provision.sh`, rejouable seul avec `sudo ./scripts/grafana-provision.sh`) : mot de passe admin, source « ASEMON Monitoring » (base `monitoring`, rôle `grafana_ro`), source « ASEMON Seuils » (rôle `grafana_thresholds`), import des JSON avec remplacement.

À la main, dans l'interface (`http://<ip>:3000`, compte `admin`) :
1. *Connections > Data sources > Add > PostgreSQL* : hôte `<IP VM-Monitoring>:5432`, base `monitoring`, utilisateur `grafana_ro`, TLS désactivé, nom **ASEMON Monitoring**.
2. *Dashboards > New > Import* : charger chaque fichier de `grafana/`, choisir cette source pour `DS_MONITORING`.

Il n'y a pas de SQL ni de tâche planifiée dans ce paquet : tout se passe à l'installation, et chaque dashboard interroge le repository en direct.

## 4. Vérification

```bash
sudo ./verify.sh          # Grafana actif, plugins, source de données OK, dashboards présents
```

Puis ouvrir `http://<ip>:3000` : le dashboard **monAp_pg — Parc** doit lister les instances qui envoient des données.

## 5. Mise à jour et désinstallation

- **Mise à jour des dashboards** : extraire le nouveau paquet, recopier `scripts/asemon.env`, relancer `sudo ./install.sh`. Les dashboards sont remplacés (même `uid`) ; **les modifications faites dans l'interface sur ces dashboards sont écrasées**.
- **Désinstallation** : `sudo systemctl disable --now grafana-server && sudo apt remove grafana`. Les dashboards peuvent aussi être supprimés un à un dans l'interface.

## 6. Dépannage

| Symptôme | Piste |
|---|---|
| `HTTP 401` dans `grafana-provision.sh` | mot de passe admin différent de `asemon.env` : `sudo grafana cli admin reset-admin-password <mdp>` |
| Dashboards vides | *Connections > Data sources > ASEMON Monitoring > Save & test* ; sinon `GRAFANA_DB_HOST`, `SUBNET` du paquet monitoring, mot de passe `grafana_ro` |
| Boîtes SQL / plans vides, formulaire des seuils absent | plugin non installé : `grafana cli plugins install <id>` puis `systemctl restart grafana-server` |
