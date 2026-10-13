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

Optional: to make `CustomerProxy` / `GetCustomerByID` / `CustomerDashboardAPI` reach
reqres.in, copy `.env.example` to `.env` and set `REQRES_API_KEY`.

> The APIs only show up in **API Manager** after the Jenkins pipeline has run (or after you
> import them yourself). `docker compose up` deploys the MI side only.

---

## What runs

| Service | Version | Job |
|---|---|---|
| `apim` | WSO2 API Manager 4.7.0 | Publishes and secures the APIs (Publisher, Dev Portal, Gateway, Key Manager) |
| `mi` | WSO2 Micro Integrator 4.6.0 | Runs the integrations (the `.car` built from `Jamii_WSO2_Project`) |
| `activemq` | ActiveMQ Classic 5.18.7 | JMS broker for MI |
| `sqlite-init` | SQLite 3.46.1 | One-shot job: builds `Jamii_db` from `schema.sql` + `seed.sql` |
| `car-build` | Maven 3.9.9 / JDK 21 | One-shot job: builds the `.car` and drops it into MI (skipped if one is already deployed) |

> **SQLite is a file, not a server.** `sqlite-init` creates the file in a shared Docker
> volume (`jamii-data`), and MI opens that same file through the JDBC driver.

**ActiveMQ version:** MI 4.6 supports ActiveMQ Classic up to 6.1.x. 5.18 uses the same
`javax.jms` API that MI already ships, so it needs no extra JMS 3.1 configuration. The
client jars are copied from the broker image into MI, so client and broker versions always
match (see `mi/Dockerfile`).

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
credentials for dev and the **`jamii-api-deploy`** job already created. Open the job and
click **Build with Parameters**.

By default the job reads the repo mounted at `/repo`, so it **builds what is committed**
on the `main` branch. To build from GitHub instead, set `JAMII_GIT_URL` (see
`jenkins/compose.yaml`).

### What the pipeline does (`Jenkinsfile` at the repo root)

```
Validate -> Build MI CAR -> Test -> Package APIM APIs
         -> Deploy: dev -> [approve] -> Deploy: uat -> [approve] -> Deploy: prod
```

| Stage | Does |
|---|---|
| Validate | XML well-formed; every API has an MI artifact, OpenAPI file, apictl project and per-env params; APIM context == MI context; policies exist |
| Build MI CAR | `mvn clean install` with the WSO2 Maven plugins |
| Test | Synapse unit tests (`mvn test`). None are written yet. |
| Package | One apictl archive per API (OpenAPI + policies copied in from their single source) |
| Deploy: \<env\> | All-or-nothing deploy of the CAR + all 4 APIs, then smoke tests (see below) |

**One pipeline for all APIs.** The pipeline handles every folder in
`Jamii_WSO2_Project/apim-apis/`. To add an API, add a folder there plus a line in
`ci/smoke-tests.txt`. The Jenkinsfile doesn't change.

**Environments.** `ci/environments/<env>.properties` hold the URLs and Jenkins credential
ids. dev has `ENABLED=true`. uat/prod are placeholders (`ENABLED=false`): their stages run
and say "nothing deployed". The same artifacts, built once, are promoted through every
environment.

**No partial deploys** (`ci/scripts/deploy.sh`):
1. Pre-flight: artifacts present, MI and APIM reachable, logins OK. Nothing has changed yet.
2. Back up the current version of every API from APIM.
3. Deploy the CAR to MI through the Management API, and wait until MI reports it active.
4. Import/update every API with `apictl` (new revision, deployed to the gateway).
5. Smoke tests: each API once directly on MI and once through the gateway with a real token.

If **anything** in steps 2–5 fails, every API already touched is restored from the backup
(or deleted if it was new), MI goes back to the last good CAR, and the build fails. This
was tested by deploying a deliberately broken API: the deploy stopped at that API and all
earlier changes were reverted.

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
