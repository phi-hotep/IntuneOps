// Purpose: demo page configuration TEMPLATE. Copy to config.js (git-ignored) and fill in the
// deployed values. The function key becomes visible in client-side JS by design; that is an
// accepted portfolio trade-off documented in demo/README.md (the real fix is Key Vault plus
// managed identity, or Easy Auth in front of the Function). Never commit config.js.
window.INTUNEOPS_DEMO_CONFIG = {
  // Local dev: http://localhost:7071/api/scan (func start; no key needed).
  // Deployed:  https://<your-function-app>.azurewebsites.net/api/scan
  functionUrl: 'http://localhost:7071/api/scan',

  // Function key for the deployed app (Azure portal: Function App > Functions > RunComplianceScan
  // > Function Keys). Leave empty for local func start.
  functionKey: ''
};
