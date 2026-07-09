# Limitations and validation approach

This document states plainly what IntuneOps was validated against, why, and what that does and
does not limit. Short version: the only mocked component is the source of managed-device data.
Everything else, from auth resolution to scope composition to the write-gated remediation and
notification stages, is the same code that runs against a live tenant.

## Why a mocked Graph surface

IntuneOps was developed and validated against a mocked Microsoft Graph surface: device payloads
that match the documented `deviceManagement/managedDevices` schema, stored as JSON fixtures in
this repository. This mirrors standard engineering practice, where automation logic is proven
against fixtures before it is ever pointed at live tenant state. It also reflects a deliberate
decision to avoid a paid licensing commitment for a portfolio project:

- The Microsoft 365 Developer Program, which used to provide a free sandbox tenant, now requires
  Visual Studio Enterprise eligibility.
- The admin-centre marketplace and the enterprise signup paths offer only paid E5/EMS plans or a
  Contact Sales route.
- The official 30-day Intune trial requires a payment card for verification, provisions a
  separate new tenant that cannot merge with an existing work account, and expires after 30 days.

Rather than take on a paid commitment for demo data, the project makes offline, mock-driven
validation a first-class mode alongside the live path. The auth abstraction and the dry-run /
`-Execute` gating mean the same code runs unchanged against a live tenant when one is available.

## What is mocked, and what is not

| Component | Mocked? | Notes |
| ----------- | --------- | ------- |
| Managed-device data (`Get-IntuneOpsDevice`) | Yes, opt-in | `-GraphDataSourceMock` reads `tests/fixtures/managedDevices/managedDevices.mock.json` instead of querying Graph. The live query path is untouched and remains the default. |
| Device model normalization | No | `ConvertTo-IntuneOpsDeviceModel` processes fixture objects and live Graph objects through the identical code. |
| Compliance evaluation | No | `Test-IntuneOpsCompliance` is pure logic with no Graph dependency in either mode. |
| Remediation planning and execution | No | The planner is pure; the execute path makes real Graph writes and is exercised in tests with mocked Graph calls. |
| Notification rendering and send | No | Rendering is pure; the send path is a real Graph Mail call, gated by `-Execute`. |
| Reporting and exit codes | No | Identical in both modes. |
| Authentication | No | The connect step is never faked. In a mock dry-run no stage calls Graph, so no session is established and no scope is requested. With `-Execute`, mock mode still signs in for real (device-code, using the `INTUNEOPS_TENANT_ID` environment variable) because remediation and mail send are live writes either way. |

The fixtures cover one fully compliant Windows device, one unencrypted Windows device (the
automated remediation path), one macOS device below the minimum OS version (the nudge path), and
one Windows device with no `windowsProtectionState` (the antivirus signal resolves to `Unknown`
under the `treatUnknownAs` policy). They are internally consistent with
`config/compliance-rules.json`, so expected results are deterministic, and they contain no real
tenant, user, or device identifiers.

## Live-ready, not live-limited

The code is validated offline but written for live use:

- Omit `-GraphDataSourceMock` and the same entrypoint queries live Graph over device-code auth
  locally or managed identity in Azure Automation.
- Scope composition, the `-Execute` gate, `-WhatIf` support, and idempotent create/assign of
  proactive remediations were all built for live tenant semantics and are covered by tests that
  mock only the Graph transport.
- The Pester suite's pure-logic tests import and pass on a machine without the Graph SDK
  installed; the mock pipeline tests likewise make zero Graph calls.

## Known limitations

- Antivirus signal coverage. Even on live tenants, `windowsProtectionState` is not always
  populated (it was the usual gap on free developer tenants). The check resolves to `Unknown`,
  governed by `treatUnknownAs` in the rules, never a silent pass or fail.
- Remediation is assignment-only in v1. On-demand per-device triggering would require
  `DeviceManagementManagedDevices.PrivilegedOperations.All` and is a named future extension.
- `deviceHealthScripts` is driven through raw v1.0 Graph calls because SDK cmdlet coverage varies
  by module version; capabilities can differ across tenants and licensing.
- The live write paths (remediation create/assign, Graph Mail send) are exercised through mocked
  Graph calls in the test suite, not against a live tenant, for the licensing reasons above. The
  request shapes follow the documented v1.0 endpoints.
