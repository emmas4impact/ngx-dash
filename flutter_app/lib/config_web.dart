import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

const _buildTimeApiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://localhost:8000',
);

String configuredApiBaseUrl() {
  final runtimeConfig = web.window.getProperty<JSObject?>(
    'NGX_DASH_CONFIG'.toJS,
  );
  if (runtimeConfig != null) {
    final runtimeApiBaseUrl = runtimeConfig.getProperty<JSString?>(
      'API_BASE_URL'.toJS,
    );
    final value = runtimeApiBaseUrl?.toDart.trim();
    if (value != null && value.isNotEmpty) {
      return value;
    }
  }

  return _buildTimeApiBaseUrl;
}
