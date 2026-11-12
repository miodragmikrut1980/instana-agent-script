Instana Agent Setup Tools v1.0.0
=================================

Alati za instalaciju i konfiguraciju Instana Host Agenta na Linux-u i Docker-u.
Namenjeni support inzenjerima i korisnicima.
Scope v1: Linux host agent + Docker. Kubernetes/cloud = v2.

FILES
─────
agent-config-generator.html   Browser konfigurator (radi offline, bez servera)
agent-triage.html             Browser log dijagnosticar & Triage analizator
agent-install.sh               Interaktivni Linux installer + manager (--triage)
profiles/                      Predefinisani profili za ceste scenarije


STA GDE ZAVRSAVA (bitno za razumevanje)
───────────────────────────────────────
Instana ne cuva sve u configuration.yaml. Alati pisu svaku postavku tamo gde je
dokumentovana:

  Postavka                 Gde ide
  ───────────────────────  ───────────────────────────────────────────────────
  Agent key, backend       Installer parametri -a / -e (Docker: env
  host i port              INSTANA_AGENT_KEY / _ENDPOINT / _ENDPOINT_PORT)
  Agent mode               Installer -m apm|infra|aws (Docker: INSTANA_AGENT_MODE)
  Zona                     configuration.yaml -> com.instana.plugin.generic.hardware
                           (enabled: true, availability-zone)
                           Docker: INSTANA_AGENT_ZONE
  Host tagovi              configuration.yaml -> com.instana.plugin.host -> tags
  Proxy                    Backend.cfg -> proxy.type/host/port/user/password/dns
  Pin verzije senzora      AgentBootstrap.cfg -> version = <tag>
  Raspored update-a        UpdateManager.cfg
  Memorija / JAVA_OPTS     systemd drop-in 10-environment.conf (Linux)
  Senzori (MySQL, MQ...)   configuration.yaml -> com.instana.plugin.<ime>

Svi .cfg fajlovi su u /opt/instana/agent/etc/instana/.
Backend.cfg = com.instana.agent.main.sender.Backend.cfg
Agent.cfg   = com.instana.agent.main.config.Agent.cfg


QUICK START — browser konfigurator (za sve platforme)
──────────────────────────────────────────────────────
1) Otvori agent-config-generator.html u browseru (Chrome, Firefox, Safari).
   Radi lokalno, bez interneta. Nista se ne salje.

2) Popuni "Quick setup": target (Linux/Docker/Kubernetes), backend (SaaS region
   ili self-hosted host:port), agent key (prazno = unosi se pri instalaciji).
   Za Kubernetes se pojavljuje polje "Cluster name"; tab "Install command" daje
   Helm komandu (zona ide u zone.name, tagovi i senzori u values.yaml ->
   agent.configuration_yaml). Za Kubernetes je napravljena samo Helm varijanta,
   bez Operatora. Proveri da je helm 3 i da kubectl pokazuje na klaster.
   "Advanced settings" otvara:
   - Agent mode (APM, Infrastructure, AWS)
   - Update mode (dynamic/static)
   - Version pinning i raspored update-a (vidi dole)
   - Resources (memorija/CPU za Linux, Docker, Kubernetes)
   - Zone i tagovi
   - Proxy
   - Senzori (MySQL, PostgreSQL, IBM MQ, Kafka...) — za svaki cekirani
     senzor pojavljuju se polja za konfiguraciju

3) Tab "configuration.yaml" prikazuje samo ono sto ide u taj fajl (zona, tagovi,
   senzori). Ostalo (key, backend, mode, proxy, pin, resursi) je u tabu
   "Install command", kao komande koje treba pokrenuti.
   Tab "Connectivity test" daje curl komandu za ciljnu masinu: proverava backend i
   repozitorijume (kroz proxy ako je unet; lozinku trazi sa read -s). HTML sam
   ne moze da testira mrezu, zato se komanda kopira i pokrece na masini gde ide agent.

4) Dugmad:
   - "Download YAML"        — preuzmi configuration.yaml
   - "Copy YAML"            — kopiraj YAML u clipboard
   - "Copy install command" — kopiraj install komande
   - "Copy as paste-in"     — kopiraj heredoc koji snima configuration.yaml u ~
                              (pazi: ako je key u YAML-u, ne cuvati u deljenim logovima)
   - "Load JSON config"     — ucitaj JSON (vidi "FORMAT JSON FAJLOVA")


VERSION PINNING I UPDATE
────────────────────────
- Pin sensors version: upise "version = <tag>" u AgentBootstrap.cfg i zamrzne
  preuzimanje senzora na taj release. Tagovi: github.com/instana/agent-updates/tags
  Korisno za reprodukciju problema na tacnoj verziji iz tiketa.
- Update schedule (UpdateManager.cfg): Daily / Weekly (ponedeljak ili sreda) +
  vreme (UTC). Podrazumevano dnevno u 04:30, jitter 30 min.
- "Freeze" = samo pin verzije. Iskljucivanje rasporeda NIJE dovoljno: agent bi
  pri svakom restartu ipak povukao najnoviju verziju senzora. Zato Freeze bez
  unete verzije daje upozorenje.


RESURSI (memorija / CPU)
────────────────────────
Podrazumevano ~544 MiB. Povecavati samo kad log pokazuje OutOfMemoryError ili se
prati mnogo entiteta (IBM MQ, OMEGAMON, cloud senzori).
- Linux: systemd drop-in
    /etc/systemd/system/instana-agent.service.d/10-environment.conf
      [Service]
      Environment=AGENT_MAX_MEM=1024M
      Environment="JAVA_OPTS=-Xmx1g"
  zatim: sudo systemctl daemon-reload && sudo systemctl restart instana-agent
- Docker: --memory / --cpus
- Kubernetes/OpenShift: agent.resources u Helm values / agent CR


QUICK START — shell installer (Linux)
──────────────────────────────────────
Preduslovi: Ubuntu/Debian ili RHEL/CentOS/SLES; sudo pristup; curl.
jq se instalira automatski kad se koristi --config ili --profile.

# Interaktivni wizard (backend, agent key, zona):
  ./agent-install.sh

# Dry run — plan bez ikakvih izmena (pise configuration.yaml u trenutni folder):
  ./agent-install.sh --dry-run

# Neinteraktivno — agent key iz env promenljive (key ne ulazi u istoriju komandi):
  INSTANA_AGENT_KEY=... sudo -E ./agent-install.sh --profile saas-us-west

# Instalacija iz config fajla ili profila:
  ./agent-install.sh --config my-config.json [--dry-run]
  ./agent-install.sh --profile ibm-mq [--dry-run]

# Status agenta (servis, verzija, backend iz Backend.cfg, zona, poslednji log):
  ./agent-install.sh --status

# Manager postojeceg agenta: pokreni skriptu bez argumenata i izaberi
# "Edit existing configuration" (--edit je samo precica do istog menija):
  sudo ./agent-install.sh

# Support bundle:
  ./agent-install.sh --support-bundle

# Uklanjanje agenta (paket, /opt/instana/agent, repo + kljuc + pristupni podaci, systemd drop-in):
#   prvo plan, ne menja nista:
  ./agent-install.sh --uninstall --dry-run
#   pa brisanje (pita da se ukuca "yes"; --yes preskace pitanje):
  sudo ./agent-install.sh --uninstall

Sta installer radi, redom: pokrene setup.instana.io/agent sa -a/-t/-m/-e,
zatim kopira configuration.yaml (ako ima zone, tagova ili senzora), upise proxy u
Backend.cfg (ako je zadat) i restartuje servis.

Senzori iz "sensors" bloka: installer upisuje ibmmq, mysql, mariadb, postgresql,
mongodb, mssql (samo "local" lista) i redis u configuration.yaml (isti izlaz kao HTML). Ostali senzori se
preskacu uz upozorenje; za njih koristi HTML konfigurator.
mssql: na Linuxu ime instance mora biti "DEFAULT" (ne "MSSQLSERVER"), inace senzor biva uklonjen
("Sensor removed due to invalid or missing configuration"); na Windowsu je to MSSQLSERVER ili ime instance.
Napomena: MariaDB se NE prepoznaje kao MySQL, ima poseban senzor "mariadb"
(korisniku treba i GRANT SELECT ON performance_schema.*). Ako agent.log javi
"need SLAVE MONITOR privilege", dodaj GRANT SLAVE MONITOR ON *.* (nije u
dokumentaciji senzora; potvrdjeno samo da upozorenje nestaje).
Napomena: IBM MQ. Ako agent i Queue Manager nisu na istoj masini (ili je MQ u
Docker-u), senzor koristi "client binding" i spaja se kao obican klijent. Korisnik iz
"username" mora imati OAM prava (dokumentacija "Configuring IBM MQ authority"),
inace agent.log javlja MQJE001 Reason '2035' a MQ log AMQ8077W. Minimum: QMGR
CONNECT,DSP,INQ; SYSTEM.ADMIN.COMMAND.QUEUE DSP,INQ,PUT,CHG; SYSTEM.DEFAULT.MODEL.QUEUE
DSP,GET; plus prava za SYSTEM.ADMIN.*.EVENT i STATISTICS.QUEUE, pa REFRESH SECURITY.
U runmqsc ime korisnika pisati u navodnicima: PRINCIPAL('app'). Docker image ima
zaseban zapis DEV.** koji ima prednost nad '**' (treba i DSP za DEV.**).
AMQ8077W za SYSTEM.AUTH.DATA.QUEUE (chg) je poznato ogranicenje, nije kvar.



Sta installer NE radi (ovo se i dalje podesava rucno ili iz HTML-a):
ostali senzori (npr. mssql remote, elasticsearch), pin verzije, raspored update-a i resursi.
HTML konfigurator ih generise kao komande u tabu "Install command".


PROFILI (profiles/)
───────────────────
ibm-mq.json               IBM MQ monitoring — jedan Queue Manager, SVRCONN
java-app.json             Java APM + MySQL + Redis
infrastructure-only.json  Samo infra metrike, bez APM tracinga
saas-eu-replica.json      SaaS EU replika, region blue (AWS Dublin). Za Frankfurt
                          (emerald) ili Belgiju (green) promeni SAAS_REGION.
saas-us-west.json         SaaS US West (ingress-red-saas.instana.io) replika

Profili imaju zonu i tagove (environment/team) unapred popunjene. Agent key je
prazan u svim profilima. Profili sa self-hosted backendom (npr. ibm-mq) imaju i
prazan HOST, pa installer pita za backend.
Profil se moze kopirati i prilagoditi.


FORMAT JSON FAJLOVA
───────────────────
Jedan format za sve (profili, --config, izvoz iz --edit):
     { "parameters": { "SAAS_REGION": "...:443"   (ili "HOST" + "PORT"),
                       "AGENT_MODE": "APM", "ZONE": "...",
                       "TAG_ENV": "...", "TAG_TEAM": "...",
                       "PROXY_TYPE": "http|socks4|socks5" (default http),
                       "PROXY_HOST": "...", "PROXY_PORT": "...",
                       "PROXY_USER": "..." },
       "secrets":    { "AGENT_KEY": "...", "PROXY_PASS": "..." },
       "sensors":    { "ibmmq":      { "queueManagers": [ { "name", "host", "channel",
                                                            "port", "username", "password" } ] },
                       "mysql":      { "user", "password" },
                       "mariadb":    { "user", "password" },
                       "postgresql": { "user", "password", "database" },
                       "mongodb":    { "user", "password", "source" },
                       "mssql":      { "local": [ { "instance", "user", "password", "port" } ] },
                       "redis":      { "password" } } }
Cita ga: agent-install.sh (--config / --profile) i dugme "Load JSON config"
u HTML-u (HTML ucitava sve navedene senzore). HTML jos prihvata i
stari ravni format (BACKEND_HOST, AGENT_KEY...).

Izvoz iz --edit (opcija e) pise ovaj format, ali "sensors" je prazan:
senzori se ne citaju iz postojeceg configuration.yaml.
Izvezeni fajl ima dozvole 0600 i sadrzi agent key u cistom tekstu — ne deliti.


EDIT MODE — sudo ./agent-install.sh -> "Edit existing configuration"
────────────────────────────────────
  1) Prikaz konfiguracije (configuration.yaml + Backend.cfg, key maskiran)
  2) Editovanje configuration.yaml u $EDITOR
  3) Promena backend host/port        (upis u Backend.cfg)
  4) Promena agent key-a              (upis u Backend.cfg)
  5) Promena zone                     (upis u configuration.yaml)
  6) Restart agenta
  7) Poslednjih 50 linija loga
  8) Test konekcije: backend + artifact-public/packages/setup.instana.io (443),
     kroz proxy iz Backend.cfg ako je podesen; za svaki host OK ili uzrok greske
     (DNS, proxy odbija konekciju, 407 treba user/lozinka, 403 proxy blokira host,
     timeout/firewall, TLS inspekcija). Na kraju i poslednji handshake/403 iz agent.log.
  9) Rollback na poslednji backup
  e) Izvoz u JSON (isti format kao profili; ucitava ga --config i HTML)
  0) Izlaz

Svaka izmena pravi backup pored fajla koji menja, npr.:
  /opt/instana/agent/etc/instana/configuration.yaml.bak.DATUM
  /opt/instana/agent/etc/instana/com.instana.agent.main.sender.Backend.cfg.bak.DATUM
Opcija 9 vraca backup samo za configuration.yaml.


SUPPORT BUNDLE
──────────────
./agent-install.sh --support-bundle

Generise ZIP (ili .tar.gz) sa:
  - system-info.txt     — OS, CPU, memorija, disk, Java
  - configuration.yaml  — konfiguracija (key/password maskirani)
  - Backend.cfg         — key, proxy.password i proxy.user maskirani (<MASKED>)
  - Agent.cfg           — kopija bez maskiranja (pregledaj pre slanja)
  - agent.log           — poslednjih 500 linija (key=... maskiran)
  - service-status.txt  — systemctl status + journalctl
  - network.txt         — otvoreni portovi + test konekcije do backenda
  - processes.txt       — relevantni procesi (instana, java, mysql...)

Pre slanja proveri da u bundle-u nema kljuceva (npr. unzip -p <bundle> Backend.cfg).
Posalji ga support timu uz broj tiketa.


DOKUMENTACIJA
─────────────
Validirano prema IBM Instana dokumentaciji (docs_instana_observability).
Relevantne stranice (trazi ih po naslovu na ibm.com/docs):
  - Configuring host agents by using the agent configuration file  (zona, tagovi)
  - Configuring Instana host agents                                 (backend, proxy, mode)
  - Installing the agent on Linux -> One-liner script parameters    (-a -e -t -m -d -y -s)
  - Environment variables -> containerized agent                    (Docker env varijable)


NAPOMENE ZA SUPPORT INZENJERE
───────────────────────────────
- Za brzu replikaciju: INSTANA_AGENT_KEY=... sudo -E ./agent-install.sh --profile <profil>
  Za par minuta imate identican setup (zona i tagovi iz profila).

- Za tacnu verziju senzora iz tiketa: HTML -> Version pinning -> unesi tag,
  pa pokreni komande iz taba "Install command".

- Prava instalacija jos nije testirana end-to-end; dry-run je proveren.
  Tacan sadrzaj Backend.cfg (host=, port=, key=) nije potvrdjen u dokumentaciji,
  samo proxy.* linije jesu.
