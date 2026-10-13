<#
.SYNOPSIS
  Puts test loan application events on LoanApplicationsQueue (through ActiveMQ's REST API)
  and shows how many messages ended up on each loan queue.

.EXAMPLE
  .\send-test-events.ps1                 # sends all 4 test events
  .\send-test-events.ps1 valid           # only the valid one
  .\send-test-events.ps1 broken-json     # valid | broken-json | missing-field | api-rejected
  .\send-test-events.ps1 -ShowOnly       # just print the queue counts

  Then look at the messages in the console: http://localhost:8161/admin/queues.jsp (admin / admin)

  To see the retry queue in action, restart MI with an unreachable API URL first:
    $env:LOANS_ELIGIBILITY_URL = 'http://localhost:8299/loans/eligibility'; docker compose up -d mi
  and afterwards put it back:
    Remove-Item Env:LOANS_ELIGIBILITY_URL; docker compose up -d mi
#>
param(
    [Parameter(Position = 0)]
    [ValidateSet('all', 'valid', 'broken-json', 'missing-field', 'api-rejected')]
    [string]$Case = 'all',

    [switch]$ShowOnly,

    [string]$BrokerUrl = 'http://localhost:8161',
    [string]$User = 'admin',
    [string]$Password = 'admin'
)

$ErrorActionPreference = 'Stop'
$auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${User}:${Password}"))
$headers = @{ Authorization = "Basic $auth"; Origin = $BrokerUrl }

function New-Event([string]$eventId, [string]$repaymentMethod = 'MPESA', [switch]$NoKraPin) {
    $customer = [ordered]@{
        reference = 'CIF000123'; firstName = 'Jane'; lastName = 'Wanjiku'; nationalIdLastFour = '5678'
        kraPin = 'A012345678Z'; dateOfBirth = '1990-05-14'; mobileNumber = '+254712345678'; county = 'Nairobi'
    }
    if ($NoKraPin) { $customer.Remove('kraPin') }
    [ordered]@{
        eventId    = $eventId
        eventType  = 'LoanApplicationSubmitted'
        customer   = $customer
        employment = [ordered]@{ type = 'SALARIED'; employer = 'Acme Ltd'; monthsEmployed = 36; grossIncome = 120000; netIncome = 95000 }
        loan       = [ordered]@{ productCode = 'PERSONAL'; amount = 50000; tenorMonths = 12; purpose = 'School fees'
                                 repaymentMethod = $repaymentMethod; existingMonthlyDebt = 5000 }
    } | ConvertTo-Json -Depth 5 -Compress
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$events = [ordered]@{
    # -> LoanDecisionsQueue
    'valid'         = New-Event "evt-$stamp-valid"
    # -> LoanApplicationsDLQ, errorStage=validation (not JSON at all)
    'broken-json'   = '{"eventId":"evt-' + $stamp + '-broken","eventType":"LoanApplicationSubmitted","customer":{"reference":"CIF0'
    # -> LoanApplicationsDLQ, errorStage=validation (fails LoanApplicationEvent.json schema)
    'missing-field' = New-Event "evt-$stamp-missing" -NoKraPin
    # -> LoanApplicationsDLQ, errorStage=api-rejected (passes our schema, LoansEligibilityAPI answers 400)
    'api-rejected'  = New-Event "evt-$stamp-rejected" -repaymentMethod 'CASH'
}

if (-not $ShowOnly) {
    foreach ($name in $events.Keys) {
        if ($Case -ne 'all' -and $Case -ne $name) { continue }
        Invoke-RestMethod -Method Post -Uri "$BrokerUrl/api/message/LoanApplicationsQueue?type=queue" `
            -Headers $headers -ContentType 'text/plain' -Body $events[$name] | Out-Null
        Write-Host "sent $name event" -ForegroundColor Green
    }
    Start-Sleep -Seconds 5   # give MI a moment to process
}

# queue sizes, read through ActiveMQ's Jolokia (JMX over HTTP) API
foreach ($q in 'LoanApplicationsQueue', 'LoanApplicationsRetryQueue', 'LoanApplicationsDLQ', 'LoanDecisionsQueue') {
    $mbean = "org.apache.activemq:type=Broker,brokerName=localhost,destinationType=Queue,destinationName=$q"
    try {
        $size = (Invoke-RestMethod -Uri "$BrokerUrl/api/jolokia/read/$mbean/QueueSize" -Headers $headers).value
    } catch { $size = '-' }
    '{0,-28} {1}' -f $q, $size
}
