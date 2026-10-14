# Jamii local platform (Docker) + CI/CD

## TL;DR - run it

You need Docker Desktop (about 6 GB RAM for Docker) and this **whole repository**. The
compose file uses `../schema.sql`, `../seed.sql` and `../Jamii_WSO2_Project`, so it can't
run on its own.

```bash
cd infra
docker compose up -d
```

That's all. No scripts, no `.env`, no flags. The first run takes about 10–15 min: it
downloads images and the Maven dependencies needed to build the MI project. After that,
a start takes about 2 min.

| What | URL | Login |
|---|---|---|
| API Manager Publisher | https://localhost:9443/publisher | admin / admin |
| API Manager Dev Portal | https://localhost:9443/devportal | admin / admin |
| APIM Gateway | https://localhost:8243/accounts/1.0.0/{accountNumber}/balance | OAuth token |
| MI APIs (direct) | http://localhost:8290/accounts/0022012569822/balance | - |
| MI Management API | https://localhost:9164/management | admin / admin |
| ActiveMQ console | http://localhost:8161/admin | admin / admin |

The customer lookup and dashboard (`CustomerProxy` / `CustomersAPI`) call reqres.in. The
project's shared reqres.in **public** key is already the default in `compose.yaml`, so they
work with no setup. To use your own key instead, copy `.env.example` to `.env` and set
`REQRES_API_KEY`.

> `docker compose up` deploys the MI side only. To get the APIs into **API Manager**, also
> start Jenkins (`cd jenkins` then `docker compose up -d --build`). On its first start it
> runs the pipeline by itself and deploys everything. See [Jenkins pipeline](#jenkins-pipeline).

---

## What runs

| Service | Version | Job |
|---|---|---|
| `apim` | WSO2 API Manager 4.7.0 | Publishes and secures the APIs (Publisher, Dev Portal, Gateway, Key Manager) |
| `mi` | WSO2 Micro Integrator 4.6.0 | Runs the integrations (the `.car` built from `Jamii_WSO2_Project`) |
| `activemq` | ActiveMQ Classic 5.18.7 | JMS broker for MI |
| `sqlite-init` | SQLite 3.46.1 | One-shot job: builds `Jamii_db` from `schema.sql` + `seed.sql` |
| `car-build` | Maven 3.9.9 / JDK 21 | One-shot job: builds the `.car` and drops it into MI (skipped if one is already deployed) |
| `apim-init` | SQLite 3.46.1 image | One-shot job: makes API Manager's search-index volume writable before API Manager starts |

API Manager keeps two volumes: `apim-db` (APIs, apps, subscriptions) and `apim-solr` (its
search index). Both must survive a container re-creation together. If the index is lost
while the database is kept, the Publisher, Dev Portal and `apictl` stop listing APIs that
still exist.

**Sign-in errors:** `apim/_auth_failure_handler_.xml` replaces API Manager's gateway-wide
auth failure handler. 401 and 403 errors then use the Jamii error format, with a `details`
field explaining how to fix them, instead of `{"code":"900908","message":"Resource forbidden"}`.

> **SQLite is a file, not a server.** `sqlite-init` creates the file in a shared Docker
> volume (`jamii-data`), and MI opens that same file through the JDBC driver.

**ActiveMQ version:** MI 4.6 supports ActiveMQ Classic up to 6.1.x. 5.18 uses the same
`javax.jms` API that MI already ships, so it needs no extra JMS 3.1 configuration. The
client jars are copied from the broker image into MI, so client and broker versions always
match (see `mi/Dockerfile`).

**Loan application queues:** the broker starts with `activemq/jamii-activemq.xml`, which is the
default config plus one rule: expired messages on `LoanApplicationsRetryQueue` go back to
`LoanApplicationsQueue`, which gives a delayed retry. The design is summarised under
"Bonus tasks" in the main [README](../README.md).

## Environments

There is **one** `compose.yaml`. Every value in it has a **dev** default, and an env file
overrides those defaults for another environment:

```bash
docker compose up -d                          # dev   (defaults - runs on this PC)
docker compose --env-file env/uat.env up -d   # uat   (placeholder, ports +10000)
docker compose --env-file env/prod.env up -d  # prod  (placeholder, ports +20000)
```

Each environment gets its own project name (`jamii-dev`, `jamii-uat`, `jamii-prod`), so its
containers, network and volumes never mix with another environment's. Only dev runs on this
PC because of RAM. uat/prod are complete and valid, just not started.

```
infra/
├── compose.yaml                  <- the platform (all environments)
├── .env.example                  <- optional secrets (copy to .env)
├── env/{dev,uat,prod}.env        <- per-environment ports, memory, versions
├── config/<env>/mi/deployment.toml
├── mi/Dockerfile                 <- MI 4.6 + SQLite JDBC + ActiveMQ client jars
├── mi/build-car.sh               <- used by the car-build service
├── sqlite/init-db.sh             <- used by the sqlite-init service
├── apim/_auth_failure_handler_.xml <- clear 401/403 errors in the Jamii format
├── jenkins/                      <- the CI server (separate compose project)
└── jamii.ps1                     <- OPTIONAL PowerShell shortcuts
```

`jamii.ps1` is only for convenience (`.\jamii.ps1 up dev`, `status`, `logs dev mi`,
`rebuild-car`, `reset-db`, `down`). It prints the plain `docker compose` command it runs.

---

## Jenkins pipeline

```bash
cd infra/jenkins
docker compose up -d --build      # http://localhost:8081  (admin / admin)
```

Jenkins comes up fully configured from code (`jenkins/casc.yaml`): no setup wizard, with
credentials for dev and the **`jamii-api-deploy`** job already created.

**You don't have to click anything the first time.** On its first start Jenkins runs the
pipeline once by itself (`jenkins/jamii-first-build.groovy`). If the platform is still
starting, the deploy step waits for MI and API Manager to be ready (up to 20 min,
`ENV_WAIT_SECONDS`), so you can start Jenkins right after `docker compose up -d`. A
first run takes about 10 minutes (Maven downloads, then waiting for APIM). After that,
all the APIs are live in MI and API Manager. Later Jenkins restarts don't redeploy. To
deploy again, open the job and click **Build with Parameters**. To switch off the
automatic first build, set `JAMII_AUTO_BUILD=false`.

By default the job reads the repo mounted at `/repo`, so it **builds what is committed**
on the `main` branch. It needs a real `git clone`, not a ZIP download. To build from
GitHub instead, set `JAMII_GIT_URL` (see `jenkins/compose.yaml`).

Works on Intel/AMD machines and on Apple Silicon Macs: the image downloads the `apictl`
build that matches the machine's CPU.

### What the pipeline does (`Jenkinsfile` at the repo root)

```
Validate -> Build MI CAR -> Test -> Package APIM APIs
         -> Deploy: dev -> [approve] -> Deploy: uat -> [approve] -> Deploy: prod
```

| Stage | Does |
|---|---|
| Validate | XML well-formed; every API has an MI artifact, OpenAPI file, apictl project and per-env params; APIM context == MI context; policies and rate-limiting tiers exist; API Products only use APIs in the repo and don't bypass an API's rate limit |
| Build MI CAR | `mvn clean install` with the WSO2 Maven plugins |
| Test | Synapse unit tests (`mvn test`). None are written yet. |
| Package | One apictl archive per API and per API Product (OpenAPI + policies copied in from their single source), plus the custom rate-limiting tiers |
| Deploy: \<env\> | All-or-nothing deploy of the CAR + the 3 APIs + the API Product, then smoke tests (see below) |

**One pipeline for all APIs.** The pipeline handles every folder in
`Jamii_WSO2_Project/apim-apis/` (APIs) and `Jamii_WSO2_Project/apim-api-products/` (API
Products), and every tier in `Jamii_WSO2_Project/apim-throttling-policies/`. To add an API
or product, add a folder there plus a line in `ci/smoke-tests.txt`. The Jenkinsfile
doesn't change.

**Changed something in the Publisher?** Portal changes live in API Manager's database, not
in git, and the next pipeline run overwrites them. Copy them into the repo first, then
commit (run from the repo root, in Command Prompt):

```bash
docker run --rm -u root --add-host host.docker.internal:host-gateway -v "%cd%:/repo" -w /repo --entrypoint bash jamii-jenkins:2.541.3 ci/scripts/pull-api.sh AccountBalanceAPI
```

For an API Product, add `--product`: `... ci/scripts/pull-api.sh --product JamiiProducts`.

**Environments.** `ci/environments/<env>.properties` hold the URLs and Jenkins credential
ids. dev has `ENABLED=true`. uat/prod are placeholders (`ENABLED=false`): their stages run
and say "nothing deployed". The same artifacts, built once, are promoted through every
environment.

**No partial deploys** (`ci/scripts/deploy.sh`):
1. Pre-flight: artifacts present, MI and APIM reachable, logins OK. Nothing has changed yet.
2. Create/update the custom rate-limiting tiers (e.g. ReqRes), then back up the current
   version of every API and API Product from APIM.
3. Deploy the CAR to MI through the Management API, and wait until MI reports it active.
4. Import/update every API with `apictl` (new revision, deployed to the gateway), then the
   API Products, which depend on the APIs.
5. Smoke tests: each API once directly on MI and once through the gateway, plus calls through
   the API Product. The test sends a real OAuth token, or an API key for APIs secured with
   API Key only (like AccountBalanceAPI).

If **anything** in steps 2–5 fails, every API and product already touched is restored from
the backup (or deleted if it was new), MI goes back to the last good CAR, and the build
fails. This was tested by deploying deliberately broken APIs: the deploy stopped there and
all earlier changes, including the API Product, were reverted.

You can run the same scripts without Jenkins too (inside the Jenkins image they have
everything they need). See the header of each script in `ci/scripts/`.

---

## Good to know

- **Inside Docker, services talk by name.** APIM's backend for each API is `http://mi:8290/...`
  (see `apim-apis/*/params.yaml`). Inside the APIM container, `localhost` means APIM itself.
- **MI config exists twice on purpose.** `Jamii_WSO2_Project/deployment/deployment.toml` is
  what VS Code uses (Windows DB path). `config/<env>/mi/deployment.toml` is the container
  version (Linux DB path + ActiveMQ). Copy any masking/other change to both.
- **Default logins are `admin/admin` everywhere.** That's fine for local dev. Real uat/prod
  would override them through `.env` / Jenkins credentials.
- **Wipe an environment completely:** `docker compose down -v` deletes its volumes (DB,
  APIM data, deployed CAR).
