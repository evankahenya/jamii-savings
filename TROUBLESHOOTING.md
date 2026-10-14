# Troubleshooting

Commands are for Windows Command Prompt (`cmd`), run from the folder shown.

## Is it ready yet?

The first `docker compose up -d` downloads about 6 GB of images and builds the MI project, so it takes 10–15 minutes. Check progress in `C:\jamii-savings\infra`:

```
docker compose ps
```

It's ready when `apim`, `mi` and `activemq` show `(healthy)`. `sqlite-init` and `car-build` show `Exited (0)`. That's correct: they're one-off setup jobs.

To see what a container is doing, run `docker compose logs -f mi` (or `apim`). Press Ctrl+C to stop following.

## Jenkins

- You can start Jenkins straight after the platform. Its pipeline waits up to 20 minutes for MI and API Manager to be ready.
- It runs the pipeline by itself only on its first start. To deploy again, open the `jamii-api-deploy` job and click Build with Parameters.
- If the build fails at "checkout", the repo was probably downloaded as a ZIP. Jenkins needs a real `git clone`, because it reads the `.git` folder.

## Not enough memory

API Manager, MI, ActiveMQ and Jenkins together need about 6 GB of memory for Docker. If containers keep restarting or never become healthy, give Docker more memory. With Docker Desktop on WSL 2 (the default), create `C:\Users\<you>\.wslconfig` containing:

```
[wsl2]
memory=6GB
```

Then run `wsl --shutdown` and start Docker Desktop again.

## "Port is already allocated"

The project uses ports 8081, 8161, 8243, 8253, 8280, 8290, 9164, 9443 and 61616. This lists anything already using them:

```
netstat -ano | findstr /R /C:":8081 .*LISTENING" /C:":8161 .*LISTENING" /C:":8243 .*LISTENING" /C:":8253 .*LISTENING" /C:":8280 .*LISTENING" /C:":8290 .*LISTENING" /C:":9164 .*LISTENING" /C:":9443 .*LISTENING" /C:":61616 .*LISTENING"
```

The last number on each line is the process ID. Find it in Task Manager → Details and close that program. To run Jenkins on a different port instead, run `set JENKINS_PORT=8082` before `docker compose up -d --build` in `infra\jenkins`.

## "Filename too long" during git clone

Clone into a short folder such as `C:\jamii-savings`, or enable long paths in git: `git config --global core.longpaths true`.

## curl doesn't work

- In PowerShell, `curl` is a different command. Type `curl.exe` instead, or use Command Prompt.
- Calls to `/customers/...` depend on reqres.in being reachable from your machine.

## Browser warns about the certificate

The pages on port 9443 (Publisher, Dev Portal, Admin Portal) and the gateway on 8243 use API Manager's self-signed certificate. That's expected for a local setup; continue to the site. With curl, add `-k`.

## Calling the APIs through the gateway

Gateway URLs look like `https://localhost:8243/{context}/1.0.0/...`, for example `https://localhost:8243/accounts/1.0.0/0022012569822/balance`. You need a key or token from the Dev Portal. See "How a client discovers and subscribes" in the [README](README.md).

Every sign-in error explains itself in its `details` field. The common ones:

| Status | Meaning | Fix |
|---|---|---|
| 401 Missing credentials | No key or token was sent | AccountBalanceAPI: `ApiKey: <key>` header. Other APIs: `Authorization: Bearer <token>` |
| 401 Invalid credentials | The key or token is wrong or expired | Generate a new one in the Dev Portal |
| 403 Forbidden | The key or token isn't linked to an application subscribed to the API | Key made on the API's page: associate it with a subscribed application (API → API Keys). Key or token made in an application: subscribe that application to the API. The same key then works. |

## Addresses and logins

| What | Address | Login |
|---|---|---|
| Jenkins | http://localhost:8081 | admin / admin |
| Publisher | https://localhost:9443/publisher | admin / admin |
| Dev Portal | https://localhost:9443/devportal | admin / admin |
| Admin Portal | https://localhost:9443/admin | admin / admin |
| ActiveMQ console | http://localhost:8161/admin | admin / admin |
| MI APIs (no gateway) | http://localhost:8290 | none |

## Stopping, starting and resetting

Run these in `C:\jamii-savings\infra` and again in `C:\jamii-savings\infra\jenkins`:

- `docker compose stop` stops everything. Your data is kept.
- `docker compose start` starts it again.
- `docker compose down -v` deletes everything, including the database and API Manager data, for a completely fresh start.

More detail on the Docker setup is in [infra/README.md](infra/README.md).
