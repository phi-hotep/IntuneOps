# IntuneOps: Architecture and Build Plan

Status: PROPOSED (awaiting approval). No implementation logic is written yet. This document
plus the README skeleton and the stubbed repo tree are the only deliverables at this stage.

## 1. What this is

IntuneOps is a PowerShell 7 automation workflow that queries Intune-managed devices via
Microsoft Graph, evaluates each device against data-driven compliance rules (disk
encryption, OS version, antivirus health), decides on a remediation path (automated Intune
proactive remediation or nudge-only), notifies end users through Graph Mail, and writes a
structured run report. It runs interactively for local development and unattended as an
Azure Automation runbook.

Design tenets:
- Read-first, write-gated. Nothing mutates tenant state without an explicit `-Execute` flag.
- Data-driven. Thresholds and rule-to-action mappings live in config, not in code.
- Auth-path abstraction. One code path, two auth strategies (interactive/device-code for
  dev, app-only/managed-identity for Automation).
- Degrade gracefully. The free dev tenant may not surface every signal (antivirus state is
  the usual gap). Missing signals are flagged as `Unknown` / simulated, never silently
  treated as pass or fail.

## 2. Module breakdown

The reusable logic lives in a single module, `IntuneOps` (Public/Private function split).
Thin entrypoints (local scripts and the Automation runbook) only parse parameters, call the
module, and set exit codes.

### Module: `src/IntuneOps`

Public (exported) functions, one per pipeline stage:

| Function | Responsibility | Phase |
|----------|----------------|-------|
| `Connect-IntuneOps` | Resolve and establish a Graph session for the selected auth path. Returns a context object; does not hold global state beyond the SDK session. | 1 |
| `Get-IntuneOpsDevice` | Query managed devices, normalize the raw Graph objects into a flat device model (deviceId, name, owner UPN, platform, OS version, encryption state, AV state, source-of-signal flags). | 1 |
| `Test-IntuneOpsCompliance` | Evaluate a device model against the loaded rules; emit a normalized compliance result object (per-check status + reasons + overall status). Pure/deterministic: no Graph calls, so it is unit-testable. | 1 |
| `Invoke-IntuneOpsRemediation` | Given non-compliant results, select the per-rule action (automated vs nudge) and either dry-run-log or execute. Honors `-Execute`; off by default. | 2 |
| `Send-IntuneOpsNotification` | Render the email template for a device's failing checks and send via Graph Mail, or in dry-run render-and-log only. | 3 |
| `Write-IntuneOpsReport` | Aggregate the run into console output, a JSON/CSV artifact, and the run log; return a summary object and drive the exit code. | 3 |

Private (internal) helpers:

| Function | Responsibility |
|----------|----------------|
| `Resolve-IntuneOpsAuth` | Decide auth strategy from settings/environment (Interactive, DeviceCode, ManagedIdentity, AppSecret, AppCertificate) and build the `Connect-MgGraph` splat. Never logs secrets. |
| `Get-IntuneOpsConfig` | Load and validate `compliance-rules.json` and `settings.psd1`; apply defaults; fail fast on schema errors. |
| `Write-IntuneOpsLog` | Structured logging to console (with severity) and to a run log file. Single sink used everywhere. |
| `Test-DiskEncryption` | One compliance check: interpret encryption signal per platform, return status + reason + signal source. |
| `Test-OSVersion` | One compliance check: compare device OS version to the configured per-platform minimum. |
| `Test-Antivirus` | One compliance check: interpret AV/Defender health signal; return `Unknown` (flagged) when the tenant does not surface it. |
| `ConvertTo-IntuneOpsDeviceModel` | Map raw Graph `managedDevice` (+ protection state) to the normalized model. |
| `Format-IntuneOpsNotification` | Render the notification subject and body (text or HTML) from the templates for a device's failing checks. (Recipient resolution folded into the notification function via the result's owner UPN, so a separate mail-lookup helper was not needed.) |

Rationale for the check-per-function split: each compliance rule is independently testable
with Pester using synthetic device models, and adding a new check is a new Private function
plus a rules entry, not a rewrite.

### Entrypoints

- `scripts/Invoke-ComplianceScan.ps1`: local dev entrypoint. Parameters: `-ConfigPath`,
  `-Execute` (default off), `-NotifyUsers` (default off), `-Platform` filter, `-LogPath`.
- `runbooks/Start-IntuneOpsRunbook.ps1`: Azure Automation entrypoint. Reads Automation
  variables/credentials, forces the managed-identity/app-only auth path, and always writes a
  report artifact. Same module, no interactive prompts.

## 3. Data flow

```
                +----------------------+
                |  compliance-rules.*  |  settings.psd1 / env / Automation vars
                +----------+-----------+
                           |
        (1) Connect        v
   Connect-IntuneOps --> Graph session (auth path abstracted)
                           |
        (2) Query          v
   Get-IntuneOpsDevice --> [ normalized device model[] ]
                           |   (deviceId, name, ownerUPN, platform,
                           |    osVersion, encryption, av, signalSource)
        (3) Evaluate       v
   Test-IntuneOpsCompliance --> [ compliance result[] ]
                           |   (per-check status + reasons, overall status)
             +-------------+-------------+
             |                           |
   compliant |                 non-compliant
             |                           |
             v          (4) Decide       v
        (report only)   Invoke-IntuneOpsRemediation
                           |  per-rule action:
                           |   - automated (Intune proactive remediation script)
                           |   - nudge-only
                           |  DRY-RUN by default; -Execute to act
                           v
        (5) Notify   Send-IntuneOpsNotification (Graph Mail; dry-run renders only)
                           |
        (6) Log/Report     v
        Write-IntuneOpsReport --> console + run log file + JSON/CSV artifact + exit code
```

Stages 1-3 are read-only. Stages 4-5 are the only state-changing stages and are gated by
`-Execute`. Stage 6 always runs.

## 4. Graph permission scopes (least privilege)

Scopes are requested per phase. Read scopes first; write scopes only arrive with the
remediation phase. For app-only (Automation), these are Application permissions with admin
consent; for interactive dev, the same names are requested as delegated scopes.

### Phase 1: read-only

| Scope | Type | Why it is needed | Why not less |
|-------|------|------------------|--------------|
| `DeviceManagementManagedDevices.Read.All` | Read | List managed devices and read their compliance-relevant properties (OS version, `isEncrypted`, ownership, and the `windowsProtectionState` / Defender signal). | Core of the whole tool. There is no narrower device-read scope in Graph. |
| `DeviceManagementConfiguration.Read.All` | Read | Read existing compliance policies / device health scripts to correlate and to detect whether a remediation script already exists (idempotency in Phase 2). | Optional for Phase 1; requested read-only here so Phase 2 needs only an upgrade to ReadWrite. |

Owner email is taken from the device object's `userPrincipalName` / `emailAddress` fields, so
`User.Read.All` / `Directory.Read.All` are deliberately NOT requested in Phase 1. If a future
requirement needs richer user attributes, `User.Read.All` (read) would be the minimal add.

### Phase 2: remediation (write, gated)

| Scope | Type | Why it is needed | Least-privilege note |
|-------|------|------------------|----------------------|
| `DeviceManagementConfiguration.ReadWrite.All` | Write | Create and assign Intune proactive remediation scripts (`deviceHealthScripts`) and their assignments. | This is the minimum scope that covers deviceHealthScripts create/assign; there is no per-object scope. Only requested when `-Execute` remediation is intended. |

**Scoped out for v1 (decision):** `DeviceManagementManagedDevices.PrivilegedOperations.All` is
deliberately NOT requested. Remediation in v1 is **assignment-only**: we create and assign the
proactive remediation script and let Intune run it on its cycle. On-demand triggering (forcing
an immediate run) would require this privileged scope, so it is scoped out on least-privilege
grounds and documented in the README as a named future extension.

### Phase 3: notifications

| Scope | Type | Why it is needed | Least-privilege note |
|-------|------|------------------|----------------------|
| `Mail.Send` | Write | Send compliance-nudge emails via Graph Mail. | For app-only this is an Application permission that grants send-as-anyone by default; we constrain it with an **Application Access Policy** scoped to a single sender mailbox (documented in README). Delegated dev sends only as the signed-in user. |

Every scope, its justification, and the consent steps are mirrored in the README so a reader
can reproduce consent without reading the code.

## 5. Secrets-handling strategy

Non-negotiable: nothing sensitive is ever committed. The repo ships templates only.

- **Local dev**: prefer interactive / device-code auth (no stored secret). Where an app
  registration is used locally, its tenant id / client id come from environment variables
  loaded from a git-ignored `.env` (template: `.env.example`). A client secret is never the
  default local path; certificate-based auth is documented as the preferred non-interactive
  local option.
- **Unattended (Azure Automation)**: primary path is a **system-assigned managed identity** on
  the Automation account (no secret material at all). Graph access for a managed identity is
  granted by assigning Graph **app roles** (application permissions) to the identity's service
  principal, since a managed identity cannot be admin-consented through the usual app
  registration UI. The exact `New-MgServicePrincipalAppRoleAssignment` step (grant
  `DeviceManagementManagedDevices.Read.All` etc. to the MI's service principal) is documented in
  the README. Fallback path, documented but not primary, is an app registration whose
  certificate/secret lives in **Azure Key Vault**, referenced through an Automation
  variable/credential; the runbook reads it at runtime and never writes it to logs.
- **Config vs secrets separation**: `settings.psd1` and `compliance-rules.json` hold only
  non-sensitive configuration (thresholds, sender mailbox address, auth *mode* selector). All
  identifiers and secrets come from environment / Automation variables / Key Vault, resolved
  by `Resolve-IntuneOpsAuth`.
- **Logging discipline**: `Write-IntuneOpsLog` never receives secret material; auth objects are
  passed by reference and never serialized to the run log.
- **Repo hygiene**: `.gitignore` excludes `.env`, `*.secret.*`, certificate files
  (`*.pfx`, `*.pem`, `*.cer`, `*.key`), local logs, and any `*.local.*` overrides. A
  `.env.example` and a `settings.example.psd1` document every expected key with placeholder
  values.

## 6. Ordered build plan (three phases)

Pause for sign-off at each phase boundary.

### Phase 1: Auth + device query + compliance evaluation
1. Module scaffold wired up (manifest, loader, Public/Private dot-sourcing).
2. `Resolve-IntuneOpsAuth` + `Connect-IntuneOps`: interactive/device-code and app-only paths;
   scope set limited to the Phase 1 read scopes.
3. `Get-IntuneOpsConfig`: load + validate `compliance-rules.json` and `settings.psd1`.
4. `Get-IntuneOpsDevice` + `ConvertTo-IntuneOpsDeviceModel`: query and normalize; flag signal
   source (real vs unknown/simulated).
5. `Test-DiskEncryption`, `Test-OSVersion`, `Test-Antivirus`, and `Test-IntuneOpsCompliance`
   orchestration; normalized result object.
6. Pester tests for the three checks and the orchestrator using synthetic device models.
7. `Invoke-ComplianceScan.ps1` local entrypoint producing a read-only compliance report.
   Deliverable: a working read-only scan with a redacted sample report. **Sign-off gate.**

### Phase 2: Remediation engine
1. Rules gain a per-rule `action` (`Automated` | `Nudge`) and an optional script reference.
2. `Invoke-IntuneOpsRemediation`: dry-run by default; `-Execute` gate; idempotent create/assign
   of `deviceHealthScripts` (detect existing before creating).
3. Sample detection + remediation scripts (BitLocker example) under `config/remediation-scripts`.
4. Scope upgrade to `DeviceManagementConfiguration.ReadWrite.All` only (assignment-only;
   privileged on-demand trigger scope deliberately not requested, see §4).
5. Pester tests for action selection and the dry-run/execute branch (Graph calls mocked).
   Deliverable: dry-run remediation log + gated execute path. **Sign-off gate.**

### Phase 3: Notifications + reporting
1. `Send-IntuneOpsNotification`: text + optional HTML template; dry-run renders and logs only;
   `Mail.Send` + Application Access Policy for app-only.
2. `Write-IntuneOpsReport`: console summary + run log file + JSON + CSV artifacts + exit codes.
   One canonical result object is the single source of truth: it is serialized to JSON, and the
   CSV is a flat projection of that same object (no second schema maintained).
3. `Start-IntuneOpsRunbook.ps1`: Azure Automation entrypoint (managed identity, no prompts).
4. End-to-end dry-run walkthrough documented in README with redacted sample output.
   Deliverable: full pipeline, local + runbook, documented. **Sign-off gate.**

## 7. Exit codes (for Automation)

| Code | Meaning |
|------|---------|
| 0 | Run completed; all evaluated devices compliant (or dry-run completed cleanly). |
| 1 | Run completed; one or more devices non-compliant (informational, not an error). |
| 2 | Partial failure: some devices/signals could not be evaluated. |
| 3 | Fatal: auth or config failure; nothing evaluated. |

Final code chosen by `Write-IntuneOpsReport`. Non-compliance is a signal, not a crash.

## 8. Decisions (resolved)

1. **Automation auth**: system-assigned **managed identity** is the primary, secretless path.
   Graph access granted via app-role assignments to the MI service principal (documented). App
   registration + Key Vault remains documented as the fallback, not primary. (See §5.)
2. **Remediation trigger**: **assignment-only** for v1. The privileged on-demand trigger scope
   (`DeviceManagementManagedDevices.PrivilegedOperations.All`) is not requested; on-demand
   triggering is a named future extension. (See §4 Phase 2.)
3. **Reports**: JSON + CSV, from **one canonical result object**. JSON is the direct
   serialization; CSV is a flat projection of the same object. No duplicate schema. (See §6
   Phase 3.)
