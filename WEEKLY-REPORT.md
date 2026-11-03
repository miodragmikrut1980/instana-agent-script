# Instana Agent Installer & Configurator — Status & Weekly Report

**Projekat:** Instana Host Agent Installer & Offline Configurator (`Agent/`)  
**Autor:** Miodrag Mikrut (Support & Escalations)  
**Datum izveštaja:** 03. novembar 2026.

---

## 1. Rezime postignutog (Completed & Confirmed on Live Systems)

U prethodnom periodu razvijen je i rigorozno testiran kompletan komplet alata za brzu i pouzdanu instalaciju, konfiguraciju i dijagnostiku Instana Host Agenta (za korisnike i Support inženjere za replikaciju problema).

### Glavne komponente:
1. **`agent-install.sh` (POSIX/Bash installer & config manager, ~64.9 KB):**
   - Interaktivna i neinteraktivna instalacija (`--config`, `--profile`).
   - Meni za izmenu konfiguracije (`sudo ./agent-install.sh` -> *Edit existing configuration*): izmena ključa, zone, taga, backend host/porta, proxy parametara, backup/restore.
   - Puna provera konektivnosti (`--connectivity` / opcija 8): testira backend endpoint + 4 Instana repozitorijuma kroz proxy i direktno (HTTP/2 handshake, TLS, detekcija 403 / 407 grešaka).
   - Sanitizacija ključa i tajnih podataka (`clean_key`, automatsko maskiranje u logovima i support bundle-u).
   - Support bundle (`--support-bundle`): sakuplja logove, konfiguracije i status sistema uz 100% maskiranje ključeva i lozinki.

2. **`agent-config-generator.html` (Offline Browser Configurator):**
   - Jedan HTML fajl, radi potpuno offline bez eksternih zavisnosti.
   - Podržava targete: **Linux Host**, **Docker**, **Kubernetes (Helm)**, **Kubernetes Operator / OpenShift**.
   - Dvosmerna integracija sa installerom: izvoz i učitavanje JSON konfiguracije.

3. **Profili (`profiles/*.json`):**
   - Gotovi profili: `saas-us-west`, `saas-eu-replica`, `infrastructure-only`, `ibm-mq`, `java-app`.

---

## 2. Testirano i potvrđeno na živim okruženjima (GCP Debian 13 VM & GKE)

| Tehnologija / Senzor | Status | Napomena |
| :--- | :--- | :--- |
| **Linux Host Agent** | ✅ Potvrđeno | Instalacija, systemd servis, Backend.cfg, zona, tagovi, restart |
| **Docker Agent** | ✅ Potvrđeno | Kontejner run, volume mounts, `INSTANA_AGENT_KEY`, HTTP/2 handshake |
| **Kubernetes (Helm)** | ✅ Potvrđeno na GKE | Helm chart, cluster.name, zone.name, `values.yaml` sa `configuration_yaml` |
| **Proxy (Squid)** | ✅ Potvrđeno | HTTP/2 tunel kroz proxy sa basic auth, escape specijalnih znakova |
| **IBM MQ Senzor** | ✅ Potvrđeno (Live) | Client binding konekcija ka QM1, OAM autorizacije (`SET AUTHREC`), bez grešaka |
| **MySQL Senzor** | ✅ Potvrđeno (Live) | Detekcija MySQL 8.4 procesa, autentifikacija, PROCESSLIST veza |
| **MariaDB Senzor** | ✅ Potvrđeno (Live) | Zaseban `com.instana.plugin.mariadb` senzor, `performance_schema` i prava |
| **PostgreSQL Senzor**| ✅ Potvrđeno (Live) | Postgres 16 kontejner, `instana` korisnik, uspešno povezivanje i aktivacija |
| **MongoDB Senzor** | ✅ Potvrđeno (Live) | Mongo 7 kontejner, role `clusterMonitor`, `read/admin`, `read/local`, uspešna veza |
| **Redis Senzor** | ✅ Potvrđeno (Live) | Autentifikacija, throughput praćenje, specijalni znakovi u lozinci |
| **MS SQL Server** | ✅ Potvrđeno (Dry-run)| Dokumentovani `local:` blok (instance, user, password, port) |

---

## 3. Trenutni rad (Current Sprint / Focus)

- **Unapređenje HTML konfiguratora (`agent-config-generator.html`):**
  - Dodavanje **Cheat-sheet komandi za pripremu baza i senzora** (gotov SQL / mongosh / runmqsc kod za kreiranje `instana` korisnika sa tačnim pravima jednim klikom).
  - Dodavanje **Autofill / Default presets** dugmadi za standardne portove i korisnike u formama senzora.
  - Dodavanje **Operator / OpenShift (CR)** deployment targeta (`InstanaAgent` Custom Resource YAML generator).
  - Poboljšani tabovi za pregled i kopiranje konfiguracije.

---

## 4. Plan za naredni period (Next Steps & Roadmap)

1. **Verifikacija metrika u Instana UI:**
   - Provera prikaza MQ, MariaDB i ostalih senzora na pravom produkcionom tenantu sa punim UI pravima.
2. **Kubernetes Operator / OpenShift testiranje:**
   - Provera `InstanaAgent` Custom Resource manifesta na živom OpenShift / Operator klasteru.
3. **Automatizacija repro okruženja (`repro/repro.sh`):**
   - Dalje testiranje automatizovanog podizanja agenta na čistim mašinama preko SSH manifesta.
