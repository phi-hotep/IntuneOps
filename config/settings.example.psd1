# Purpose: non-sensitive runtime settings template. Copy to settings.psd1 (git-ignored if it holds anything local) and adjust. Identifiers/secrets come from env or Automation vars, NOT from here.
@{
    # Auth mode selector; the actual identifiers/secrets are resolved from environment or
    # Azure Automation variables by Resolve-IntuneOpsAuth. One of:
    # Interactive | DeviceCode | AppCertificate | AppSecret | ManagedIdentity
    AuthMode      = 'DeviceCode'

    # Graph environment (Global | USGov | China) for sovereign clouds.
    GraphEnvironment = 'Global'

    # Sender mailbox for compliance notifications (Phase 3). For app-only send, constrain this
    # mailbox with an Application Access Policy (see README).
    MailSender    = 'compliance-bot@your-dev-tenant.onmicrosoft.com'

    # Notification rendering. UseHtmlEmail sends the HTML template (plus is otherwise text).
    UseHtmlEmail  = $false
    NotificationSubjectTemplate = 'Action required: {{DeviceName}} is not compliant'

    # Default safety: dry-run on, notifications off. Overridable by entrypoint switches.
    DryRunByDefault = $true
    NotifyByDefault = $false

    # Relative paths (resolved against repo root at runtime).
    RulesPath     = 'config/compliance-rules.json'
    LogDirectory  = 'logs'
    ReportDirectory = 'reports'
}
