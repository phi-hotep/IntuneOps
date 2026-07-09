# Purpose: managed-dependency manifest for the demo Function. The demo path runs the pipeline in
# mock dry-run mode and makes ZERO Graph calls, so the Graph modules are deliberately not enabled:
# pulling them from the gallery at cold start would add minutes of delay for modules that are never
# invoked. If this Function is ever extended to a live data source, uncomment the pins below AND
# set managedDependency.enabled to true in host.json.
@{
    # 'Microsoft.Graph.Authentication'   = '2.*'
    # 'Microsoft.Graph.DeviceManagement' = '2.*'
}
