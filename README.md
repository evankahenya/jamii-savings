# Jamii Savings: WSO2 MI + API Manager + Jenkins

Three integrations for a fictional bank, built on WSO2 Micro Integrator 4.6, published through WSO2 API Manager 4.7, and deployed by a single Jenkins pipeline. Both bonus tasks are included: a customer dashboard and a JMS loan-application queue.

## How to run (Windows, Command Prompt)

Requires Git and Docker Desktop (running, with about 6 GB of memory).

1. `git clone https://github.com/evankahenya/jamii-savings.git C:\jamii-savings`
2. `cd C:\jamii-savings\infra` then `docker compose up -d` starts API Manager, MI, ActiveMQ and the database. The first run takes about 15 minutes.
3. `cd jenkins` then `docker compose up -d --build` starts Jenkins, which deploys the APIs by itself.
4. Open http://localhost:8081 (`admin` / `admin`) and wait for the `jamii-api-deploy` build to turn green.
5. Test it: `curl http://localhost:8290/accounts/0022012569822/balance`

All other logins are also `admin` / `admin`: Publisher and Dev Portal at https://localhost:9443, ActiveMQ at http://localhost:8161. If something doesn't work, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Repository layout

```
jamii-savings/
├── Jamii_WSO2_Project/            MI project
│   ├── src/main/wso2mi/            ├─ APIs, proxy, data service, sequences
│   │   └── resources/              └─ OpenAPI definitions and schemas
│   ├── apim-apis/                 APIM apictl projects (the 3 APIs)
│   ├── apim-api-products/         API Product (JamiiProducts)
│   ├── apim-policies/             Custom gateway policies
│   └── apim-throttling-policies/  Custom rate-limit tier (ReqRes)
├── schema.sql, seed.sql           Database schema and seed data
├── Jenkinsfile                    The pipeline
├── ci/                            Scripts the pipeline runs
└── infra/                         Docker Compose environment (dev; uat/prod placeholders)
```

### The APIs

## 1. AccountBalanceAPI: `/accounts`
- `GET /{accountNumber}/balance` reads the balance from SQLite through an MI data service, using a parameterized query.
- Errors: unknown account → 404, database error → 500, database unreachable or slower than 5 s → 503.
- Security: API Key. Responses are cached for 60 s.

## 2. CustomersAPI: `/customers`
- `GET /{customerId}` (Part 1b) goes through the `CustomerProxy` proxy service to reqres.in, a mock REST service that hosts our customer records.
  - It adds a correlation ID if the caller didn't send one, and strips internal headers.
  - It times out after 10 s. A fault sequence maps a timeout to 504 and a backend that is down to 503.
  - Why reqres.in: we can host our own customer records behind a real API key, with real limits and latency.
- `GET /{customerId}/dashboard` (Bonus A) gets the customer, then all their account balances in parallel, and merges them into one response.
- Security: OAuth2. Rate limit: 250 requests a day, because that is all the reqres.in free plan allows.

### 3. LoansAPI: `/loans`
- `POST /eligibility` (Part 1c) turns the JSON request into SOAP, calls a SOAP mock on Beeceptor, and returns clean JSON.
  - A SOAP Fault becomes a JSON 502 error. Raw fault XML is never returned.
  - Why Beeceptor: no public SOAP service checks loan eligibility, so we defined our own contract, including faults.
  - Mapping: the request and response are both validated against schemas, and amounts become `{amount, currency}` objects, so clients never handle XML.
- `POST /applications` (Bonus B) puts the loan application on an ActiveMQ queue and answers 202 straight away.
- Security: OAuth2.

### All three APIs
- They share one error format: `{ "error", "code", "requestId", "timestamp" }`.
- Bad input returns 400, never 500.
- Logs record the request in, the backend call and the response out, with account numbers and customer IDs masked.

## API Manager

### Security
- API Key for AccountBalanceAPI: a read-only lookup, where a simple key suits server-to-server callers.
- OAuth2 for CustomersAPI and LoansAPI: they return personal data or start a loan process.

### Rate limiting
- Every API offers the Bronze, Silver, Gold and Unlimited subscription tiers.
- CustomersAPI also has a custom tier, `ReqRes`: 250 requests a day for the whole API, shared by all callers, so we never use up the reqres.in quota.

### Gateway policies
- `jamiiHeaderSecurityPolicies` adds browser security and no-cache headers to every response and removes the `Server` header.
- `jamiiBackendErrorPolicy` returns our usual JSON error when the gateway can't reach MI.

### API Product
- `JamiiProducts` (`/product`) groups all five resources, so a client can subscribe once to everything.
- Its customer resources also use the `ReqRes` tier. Otherwise the product would be a way around the limit, so the pipeline checks this.

### How a client discovers and subscribes (Dev Portal, https://localhost:9443/devportal)
1. Find the API or `JamiiProducts`, and read its documentation or use Try Out.
2. Go to Applications and create an application.
3. On the API or product, open Subscriptions, pick the application and a tier, and subscribe.
4. In the application, generate OAuth2 keys, or an API key for AccountBalanceAPI.
5. Call the gateway at `https://localhost:8243/{context}/1.0.0/...` with `Authorization: Bearer <token>` or `ApiKey: <key>`.

## Pipeline (Part 3)

One `Jenkinsfile` builds and deploys all the APIs, so adding an API doesn't change it.

Validate → Build (`mvn clean install`) → Test → Package (`apictl`) → Deploy dev → Deploy uat → Deploy prod

Each deploy updates MI, then API Manager, then runs smoke tests. If anything fails, all changes are rolled back and the build fails, so nothing is ever half-deployed. uat and prod are placeholders.

## Bonus tasks

### A. Customer dashboard
- It gets the customer record, then all their account balances in parallel, and merges them.
- Decision: return partial data. If a balance call fails or times out, the response is still 200, and that account is marked `"status": "UNAVAILABLE"` with the error code.
- If the customer lookup itself fails, the whole request fails (404, 503 or 502), because a dashboard without the customer has nothing meaningful to show.

### B. Loan application queue
- `POST /loans/applications` validates the request, puts a `LoanApplicationSubmitted` event on `LoanApplicationsQueue`, and answers 202.
- The `LoanApplicationConsumer` proxy picks it up, checks eligibility through `/loans/eligibility`, and publishes the result to `LoanDecisionsQueue`.
- Bad events (invalid JSON, schema errors, rejected by the API) go to `LoanApplicationsDLQ` with the reason. Nothing is dropped.
- Temporary failures (API down, slow or returning 5xx) are retried every 60 s, up to 3 times, then sent to the DLQ. 
 - `LoanApplictionsRetryQueue` expires messages to the main `LoanApplicationsQueue` if the number of max_reties are still within threshold.



## Architecture decisions and trade-offs

- One API per domain. The customer lookup and dashboard share `/customers`, and eligibility and applications share `/loans`, giving 3 clear APIs plus a product that covers everything.
- The pipeline deploys over the network only (MI Management API and `apictl`), so it can target any environment listed in `ci/environments/`.
- Each OpenAPI file and policy exists once in the repo and is copied into the packages at build time. `ci/scripts/pull-api.sh` brings changes made in the Publisher back into the repo.
- SQLite keeps the database self-contained (schema and seed load on startup). It can't handle concurrent writers, which is fine for a read-only balance API.
- The ReqRes limit is enforced at the gateway, separately for `/customers` and for the product, so in theory reqres.in could still receive more than 250 calls a day.

## Assumptions

- Account numbers have 13 digits, customer IDs are UUIDs (the reqres.in record IDs), and the currency is KES unless the record says otherwise.
- The reqres.in key in `infra/compose.yaml` is a public key, shared on purpose so reviewers need no setup.
- `admin` / `admin` logins and the built-in databases are fine for a local dev environment only.
- The eligibility rules live in the SOAP backend. MI validates and transforms the data but doesn't decide eligibility.

## With more time
- Write Synapse unit tests. The Test stage runs but has none yet; today's checks are validation and the post-deployment smoke tests.
- Use a real database and a secrets store, change the default logins, and set up uat and prod for real.
- Let the pipeline remove APIs that were deleted from the repo, and support versions other than 1.0.0.
