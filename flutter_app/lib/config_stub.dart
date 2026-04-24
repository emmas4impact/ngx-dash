const _buildTimeApiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://localhost:8000',
);

String configuredApiBaseUrl() => _buildTimeApiBaseUrl;
