# Bonus B - Message Queue Integration: Loan Application Events

Customers or channels submit loan applications to **LoanApplicationAPI** (published on APIM).
The API validates each request, puts it on an ActiveMQ queue as an event, and answers **202 Accepted**
straight away. A WSO2 Micro Integrator proxy, `LoanApplicationConsumer`, reads the events from the
queue. It transforms each event into a request for the Part 1 **LoansEligibilityAPI**, calls the
API, and publishes the decision to an output queue. Messages that fail are never dropped. If the
problem might go away by itself, the message is retried later. If not, it goes to a dead-letter
queue with the reason attached.

## Flow

```
Client ──► APIM gateway ──► LoanApplicationAPI (POST /applications/loan-applications)
                              │ validate request (JSON schema)   ── invalid ──► 400 / 415 to the caller
                              │ wrap as LoanApplicationSubmitted event, publish  ── broker down ──► 503
                              └─► 202 { applicationId, status: RECEIVED }
                                        │
LoanApplicationsQueue ◄─────────────────┘   (other systems can publish here directly too)
        │
        ▼
LoanApplicationConsumer (MI JMS proxy)
                              │ 1. parse + validate the event (JSON schema)   ── invalid ──────────► LoanApplicationsDLQ
                              │ 2. transform: short flat event -> LoansEligibilityAPI request
                              │ 3. POST /loans/eligibility (Part 1 API)
                              ├── 200            ──► LoanDecisionsQueue  (LoanEligibilityDecided event)
                              ├── 4xx            ──► LoanApplicationsDLQ (the API rejected the data)
                              └── 5xx / no reply ──► LoanApplicationsRetryQueue (TTL 60s)
                                                       └─ TTL expires -> ActiveMQ moves it back to LoanApplicationsQueue
                                                       └─ after 3 retries -> LoanApplicationsDLQ
```

| Queue | Contents |
|---|---|
| `LoanApplicationsQueue` | Input. `LoanApplicationSubmitted` events |
| `LoanApplicationsRetryQueue` | Events waiting about 60s before another attempt. Nothing consumes this queue. |
| `LoanApplicationsDLQ` | Events that cannot be processed. The original body is kept and the reason is in JMS properties. |
| `LoanDecisionsQueue` | Output. `LoanEligibilityDecided` events |

## Messages

**API request (`POST /applications/loan-applications`)**: the application without any event fields:
```json
{
  "customer":   { "reference": "CIF000123", "firstName": "Jane", "lastName": "Wanjiku", "nationalIdLastFour": "5678",
                  "kraPin": "A012345678Z", "dateOfBirth": "1990-05-14", "mobileNumber": "+254712345678", "county": "Nairobi" },
  "employment": { "type": "SALARIED", "employer": "Acme Ltd", "monthsEmployed": 36, "grossIncome": 120000, "netIncome": 95000 },
  "loan":       { "productCode": "PERSONAL", "amount": 50000, "tenorMonths": 12, "purpose": "School fees",
                  "repaymentMethod": "MPESA", "existingMonthlyDebt": 5000 }
}
```
The API's schema (`LoanApplicationRequest.json`) is stricter than the event schema: `employment.type`
and `repaymentMethod` must be one of the values LoansEligibilityAPI accepts. That way a caller gets a
400 straight away, and the DLQ is left for problems the API can't catch.

**API response (202 Accepted)**: the `applicationId` is the correlation ID. It is also the event's
`eventId`, so it can be traced through the queue, the consumer and LoansEligibilityAPI:
```json
{"applicationId":"78821580-948b-4c75-8257-e18bfedeab9e","status":"RECEIVED",
 "message":"Loan application received. Eligibility will be checked shortly.","timestamp":"2026-10-13T17:33:48.585Z"}
```
Other responses: 400 (invalid JSON or a field fails validation, with `details`), 415 (not JSON),
405 (not POST), 503 (broker unavailable, so nothing was queued).

**Event (`LoanApplicationsQueue`)**: the API adds `eventId`, `eventType` and `submittedAt`. Other
systems can publish the same short, flat event directly:
```json
{
  "eventId": "evt-20261013-0001",
  "eventType": "LoanApplicationSubmitted",
  "customer": { "reference": "CIF000123", "firstName": "Jane", "lastName": "Wanjiku",
                "nationalIdLastFour": "5678", "kraPin": "A012345678Z", "dateOfBirth": "1990-05-14",
                "mobileNumber": "+254712345678", "county": "Nairobi" },
  "employment": { "type": "SALARIED", "employer": "Acme Ltd", "monthsEmployed": 36,
                  "grossIncome": 120000, "netIncome": 95000 },
  "loan": { "productCode": "PERSONAL", "amount": 50000, "tenorMonths": 12,
            "purpose": "School fees", "repaymentMethod": "MPESA", "existingMonthlyDebt": 5000 }
}
```

**Transformation:** the event is reshaped into the nested LoansEligibilityAPI request (`applicant`,
`employmentDetails`, `loanRequest`, ...). Fields the event doesn't carry get defaults: currency `KES`,
`channelId: QUEUE`, `residencyStatus: RESIDENT`, `incomeVerified: false`, no other debts, and
`consentToCreditAssessment: true`. The `eventId` becomes the correlation ID and is sent to the API as
`X-Correlation-ID`, so a single ID appears in the log lines of both the consumer and the API.

**Output (`LoanDecisionsQueue`)**
```json
{"eventId":"evt-20261013-0001","eventType":"LoanEligibilityDecided","customerReference":"CIF000123",
 "status":"ELIGIBLE","riskBand":"Low","indicativeAmount":45000,"currency":"KES",
 "monthlyInstalment":4200,"tenorMonths":12,"decidedAt":"2026-10-13T17:05:42.898Z"}
```

**Dead letter (`LoanApplicationsDLQ`)**: the body is the original message, byte for byte, so it can be
fixed and replayed from the ActiveMQ console. These JMS properties describe the failure:

| Property | Example |
|---|---|
| `errorStage` | `validation`, `api-rejected`, `retries-exhausted`, `processing-error` |
| `errorReason` | `Event failed schema validation: object has missing required properties (["kraPin"])` |
| `retryCount` | `3` |
| `failedAt` | `2026-10-13T17:12:14.180Z` |
| `correlationId` | the `eventId`, or the JMS message ID if the body couldn't be read |

## How failures are handled

| What happens | Example | Where it goes | Why |
|---|---|---|---|
| Body is not JSON | truncated message | DLQ (`validation`) | It will never parse, so retrying can't help |
| JSON but wrong shape | missing `kraPin` | DLQ (`validation`) | Same as above |
| API answers 4xx | `repaymentMethod: "CASH"` → 400 | DLQ (`api-rejected`) | The data itself is wrong, so the same message would fail again |
| API answers 5xx, times out or is unreachable | backend down | Retry queue, then DLQ after 3 tries (`retries-exhausted`) | Likely temporary. Waiting gives it time to recover. |
| Anything unexpected | mediation error | DLQ (`processing-error`) | Keep the message so a person can look at it |

To keep a malformed message from crashing the consumer before a copy is saved, the queue is always read
as **plain text**. The consumer saves the raw text first, then tries to parse it. A message that can't be
read as JSON is therefore still forwarded to the DLQ unchanged.

**Delayed retry.** ActiveMQ dead-letters expired messages. For `LoanApplicationsRetryQueue` only,
`infra/activemq/jamii-activemq.xml` sets the dead-letter destination to the main queue. When MI puts a
message on the retry queue with a 60s time-to-live, ActiveMQ moves it back to `LoanApplicationsQueue`
once the time is up. The broker checks for expired messages every 5s, so the delay in practice is
60-65s. The attempt number is carried in a `retryCount` JMS property, and MI sends the message to the
DLQ once it reaches the limit.

Settings (env vars on the MI container, defaults in `infra/compose.yaml`):

| Setting | Default | Meaning |
|---|---|---|
| `loan_max_retries` | `3` | Number of delayed retries before giving up |
| `loan_retry_ttl_ms` | `60000` | Wait time between attempts |
| `loans_eligibility_url` | `http://localhost:8290/loans/eligibility` | The API that gets called |

## How this differs from the request/response APIs

The design uses both styles. **LoanApplicationAPI** is request/response: it fails fast and tells the
caller what went wrong (400, 415, or 503 if the broker is down, in which case the caller retries).
Once it answers 202 the message is safe in the broker, and **everything after that is the queue's
job**.

**Who handles the error.** In the request/response APIs a client is waiting on the connection. The API
fails fast with a status code (400 for bad input, 502/503/504 when the backend fails) and the
**client** decides whether to retry. Nothing is stored, and if the client gives up the request is gone.
On the queue nobody is waiting, so the **integration itself** is responsible for every message from
start to finish. It cannot "return an error" to anyone. It has to decide what to do with the message.

**Retries.** A request/response API can't wait a minute and try again: the client would time out.
So retries there are immediate and short, or left to the client. A queue consumer can wait as long as
it needs to. The retry queue spaces attempts 60s apart without blocking anything, and the message stays
safe in the broker in the meantime, even if MI restarts.

**Sorting errors.** Request/response errors are reported back as status codes. On the queue, every
error must be classified as either **temporary** (retry later) or **permanent** (DLQ). Getting this
wrong has a cost. Retrying a permanent error wastes calls and delays other messages. Sending a temporary
error to the DLQ loses a message that would have succeeded a minute later.

**Limits.** A request/response retry ends when the client gives up. A queue retry has no natural end,
so an explicit **maximum retry count** is needed. Without one, a "poison message" would loop forever.

**What a queue retry implies.** Because a message can be processed more than once (retries, broker
redelivery), consumers of `LoanDecisionsQueue` should treat `eventId` as an idempotency key and ignore
duplicates.

## Running it

```powershell
cd infra
docker compose up -d                        # ActiveMQ + MI (+ APIM)
.\activemq\send-test-events.ps1             # sends valid, broken-json, missing-field, api-rejected
```
Results are visible in the ActiveMQ console at http://localhost:8161/admin/queues.jsp (admin / admin)
and in the MI logs (`docker compose logs -f mi`).

Or go through the API. You can call MI directly or the APIM gateway with a token from the Dev Portal
(application → subscribe to LoanApplicationAPI → generate keys):
```powershell
curl.exe -i -X POST http://localhost:8290/applications/loan-applications -H "Content-Type: application/json" -d '<request body above>'
curl.exe -k -i -X POST https://localhost:8243/applications/1.0.0/loan-applications -H "Authorization: Bearer <token>" -H "Content-Type: application/json" -d '<request body above>'
```

To see retries, restart MI with an API URL that doesn't work, then send a valid event:
```powershell
$env:LOANS_ELIGIBILITY_URL = 'http://localhost:8299/loans/eligibility'; docker compose up -d mi
.\activemq\send-test-events.ps1 valid      # retry 1, 2, 3 about 60s apart, then DLQ (retries-exhausted)
Remove-Item Env:LOANS_ELIGIBILITY_URL; docker compose up -d mi   # back to normal
```
If MI is restarted with the correct URL *while* a message is waiting in the retry queue, the next
attempt succeeds and the decision is published. This is the recovery case.

## Files

| File | Purpose |
|---|---|
| `Jamii_WSO2_Project/src/main/wso2mi/artifacts/apis/LoanApplicationAPI.xml` | The entry API: validate, publish to the queue, 202 |
| `.../resources/schemas/LoanApplicationRequest.json`, `.../api-definitions/LoanApplicationAPI.yaml` | API request schema and OpenAPI definition |
| `Jamii_WSO2_Project/apim-apis/LoanApplicationAPI/` | APIM project (deployed by the pipeline like the other APIs) |
| `Jamii_WSO2_Project/src/main/wso2mi/artifacts/proxy-services/LoanApplicationConsumer.xml` | The consumer: parse, validate, transform, call, route |
| `.../sequences/LoanApplicationRetrySeq.xml` | Retry queue or DLQ, based on `retryCount` |
| `.../sequences/LoanApplicationDLQSeq.xml` | Sends the original message plus error properties to the DLQ |
| `.../endpoints/LoansEligibilityInternalEP.xml` | HTTP endpoint for LoansEligibilityAPI |
| `.../endpoints/Loan*QueueEP.xml`, `LoanApplicationsDLQEP.xml` | JMS endpoints for the 4 queues |
| `.../resources/schemas/LoanApplicationEvent.json` | Input event schema |
| `infra/activemq/jamii-activemq.xml` | Broker config with the retry-queue expiry rule |
| `infra/activemq/send-test-events.ps1` | Test event sender |
