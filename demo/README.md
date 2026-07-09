# IntuneOps interactive demo (button-triggered scan)

A single web page with one button. Pressing it runs the real IntuneOps pipeline live in an
HTTP-triggered Azure Function (PowerShell 7) against the mock device fixtures, in dry-run, and
renders the canonical result: the per-device evaluate table, the planned (not applied)
remediation actions, the rendered (not sent) notifications, and the run summary.

This is a portfolio and interview demo surface. It does not replace the production path (Azure
Automation runbook with managed identity, scheduled); it sits beside it. The Function is a thin
wrapper: all compliance, remediation, notification, and report logic stays in the `IntuneOps`
module.

## Layout

```
demo/
  function/                          Azure Function app root (PowerShell 7)
    host.json                        Host config (managed dependencies off; see requirements.psd1)
    requirements.psd1                Graph module pins, deliberately commented out (zero Graph calls)
    local.settings.sample.json      Copy to local.settings.json for func start (git-ignored)
    Stage-FunctionPayload.ps1        Copies the pipeline into the app folder before publish
    RunComplianceScan/
      function.json                  HTTP trigger, route /api/scan, authLevel function
      run.ps1                        Runs the pipeline in mock dry-run, returns the report JSON
  deploy/
    Bootstrap-Demo.ps1               One-time idempotent infra + GitHub OIDC provisioning
  web/                               Static demo page (Cloudflare Pages)
    index.html                       Self-contained page: vanilla HTML/CSS/JS, no build step
    config.sample.js                 Copy to config.js (git-ignored) and set URL + key
```

There are two ways to deploy: the [automated CI/CD pipeline](#cicd-automated-deploy) (recommended:
one push deploys everything) and the manual steps further below (kept as a fallback and to explain
each piece).

## Permanently dry-run (security property, not a default)

The Function is structurally incapable of mutating tenant state:

- `run.ps1` never reads the request. No query parameter, header, or body value influences any
  flag, so there is no code path from the web to `-Execute`.
- The remediation and notification stages are invoked without `-Execute`, which in this module
  means zero state-changing Graph calls by design.
- The device data source is the mock fixtures; no Graph session is ever established and no Graph
  scope is ever requested.

This was verified by calling the endpoint with `?execute=true&Execute=1` and an
`{"execute": true}` body: every outcome stays `DryRun` / `WouldCreateAndAssign` / `Rendered`.

## Response shape

`GET /api/scan` returns `application/json`:

```json
{
  "results":       [ { "DeviceId": "...", "DeviceName": "...", "OwnerUpn": "...", "Platform": "...",
                       "OsVersion": "...", "Checks": [ { "Check": "DiskEncryption|OSVersion|Antivirus",
                       "Status": "Compliant|NonCompliant|Unknown", "Reason": "...", "SignalSource": "...",
                       "Expected": "...", "Actual": "..." } ],
                       "OverallStatus": "Compliant|NonCompliant|Unknown", "Reasons": [ "..." ],
                       "EvaluatedAt": "ISO-8601" } ],
  "remediation":   [ { "Kind": "Automated|Nudge", "Check": "...", "Target": "...", "Mode": "DryRun",
                       "Result": "WouldCreateAndAssign|WouldNudge", "Detail": "...",
                       "AffectedDeviceCount": 1 } ],
  "notifications": [ { "To": "...", "Subject": "...", "ContentType": "Text|HTML", "Mode": "DryRun",
                       "Result": "Rendered", "Device": "..." } ],
  "summary":       { "Counts": { "Total": 4, "Compliant": 1, "NonCompliant": 2, "Unknown": 1 },
                     "Remediation": { "Planned": 2, "Applied": 0, "Simulated": 2, "Skipped": 0, "Failed": 0 },
                     "Notifications": { "Total": 2, "Sent": 0, "Rendered": 2, "Skipped": 0, "Failed": 0 },
                     "RecommendedExitCode": 1, "JsonPath": null, "CsvPath": null },
  "meta":          { "mode": "mock-dry-run", "dataSource": "fixtures", "executed": false,
                     "generatedAtUtc": "ISO-8601", "durationMs": 900 }
}
```

`results`, `remediation`, `notifications`, and `summary` are the pipeline's own canonical objects,
unchanged (the same shapes the CLI writes; `JsonPath`/`CsvPath` are nulled so no server paths
reach the browser). Only the outer wrapper and `meta` are demo additions. On failure the Function
returns 500 with `{ "error": "<safe message>" }` and no stack trace.

## Run it locally, end to end

Prerequisites: PowerShell 7, Azure Functions Core Tools v4, and any static file server.

1. Start the Function (from the repo root):

   ```powershell
   Copy-Item demo/function/local.settings.sample.json demo/function/local.settings.json
   Set-Location demo/function
   func start --port 7071
   ```

   Locally, `run.ps1` finds the pipeline through the repo checkout; no staging needed. Smoke-test
   it: `Invoke-RestMethod http://localhost:7071/api/scan` (no key needed locally).

2. Serve the page (second terminal, from the repo root):

   ```powershell
   Copy-Item demo/web/config.sample.js demo/web/config.js   # defaults already point at localhost
   python -m http.server 8788 --directory demo/web
   ```

   Open http://localhost:8788 and press the button. The sample `local.settings.json` already
   allows the `localhost:8788` origin through local CORS.

## CI/CD (automated deploy)

`.github/workflows/deploy.yml` deploys the whole demo on push. Three jobs:

- `test`: runs the Pester suite (mock and pure-logic tests, no Graph SDK) and PSScriptAnalyzer
  (fails on error-level findings only). Runs on every push and pull request.
- `deploy-function`: signs in to Azure with OIDC, stages the payload
  (`Stage-FunctionPayload.ps1`), and publishes the Function App. Skipped on pull requests.
- `deploy-web`: signs in to Azure, reads the live function key, writes `demo/web/config.js` from
  it (the key is masked in the logs), and deploys the page to Cloudflare Pages. Skipped on pull
  requests.

Azure authentication is OIDC (a federated service principal), so no Azure password is stored in
GitHub. The function key is fetched live at deploy time, so there is no function-key secret to
hand-manage either.

### One-time setup

1. Provision the Azure infra and the OIDC identity (idempotent, safe to re-run):

   ```powershell
   az login
   ./demo/deploy/Bootstrap-Demo.ps1 -AppName intuneops-demo -StorageAccount <globally-unique-name> -GitHubRepo <owner>/<repo>
   ```

   This creates the resource group, storage account, and Function App (PowerShell 7.4,
   Consumption, Functions v4), allows the Cloudflare Pages origin through CORS, creates the app
   registration + federated credential GitHub signs in with, and prints the Azure secret values.
   It does not deploy anything; the pipeline does that on its first run.

2. Push the repository to GitHub (it has no remote yet):

   ```powershell
   git init            # only if needed
   git add -A
   git commit -m "IntuneOps"
   git remote add origin https://github.com/<owner>/<repo>.git
   git push -u origin master
   ```

3. Set five repository secrets (Settings, Secrets and variables, Actions):

   | Secret | Source |
   | ------ | ------ |
   | `AZURE_CLIENT_ID` | printed by the bootstrap script |
   | `AZURE_TENANT_ID` | printed by the bootstrap script |
   | `AZURE_SUBSCRIPTION_ID` | printed by the bootstrap script |
   | `CLOUDFLARE_API_TOKEN` | Cloudflare token with **Account, Cloudflare Pages: Edit** and **Account Settings: Read** |
   | `CLOUDFLARE_ACCOUNT_ID` | Cloudflare dashboard (never commit it; supply it only as this secret) |

4. Push to the deploy branch (or run the workflow manually). All three jobs go green, the Function
   is live, and the page is published.

5. After the first web deploy, purge the Cloudflare cache and warm the Function once (see the
   cache and cold-start notes below).

### Branch consistency

One branch name must agree in three places: the `push` trigger in `deploy.yml`, the OIDC
federated-credential subject created by the bootstrap (`-Branch`), and the repository's real
default branch. This project uses `master`: the workflow trigger, `DEPLOY_BRANCH`, and the
bootstrap `-Branch` default all target `master`, matching the repo's existing branch. If you ever
move to a different default branch, change it in all three places at once. The bootstrap prints a
warning if the branch it is about to pin does not match the checked-out branch.

### Troubleshooting

- **`deploy-web` failed but `deploy-function` succeeded.** The Function is live but the page is
  stale. On the Actions run page choose "Re-run failed jobs" to re-run only `deploy-web`; do not
  re-run the whole workflow, which would redeploy the Function needlessly.
- **The button stopped working after a key rotation.** `deploy-web` bakes the live function key
  into the client-visible `config.js` on every web deploy. If you rotate the function key in
  Azure, the deployed page keeps the old key until you re-run `deploy-web` to regenerate
  `config.js`. This is the same client-visible-key trade-off described below, now automated.
- **`AADSTS70021` / no matching federated identity record.** The branch the workflow ran on does
  not match the federated-credential subject. Line them up (see Branch consistency).

## Deploy the Function to Azure (manual alternative)

1. Create a Function App (consumption plan, PowerShell 7.4 runtime, Windows), for example:

   ```powershell
   az functionapp create --resource-group <rg> --consumption-plan-location <region> `
     --runtime powershell --runtime-version 7.4 --functions-version 4 `
     --name <app-name> --storage-account <storage-account>
   ```

2. Stage the pipeline payload and publish (the app must be self-contained; the staged copy is
   git-ignored, so re-run this after every pipeline change):

   ```powershell
   pwsh demo/function/Stage-FunctionPayload.ps1
   Set-Location demo/function
   func azure functionapp publish <app-name>
   ```

3. Get the function key: Azure portal, Function App, Functions, `RunComplianceScan`, Function
   Keys (or `az functionapp function keys list --resource-group <rg> --name <app-name>
   --function-name RunComplianceScan`).

4. Configure CORS for the page origins (see next section).

Cost note: on the consumption plan this idles at effectively zero and each click is one short
execution.

## CORS

The browser page calls the Function cross-origin, so the Function must allow the page's exact
origins. This is the single most common failure mode of this setup.

- Local: handled by `Host.CORS` in `local.settings.json` (the sample allows
  `http://localhost:8788` and `http://127.0.0.1:8788`).
- Deployed: CORS for a deployed Function is set on the platform, not in `host.json`. Allow both
  the production custom domain and the Cloudflare Pages preview origin, and nothing else. Do not
  use a wildcard `*` origin in production.

  ```powershell
  az functionapp cors add --resource-group <rg> --name <app-name> `
    --allowed-origins https://<your-custom-domain> https://<your-project>.pages.dev
  ```

  Portal equivalent: Function App, API, CORS, add the two origins, Save.

Troubleshooting: if the page shows a network error and the browser console says something like
"blocked by CORS policy: No 'Access-Control-Allow-Origin' header", the calling origin is not in
the allowed list. Add the exact scheme plus host you are browsing from (preview deployments on
`*.pages.dev` subdomains each have their own origin; `https://<project>.pages.dev` covers the
production Pages origin only).

## Deploy the page to Cloudflare Pages

The page is dependency-free with no build step, so deployment is a direct upload of `demo/web/`:

```powershell
Copy-Item demo/web/config.sample.js demo/web/config.js
# edit demo/web/config.js: set functionUrl and functionKey to the deployed values
wrangler pages deploy demo/web --project-name <project>
```

`config.js` is git-ignored but IS uploaded by the deploy (Pages ships the folder contents, not
the git tree), which is exactly the intent: the key lives in the deployed page, not in the repo.

### Cloudflare cache purge (do this after every deploy)

The custom domain can keep serving stale HTML/JS after a Pages deploy until the cache is purged:

1. Cloudflare dashboard, your zone, Caching, Configuration, Purge Everything (or purge the
   specific URLs `index.html` and `config.js`).
2. Verify in a private/incognito window (a normal window can still show your browser's own cached
   copy even after the edge purge).

### Cold-start warm-up (before a live demo)

The first execution after idle takes several seconds on the consumption plan (PowerShell worker
start plus module import; subsequent clicks are fast because the module stays loaded). Before a
screen-share, hit the Function URL once (browser tab or `Invoke-RestMethod`) so the on-camera
click is snappy. The page's loading state covers a cold start honestly if you skip this.

## The function-key trade-off (read this)

The page sends the function key as the `code` query parameter, so the key is visible to anyone
who views the page source or the network tab. That is an accepted, deliberate trade-off for a
portfolio demo, and it is only acceptable here because the Function is read-only by construction:
it runs on mock data, in permanent dry-run, with no Graph access and no secrets to leak. The
worst an abuser can do is run a deterministic mock scan on the consumption plan.

Do not carry this pattern to anything real. The real fixes, in preference order:

1. Put the Function behind Easy Auth (App Service Authentication) so callers sign in, or
2. Keep the key server-side: a tiny proxy (for example a Cloudflare Pages Function) reads the key
   from Key Vault or an environment binding and forwards the request, with the Azure Function
   locked to that caller (managed identity between the pieces).

Housekeeping for the demo as-is: keep the key out of git (`config.js` is ignored), and rotate the
function key in the portal if it ever leaks somewhere more durable than the page it is meant to
be on.

## Values to set at deploy time

| Value | Where it goes | Where to get it |
| ------- | --------------- | ----------------- |
| Function URL (`https://<app>.azurewebsites.net/api/scan`) | `demo/web/config.js` (`functionUrl`) | Output of `func azure functionapp publish`, or the portal |
| Function key | `demo/web/config.js` (`functionKey`) | Portal: Function App, Functions, RunComplianceScan, Function Keys |
| CORS origins (custom domain + `<project>.pages.dev`) | Function App CORS (portal or `az functionapp cors add`) | Your Pages project settings |
