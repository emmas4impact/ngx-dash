import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

typedef PushTokenRegistrar =
    Future<void> Function(String token, {required String platform});
typedef PushTokenRemover = Future<void> Function(String token);

const _firebaseProjectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
const _firebaseMessagingSenderId = String.fromEnvironment(
  'FIREBASE_MESSAGING_SENDER_ID',
);
const _firebaseAndroidAppId = String.fromEnvironment('FIREBASE_ANDROID_APP_ID');
const _firebaseAndroidApiKey = String.fromEnvironment(
  'FIREBASE_ANDROID_API_KEY',
);
const _firebaseIosAppId = String.fromEnvironment('FIREBASE_IOS_APP_ID');
const _firebaseIosApiKey = String.fromEnvironment('FIREBASE_IOS_API_KEY');
const _firebaseIosBundleId = String.fromEnvironment(
  'FIREBASE_IOS_BUNDLE_ID',
  defaultValue: 'com.stockfoliong.app',
);

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  final options = _firebaseOptionsForCurrentPlatform();
  if (options == null) return;
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp(options: options);
  }
}

class PushRegistrationResult {
  const PushRegistrationResult({
    required this.enabled,
    required this.message,
    this.available = true,
  });

  final bool enabled;
  final bool available;
  final String message;
}

class PushAlertMessage {
  const PushAlertMessage({
    required this.title,
    required this.body,
    this.symbol,
    this.route,
  });

  final String title;
  final String body;
  final String? symbol;
  final String? route;
}

class PushNotifications {
  PushNotifications._();

  static final PushNotifications instance = PushNotifications._();

  final _messages = StreamController<PushAlertMessage>.broadcast();
  final _openedMessages = StreamController<PushAlertMessage>.broadcast();
  StreamSubscription<String>? _refreshSubscription;
  StreamSubscription<RemoteMessage>? _foregroundSubscription;
  StreamSubscription<RemoteMessage>? _openedSubscription;
  PushRegistrationResult _lastResult = const PushRegistrationResult(
    enabled: false,
    available: false,
    message: 'Push alerts have not been checked yet.',
  );
  String? _currentToken;
  bool _initialized = false;
  PushAlertMessage? _pendingOpenedMessage;

  Stream<PushAlertMessage> get messages => _messages.stream;
  Stream<PushAlertMessage> get openedMessages => _openedMessages.stream;
  PushRegistrationResult get lastResult => _lastResult;

  PushAlertMessage? consumePendingOpenedMessage() {
    final message = _pendingOpenedMessage;
    _pendingOpenedMessage = null;
    return message;
  }

  Future<PushRegistrationResult> ensureRegistered({
    required PushTokenRegistrar registerToken,
  }) async {
    if (_initialized) {
      return _lastResult;
    }

    if (kIsWeb) {
      _lastResult = const PushRegistrationResult(
        enabled: false,
        available: false,
        message:
            'Web push is not configured yet. Mobile push works through Firebase.',
      );
      return _lastResult;
    }

    final platform = defaultTargetPlatform;
    if (platform != TargetPlatform.android && platform != TargetPlatform.iOS) {
      _lastResult = const PushRegistrationResult(
        enabled: false,
        available: false,
        message: 'Push alerts are only supported on Android and iOS.',
      );
      return _lastResult;
    }

    final options = _firebaseOptionsForCurrentPlatform();
    if (options == null) {
      _lastResult = const PushRegistrationResult(
        enabled: false,
        available: false,
        message:
            'Firebase config is missing. Add the Firebase dart-defines before testing device push.',
      );
      return _lastResult;
    }

    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(options: options);
      }
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

      final messaging = FirebaseMessaging.instance;
      _openedSubscription ??= FirebaseMessaging.onMessageOpenedApp.listen((
        message,
      ) {
        _openedMessages.add(_messageFromRemoteMessage(message));
      });

      final initialMessage = await messaging.getInitialMessage();
      if (initialMessage != null) {
        _pendingOpenedMessage = _messageFromRemoteMessage(initialMessage);
      }

      final permission = await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      if (permission.authorizationStatus == AuthorizationStatus.denied) {
        _lastResult = const PushRegistrationResult(
          enabled: false,
          available: true,
          message: 'Push permission was denied on this device.',
        );
        return _lastResult;
      }

      if (platform == TargetPlatform.iOS) {
        await messaging.setForegroundNotificationPresentationOptions(
          alert: true,
          badge: true,
          sound: true,
        );
      }

      final token = await messaging.getToken();
      if (token == null || token.isEmpty) {
        _lastResult = const PushRegistrationResult(
          enabled: false,
          available: true,
          message:
              'Firebase is ready, but the device token is not available yet.',
        );
        return _lastResult;
      }

      await registerToken(token, platform: _platformName(platform));
      _currentToken = token;
      _initialized = true;

      _refreshSubscription ??= messaging.onTokenRefresh.listen((
        newToken,
      ) async {
        _currentToken = newToken;
        try {
          await registerToken(newToken, platform: _platformName(platform));
        } catch (_) {}
      });
      _foregroundSubscription ??= FirebaseMessaging.onMessage.listen((message) {
        _messages.add(_messageFromRemoteMessage(message));
      });

      _lastResult = const PushRegistrationResult(
        enabled: true,
        available: true,
        message: 'Push alerts are enabled on this device.',
      );
      return _lastResult;
    } catch (error) {
      _lastResult = PushRegistrationResult(
        enabled: false,
        available: true,
        message: 'Firebase push setup failed: $error',
      );
      return _lastResult;
    }
  }

  Future<void> unregister({required PushTokenRemover removeToken}) async {
    final token = _currentToken;
    if (token == null || token.isEmpty) return;
    try {
      await removeToken(token);
    } catch (_) {}
    try {
      await FirebaseMessaging.instance.deleteToken();
    } catch (_) {}
    _currentToken = null;
    _initialized = false;
  }

  Future<void> dispose() async {
    await _refreshSubscription?.cancel();
    await _foregroundSubscription?.cancel();
    await _openedSubscription?.cancel();
    _refreshSubscription = null;
    _foregroundSubscription = null;
    _openedSubscription = null;
  }
}

PushAlertMessage _messageFromRemoteMessage(RemoteMessage message) {
  final title =
      message.notification?.title ??
      message.data['title']?.toString() ??
      'Stockfolio NG alert';
  final body =
      message.notification?.body ??
      message.data['body']?.toString() ??
      'A market alert just came in.';
  return PushAlertMessage(
    title: title,
    body: body,
    route: message.data['route']?.toString(),
    symbol: message.data['symbol']?.toString(),
  );
}

FirebaseOptions? _firebaseOptionsForCurrentPlatform() {
  if (_firebaseProjectId.isEmpty || _firebaseMessagingSenderId.isEmpty) {
    return null;
  }

  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
      if (_firebaseAndroidAppId.isEmpty || _firebaseAndroidApiKey.isEmpty) {
        return null;
      }
      return const FirebaseOptions(
        apiKey: _firebaseAndroidApiKey,
        appId: _firebaseAndroidAppId,
        messagingSenderId: _firebaseMessagingSenderId,
        projectId: _firebaseProjectId,
      );
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
      if (_firebaseIosAppId.isEmpty || _firebaseIosApiKey.isEmpty) {
        return null;
      }
      return const FirebaseOptions(
        apiKey: _firebaseIosApiKey,
        appId: _firebaseIosAppId,
        messagingSenderId: _firebaseMessagingSenderId,
        projectId: _firebaseProjectId,
        iosBundleId: _firebaseIosBundleId,
      );
    default:
      return null;
  }
}

String _platformName(TargetPlatform platform) {
  switch (platform) {
    case TargetPlatform.android:
      return 'android';
    case TargetPlatform.iOS:
      return 'ios';
    case TargetPlatform.macOS:
      return 'macos';
    case TargetPlatform.windows:
      return 'windows';
    case TargetPlatform.linux:
      return 'linux';
    case TargetPlatform.fuchsia:
      return 'fuchsia';
  }
}
