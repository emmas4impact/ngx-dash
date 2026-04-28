import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_version.dart';
import 'config.dart';
import 'push_notifications.dart';
import 'profile_image_picker_stub.dart'
    if (dart.library.html) 'profile_image_picker_web.dart';
import 'stock_logo_assets.dart';

final apiBaseUrl = normalizeApiBaseUrl(configuredApiBaseUrl());
const _themeModePreferenceKey = 'theme_mode';
const _webSessionDeadlineKey = 'web_session_deadline_ms';
const _webSessionExtendedKey = 'web_session_extended';
const _financialPrivacyPreferenceKey = 'financial_privacy_hidden';
const _seedColor = Color(0xFF00A86B);
const _gainColor = Color(0xFF00B67A);
const _lossColor = Color(0xFFFF5A7A);
const _darkScaffold = Color(0xFF0B1215);
const _darkSurface = Color(0xFF101A1E);
const _darkSurfaceAlt = Color(0xFF142126);
const _lightScaffold = Color(0xFFF3F7FC);

String stockLogoUrl(String symbol) =>
    '$apiBaseUrl/public/stocks/${Uri.encodeComponent(symbol)}/logo';

String stockLogoAssetPath(String symbol) =>
    'assets/company_logos/${symbol.trim().toUpperCase()}.png';

class MarketStatusPalette {
  const MarketStatusPalette({
    required this.base,
    required this.container,
    required this.content,
    required this.icon,
  });

  final Color base;
  final Color container;
  final Color content;
  final IconData icon;
}

MarketStatusPalette marketStatusPalette(
  ThemeData theme,
  String status, {
  bool stale = false,
}) {
  final normalized = status.toUpperCase().replaceAll('-', '_');
  if (stale) {
    return const MarketStatusPalette(
      base: Color(0xFFD97706),
      container: Color(0xFFFEF3C7),
      content: Color(0xFF92400E),
      icon: Icons.warning_amber_rounded,
    );
  }
  if (normalized.contains('ENDOFDAY') || normalized.contains('END_OF_DAY')) {
    return theme.brightness == Brightness.dark
        ? const MarketStatusPalette(
            base: Color(0xFFF87171),
            container: Color(0xFF32161A),
            content: Color(0xFFFECACA),
            icon: Icons.lock_clock_outlined,
          )
        : const MarketStatusPalette(
            base: Color(0xFFDC2626),
            container: Color(0xFFFEE2E2),
            content: Color(0xFF991B1B),
            icon: Icons.lock_clock_outlined,
          );
  }
  if (normalized.contains('START_INDEX')) {
    return theme.brightness == Brightness.dark
        ? const MarketStatusPalette(
            base: Color(0xFF34D399),
            container: Color(0xFF0F2A24),
            content: Color(0xFFD1FAE5),
            icon: Icons.trending_up_rounded,
          )
        : const MarketStatusPalette(
            base: Color(0xFF059669),
            container: Color(0xFFD1FAE5),
            content: Color(0xFF065F46),
            icon: Icons.trending_up_rounded,
          );
  }
  if (normalized.contains('PRE_OPEN')) {
    return theme.brightness == Brightness.dark
        ? const MarketStatusPalette(
            base: Color(0xFFA3E635),
            container: Color(0xFF233012),
            content: Color(0xFFECFCCB),
            icon: Icons.schedule_rounded,
          )
        : const MarketStatusPalette(
            base: Color(0xFF65A30D),
            container: Color(0xFFECFCCB),
            content: Color(0xFF3F6212),
            icon: Icons.schedule_rounded,
          );
  }
  return theme.brightness == Brightness.dark
      ? const MarketStatusPalette(
          base: Color(0xFF60A5FA),
          container: Color(0xFF172554),
          content: Color(0xFFDBEAFE),
          icon: Icons.insights_outlined,
        )
      : const MarketStatusPalette(
          base: Color(0xFF2563EB),
          container: Color(0xFFDBEAFE),
          content: Color(0xFF1E3A8A),
          icon: Icons.insights_outlined,
        );
}

Color chartGridColor(ThemeData theme) => theme.brightness == Brightness.dark
    ? Colors.white.withValues(alpha: 0.09)
    : theme.colorScheme.outlineVariant.withValues(alpha: 0.55);

String normalizeApiBaseUrl(String value) {
  final trimmed = value.trim().replaceAll(RegExp(r'/+$'), '');
  if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
    return trimmed;
  }
  if (trimmed.startsWith('localhost') ||
      trimmed.startsWith('127.0.0.1') ||
      trimmed.startsWith('10.0.2.2')) {
    return 'http://$trimmed';
  }
  return 'https://$trimmed';
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const NgxPortfolioApp());
}

class NgxPortfolioApp extends StatefulWidget {
  const NgxPortfolioApp({super.key});

  @override
  State<NgxPortfolioApp> createState() => _NgxPortfolioAppState();
}

class _NgxPortfolioAppState extends State<NgxPortfolioApp> {
  final ApiClient api = ApiClient(apiBaseUrl);
  bool loading = true;
  bool authenticated = false;
  late String? emailVerificationToken;
  late String? passwordResetToken;
  ThemeMode themeMode = ThemeMode.system;

  @override
  void initState() {
    super.initState();
    emailVerificationToken = Uri.base.queryParameters['verify_email_token'];
    passwordResetToken = Uri.base.queryParameters['reset_password_token'];
    _loadToken();
  }

  Future<void> _loadToken() async {
    final prefs = await SharedPreferences.getInstance();
    await api.restoreToken();
    final savedThemeMode = prefs.getString(_themeModePreferenceKey);
    setState(() {
      authenticated = api.hasToken;
      themeMode = switch (savedThemeMode) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
      loading = false;
    });
  }

  Future<void> _setThemeMode(ThemeMode nextMode) async {
    final prefs = await SharedPreferences.getInstance();
    final value = switch (nextMode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    };
    await prefs.setString(_themeModePreferenceKey, value);
    if (!mounted) return;
    setState(() => themeMode = nextMode);
  }

  void _signedIn() {
    setState(() => authenticated = true);
  }

  Future<void> _signOut() async {
    await PushNotifications.instance.unregister(
      removeToken: api.unregisterPushToken,
    );
    await api.clearToken();
    setState(() => authenticated = false);
  }

  @override
  Widget build(BuildContext context) {
    final lightScheme =
        ColorScheme.fromSeed(
          seedColor: _seedColor,
          brightness: Brightness.light,
        ).copyWith(
          primary: const Color(0xFF009F6B),
          secondary: const Color(0xFF00C389),
          tertiary: const Color(0xFF1976FF),
          surface: Colors.white,
          surfaceContainerHighest: const Color(0xFFEAF7F2),
        );
    final darkScheme =
        ColorScheme.fromSeed(
          seedColor: _seedColor,
          brightness: Brightness.dark,
        ).copyWith(
          primary: const Color(0xFF38E2A2),
          secondary: const Color(0xFF68F0C0),
          tertiary: const Color(0xFF69A7FF),
          surface: _darkSurface,
          surfaceContainerHighest: const Color(0xFF15262B),
        );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Stockfolio',
      themeMode: themeMode,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: lightScheme,
        scaffoldBackgroundColor: _lightScaffold,
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFF5FBFF),
          foregroundColor: Color(0xFF10231D),
          elevation: 0,
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: const Color(0xFFF9FCFF),
          indicatorColor: const Color(0xFFD7FFF0),
          iconTheme: WidgetStateProperty.resolveWith((states) {
            final selected = states.contains(WidgetState.selected);
            return IconThemeData(
              color: selected
                  ? const Color(0xFF009F6B)
                  : const Color(0xFF4E6960),
            );
          }),
          labelTextStyle: WidgetStateProperty.resolveWith((states) {
            final selected = states.contains(WidgetState.selected);
            return TextStyle(
              color: selected
                  ? const Color(0xFF009F6B)
                  : const Color(0xFF4E6960),
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            );
          }),
        ),
        navigationRailTheme: const NavigationRailThemeData(
          backgroundColor: Color(0xFFF1FAF6),
          indicatorColor: Color(0xFFD7FFF0),
          selectedIconTheme: IconThemeData(color: Color(0xFF009F6B)),
          selectedLabelTextStyle: TextStyle(
            color: Color(0xFF009F6B),
            fontWeight: FontWeight.w700,
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: const BorderSide(color: Color(0xFFD7E2DE)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: const BorderSide(color: _seedColor, width: 1.5),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: const BorderSide(color: Color(0xFFDC2626)),
          ),
          focusedErrorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: const BorderSide(color: Color(0xFFDC2626), width: 1.5),
          ),
        ),
        cardTheme: const CardThemeData(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(24)),
            side: BorderSide(color: Color(0xFFD9E5EC)),
          ),
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: darkScheme,
        scaffoldBackgroundColor: _darkScaffold,
        canvasColor: _darkScaffold,
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF121C20),
          foregroundColor: Color(0xFFE6F4EF),
          elevation: 0,
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: const Color(0xFF10181C),
          indicatorColor: const Color(0xFF114639),
          iconTheme: WidgetStateProperty.resolveWith((states) {
            final selected = states.contains(WidgetState.selected);
            return IconThemeData(
              color: selected
                  ? const Color(0xFF68F0C0)
                  : const Color(0xFF91ABA3),
            );
          }),
          labelTextStyle: WidgetStateProperty.resolveWith((states) {
            final selected = states.contains(WidgetState.selected);
            return TextStyle(
              color: selected
                  ? const Color(0xFF68F0C0)
                  : const Color(0xFF92AAA4),
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            );
          }),
        ),
        navigationRailTheme: const NavigationRailThemeData(
          backgroundColor: Color(0xFF10181C),
          indicatorColor: Color(0xFF114639),
          selectedIconTheme: IconThemeData(color: Color(0xFF68F0C0)),
          unselectedIconTheme: IconThemeData(color: Color(0xFF9DB1AB)),
          selectedLabelTextStyle: TextStyle(
            color: Color(0xFF68F0C0),
            fontWeight: FontWeight.w700,
          ),
          unselectedLabelTextStyle: TextStyle(color: Color(0xFF9DB1AB)),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: _darkSurfaceAlt,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: const BorderSide(color: Color(0xFF26363C)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: const BorderSide(color: Color(0xFF58C1A0), width: 1.5),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: const BorderSide(color: Color(0xFFF87171)),
          ),
          focusedErrorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: const BorderSide(color: Color(0xFFF87171), width: 1.5),
          ),
        ),
        cardTheme: const CardThemeData(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(24)),
            side: BorderSide(color: Color(0xFF203138)),
          ),
        ),
      ),
      home: loading
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : emailVerificationToken != null
          ? EmailVerificationScreen(
              api: api,
              token: emailVerificationToken!,
              onDone: () => setState(() => emailVerificationToken = null),
            )
          : passwordResetToken != null
          ? ResetPasswordScreen(
              api: api,
              token: passwordResetToken!,
              onDone: () => setState(() => passwordResetToken = null),
            )
          : authenticated
          ? DashboardShell(
              api: api,
              onSignOut: _signOut,
              themeMode: themeMode,
              onThemeModeChanged: _setThemeMode,
            )
          : AuthScreen(
              api: api,
              onSignedIn: _signedIn,
              themeMode: themeMode,
              onThemeModeChanged: _setThemeMode,
            ),
    );
  }
}

class ApiClient {
  ApiClient(this.baseUrl);

  final String baseUrl;
  final http.Client _client = http.Client();
  String? _token;

  bool get hasToken => _token != null && _token!.isNotEmpty;

  Future<void> restoreToken() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString('access_token');
    if (kIsWeb &&
        _token != null &&
        prefs.getInt(_webSessionDeadlineKey) == null) {
      await _startWebSession(prefs);
    }
  }

  Future<void> clearToken() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('access_token');
    await prefs.remove(_webSessionDeadlineKey);
    await prefs.remove(_webSessionExtendedKey);
    _token = null;
  }

  Future<void> _saveToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('access_token', token);
    if (kIsWeb) {
      await _startWebSession(prefs);
    }
    _token = token;
  }

  Future<void> _startWebSession(SharedPreferences prefs) async {
    await prefs.setInt(
      _webSessionDeadlineKey,
      DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
    );
    await prefs.setBool(_webSessionExtendedKey, false);
  }

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    if (_token != null) 'Authorization': 'Bearer $_token',
  };

  String get privacyPolicyUrl => '$baseUrl/public/privacy-policy';
  String get accountDeletionUrl => '$baseUrl/public/account-deletion';

  Uri _uri(String path, [Map<String, String>? query]) {
    return Uri.parse('$baseUrl$path').replace(queryParameters: query);
  }

  Future<void> register(String email, String password, String? fullName) async {
    final response = await _client.post(
      _uri('/auth/register'),
      headers: _headers,
      body: jsonEncode({
        'email': email,
        'password': password,
        'full_name': fullName,
      }),
    );
    _expect(response, 201);
    await login(email, password);
  }

  Future<void> login(String email, String password) async {
    final response = await _client.post(
      _uri('/auth/login'),
      headers: _headers,
      body: jsonEncode({'email': email, 'password': password}),
    );
    _expect(response, 200);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    await _saveToken(data['access_token'] as String);
  }

  Future<String> forgotPassword(String email) async {
    final response = await _client.post(
      _uri('/auth/forgot-password'),
      headers: _headers,
      body: jsonEncode({'email': email}),
    );
    _expect(response, 200);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final link = data['verification_url']?.toString();
    final message =
        data['message']?.toString() ??
        'If that email is registered, a password reset link has been sent.';
    return link == null || link.isEmpty ? message : '$message $link';
  }

  Future<String> resetPassword(String token, String newPassword) async {
    final response = await _client.post(
      _uri('/auth/reset-password'),
      headers: _headers,
      body: jsonEncode({'token': token, 'new_password': newPassword}),
    );
    _expect(response, 200);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return data['message']?.toString() ??
        'Password reset successful. You can now sign in.';
  }

  Future<AppUser> me() async {
    final response = await _client.get(_uri('/me'), headers: _headers);
    _expect(response, 200);
    return AppUser.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<AppUser> updateProfile(ProfileInput input) async {
    final response = await _client.put(
      _uri('/me'),
      headers: _headers,
      body: jsonEncode(input.toJson()),
    );
    _expect(response, 200);
    return AppUser.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<AppUser> uploadProfileImage(
    List<int> bytes, {
    required String mimeType,
    String filename = 'profile.jpg',
  }) async {
    final request = http.MultipartRequest('POST', _uri('/me/profile-image'));
    if (_token != null) {
      request.headers['Authorization'] = 'Bearer $_token';
    }
    request.fields['mime_type'] = mimeType;
    request.files.add(
      http.MultipartFile.fromBytes('file', bytes, filename: filename),
    );
    final streamed = await _client.send(request);
    final response = await http.Response.fromStream(streamed);
    _expect(response, 200);
    return AppUser.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<AppUser> deleteProfileImage() async {
    final response = await _client.delete(
      _uri('/me/profile-image'),
      headers: _headers,
    );
    _expect(response, 200);
    return AppUser.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<String> changePassword(
    String currentPassword,
    String newPassword,
  ) async {
    final response = await _client.post(
      _uri('/me/password'),
      headers: _headers,
      body: jsonEncode({
        'current_password': currentPassword,
        'new_password': newPassword,
      }),
    );
    _expect(response, 200);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return data['message']?.toString() ?? 'Password updated.';
  }

  Future<String> deleteAccount(String password) async {
    final response = await _client.post(
      _uri('/me/delete-account'),
      headers: _headers,
      body: jsonEncode({'password': password}),
    );
    _expect(response, 200);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return data['message']?.toString() ?? 'Account deleted.';
  }

  Future<String> requestEmailVerification() async {
    final response = await _client.post(
      _uri('/me/email-verification'),
      headers: _headers,
    );
    _expect(response, 200);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final link = data['verification_url']?.toString();
    final message =
        data['message']?.toString() ?? 'Verification email requested.';
    return link == null || link.isEmpty ? message : '$message $link';
  }

  Future<String> verifyEmailToken(String token) async {
    final response = await _client.get(
      _uri('/auth/verify-email', {'token': token}),
      headers: _headers,
    );
    _expect(response, 200);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return data['message']?.toString() ?? 'Email address verified.';
  }

  Future<String> emailPortfolioReport() async {
    final response = await _client.post(
      _uri('/me/portfolio-report/email'),
      headers: _headers,
    );
    _expect(response, 200);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return data['message']?.toString() ?? 'Portfolio report request complete.';
  }

  Future<void> registerPushToken(
    String token, {
    required String platform,
  }) async {
    final response = await _client.post(
      _uri('/me/push-tokens'),
      headers: _headers,
      body: jsonEncode({'token': token, 'platform': platform}),
    );
    _expect(response, 200);
  }

  Future<void> unregisterPushToken(String token) async {
    final request = http.Request('DELETE', _uri('/me/push-tokens'))
      ..headers.addAll(_headers)
      ..body = jsonEncode({'token': token});
    final streamed = await _client.send(request);
    final response = await http.Response.fromStream(streamed);
    _expect(response, 204);
  }

  Future<List<Stock>> stocks({String? search}) async {
    final response = await _client.get(
      _uri(
        '/stocks',
        search == null || search.isEmpty ? null : {'search': search},
      ),
      headers: _headers,
    );
    _expect(response, 200);
    final data = jsonDecode(response.body) as List<dynamic>;
    return data
        .map((item) => Stock.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<MarketIdeasBundle> marketIdeas({int limit = 4}) async {
    final response = await _client.get(
      _uri('/market/ideas', {'limit': '$limit'}),
      headers: _headers,
    );
    _expect(response, 200);
    return MarketIdeasBundle.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<Stock> stock(String symbol) async {
    final response = await _client.get(
      _uri('/stocks/$symbol'),
      headers: _headers,
    );
    _expect(response, 200);
    return Stock.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<List<Holding>> holdings() async {
    final response = await _client.get(
      _uri('/portfolio/holdings'),
      headers: _headers,
    );
    _expect(response, 200);
    final data = jsonDecode(response.body) as List<dynamic>;
    return data
        .map((item) => Holding.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<Holding> saveHolding(HoldingInput input) async {
    final response = await _client.post(
      _uri('/portfolio/holdings'),
      headers: _headers,
      body: jsonEncode(input.toJson()),
    );
    _expect(response, 200);
    return Holding.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<void> deleteHolding(String symbol) async {
    final response = await _client.delete(
      _uri('/portfolio/holdings/$symbol'),
      headers: _headers,
    );
    _expect(response, 204);
  }

  Future<List<PricePoint>> history(String symbol, {int months = 12}) async {
    final response = await _client.get(
      _uri('/stocks/$symbol/history', {'months': '$months'}),
      headers: _headers,
    );
    _expect(response, 200);
    final data = jsonDecode(response.body) as List<dynamic>;
    return data
        .map((item) => PricePoint.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<StockDetailBundle> stockDetail(String symbol) async {
    final response = await _client.get(
      _uri('/stocks/$symbol/detail', {'months': '12', 'news_limit': '6'}),
      headers: _headers,
    );
    _expect(response, 200);
    return StockDetailBundle.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<StockDetailBundle> publicStockDetail(String symbol) async {
    final response = await _client.get(
      _uri('/public/stocks/$symbol/detail', {
        'months': '12',
        'news_limit': '6',
      }),
      headers: _headers,
    );
    _expect(response, 200);
    return StockDetailBundle.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<String> syncStocks({bool includeHistory = false}) async {
    final response = await _client.post(
      _uri('/admin/sync/stocks', {
        'include_history': includeHistory.toString(),
      }),
      headers: _headers,
    );
    _expect(response, 200);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final status = data['status']?.toString() ?? 'success';
    final message = data['message']?.toString();
    if (status != 'success' && message != null && message.isNotEmpty) {
      return message;
    }
    final historyRows = (data['history_rows_upserted'] as num?)?.toInt() ?? 0;
    if (includeHistory) {
      return 'Synced ${data['stocks_upserted']} stocks from ${data['source']} and refreshed $historyRows history rows';
    }
    if (historyRows > 0) {
      return 'Synced ${data['stocks_upserted']} stocks from ${data['source']} and updated $historyRows daily snapshots';
    }
    return 'Synced ${data['stocks_upserted']} stocks from ${data['source']}';
  }

  Future<SyncStatus> syncStatus() async {
    final response = await _client.get(
      _uri('/admin/sync/status'),
      headers: _headers,
    );
    _expect(response, 200);
    return SyncStatus.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<List<SyncLogEntry>> syncLogs() async {
    final response = await _client.get(
      _uri('/admin/sync/logs', {'limit': '50'}),
      headers: _headers,
    );
    _expect(response, 200);
    final data = jsonDecode(response.body) as List<dynamic>;
    return data
        .map((item) => SyncLogEntry.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<List<AccountDeletionRequestEntry>> accountDeletionRequests() async {
    final response = await _client.get(
      _uri('/admin/account-deletion-requests', {'limit': '50'}),
      headers: _headers,
    );
    _expect(response, 200);
    final data = jsonDecode(response.body) as List<dynamic>;
    return data
        .map(
          (item) => AccountDeletionRequestEntry.fromJson(
            item as Map<String, dynamic>,
          ),
        )
        .toList();
  }

  Future<PushStatusSummary> pushStatus() async {
    final response = await _client.get(
      _uri('/admin/push/status'),
      headers: _headers,
    );
    _expect(response, 200);
    return PushStatusSummary.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<String> sendTestPush({String? symbol}) async {
    final response = await _client.post(
      _uri('/admin/push/test'),
      headers: _headers,
      body: jsonEncode({'symbol': symbol}),
    );
    _expect(response, 200);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return data['message']?.toString() ?? 'Push test sent.';
  }

  Future<MarketStatus> marketStatus() async {
    final response = await _client.get(
      _uri('/market/status'),
      headers: _headers,
    );
    _expect(response, 200);
    return MarketStatus.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<MarketStatus> publicMarketStatus() async {
    final response = await _client.get(_uri('/public/market/status'));
    _expect(response, 200);
    return MarketStatus.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<MarketSnapshot> marketSnapshot() async {
    final response = await _client.get(
      _uri('/market/snapshot'),
      headers: _headers,
    );
    _expect(response, 200);
    return MarketSnapshot.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<MarketLeaders> marketLeaders({int limit = 5}) async {
    final response = await _client.get(
      _uri('/market/leaders', {'limit': '$limit'}),
      headers: _headers,
    );
    _expect(response, 200);
    return MarketLeaders.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<MarketLeaders> publicMarketLeaders({int limit = 6}) async {
    final response = await _client.get(
      _uri('/public/market/leaders', {'limit': '$limit'}),
    );
    _expect(response, 200);
    return MarketLeaders.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<List<CompanyNewsItem>> companyNews(String symbol) async {
    final response = await _client.get(
      _uri('/stocks/$symbol/company-news', {'limit': '5'}),
      headers: _headers,
    );
    _expect(response, 200);
    final data = jsonDecode(response.body) as List<dynamic>;
    return data
        .map((item) => CompanyNewsItem.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  void _expect(http.Response response, int statusCode) {
    if (response.statusCode == statusCode) return;
    var message = 'Request failed (${response.statusCode})';
    try {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      message = data['detail']?.toString() ?? message;
    } catch (_) {}
    throw ApiException(message);
  }
}

class ApiException implements Exception {
  ApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

double? asDouble(dynamic value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString());
}

String? blankToNull(String value) {
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String stockPickerLabel(Stock stock) =>
    blankToNull(stock.name ?? '') ?? stock.symbol;

ImageProvider<Object>? profileImageProvider(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  if (trimmed.startsWith('data:')) {
    try {
      final data = UriData.parse(trimmed);
      return MemoryImage(data.contentAsBytes());
    } catch (_) {
      return null;
    }
  }
  if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
    return NetworkImage(trimmed);
  }
  return null;
}

extension StringFallback on String {
  String withFallback(String fallback) => isEmpty ? fallback : this;
}

class Stock {
  Stock({
    required this.symbol,
    this.name,
    this.lastPrice,
    this.openPrice,
    this.change,
    this.percentChange,
    this.margin,
    this.volume,
    this.marketCap,
    this.sector,
    this.ngxId,
    this.updatedAt,
  });

  final String symbol;
  final String? name;
  final double? lastPrice;
  final double? openPrice;
  final double? change;
  final double? percentChange;
  final double? margin;
  final double? volume;
  final double? marketCap;
  final String? sector;
  final String? ngxId;
  final DateTime? updatedAt;

  bool get hasChart => ngxId != null && ngxId!.isNotEmpty;

  factory Stock.fromJson(Map<String, dynamic> json) {
    return Stock(
      symbol: json['symbol'] as String,
      name: json['name'] as String?,
      lastPrice: asDouble(json['last_price']),
      openPrice: asDouble(json['open_price']),
      change: asDouble(json['change']),
      percentChange: asDouble(json['percent_change']),
      margin: asDouble(json['margin']),
      volume: asDouble(json['volume']),
      marketCap: asDouble(json['market_cap']),
      sector: json['sector'] as String?,
      ngxId: json['ngx_id'] as String?,
      updatedAt: json['updated_at'] == null
          ? null
          : DateTime.tryParse(json['updated_at'] as String),
    );
  }
}

class Holding {
  Holding({
    required this.symbol,
    this.name,
    required this.quantity,
    required this.avgPurchasePrice,
    this.currentPrice,
    required this.totalValue,
    required this.totalCost,
    required this.profitLoss,
    this.profitLossPercent,
    this.notes,
  });

  final String symbol;
  final String? name;
  final double quantity;
  final double avgPurchasePrice;
  final double? currentPrice;
  final double totalValue;
  final double totalCost;
  final double profitLoss;
  final double? profitLossPercent;
  final String? notes;

  factory Holding.fromJson(Map<String, dynamic> json) {
    return Holding(
      symbol: json['stock_symbol'] as String,
      name: json['stock_name'] as String?,
      quantity: asDouble(json['quantity']) ?? 0,
      avgPurchasePrice: asDouble(json['avg_purchase_price']) ?? 0,
      currentPrice: asDouble(json['current_price']),
      totalValue: asDouble(json['total_value']) ?? 0,
      totalCost: asDouble(json['total_cost']) ?? 0,
      profitLoss: asDouble(json['profit_loss']) ?? 0,
      profitLossPercent: asDouble(json['profit_loss_percent']),
      notes: json['notes'] as String?,
    );
  }

  factory Holding.fromStock(Stock stock) {
    return Holding(
      symbol: stock.symbol,
      name: stock.name,
      quantity: 0,
      avgPurchasePrice: 0,
      currentPrice: stock.lastPrice,
      totalValue: 0,
      totalCost: 0,
      profitLoss: 0,
    );
  }
}

class StockDetailBundle {
  StockDetailBundle({
    required this.stock,
    required this.history,
    this.marketSnapshot,
    required this.news,
  });

  final Stock stock;
  final List<PricePoint> history;
  final MarketSnapshot? marketSnapshot;
  final List<CompanyNewsItem> news;

  factory StockDetailBundle.fromJson(Map<String, dynamic> json) {
    final historyJson = json['history'] as List<dynamic>? ?? const [];
    final newsJson = json['news'] as List<dynamic>? ?? const [];
    return StockDetailBundle(
      stock: Stock.fromJson(json['stock'] as Map<String, dynamic>),
      history: historyJson
          .map((item) => PricePoint.fromJson(item as Map<String, dynamic>))
          .toList(),
      marketSnapshot: json['market_snapshot'] == null
          ? null
          : MarketSnapshot.fromJson(
              json['market_snapshot'] as Map<String, dynamic>,
            ),
      news: newsJson
          .map((item) => CompanyNewsItem.fromJson(item as Map<String, dynamic>))
          .toList(),
    );
  }
}

class MarketIdea {
  MarketIdea({
    required this.stock,
    required this.score,
    this.oneYearGrowthPercent,
    this.stocksAnalyzed,
    required this.rationale,
    this.webSummary,
    this.priceToEarningsRatio,
    this.priceToBookRatio,
    this.fundamentalNote,
  });

  final Stock stock;
  final double score;
  final double? oneYearGrowthPercent;
  final int? stocksAnalyzed;
  final List<String> rationale;
  final String? webSummary;
  final double? priceToEarningsRatio;
  final double? priceToBookRatio;
  final String? fundamentalNote;

  factory MarketIdea.fromJson(Map<String, dynamic> json) {
    final rationaleJson = json['rationale'] as List<dynamic>? ?? const [];
    return MarketIdea(
      stock: Stock.fromJson(json['stock'] as Map<String, dynamic>),
      score: asDouble(json['score']) ?? 0,
      oneYearGrowthPercent: asDouble(json['one_year_growth_percent']),
      stocksAnalyzed: (json['stocks_analyzed'] as num?)?.toInt(),
      rationale: rationaleJson.map((item) => item.toString()).toList(),
      webSummary: json['web_summary'] as String?,
      priceToEarningsRatio: asDouble(json['price_to_earnings_ratio']),
      priceToBookRatio: asDouble(json['price_to_book_ratio']),
      fundamentalNote: json['fundamental_note'] as String?,
    );
  }
}

class MarketIdeasBundle {
  MarketIdeasBundle({
    required this.disclaimer,
    required this.ideas,
    required this.stocksAnalyzed,
    this.generatedAt,
  });

  final String disclaimer;
  final List<MarketIdea> ideas;
  final int stocksAnalyzed;
  final DateTime? generatedAt;

  factory MarketIdeasBundle.fromJson(Map<String, dynamic> json) {
    final ideasJson = json['ideas'] as List<dynamic>? ?? const [];
    return MarketIdeasBundle(
      disclaimer: json['disclaimer']?.toString() ?? '',
      ideas: ideasJson
          .map((item) => MarketIdea.fromJson(item as Map<String, dynamic>))
          .toList(),
      stocksAnalyzed: (json['stocks_analyzed'] as num?)?.toInt() ?? 0,
      generatedAt: json['generated_at'] == null
          ? null
          : DateTime.tryParse(json['generated_at'] as String),
    );
  }
}

class HoldingInput {
  HoldingInput({
    required this.symbol,
    required this.quantity,
    required this.avgPurchasePrice,
    this.manualName,
    this.manualCurrentPrice,
    this.notes,
  });

  final String symbol;
  final double quantity;
  final double avgPurchasePrice;
  final String? manualName;
  final double? manualCurrentPrice;
  final String? notes;

  Map<String, dynamic> toJson() => {
    'stock_symbol': symbol,
    'quantity': quantity,
    'avg_purchase_price': avgPurchasePrice,
    'manual_name': manualName,
    'manual_current_price': manualCurrentPrice,
    'notes': notes,
  };
}

class AppUser {
  AppUser({
    required this.id,
    required this.email,
    this.fullName,
    this.profileImageUrl,
    this.phone,
    this.address,
    this.city,
    this.country,
    required this.emailVerified,
    required this.isSuperuser,
    this.createdAt,
    this.updatedAt,
  });

  final int id;
  final String email;
  final String? fullName;
  final String? profileImageUrl;
  final String? phone;
  final String? address;
  final String? city;
  final String? country;
  final bool emailVerified;
  final bool isSuperuser;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  String get displayName =>
      fullName == null || fullName!.trim().isEmpty ? email : fullName!.trim();

  String get firstName {
    final source = fullName?.trim();
    if (source != null && source.isNotEmpty) {
      return source.split(RegExp(r'\s+')).first;
    }
    final emailLocal = email.split('@').first.trim();
    return emailLocal.isEmpty ? 'Investor' : emailLocal;
  }

  factory AppUser.fromJson(Map<String, dynamic> json) {
    return AppUser(
      id: (json['id'] as num?)?.toInt() ?? 0,
      email: json['email']?.toString() ?? '',
      fullName: json['full_name'] as String?,
      profileImageUrl: json['profile_image_url'] as String?,
      phone: json['phone'] as String?,
      address: json['address'] as String?,
      city: json['city'] as String?,
      country: json['country'] as String?,
      emailVerified: json['email_verified'] == true,
      isSuperuser: json['is_superuser'] == true,
      createdAt: json['created_at'] == null
          ? null
          : DateTime.tryParse(json['created_at'] as String),
      updatedAt: json['updated_at'] == null
          ? null
          : DateTime.tryParse(json['updated_at'] as String),
    );
  }
}

class ProfileInput {
  ProfileInput({
    this.fullName,
    this.profileImageUrl,
    this.phone,
    this.address,
    this.city,
    this.country,
  });

  final String? fullName;
  final String? profileImageUrl;
  final String? phone;
  final String? address;
  final String? city;
  final String? country;

  Map<String, dynamic> toJson() => {
    'full_name': fullName,
    'profile_image_url': profileImageUrl,
    'phone': phone,
    'address': address,
    'city': city,
    'country': country,
  };
}

class PricePoint {
  PricePoint({required this.date, required this.open, required this.close});

  final DateTime date;
  final double open;
  final double close;

  factory PricePoint.fromJson(Map<String, dynamic> json) {
    return PricePoint(
      date: DateTime.parse(json['trade_date'] as String),
      open: asDouble(json['open_price']) ?? asDouble(json['close_price']) ?? 0,
      close: asDouble(json['close_price']) ?? 0,
    );
  }
}

class MarketStatus {
  MarketStatus({
    required this.status,
    required this.source,
    this.message,
    this.updatedAt,
    required this.stale,
  });

  final String status;
  final String source;
  final String? message;
  final DateTime? updatedAt;
  final bool stale;

  factory MarketStatus.fromJson(Map<String, dynamic> json) {
    return MarketStatus(
      status: json['status']?.toString() ?? 'UNKNOWN',
      source: json['source']?.toString() ?? 'ngx_doclib',
      message: json['message'] as String?,
      updatedAt: json['updated_at'] == null
          ? null
          : DateTime.tryParse(json['updated_at'] as String),
      stale: json['stale'] == true,
    );
  }
}

class MarketSnapshot {
  MarketSnapshot({
    this.asi,
    this.deals,
    this.volume,
    this.value,
    this.marketCap,
    this.bondCap,
    this.etfCap,
  });

  final double? asi;
  final double? deals;
  final double? volume;
  final double? value;
  final double? marketCap;
  final double? bondCap;
  final double? etfCap;

  factory MarketSnapshot.fromJson(Map<String, dynamic> json) {
    return MarketSnapshot(
      asi: asDouble(json['asi']),
      deals: asDouble(json['deals']),
      volume: asDouble(json['volume']),
      value: asDouble(json['value']),
      marketCap: asDouble(json['market_cap']),
      bondCap: asDouble(json['bond_cap']),
      etfCap: asDouble(json['etf_cap']),
    );
  }
}

class MarketLeaders {
  MarketLeaders({required this.topMovers, required this.topLosers});

  final List<Stock> topMovers;
  final List<Stock> topLosers;

  factory MarketLeaders.fromJson(Map<String, dynamic> json) {
    final movers = json['top_movers'] as List<dynamic>? ?? const [];
    final losers = json['top_losers'] as List<dynamic>? ?? const [];
    return MarketLeaders(
      topMovers: movers
          .map((item) => Stock.fromJson(item as Map<String, dynamic>))
          .toList(),
      topLosers: losers
          .map((item) => Stock.fromJson(item as Map<String, dynamic>))
          .toList(),
    );
  }
}

class LandingMarketData {
  LandingMarketData({required this.status, required this.leaders});

  final MarketStatus status;
  final MarketLeaders leaders;
}

class PushStatusSummary {
  PushStatusSummary({
    required this.enabled,
    this.projectId,
    required this.registeredDevices,
    required this.usersWithDevices,
    required this.thresholdPercent,
  });

  final bool enabled;
  final String? projectId;
  final int registeredDevices;
  final int usersWithDevices;
  final double thresholdPercent;

  factory PushStatusSummary.fromJson(Map<String, dynamic> json) {
    return PushStatusSummary(
      enabled: json['enabled'] == true,
      projectId: json['project_id'] as String?,
      registeredDevices: (json['registered_devices'] as num?)?.toInt() ?? 0,
      usersWithDevices: (json['users_with_devices'] as num?)?.toInt() ?? 0,
      thresholdPercent: asDouble(json['threshold_percent']) ?? 5,
    );
  }
}

class CompanyNewsItem {
  CompanyNewsItem({
    this.title,
    this.url,
    this.modified,
    this.ngxId,
    this.submissionType,
  });

  final String? title;
  final String? url;
  final DateTime? modified;
  final String? ngxId;
  final String? submissionType;

  factory CompanyNewsItem.fromJson(Map<String, dynamic> json) {
    return CompanyNewsItem(
      title: json['title'] as String?,
      url: json['url'] as String?,
      modified: json['modified'] == null
          ? null
          : DateTime.tryParse(json['modified'] as String),
      ngxId: json['ngx_id'] as String?,
      submissionType: json['submission_type'] as String?,
    );
  }
}

class SyncStatus {
  SyncStatus({
    required this.status,
    this.source,
    this.message,
    this.lastSuccessAt,
    this.lastAttemptAt,
    required this.stocksCount,
  });

  final String status;
  final String? source;
  final String? message;
  final DateTime? lastSuccessAt;
  final DateTime? lastAttemptAt;
  final int stocksCount;

  bool get isStale => status == 'warning' || status == 'failed';

  factory SyncStatus.fromJson(Map<String, dynamic> json) {
    return SyncStatus(
      status: json['status']?.toString() ?? 'unknown',
      source: json['source'] as String?,
      message: json['message'] as String?,
      lastSuccessAt: json['last_success_at'] == null
          ? null
          : DateTime.tryParse(json['last_success_at'] as String),
      lastAttemptAt: json['last_attempt_at'] == null
          ? null
          : DateTime.tryParse(json['last_attempt_at'] as String),
      stocksCount: (json['stocks_count'] as num?)?.toInt() ?? 0,
    );
  }
}

class SyncLogEntry {
  SyncLogEntry({
    required this.id,
    required this.status,
    required this.source,
    required this.stocksUpserted,
    required this.historyRowsUpserted,
    this.message,
    required this.createdAt,
  });

  final int id;
  final String status;
  final String source;
  final int stocksUpserted;
  final int historyRowsUpserted;
  final String? message;
  final DateTime createdAt;

  factory SyncLogEntry.fromJson(Map<String, dynamic> json) {
    return SyncLogEntry(
      id: (json['id'] as num?)?.toInt() ?? 0,
      status: json['status']?.toString() ?? 'unknown',
      source: json['source']?.toString() ?? 'unknown',
      stocksUpserted: (json['stocks_upserted'] as num?)?.toInt() ?? 0,
      historyRowsUpserted:
          (json['history_rows_upserted'] as num?)?.toInt() ?? 0,
      message: json['message'] as String?,
      createdAt:
          DateTime.tryParse(json['created_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

class AccountDeletionRequestEntry {
  AccountDeletionRequestEntry({
    required this.id,
    required this.email,
    this.reason,
    required this.source,
    required this.status,
    required this.createdAt,
  });

  final int id;
  final String email;
  final String? reason;
  final String source;
  final String status;
  final DateTime createdAt;

  factory AccountDeletionRequestEntry.fromJson(Map<String, dynamic> json) {
    return AccountDeletionRequestEntry(
      id: (json['id'] as num?)?.toInt() ?? 0,
      email: json['email']?.toString() ?? '',
      reason: json['reason'] as String?,
      source: json['source']?.toString() ?? 'web',
      status: json['status']?.toString() ?? 'pending',
      createdAt:
          DateTime.tryParse(json['created_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

final moneyFormat = NumberFormat.currency(symbol: 'NGN ', decimalDigits: 2);
final compactFormat = NumberFormat.compact();

class AuthScreen extends StatefulWidget {
  const AuthScreen({
    super.key,
    required this.api,
    required this.onSignedIn,
    required this.themeMode,
    required this.onThemeModeChanged,
  });

  final ApiClient api;
  final VoidCallback onSignedIn;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final email = TextEditingController();
  final password = TextEditingController();
  final fullName = TextEditingController();
  bool registerMode = false;
  bool busy = false;
  String? emailError;
  String? passwordError;
  late Future<LandingMarketData> landingFuture = _loadLandingData();
  late final Future<PackageInfo> packageInfoFuture = PackageInfo.fromPlatform();
  Timer? landingRefreshTimer;
  Timer? marketMotionTimer;
  int marketHeadlineIndex = 0;

  @override
  void initState() {
    super.initState();
    landingRefreshTimer = Timer.periodic(const Duration(seconds: 45), (_) {
      if (!mounted) return;
      setState(() {
        landingFuture = _loadLandingData();
      });
    });
    marketMotionTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!mounted) return;
      setState(() => marketHeadlineIndex++);
    });
  }

  @override
  void dispose() {
    landingRefreshTimer?.cancel();
    marketMotionTimer?.cancel();
    email.dispose();
    password.dispose();
    fullName.dispose();
    super.dispose();
  }

  Future<LandingMarketData> _loadLandingData() async {
    final status = await widget.api.publicMarketStatus();
    final leaders = await widget.api.publicMarketLeaders(limit: 6);
    return LandingMarketData(status: status, leaders: leaders);
  }

  bool _validateAuthForm() {
    final trimmedEmail = email.text.trim();
    final nextEmailError = trimmedEmail.isEmpty
        ? 'Enter a valid email.'
        : (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(trimmedEmail)
              ? 'Enter a valid email.'
              : null);
    final nextPasswordError = password.text.isEmpty
        ? 'Enter your password.'
        : (registerMode && password.text.length < 8
              ? 'Password must be at least 8 characters.'
              : null);
    setState(() {
      emailError = nextEmailError;
      passwordError = nextPasswordError;
    });
    return nextEmailError == null && nextPasswordError == null;
  }

  Future<void> submit() async {
    if (!_validateAuthForm()) return;
    setState(() => busy = true);
    try {
      if (registerMode) {
        await widget.api.register(
          email.text.trim(),
          password.text,
          fullName.text.trim(),
        );
      } else {
        await widget.api.login(email.text.trim(), password.text);
      }
      widget.onSignedIn();
    } catch (error) {
      if (mounted) showError(context, error.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _requestPasswordReset() async {
    final controller = TextEditingController(text: email.text.trim());
    try {
      final result = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Reset password'),
          content: TextField(
            controller: controller,
            keyboardType: TextInputType.emailAddress,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Registered email',
              hintText: 'name@example.com',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(context).pop(controller.text.trim()),
              child: const Text('Send reset link'),
            ),
          ],
        ),
      );
      if (!mounted || result == null) return;
      if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(result)) {
        showError(context, 'Enter a valid email address.');
        return;
      }
      setState(() => busy = true);
      final message = await widget.api.forgotPassword(result);
      if (!mounted) return;
      showMessage(context, message);
    } catch (error) {
      if (mounted) showError(context, error.toString());
    } finally {
      controller.dispose();
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _openLandingStockDetail(Stock stock) async {
    final compact = MediaQuery.of(context).size.width < 760;
    final content = LandingStockDetailSheet(api: widget.api, stock: stock);
    if (compact) {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (context) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.9,
          maxChildSize: 0.95,
          minChildSize: 0.65,
          builder: (context, scrollController) => content,
        ),
      );
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920, maxHeight: 760),
          child: content,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: FutureBuilder<LandingMarketData>(
        future: landingFuture,
        builder: (context, snapshot) {
          final landing = snapshot.data;
          final combinedLeaders = <Stock>[
            ...(landing?.leaders.topMovers ?? const <Stock>[]),
            ...(landing?.leaders.topLosers ?? const <Stock>[]),
          ];
          final headlineStock = combinedLeaders.isEmpty
              ? null
              : combinedLeaders[marketHeadlineIndex % combinedLeaders.length];

          return Container(
            decoration: BoxDecoration(color: theme.scaffoldBackgroundColor),
            child: SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final isDesktop = constraints.maxWidth >= 1120;
                  final authPanel = _AuthHeroPanel(
                    theme: theme,
                    registerMode: registerMode,
                    busy: busy,
                    fullName: fullName,
                    email: email,
                    emailError: emailError,
                    passwordError: passwordError,
                    password: password,
                    onSubmit: submit,
                    onForgotPassword: _requestPasswordReset,
                    onToggleMode: () => setState(() {
                      registerMode = !registerMode;
                      emailError = null;
                      passwordError = null;
                    }),
                    onEmailChanged: (_) => setState(() => emailError = null),
                    onPasswordChanged: (_) =>
                        setState(() => passwordError = null),
                  );
                  final marketView = _LandingMarketView(
                    theme: theme,
                    landing: landing,
                    loading:
                        snapshot.connectionState == ConnectionState.waiting &&
                        landing == null,
                    headlineStock: headlineStock,
                    onOpenStock: _openLandingStockDetail,
                  );
                  final themeButton = Align(
                    alignment: Alignment.centerRight,
                    child: ThemeModeButton(
                      themeMode: widget.themeMode,
                      onSelected: widget.onThemeModeChanged,
                    ),
                  );
                  final footer = Column(
                    children: [
                      const SizedBox(height: 18),
                      VersionLabel(packageInfoFuture: packageInfoFuture),
                      Text(
                        'Copyright 2026 Stockfolio NG',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  );

                  if (isDesktop) {
                    return SingleChildScrollView(
                      padding: const EdgeInsets.all(20),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minHeight: max(0, constraints.maxHeight - 40),
                        ),
                        child: Column(
                          children: [
                            themeButton,
                            const SizedBox(height: 12),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(width: 370, child: authPanel),
                                const SizedBox(width: 20),
                                Expanded(child: marketView),
                              ],
                            ),
                            footer,
                          ],
                        ),
                      ),
                    );
                  }

                  return RefreshIndicator(
                    onRefresh: () async {
                      setState(() {
                        landingFuture = _loadLandingData();
                      });
                      await landingFuture;
                    },
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        themeButton,
                        const SizedBox(height: 12),
                        authPanel,
                        const SizedBox(height: 16),
                        marketView,
                        footer,
                      ],
                    ),
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }
}

class _AuthHeroPanel extends StatelessWidget {
  const _AuthHeroPanel({
    required this.theme,
    required this.registerMode,
    required this.busy,
    required this.fullName,
    required this.email,
    required this.emailError,
    required this.password,
    required this.passwordError,
    required this.onSubmit,
    required this.onForgotPassword,
    required this.onToggleMode,
    required this.onEmailChanged,
    required this.onPasswordChanged,
  });

  final ThemeData theme;
  final bool registerMode;
  final bool busy;
  final TextEditingController fullName;
  final TextEditingController email;
  final String? emailError;
  final TextEditingController password;
  final String? passwordError;
  final Future<void> Function() onSubmit;
  final Future<void> Function() onForgotPassword;
  final VoidCallback onToggleMode;
  final ValueChanged<String> onEmailChanged;
  final ValueChanged<String> onPasswordChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: scheme.onSurfaceVariant,
      height: 1.4,
    );
    return Container(
      decoration: BoxDecoration(
        color: theme.brightness == Brightness.dark
            ? _darkSurface
            : Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: scheme.outlineVariant),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(
              alpha: theme.brightness == Brightness.dark ? 0.16 : 0.04,
            ),
            blurRadius: 28,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(Icons.candlestick_chart, color: scheme.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Stockfolio NG', style: theme.textTheme.titleLarge),
                      Text(
                        'Track Nigerian equities with live market context.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 32),
            Text(
              registerMode ? 'Create your account' : 'Welcome back',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              registerMode
                  ? 'Build a personal portfolio, watch movers, and follow your holdings with charts.'
                  : 'Sign in to your dashboard, portfolio alerts, charts, and market overview.',
              style: muted,
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: const [
                _LandingTag(icon: Icons.show_chart, text: 'Live market view'),
                _LandingTag(
                  icon: Icons.account_balance_wallet,
                  text: 'Portfolio tracking',
                ),
                _LandingTag(
                  icon: Icons.notifications_active_outlined,
                  text: 'Alerts',
                ),
              ],
            ),
            const SizedBox(height: 24),
            AutofillGroup(
              child: Column(
                children: [
                  if (registerMode) ...[
                    TextField(
                      controller: fullName,
                      autofillHints: const [AutofillHints.name],
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.badge_outlined),
                        labelText: 'Name',
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  TextField(
                    controller: email,
                    keyboardType: TextInputType.emailAddress,
                    onChanged: onEmailChanged,
                    autofillHints: registerMode
                        ? const [AutofillHints.newUsername, AutofillHints.email]
                        : const [AutofillHints.username, AutofillHints.email],
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.mail_outline),
                      labelText: 'Email',
                      errorText: emailError,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: password,
                    obscureText: true,
                    onChanged: onPasswordChanged,
                    autofillHints: registerMode
                        ? const [AutofillHints.newPassword]
                        : const [AutofillHints.password],
                    onSubmitted: (_) {
                      if (!busy) {
                        onSubmit();
                      }
                    },
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.lock_outline),
                      labelText: 'Password',
                      errorText: passwordError,
                    ),
                  ),
                ],
              ),
            ),
            if (!registerMode) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(
                    Icons.password_outlined,
                    size: 16,
                    color: theme.colorScheme.secondary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Your browser or device can offer to save this password after sign in.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 20),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: busy ? null : onSubmit,
                  icon: busy
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          registerMode ? Icons.person_add_alt_1 : Icons.login,
                        ),
                  label: Text(registerMode ? 'Create account' : 'Sign in'),
                ),
                if (!registerMode)
                  TextButton(
                    onPressed: busy ? null : onForgotPassword,
                    child: const Text('Forgot password?'),
                  ),
              ],
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: busy ? null : onToggleMode,
                child: Text(
                  registerMode ? 'Use existing account' : 'Create new account',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LandingMarketView extends StatelessWidget {
  const _LandingMarketView({
    required this.theme,
    required this.landing,
    required this.loading,
    required this.headlineStock,
    required this.onOpenStock,
  });

  final ThemeData theme;
  final LandingMarketData? landing;
  final bool loading;
  final Stock? headlineStock;
  final ValueChanged<Stock> onOpenStock;

  @override
  Widget build(BuildContext context) {
    final scheme = theme.colorScheme;
    final leaders = landing?.leaders;
    final movers = leaders?.topMovers ?? const <Stock>[];
    final losers = leaders?.topLosers ?? const <Stock>[];
    final chartStocks = [...movers.take(3), ...losers.take(2)];
    final status = landing?.status;
    final statusPalette = marketStatusPalette(
      theme,
      status?.status ?? 'UNKNOWN',
      stale: status?.stale ?? false,
    );
    final heroBackground = theme.brightness == Brightness.dark
        ? const LinearGradient(
            colors: [Color(0xFF132328), Color(0xFF0D181C)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          )
        : const LinearGradient(
            colors: [Color(0xFF10352F), Color(0xFF16443C)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            gradient: heroBackground,
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.14),
                blurRadius: 32,
                offset: const Offset(0, 18),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 10,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: statusPalette.container.withValues(
                        alpha: theme.brightness == Brightness.dark
                            ? 0.82
                            : 0.95,
                      ),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          statusPalette.icon,
                          size: 18,
                          color: statusPalette.content,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          landing == null
                              ? 'Market pulse loading'
                              : 'Market status: ${landing!.status.status}',
                          style: TextStyle(
                            color: statusPalette.content,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (landing?.status.message != null &&
                      landing!.status.message!.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        landing!.status.message!,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.82),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 18),
              Text(
                'See the market move before you even log in.',
                style: theme.textTheme.headlineMedium?.copyWith(
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Live movers, opening-versus-current momentum, and a portfolio-focused workflow for Nigerian equities.',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: Colors.white.withValues(alpha: 0.82),
                ),
              ),
              const SizedBox(height: 18),
              if (loading)
                const LinearProgressIndicator()
              else if (headlineStock != null)
                _LandingHeadlineCard(
                  stock: headlineStock!,
                  onTap: () => onOpenStock(headlineStock!),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _LandingMetricTile(
              label: 'Top movers tracked',
              value: movers.length.toString(),
              icon: Icons.local_fire_department_outlined,
              tone: const Color(0xFFDB5C19),
            ),
            _LandingMetricTile(
              label: 'Top losers tracked',
              value: losers.length.toString(),
              icon: Icons.trending_down_outlined,
              tone: const Color(0xFFB83232),
            ),
            _LandingMetricTile(
              label: 'Market mood',
              value: landing?.status.status ?? 'Loading',
              icon: Icons.wifi_tethering_outlined,
              tone: const Color(0xFF0E7C66),
            ),
          ],
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            final chartPanel = Container(
              constraints: const BoxConstraints(minHeight: 340),
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: theme.brightness == Brightness.dark
                    ? _darkSurface
                    : Colors.white,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: _LandingPulseChart(stocks: chartStocks),
            );
            final sidePanel = Column(
              children: [
                MarketLeaderPanel(
                  title: 'Top movers',
                  icon: Icons.local_fire_department_outlined,
                  stocks: movers,
                  positive: true,
                  onStockTap: onOpenStock,
                ),
                const SizedBox(height: 12),
                MarketLeaderPanel(
                  title: 'Top losers',
                  icon: Icons.trending_down_outlined,
                  stocks: losers,
                  positive: false,
                  onStockTap: onOpenStock,
                ),
              ],
            );

            if (constraints.maxWidth >= 980) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 8, child: chartPanel),
                  const SizedBox(width: 16),
                  Expanded(flex: 5, child: sidePanel),
                ],
              );
            }

            return Column(
              children: [chartPanel, const SizedBox(height: 12), sidePanel],
            );
          },
        ),
      ],
    );
  }
}

class _LandingHeadlineCard extends StatelessWidget {
  const _LandingHeadlineCard({required this.stock, required this.onTap});

  final Stock stock;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final positive = (stock.percentChange ?? 0) >= 0;
    final accent = positive ? const Color(0xFF5ED19B) : const Color(0xFFFFB4B4);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 500),
      child: InkWell(
        key: ValueKey(stock.symbol),
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
          ),
          child: Row(
            children: [
              CompanyLogo(symbol: stock.symbol, size: 46),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      stock.symbol,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 18,
                      ),
                    ),
                    Text(
                      stock.name ?? stock.symbol,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.72),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    stock.lastPrice == null
                        ? 'No price'
                        : moneyFormat.format(stock.lastPrice),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 18,
                    ),
                  ),
                  Text(
                    '${stock.percentChange?.toStringAsFixed(2) ?? '0.00'}%',
                    style: TextStyle(
                      color: accent,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LandingPulseChart extends StatelessWidget {
  const _LandingPulseChart({required this.stocks});

  final List<Stock> stocks;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (stocks.isEmpty) {
      return const EmptyState(
        icon: Icons.multiline_chart,
        text: 'Market graph is warming up.',
      );
    }

    final lines = <_LandingChartSeries>[];
    final allY = <double>[];
    final palette = <Color>[
      const Color(0xFF0E7C66),
      const Color(0xFFDB5C19),
      const Color(0xFF3A7BD5),
      const Color(0xFF9C27B0),
      const Color(0xFFB83232),
    ];

    for (var i = 0; i < stocks.length; i++) {
      final stock = stocks[i];
      final open = stock.openPrice ?? stock.lastPrice;
      final close = stock.lastPrice;
      if (open == null || close == null || open <= 0 || close <= 0) {
        continue;
      }
      final delta = close - open;
      final spots = List.generate(10, (index) {
        final t = index / 9;
        final curve = sin(t * pi) * delta * 0.22;
        final value = open + (delta * t) + curve;
        allY.add(value);
        return FlSpot(index.toDouble(), value);
      });
      lines.add(
        _LandingChartSeries(
          stock: stock,
          color: palette[i % palette.length],
          spots: spots,
        ),
      );
    }

    if (lines.isEmpty || allY.isEmpty) {
      return const EmptyState(
        icon: Icons.multiline_chart,
        text: 'Market graph is warming up.',
      );
    }

    final minY = allY.reduce(min);
    final maxY = allY.reduce(max);
    final padding = max(0.5, (maxY - minY) * 0.16);

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 640;
        final labels = compact
            ? {0: 'Open', 9: 'Now'}
            : {0: 'Open', 4: 'Noon', 9: 'Now'};
        String axisLabel(double value) {
          if (value >= 1000) {
            return '₦${compactFormat.format(value)}';
          }
          return value >= 10
              ? '₦${value.toStringAsFixed(0)}'
              : '₦${value.toStringAsFixed(2)}';
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Market pulse',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'A live-style view built from today’s opening price versus current market price.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: compact ? 250 : 230,
              child: LineChart(
                LineChartData(
                  minX: 0,
                  maxX: 9,
                  minY: minY - padding,
                  maxY: maxY + padding,
                  borderData: FlBorderData(show: false),
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: false,
                    getDrawingHorizontalLine: (_) =>
                        FlLine(color: chartGridColor(theme), strokeWidth: 1),
                  ),
                  titlesData: FlTitlesData(
                    topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 30,
                        getTitlesWidget: (value, meta) {
                          final index = value.round();
                          if ((value - index).abs() > 0.05 ||
                              !labels.containsKey(index)) {
                            return const SizedBox.shrink();
                          }
                          return Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              labels[index]!,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: compact ? 44 : 52,
                        interval: max(1.0, (maxY - minY) / 3),
                        getTitlesWidget: (value, meta) => Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Text(
                            axisLabel(value),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  lineBarsData: [
                    for (final line in lines)
                      LineChartBarData(
                        spots: line.spots,
                        isCurved: true,
                        barWidth: 3,
                        color: line.color,
                        dotData: const FlDotData(show: false),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 12,
              runSpacing: 10,
              children: [
                for (final line in lines)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: line.color.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: line.color.withValues(alpha: 0.18),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: line.color,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            '${line.stock.symbol} ${line.stock.percentChange?.toStringAsFixed(2) ?? '0.00'}%',
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _LandingChartSeries {
  const _LandingChartSeries({
    required this.stock,
    required this.color,
    required this.spots,
  });

  final Stock stock;
  final Color color;
  final List<FlSpot> spots;
}

class _LandingMetricTile extends StatelessWidget {
  const _LandingMetricTile({
    required this.label,
    required this.value,
    required this.icon,
    required this.tone,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SizedBox(
      width: 220,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: theme.brightness == Brightness.dark
              ? _darkSurface
              : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: tone.withValues(alpha: 0.12),
              child: Icon(icon, color: tone),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LandingTag extends StatelessWidget {
  const _LandingTag({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: scheme.primary),
          const SizedBox(width: 6),
          Text(text),
        ],
      ),
    );
  }
}

class EmailVerificationScreen extends StatefulWidget {
  const EmailVerificationScreen({
    super.key,
    required this.api,
    required this.token,
    required this.onDone,
  });

  final ApiClient api;
  final String token;
  final VoidCallback onDone;

  @override
  State<EmailVerificationScreen> createState() =>
      _EmailVerificationScreenState();
}

class _EmailVerificationScreenState extends State<EmailVerificationScreen> {
  late Future<String> future = widget.api.verifyEmailToken(widget.token);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: FutureBuilder<String>(
                future: future,
                builder: (context, snapshot) {
                  final done =
                      snapshot.connectionState != ConnectionState.waiting;
                  final failed = snapshot.hasError;
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        done
                            ? (failed
                                  ? Icons.error_outline
                                  : Icons.verified_outlined)
                            : Icons.mark_email_read_outlined,
                        size: 48,
                        color: failed
                            ? Colors.red.shade700
                            : Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        done
                            ? (failed
                                  ? 'Verification failed'
                                  : 'Email verified')
                            : 'Verifying email',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        done
                            ? (failed
                                  ? snapshot.error.toString()
                                  : snapshot.data ?? 'Email address verified.')
                            : 'Please wait while we confirm your email address.',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 18),
                      FilledButton.icon(
                        onPressed: done ? widget.onDone : null,
                        icon: const Icon(Icons.login),
                        label: const Text('Continue'),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ResetPasswordScreen extends StatefulWidget {
  const ResetPasswordScreen({
    super.key,
    required this.api,
    required this.token,
    required this.onDone,
  });

  final ApiClient api;
  final String token;
  final VoidCallback onDone;

  @override
  State<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends State<ResetPasswordScreen> {
  final password = TextEditingController();
  final confirmPassword = TextEditingController();
  bool busy = false;
  String? passwordError;
  String? confirmError;

  @override
  void dispose() {
    password.dispose();
    confirmPassword.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final nextPasswordError = password.text.length < 8
        ? 'Password must be at least 8 characters.'
        : null;
    final nextConfirmError = confirmPassword.text != password.text
        ? 'Passwords do not match.'
        : null;
    setState(() {
      passwordError = nextPasswordError;
      confirmError = nextConfirmError;
    });
    if (nextPasswordError != null || nextConfirmError != null) return;

    setState(() => busy = true);
    try {
      final message = await widget.api.resetPassword(
        widget.token,
        password.text,
      );
      if (!mounted) return;
      showMessage(context, message);
      widget.onDone();
    } catch (error) {
      if (mounted) showError(context, error.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Reset password',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Choose a new password for your Stockfolio NG account.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: password,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: 'New password',
                      errorText: passwordError,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: confirmPassword,
                    obscureText: true,
                    onSubmitted: (_) => busy ? null : _submit(),
                    decoration: InputDecoration(
                      labelText: 'Confirm password',
                      errorText: confirmError,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      FilledButton.icon(
                        onPressed: busy ? null : _submit,
                        icon: busy
                            ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.lock_reset),
                        label: const Text('Reset password'),
                      ),
                      const SizedBox(width: 12),
                      TextButton(
                        onPressed: busy ? null : widget.onDone,
                        child: const Text('Back to sign in'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ThemeModeButton extends StatelessWidget {
  const ThemeModeButton({
    super.key,
    required this.themeMode,
    required this.onSelected,
  });

  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final icon = switch (themeMode) {
      ThemeMode.light => Icons.light_mode_outlined,
      ThemeMode.dark => Icons.dark_mode_outlined,
      ThemeMode.system => Icons.brightness_auto_outlined,
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.16)),
      ),
      child: PopupMenuButton<ThemeMode>(
        tooltip: 'Theme',
        initialValue: themeMode,
        onSelected: onSelected,
        icon: Icon(icon, color: scheme.primary),
        itemBuilder: (context) => const [
          PopupMenuItem(value: ThemeMode.system, child: Text('System default')),
          PopupMenuItem(value: ThemeMode.light, child: Text('Light')),
          PopupMenuItem(value: ThemeMode.dark, child: Text('Dark')),
        ],
      ),
    );
  }
}

class LandingStockDetailSheet extends StatelessWidget {
  const LandingStockDetailSheet({
    super.key,
    required this.api,
    required this.stock,
  });

  final ApiClient api;
  final Stock stock;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<StockDetailBundle>(
      future: api.publicStockDetail(stock.symbol),
      builder: (context, snapshot) {
        final detail = snapshot.data;
        final resolvedStock = detail?.stock ?? stock;
        final points = detail?.history ?? [];
        final hasIntradayFallback =
            points.isEmpty &&
            (resolvedStock.openPrice ?? 0) > 0 &&
            (resolvedStock.lastPrice ?? 0) > 0;
        final latest = points.isEmpty ? null : points.last;
        final marketSnapshot = detail?.marketSnapshot;
        final news = detail?.news ?? [];
        final loading = snapshot.connectionState == ConnectionState.waiting;

        return Material(
          color: Theme.of(context).scaffoldBackgroundColor,
          child: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      CompanyLogo(symbol: resolvedStock.symbol, size: 42),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              resolvedStock.symbol,
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            Text(
                              resolvedStock.name ?? resolvedStock.symbol,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close',
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    height: 240,
                    child: loading
                        ? const Center(child: CircularProgressIndicator())
                        : hasIntradayFallback
                        ? _LandingPulseChart(stocks: [resolvedStock])
                        : points.isEmpty
                        ? const EmptyState(
                            icon: Icons.show_chart,
                            text: 'No chart data available yet.',
                          )
                        : PriceChart(points: points),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      StockDetailValue(
                        label: 'Current',
                        value: resolvedStock.lastPrice == null
                            ? 'Not available'
                            : moneyFormat.format(resolvedStock.lastPrice),
                      ),
                      StockDetailValue(
                        label: 'Opening',
                        value: latest == null
                            ? 'Not available'
                            : moneyFormat.format(latest.open),
                      ),
                      StockDetailValue(
                        label: 'Closing',
                        value: latest == null
                            ? 'Not available'
                            : moneyFormat.format(latest.close),
                      ),
                      StockDetailValue(
                        label: 'Volume',
                        value: resolvedStock.volume == null
                            ? 'Not available'
                            : compactFormat.format(resolvedStock.volume),
                      ),
                      StockDetailValue(
                        label: 'Market cap',
                        value: resolvedStock.marketCap == null
                            ? 'Not available'
                            : moneyFormat.format(resolvedStock.marketCap),
                      ),
                      StockDetailValue(
                        label: 'Margin',
                        value: resolvedStock.margin == null
                            ? 'Not available'
                            : '${resolvedStock.margin!.toStringAsFixed(2)}%',
                      ),
                      StockDetailValue(
                        label: 'ASI',
                        value: marketSnapshot?.asi == null
                            ? 'Not available'
                            : compactFormat.format(marketSnapshot!.asi),
                      ),
                      StockDetailValue(
                        label: 'Deals',
                        value: marketSnapshot?.deals == null
                            ? 'Not available'
                            : compactFormat.format(marketSnapshot!.deals),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'Company updates',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  if (news.isEmpty)
                    Text(
                      loading
                          ? 'Loading updates...'
                          : 'No recent updates available.',
                    )
                  else
                    ...news.map((item) => CompanyNewsTile(item: item)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class DashboardShell extends StatefulWidget {
  const DashboardShell({
    super.key,
    required this.api,
    required this.onSignOut,
    required this.themeMode,
    required this.onThemeModeChanged,
  });

  final ApiClient api;
  final Future<void> Function() onSignOut;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;

  @override
  State<DashboardShell> createState() => _DashboardShellState();
}

class _DashboardShellState extends State<DashboardShell> {
  int index = 0;
  late Future<AppUser> userFuture = widget.api.me();
  late final Future<PackageInfo> packageInfoFuture = PackageInfo.fromPlatform();
  late final Future<PushRegistrationResult> pushSetupFuture = PushNotifications
      .instance
      .ensureRegistered(registerToken: widget.api.registerPushToken);
  Timer? alertTimer;
  Timer? webSessionTimer;
  StreamSubscription<PushAlertMessage>? pushMessageSubscription;
  StreamSubscription<PushAlertMessage>? pushOpenSubscription;
  final Map<String, double> _lastSeenHoldingPrices = {};
  final Map<String, double> _lastAlertPrices = {};
  DateTime? webSessionDeadline;
  bool webSessionExtended = false;
  bool sessionPromptOpen = false;
  bool hideFinancialValues = false;

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(Duration.zero, _seedAlertBaseline);
    alertTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _checkPortfolioAlerts(),
    );
    if (kIsWeb) {
      Future<void>.delayed(Duration.zero, _loadWebSessionState);
      webSessionTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _handleWebSessionTick(),
      );
    }
    Future<void>.delayed(Duration.zero, _loadFinancialPrivacyState);
    pushMessageSubscription = PushNotifications.instance.messages.listen(
      _showPushMessage,
    );
    pushOpenSubscription = PushNotifications.instance.openedMessages.listen(
      _handlePushOpen,
    );
    Future<void>.delayed(Duration.zero, _handleInitialPushOpen);
  }

  @override
  void dispose() {
    alertTimer?.cancel();
    webSessionTimer?.cancel();
    pushMessageSubscription?.cancel();
    pushOpenSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadWebSessionState() async {
    if (!kIsWeb) return;
    final prefs = await SharedPreferences.getInstance();
    final deadlineMs = prefs.getInt(_webSessionDeadlineKey);
    final deadline = deadlineMs == null
        ? DateTime.now().add(const Duration(hours: 1))
        : DateTime.fromMillisecondsSinceEpoch(deadlineMs);
    final extended = prefs.getBool(_webSessionExtendedKey) ?? false;
    if (deadlineMs == null) {
      await prefs.setInt(
        _webSessionDeadlineKey,
        deadline.millisecondsSinceEpoch,
      );
      await prefs.setBool(_webSessionExtendedKey, extended);
    }
    if (!mounted) return;
    setState(() {
      webSessionDeadline = deadline;
      webSessionExtended = extended;
    });
    _handleWebSessionTick();
  }

  Future<void> _loadFinancialPrivacyState() async {
    final prefs = await SharedPreferences.getInstance();
    final hidden = prefs.getBool(_financialPrivacyPreferenceKey) ?? false;
    if (!mounted) return;
    setState(() {
      hideFinancialValues = hidden;
    });
  }

  Future<void> _toggleFinancialPrivacy() async {
    final next = !hideFinancialValues;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_financialPrivacyPreferenceKey, next);
    if (!mounted) return;
    setState(() {
      hideFinancialValues = next;
    });
  }

  Future<void> _handleWebSessionTick() async {
    if (!mounted ||
        !kIsWeb ||
        webSessionDeadline == null ||
        sessionPromptOpen) {
      return;
    }
    final remaining = webSessionDeadline!.difference(DateTime.now());
    if (remaining.isNegative || remaining.inSeconds == 0) {
      if (!webSessionExtended) {
        sessionPromptOpen = true;
        final extend = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            title: const Text('Session expired'),
            content: const Text(
              'Your web session has reached 1 hour. Extend it once for another 30 minutes?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Log out'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Extend 30 mins'),
              ),
            ],
          ),
        );
        sessionPromptOpen = false;
        if (extend == true) {
          final prefs = await SharedPreferences.getInstance();
          final nextDeadline = DateTime.now().add(const Duration(minutes: 30));
          await prefs.setInt(
            _webSessionDeadlineKey,
            nextDeadline.millisecondsSinceEpoch,
          );
          await prefs.setBool(_webSessionExtendedKey, true);
          if (!mounted) return;
          setState(() {
            webSessionDeadline = nextDeadline;
            webSessionExtended = true;
          });
          showMessage(context, 'Session extended for 30 minutes.');
          return;
        }
      }
      if (!mounted) return;
      showMessage(context, 'Your web session has ended. Please sign in again.');
      await widget.onSignOut();
      return;
    }
    if (mounted) {
      setState(() {});
    }
  }

  String? get sessionCountdownLabel {
    if (!kIsWeb || webSessionDeadline == null) return null;
    final remaining = webSessionDeadline!.difference(DateTime.now());
    if (remaining.isNegative) return 'Session ending';
    final hours = remaining.inHours;
    final minutes = remaining.inMinutes.remainder(60);
    final seconds = remaining.inSeconds.remainder(60);
    if (hours > 0) {
      return 'Session ${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return 'Session ${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  Future<void> _seedAlertBaseline() async {
    try {
      final holdings = await widget.api.holdings();
      for (final holding in holdings) {
        final currentPrice = holding.currentPrice;
        if (currentPrice != null && currentPrice > 0) {
          _lastSeenHoldingPrices[holding.symbol] = currentPrice;
        }
      }
    } catch (_) {}
  }

  Future<void> _checkPortfolioAlerts() async {
    if (!mounted) return;
    try {
      final holdings = await widget.api.holdings();
      final activeSymbols = holdings.map((holding) => holding.symbol).toSet();
      _lastSeenHoldingPrices.removeWhere(
        (symbol, _) => !activeSymbols.contains(symbol),
      );
      _lastAlertPrices.removeWhere(
        (symbol, _) => !activeSymbols.contains(symbol),
      );

      Holding? alertHolding;
      double? alertChange;

      for (final holding in holdings) {
        final currentPrice = holding.currentPrice;
        if (currentPrice == null || currentPrice <= 0) continue;

        final previousPrice = _lastSeenHoldingPrices[holding.symbol];
        final lastAlertPrice = _lastAlertPrices[holding.symbol];
        if (previousPrice != null && previousPrice > 0) {
          final change = (currentPrice - previousPrice) / previousPrice;
          final alreadyAlertedAtBand =
              lastAlertPrice != null &&
              lastAlertPrice > 0 &&
              ((currentPrice - lastAlertPrice).abs() / lastAlertPrice) < 0.05;
          if (change.abs() >= 0.05 && !alreadyAlertedAtBand) {
            if (alertHolding == null ||
                change.abs() > (alertChange?.abs() ?? 0)) {
              alertHolding = holding;
              alertChange = change;
            }
          }
        }

        _lastSeenHoldingPrices[holding.symbol] = currentPrice;
      }

      if (!mounted || alertHolding == null || alertChange == null) return;

      _lastAlertPrices[alertHolding.symbol] = alertHolding.currentPrice!;
      final directionText = alertChange >= 0
          ? 'is on fire today'
          : 'is sliding today';
      final movePercent = (alertChange.abs() * 100).toStringAsFixed(2);
      final priceText = moneyFormat.format(alertHolding.currentPrice);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              '${alertHolding.symbol} $directionText. Move: $movePercent%. Current price: $priceText',
            ),
            action: SnackBarAction(
              label: 'Portfolio',
              onPressed: () => setState(() => index = 1),
            ),
          ),
        );
    } catch (_) {}
  }

  void _showPushMessage(PushAlertMessage message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('${message.title}. ${message.body}'),
          action: SnackBarAction(
            label: 'Open',
            onPressed: () => _openPushDestination(message),
          ),
        ),
      );
  }

  Future<void> _handleInitialPushOpen() async {
    await pushSetupFuture;
    if (!mounted) return;
    final message = PushNotifications.instance.consumePendingOpenedMessage();
    if (message != null) {
      _handlePushOpen(message);
    }
  }

  void _handlePushOpen(PushAlertMessage message) {
    if (!mounted) return;
    _openPushDestination(message);
  }

  void _openPushDestination(PushAlertMessage message) {
    if (!mounted) return;
    final route = (message.route ?? '').trim().toLowerCase();
    var nextIndex = switch (route) {
      'home' => 0,
      'portfolio' => 1,
      'stocks' || 'stock' => 2,
      'charts' || 'chart' => 3,
      'profile' || 'account' => 4,
      _ => message.symbol?.trim().isNotEmpty == true ? 2 : 1,
    };
    setState(() => index = nextIndex);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isCompactLayout = MediaQuery.sizeOf(context).width < 900;
    return FutureBuilder<AppUser>(
      future: userFuture,
      builder: (context, snapshot) {
        final user = snapshot.data;
        final isAdmin = user?.isSuperuser ?? false;
        final screens = [
          HomeScreen(
            user: user,
            api: widget.api,
            hideFinancialValues: hideFinancialValues,
            onToggleFinancialPrivacy: _toggleFinancialPrivacy,
          ),
          PortfolioScreen(
            api: widget.api,
            hideFinancialValues: hideFinancialValues,
            onToggleFinancialPrivacy: _toggleFinancialPrivacy,
          ),
          StocksScreen(api: widget.api),
          ChartsScreen(api: widget.api),
          AccountScreen(
            api: widget.api,
            userFuture: userFuture,
            onSignOut: widget.onSignOut,
            onProfileChanged: () {
              setState(() {
                userFuture = widget.api.me();
              });
            },
            pushSetupFuture: pushSetupFuture,
          ),
          if (isAdmin)
            AdminScreen(api: widget.api, pushSetupFuture: pushSetupFuture),
        ];
        if (index >= screens.length) index = screens.length - 1;

        final destinations = [
          const NavigationDestination(
            icon: Icon(Icons.home_outlined),
            label: 'Home',
          ),
          const NavigationDestination(
            icon: Icon(Icons.account_balance_wallet_outlined),
            label: 'Portfolio',
          ),
          const NavigationDestination(
            icon: Icon(Icons.format_list_bulleted),
            label: 'Stocks',
          ),
          const NavigationDestination(
            icon: Icon(Icons.show_chart),
            label: 'Charts',
          ),
          const NavigationDestination(
            icon: Icon(Icons.person_outline),
            label: 'Profile',
          ),
          if (isAdmin)
            const NavigationDestination(
              icon: Icon(Icons.admin_panel_settings_outlined),
              label: 'Admin',
            ),
        ];

        final railDestinations = [
          const NavigationRailDestination(
            icon: Icon(Icons.home_outlined),
            label: Text('Home'),
          ),
          const NavigationRailDestination(
            icon: Icon(Icons.account_balance_wallet_outlined),
            label: Text('Portfolio'),
          ),
          const NavigationRailDestination(
            icon: Icon(Icons.format_list_bulleted),
            label: Text('Stocks'),
          ),
          const NavigationRailDestination(
            icon: Icon(Icons.show_chart),
            label: Text('Charts'),
          ),
          const NavigationRailDestination(
            icon: Icon(Icons.person_outline),
            label: Text('Profile'),
          ),
          if (isAdmin)
            const NavigationRailDestination(
              icon: Icon(Icons.admin_panel_settings_outlined),
              label: Text('Admin'),
            ),
        ];

        return Scaffold(
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            foregroundColor: Colors.white,
            elevation: 0,
            flexibleSpace: DecoratedBox(
              decoration: BoxDecoration(
                gradient: theme.brightness == Brightness.dark
                    ? const LinearGradient(
                        colors: [Color(0xFF10382F), Color(0xFF0A5B49)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      )
                    : const LinearGradient(
                        colors: [Color(0xFF008F68), Color(0xFF19C68D)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
              ),
            ),
            title: Text(
              user == null ? 'Stockfolio' : 'Welcome, ${user.firstName}',
            ),
            actions: [
              if (sessionCountdownLabel != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Chip(
                    label: Text(sessionCountdownLabel!),
                    avatar: Icon(
                      Icons.timer_outlined,
                      size: 18,
                      color: Colors.white,
                    ),
                    backgroundColor: Colors.white.withValues(alpha: 0.12),
                    side: BorderSide(
                      color: Colors.white.withValues(alpha: 0.18),
                    ),
                    labelStyle: const TextStyle(color: Colors.white),
                  ),
                ),
              const SizedBox(width: 8),
              if (!isCompactLayout)
                ThemeModeButton(
                  themeMode: widget.themeMode,
                  onSelected: widget.onThemeModeChanged,
                ),
              IconButton(
                tooltip: 'Sign out',
                onPressed: widget.onSignOut,
                icon: const Icon(Icons.logout),
              ),
            ],
          ),
          body: snapshot.connectionState == ConnectionState.waiting
              ? const Center(child: CircularProgressIndicator())
              : LayoutBuilder(
                  builder: (context, constraints) {
                    if (constraints.maxWidth >= 900) {
                      return Row(
                        children: [
                          NavigationRail(
                            selectedIndex: index,
                            onDestinationSelected: (value) =>
                                setState(() => index = value),
                            labelType: NavigationRailLabelType.all,
                            destinations: railDestinations,
                          ),
                          const VerticalDivider(width: 1),
                          Expanded(child: screens[index]),
                        ],
                      );
                    }
                    return screens[index];
                  },
                ),
          bottomNavigationBar: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isCompactLayout)
                BottomNavUtilityBar(
                  packageInfoFuture: packageInfoFuture,
                  themeMode: widget.themeMode,
                  onThemeSelected: widget.onThemeModeChanged,
                ),
              if (isCompactLayout)
                NavigationBar(
                  selectedIndex: index,
                  onDestinationSelected: (value) =>
                      setState(() => index = value),
                  destinations: destinations,
                ),
              if (!isCompactLayout)
                VersionLabel(packageInfoFuture: packageInfoFuture),
            ],
          ),
        );
      },
    );
  }
}

class VersionLabel extends StatelessWidget {
  const VersionLabel({
    super.key,
    required this.packageInfoFuture,
    this.centered = true,
    this.compact = false,
  });

  final Future<PackageInfo> packageInfoFuture;
  final bool centered;
  final bool compact;

  String get platformLabel {
    if (kIsWeb) return 'Web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'Android';
      case TargetPlatform.iOS:
        return 'iOS';
      case TargetPlatform.macOS:
        return 'macOS';
      case TargetPlatform.windows:
        return 'Windows';
      case TargetPlatform.linux:
        return 'Linux';
      case TargetPlatform.fuchsia:
        return 'Fuchsia';
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      bottom: !compact,
      child: FutureBuilder<PackageInfo>(
        future: packageInfoFuture,
        builder: (context, snapshot) {
          final info = snapshot.data;
          final packageVersion =
              info == null || info.version.isEmpty || info.buildNumber.isEmpty
              ? null
              : '${info.version}.${info.buildNumber}';
          final version = packageVersion ?? appDisplayVersion;
          final text = '$platformLabel $version';
          if (compact) {
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface.withValues(
                  alpha: Theme.of(context).brightness == Brightness.dark
                      ? 0.55
                      : 0.95,
                ),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
              child: Text(
                text,
                softWrap: false,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            );
          }
          return Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: SizedBox(
              width: double.infinity,
              child: Text(
                '$platformLabel version $version',
                textAlign: centered ? TextAlign.center : TextAlign.start,
                softWrap: false,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class BottomNavUtilityBar extends StatelessWidget {
  const BottomNavUtilityBar({
    super.key,
    required this.packageInfoFuture,
    required this.themeMode,
    required this.onThemeSelected,
  });

  final Future<PackageInfo> packageInfoFuture;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      bottom: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
        decoration: BoxDecoration(
          color: theme.brightness == Brightness.dark
              ? const Color(0xFF0F181C)
              : const Color(0xFFF9FCFF),
          border: Border(
            top: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: VersionLabel(
                  packageInfoFuture: packageInfoFuture,
                  centered: false,
                  compact: true,
                ),
              ),
            ),
            const SizedBox(width: 12),
            ThemeModeButton(themeMode: themeMode, onSelected: onThemeSelected),
          ],
        ),
      ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.user,
    required this.api,
    required this.hideFinancialValues,
    required this.onToggleFinancialPrivacy,
  });

  final AppUser? user;
  final ApiClient api;
  final bool hideFinancialValues;
  final Future<void> Function() onToggleFinancialPrivacy;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late Future<List<Holding>> holdingsFuture = widget.api.holdings();
  late Future<MarketLeaders> leadersFuture = widget.api.marketLeaders();
  late Future<MarketIdeasBundle> ideasFuture = widget.api.marketIdeas();
  Timer? refreshTimer;

  @override
  void initState() {
    super.initState();
    refreshTimer = Timer.periodic(const Duration(minutes: 15), (_) {
      if (mounted) refresh();
    });
  }

  @override
  void dispose() {
    refreshTimer?.cancel();
    super.dispose();
  }

  void refresh() {
    setState(() {
      holdingsFuture = widget.api.holdings();
      leadersFuture = widget.api.marketLeaders();
      ideasFuture = widget.api.marketIdeas();
    });
  }

  Future<void> _openStockDetail(Stock stock) async {
    final compact = MediaQuery.of(context).size.width < 760;
    final content = LandingStockDetailSheet(api: widget.api, stock: stock);
    if (compact) {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (context) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.9,
          maxChildSize: 0.95,
          minChildSize: 0.65,
          builder: (context, scrollController) => content,
        ),
      );
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920, maxHeight: 760),
          child: content,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return RefreshIndicator(
      onRefresh: () async => refresh(),
      child: FutureBuilder<List<Holding>>(
        future: holdingsFuture,
        builder: (context, snapshot) {
          final holdings = snapshot.data ?? [];
          final totalValue = holdings.fold<double>(
            0,
            (sum, item) => sum + item.totalValue,
          );
          final totalCost = holdings.fold<double>(
            0,
            (sum, item) => sum + item.totalCost,
          );
          final profitLoss = totalValue - totalCost;
          final profitPercent = totalCost == 0
              ? 0.0
              : (profitLoss / totalCost) * 100;
          Holding? bestHolding;
          Holding? weakestHolding;
          for (final holding in holdings) {
            final change = holding.profitLossPercent ?? 0;
            if (bestHolding == null ||
                change >
                    (bestHolding.profitLossPercent ??
                        double.negativeInfinity)) {
              bestHolding = holding;
            }
            if (weakestHolding == null ||
                change <
                    (weakestHolding.profitLossPercent ?? double.infinity)) {
              weakestHolding = holding;
            }
          }

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _PortfolioOverviewHero(
                totalValue: totalValue,
                profitLoss: profitLoss,
                profitPercent: profitPercent,
                holdingCount: holdings.length,
                bestHolding: bestHolding,
                weakestHolding: weakestHolding,
                hideFinancialValues: widget.hideFinancialValues,
                onToggleVisibility: widget.onToggleFinancialPrivacy,
              ),
              const SizedBox(height: 18),
              Text(
                'Your dashboard',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'A quick read on your portfolio health and the market leaders shaping today.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  MetricCard(
                    label: 'Unrealized return',
                    value: '${profitPercent.toStringAsFixed(2)}%',
                    icon: Icons.payments,
                    positive: profitLoss >= 0,
                  ),
                  MetricCard(
                    label: 'Best holding',
                    value: bestHolding == null
                        ? '-'
                        : '${bestHolding.symbol} ${(bestHolding.profitLossPercent ?? 0).toStringAsFixed(2)}%',
                    icon: Icons.emoji_events_outlined,
                    positive: (bestHolding?.profitLossPercent ?? 0) >= 0,
                  ),
                  MetricCard(
                    label: 'Needs attention',
                    value: weakestHolding == null
                        ? '-'
                        : '${weakestHolding.symbol} ${(weakestHolding.profitLossPercent ?? 0).toStringAsFixed(2)}%',
                    icon: profitLoss >= 0
                        ? Icons.monitor_heart_outlined
                        : Icons.warning_amber_rounded,
                    positive: false,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              FutureBuilder<MarketLeaders>(
                future: leadersFuture,
                builder: (context, leadersSnapshot) {
                  final leaders = leadersSnapshot.data;
                  if (leaders == null &&
                      leadersSnapshot.connectionState ==
                          ConnectionState.waiting) {
                    return const Card(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: LinearProgressIndicator(),
                      ),
                    );
                  }
                  return LayoutBuilder(
                    builder: (context, constraints) {
                      final moversPanel = MarketLeaderPanel(
                        title: 'Top movers',
                        icon: Icons.local_fire_department_outlined,
                        stocks: leaders?.topMovers ?? const [],
                        positive: true,
                        onStockTap: (stock) => _openStockDetail(stock),
                      );
                      final losersPanel = MarketLeaderPanel(
                        title: 'Top losers',
                        icon: Icons.trending_down_outlined,
                        stocks: leaders?.topLosers ?? const [],
                        positive: false,
                        onStockTap: (stock) => _openStockDetail(stock),
                      );
                      if (constraints.maxWidth >= 900) {
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: moversPanel),
                            const SizedBox(width: 12),
                            Expanded(child: losersPanel),
                          ],
                        );
                      }
                      return Column(
                        children: [
                          moversPanel,
                          const SizedBox(height: 12),
                          losersPanel,
                        ],
                      );
                    },
                  );
                },
              ),
              const SizedBox(height: 16),
              FutureBuilder<MarketIdeasBundle>(
                future: ideasFuture,
                builder: (context, ideasSnapshot) {
                  final ideas = ideasSnapshot.data;
                  if (ideas == null &&
                      ideasSnapshot.connectionState ==
                          ConnectionState.waiting) {
                    return const Card(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: LinearProgressIndicator(),
                      ),
                    );
                  }
                  if (ideas == null || ideas.ideas.isEmpty) {
                    return const SizedBox.shrink();
                  }
                  return MarketIdeasPanel(bundle: ideas);
                },
              ),
            ],
          );
        },
      ),
    );
  }
}

class AccountScreen extends StatefulWidget {
  const AccountScreen({
    super.key,
    required this.api,
    required this.userFuture,
    required this.onSignOut,
    required this.onProfileChanged,
    required this.pushSetupFuture,
  });

  final ApiClient api;
  final Future<AppUser> userFuture;
  final Future<void> Function() onSignOut;
  final VoidCallback onProfileChanged;
  final Future<PushRegistrationResult> pushSetupFuture;

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final fullName = TextEditingController();
  final phone = TextEditingController();
  final address = TextEditingController();
  final city = TextEditingController();
  final country = TextEditingController();
  final imagePicker = ImagePicker();
  int? loadedUserId;
  String? profileImageUrl;
  MemoryImage? profileImageMemory;
  bool savingProfile = false;
  bool sendingVerification = false;
  bool sendingReport = false;
  bool deletingAccount = false;
  bool pickingProfileImage = false;

  @override
  void dispose() {
    fullName.dispose();
    phone.dispose();
    address.dispose();
    city.dispose();
    country.dispose();
    super.dispose();
  }

  void loadUser(AppUser user) {
    if (loadedUserId == user.id) return;
    loadedUserId = user.id;
    fullName.text = user.fullName ?? '';
    _setProfileImage(user.profileImageUrl);
    phone.text = user.phone ?? '';
    address.text = user.address ?? '';
    city.text = user.city ?? '';
    country.text = user.country ?? '';
  }

  Future<void> saveProfile() async {
    setState(() => savingProfile = true);
    try {
      final updatedUser = await widget.api.updateProfile(
        ProfileInput(
          fullName: blankToNull(fullName.text),
          phone: blankToNull(phone.text),
          address: blankToNull(address.text),
          city: blankToNull(city.text),
          country: blankToNull(country.text),
        ),
      );
      loadedUserId = updatedUser.id;
      _setProfileImage(updatedUser.profileImageUrl);
      phone.text = updatedUser.phone ?? '';
      address.text = updatedUser.address ?? '';
      city.text = updatedUser.city ?? '';
      country.text = updatedUser.country ?? '';
      widget.onProfileChanged();
      if (mounted) showMessage(context, 'Profile updated.');
    } catch (error) {
      if (mounted) showError(context, error.toString());
    } finally {
      if (mounted) setState(() => savingProfile = false);
    }
  }

  Future<void> pickProfileImage() async {
    setState(() => pickingProfileImage = true);
    try {
      Uint8List? bytes;
      String mimeType = 'image/jpeg';
      String filename = 'profile.jpg';
      if (kIsWeb) {
        final picked = await pickProfileImageForWeb();
        if (picked != null) {
          bytes = Uint8List.fromList(picked.bytes);
          mimeType = picked.mimeType;
          final extension = switch (mimeType) {
            'image/png' => 'png',
            'image/gif' => 'gif',
            'image/webp' => 'webp',
            _ => 'jpg',
          };
          filename = 'profile.$extension';
        }
      } else {
        final file = await imagePicker.pickImage(
          source: ImageSource.gallery,
          imageQuality: 72,
          maxWidth: 720,
          maxHeight: 720,
        );
        if (file != null) {
          bytes = await file.readAsBytes();
          filename = file.name;
          if (file.mimeType != null && file.mimeType!.isNotEmpty) {
            mimeType = file.mimeType!;
          }
        }
      }
      if (bytes == null || bytes.isEmpty) return;
      final updatedUser = await widget.api.uploadProfileImage(
        bytes,
        mimeType: mimeType,
        filename: filename,
      );
      if (!mounted) return;
      setState(() {
        loadedUserId = updatedUser.id;
        _setProfileImage(updatedUser.profileImageUrl);
        fullName.text = updatedUser.fullName ?? fullName.text;
        phone.text = updatedUser.phone ?? '';
        address.text = updatedUser.address ?? '';
        city.text = updatedUser.city ?? '';
        country.text = updatedUser.country ?? '';
      });
      widget.onProfileChanged();
      showMessage(context, 'Profile photo updated.');
    } catch (error) {
      if (mounted) showError(context, error.toString());
    } finally {
      if (mounted) setState(() => pickingProfileImage = false);
    }
  }

  Future<void> clearProfileImage() async {
    setState(() => pickingProfileImage = true);
    try {
      final updatedUser = await widget.api.deleteProfileImage();
      if (!mounted) return;
      setState(() {
        loadedUserId = updatedUser.id;
        _setProfileImage(updatedUser.profileImageUrl);
      });
      widget.onProfileChanged();
      showMessage(context, 'Profile photo removed.');
    } catch (error) {
      if (mounted) showError(context, error.toString());
    } finally {
      if (mounted) setState(() => pickingProfileImage = false);
    }
  }

  void _setProfileImage(String? value) {
    profileImageUrl = value;
    profileImageMemory = null;
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty || !trimmed.startsWith('data:')) {
      return;
    }
    try {
      final data = UriData.parse(trimmed);
      profileImageMemory = MemoryImage(data.contentAsBytes());
    } catch (_) {}
  }

  Future<void> sendVerification() async {
    setState(() => sendingVerification = true);
    try {
      final message = await widget.api.requestEmailVerification();
      widget.onProfileChanged();
      if (mounted) {
        showMessage(
          context,
          message.toLowerCase().contains('sent')
              ? 'Check your email for the verification link.'
              : message,
        );
      }
    } catch (error) {
      if (mounted) showError(context, error.toString());
    } finally {
      if (mounted) setState(() => sendingVerification = false);
    }
  }

  Future<void> sendReport() async {
    setState(() => sendingReport = true);
    try {
      final message = await widget.api.emailPortfolioReport();
      if (mounted) showMessage(context, message);
    } catch (error) {
      if (mounted) showError(context, error.toString());
    } finally {
      if (mounted) setState(() => sendingReport = false);
    }
  }

  Future<void> changePassword() async {
    final result = await showDialog<PasswordInput>(
      context: context,
      builder: (context) => const PasswordDialog(),
    );
    if (result == null) return;
    try {
      final message = await widget.api.changePassword(
        result.currentPassword,
        result.newPassword,
      );
      if (mounted) showMessage(context, message);
    } catch (error) {
      if (mounted) showError(context, error.toString());
    }
  }

  Future<void> refreshPushSetup() async {
    try {
      final result = await PushNotifications.instance.ensureRegistered(
        registerToken: widget.api.registerPushToken,
      );
      if (mounted) showMessage(context, result.message);
    } catch (error) {
      if (mounted) showError(context, error.toString());
    }
  }

  Future<void> showPrivacyPolicy() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => LegalDocumentScreen(
          title: 'Privacy policy',
          sections: [
            LegalSection(
              heading: 'What Stockfolio NG stores',
              body:
                  'Stockfolio NG stores your account details, optional profile fields, and the portfolio information you enter, such as stock symbols, quantities, purchase prices, notes, and email verification state.',
            ),
            LegalSection(
              heading: 'How the data is used',
              body:
                  'Your data is used to authenticate you, show your portfolio, generate charts and reports, send account-related emails, and keep the service running securely.',
            ),
            LegalSection(
              heading: 'Sharing and providers',
              body:
                  'The app does not sell your personal data. Data may be processed by infrastructure and email delivery providers used to operate the service. Public market data comes from NGX-related endpoints.',
            ),
            LegalSection(
              heading: 'Retention and deletion',
              body:
                  'You can delete your account inside the app. That removes the account and associated portfolio records, except where data must be retained for security, fraud prevention, or legal compliance.',
            ),
          ],
          footerText:
              'Public policy URL: ${widget.api.privacyPolicyUrl}\nAccount deletion page: ${widget.api.accountDeletionUrl}',
        ),
      ),
    );
  }

  Future<void> showDeletionPolicy() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => LegalDocumentScreen(
          title: 'Account deletion',
          sections: [
            const LegalSection(
              heading: 'Delete inside the app',
              body:
                  'Use the Delete account action in the Account section to permanently remove your account and associated portfolio records after confirming your password.',
            ),
            const LegalSection(
              heading: 'Delete outside the app',
              body:
                  'If you cannot access the app, use the public account deletion page to submit a deletion request with your account email address.',
            ),
          ],
          footerText: 'Public deletion URL: ${widget.api.accountDeletionUrl}',
        ),
      ),
    );
  }

  Future<void> deleteAccount(AppUser user) async {
    final result = await showDialog<AccountDeletionInput>(
      context: context,
      builder: (context) => AccountDeletionDialog(email: user.email),
    );
    if (result == null) return;

    setState(() => deletingAccount = true);
    try {
      final message = await widget.api.deleteAccount(result.password);
      if (!mounted) return;
      showMessage(context, message);
      await widget.onSignOut();
    } catch (error) {
      if (mounted) showError(context, error.toString());
    } finally {
      if (mounted) setState(() => deletingAccount = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AppUser>(
      future: widget.userFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final user = snapshot.data;
        if (user == null) {
          return const EmptyState(
            icon: Icons.person_off_outlined,
            text: 'Profile could not be loaded.',
          );
        }
        loadUser(user);

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ProfileAvatar(
                          imageProvider: profileImageMemory,
                          imageUrl: profileImageUrl,
                          fallbackText: user.firstName,
                          radius: 30,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                user.displayName,
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                            ],
                          ),
                        ),
                        user.emailVerified
                            ? const Chip(
                                avatar: Icon(Icons.verified, size: 18),
                                label: Text('Verified'),
                              )
                            : ActionChip(
                                avatar: sendingVerification
                                    ? const SizedBox.square(
                                        dimension: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.error_outline, size: 18),
                                label: const Text('Unverified'),
                                onPressed: sendingVerification
                                    ? null
                                    : sendVerification,
                              ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        OutlinedButton.icon(
                          onPressed: pickingProfileImage
                              ? null
                              : pickProfileImage,
                          icon: pickingProfileImage
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.photo_camera_back_outlined),
                          label: const Text('Upload photo'),
                        ),
                        if (profileImageUrl != null)
                          OutlinedButton.icon(
                            onPressed: clearProfileImage,
                            icon: const Icon(Icons.delete_outline),
                            label: const Text('Remove photo'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    ProfileLine(
                      icon: Icons.alternate_email,
                      label: 'Email',
                      value: user.email,
                    ),
                    ProfileLine(
                      icon: Icons.verified_user_outlined,
                      label: 'Email status',
                      value: user.emailVerified ? 'Verified' : 'Not verified',
                    ),
                    ProfileLine(
                      icon: Icons.phone_outlined,
                      label: 'Phone',
                      value: user.phone ?? 'Not set',
                    ),
                    ProfileLine(
                      icon: Icons.home_outlined,
                      label: 'Address',
                      value: user.address ?? 'Not set',
                    ),
                    ProfileLine(
                      icon: Icons.location_city_outlined,
                      label: 'City',
                      value: user.city ?? 'Not set',
                    ),
                    ProfileLine(
                      icon: Icons.public,
                      label: 'Country',
                      value: user.country ?? 'Not set',
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            FutureBuilder<PushRegistrationResult>(
              future: widget.pushSetupFuture,
              builder: (context, snapshot) {
                final pushResult =
                    snapshot.data ?? PushNotifications.instance.lastResult;
                final enabled = pushResult.enabled;
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              enabled
                                  ? Icons.notifications_active_outlined
                                  : Icons.notifications_off_outlined,
                              color: enabled
                                  ? Colors.green.shade700
                                  : Colors.orange.shade800,
                            ),
                            const SizedBox(width: 10),
                            Text(
                              'Mobile push alerts',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(pushResult.message),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: refreshPushSetup,
                          icon: const Icon(Icons.notifications_active_outlined),
                          label: const Text('Refresh push setup'),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Update profile',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: fullName,
                      decoration: const InputDecoration(
                        labelText: 'Full name',
                        prefixIcon: Icon(Icons.person_outline),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: phone,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(
                        labelText: 'Phone',
                        prefixIcon: Icon(Icons.phone_outlined),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: address,
                      decoration: const InputDecoration(
                        labelText: 'Address',
                        prefixIcon: Icon(Icons.home_outlined),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        SizedBox(
                          width: 280,
                          child: TextField(
                            controller: city,
                            decoration: const InputDecoration(
                              labelText: 'City',
                              prefixIcon: Icon(Icons.location_city_outlined),
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 280,
                          child: TextField(
                            controller: country,
                            decoration: const InputDecoration(
                              labelText: 'Country',
                              prefixIcon: Icon(Icons.public),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.icon(
                        onPressed: savingProfile ? null : saveProfile,
                        icon: savingProfile
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.save_outlined),
                        label: const Text('Save profile'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                OutlinedButton.icon(
                  onPressed: showPrivacyPolicy,
                  icon: const Icon(Icons.privacy_tip_outlined),
                  label: const Text('Privacy policy'),
                ),
                OutlinedButton.icon(
                  onPressed: showDeletionPolicy,
                  icon: const Icon(Icons.policy_outlined),
                  label: const Text('Deletion policy'),
                ),
                FilledButton.icon(
                  onPressed: user.emailVerified || sendingVerification
                      ? null
                      : sendVerification,
                  icon: sendingVerification
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.mark_email_read_outlined),
                  label: const Text('Verify email'),
                ),
                OutlinedButton.icon(
                  onPressed: sendingReport ? null : sendReport,
                  icon: sendingReport
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.picture_as_pdf_outlined),
                  label: const Text('Email portfolio PDF'),
                ),
                OutlinedButton.icon(
                  onPressed: changePassword,
                  icon: const Icon(Icons.lock_reset),
                  label: const Text('Change password'),
                ),
                FilledButton.tonalIcon(
                  onPressed: deletingAccount ? null : () => deleteAccount(user),
                  icon: deletingAccount
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.delete_forever_outlined),
                  style: FilledButton.styleFrom(
                    foregroundColor: Colors.red.shade800,
                  ),
                  label: const Text('Delete account'),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class PortfolioScreen extends StatefulWidget {
  const PortfolioScreen({
    super.key,
    required this.api,
    required this.hideFinancialValues,
    required this.onToggleFinancialPrivacy,
  });

  final ApiClient api;
  final bool hideFinancialValues;
  final Future<void> Function() onToggleFinancialPrivacy;

  @override
  State<PortfolioScreen> createState() => _PortfolioScreenState();
}

class _PortfolioScreenState extends State<PortfolioScreen> {
  late Future<List<Holding>> future = widget.api.holdings();
  Holding? selectedHolding;
  Future<StockDetailBundle>? selectedDetailFuture;
  Timer? refreshTimer;

  @override
  void initState() {
    super.initState();
    refreshTimer = Timer.periodic(const Duration(minutes: 15), (_) {
      if (mounted) refresh();
    });
  }

  @override
  void dispose() {
    refreshTimer?.cancel();
    super.dispose();
  }

  void refresh() {
    setState(() {
      future = widget.api.holdings();
      if (selectedHolding != null) {
        selectedDetailFuture = widget.api.stockDetail(selectedHolding!.symbol);
      }
    });
  }

  void selectHolding(Holding holding) {
    setState(() {
      selectedHolding = holding;
      selectedDetailFuture = widget.api.stockDetail(holding.symbol);
    });
  }

  Future<void> addHolding([Holding? holding]) async {
    final result = await showDialog<HoldingInput>(
      context: context,
      builder: (context) => HoldingDialog(initial: holding),
    );
    if (result == null) return;
    try {
      await widget.api.saveHolding(result);
      refresh();
    } catch (error) {
      if (mounted) showError(context, error.toString());
    }
  }

  Future<void> remove(String symbol) async {
    try {
      await widget.api.deleteHolding(symbol);
      if (selectedHolding?.symbol == symbol) {
        selectedHolding = null;
        selectedDetailFuture = null;
      }
      refresh();
    } catch (error) {
      if (mounted) showError(context, error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Holding>>(
      future: future,
      builder: (context, snapshot) {
        final holdings = snapshot.data ?? [];
        final totalValue = holdings.fold<double>(
          0,
          (sum, item) => sum + item.totalValue,
        );
        final totalCost = holdings.fold<double>(
          0,
          (sum, item) => sum + item.totalCost,
        );
        final profitLoss = totalValue - totalCost;
        if (selectedHolding != null &&
            !holdings.any(
              (holding) => holding.symbol == selectedHolding!.symbol,
            )) {
          selectedHolding = null;
          selectedDetailFuture = null;
        }

        return RefreshIndicator(
          onRefresh: () async => refresh(),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  MetricCard(
                    label: 'Portfolio value',
                    value: widget.hideFinancialValues
                        ? '*****'
                        : moneyFormat.format(totalValue),
                    icon: Icons.payments,
                  ),
                  MetricCard(
                    label: 'Amount invested',
                    value: widget.hideFinancialValues
                        ? '*****'
                        : moneyFormat.format(totalCost),
                    icon: Icons.savings,
                  ),
                  MetricCard(
                    label: 'Profit / loss',
                    value: widget.hideFinancialValues
                        ? '*****'
                        : moneyFormat.format(profitLoss),
                    icon: profitLoss >= 0
                        ? Icons.trending_up
                        : Icons.trending_down,
                    positive: profitLoss >= 0,
                  ),
                  MetricCard(
                    label: widget.hideFinancialValues
                        ? 'Reveal totals'
                        : 'Hide totals',
                    value: widget.hideFinancialValues
                        ? 'Tap to show'
                        : 'Tap to hide',
                    icon: widget.hideFinancialValues
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                    onTap: widget.onToggleFinancialPrivacy,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: () => addHolding(),
                  icon: const Icon(Icons.add),
                  label: const Text('Add holding'),
                ),
              ),
              const SizedBox(height: 16),
              if (snapshot.connectionState == ConnectionState.waiting)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: CircularProgressIndicator(),
                  ),
                )
              else if (holdings.isEmpty)
                const EmptyState(
                  icon: Icons.account_balance_wallet_outlined,
                  text: 'No holdings yet.',
                )
              else
                LayoutBuilder(
                  builder: (context, constraints) {
                    final selected = selectedHolding;
                    final detail = PortfolioHoldingDetail(
                      holding: selected,
                      detailFuture: selectedDetailFuture,
                    );
                    final holdingCards = holdings
                        .map(
                          (holding) => HoldingTile(
                            holding: holding,
                            selected: holding.symbol == selected?.symbol,
                            onTap: () => selectHolding(holding),
                            onEdit: () => addHolding(holding),
                            onDelete: () => remove(holding.symbol),
                          ),
                        )
                        .toList();
                    if (constraints.maxWidth >= 980) {
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: Column(children: holdingCards)),
                          const SizedBox(width: 16),
                          SizedBox(width: 440, child: detail),
                        ],
                      );
                    }
                    return Column(
                      children: [
                        detail,
                        const SizedBox(height: 12),
                        ...holdingCards,
                      ],
                    );
                  },
                ),
            ],
          ),
        );
      },
    );
  }
}

class CompanyLogo extends StatelessWidget {
  const CompanyLogo({super.key, required this.symbol, this.size = 40});

  final String symbol;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final fallback = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer.withValues(alpha: 0.55),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Icon(
        Icons.business_outlined,
        size: size * 0.55,
        color: colorScheme.onPrimaryContainer,
      ),
    );

    Widget remoteLogo() {
      return Image.network(
        stockLogoUrl(symbol),
        width: size,
        height: size,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (context, error, stackTrace) => fallback,
        loadingBuilder: (context, child, loadingProgress) {
          if (loadingProgress == null) {
            return child;
          }
          return fallback;
        },
      );
    }

    final normalizedSymbol = symbol.trim().toUpperCase();
    final logo = curatedStockLogoSymbols.contains(normalizedSymbol)
        ? Image.asset(
            stockLogoAssetPath(normalizedSymbol),
            width: size,
            height: size,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (context, error, stackTrace) => remoteLogo(),
          )
        : remoteLogo();

    return ClipOval(child: logo);
  }
}

class HoldingTile extends StatelessWidget {
  const HoldingTile({
    super.key,
    required this.holding,
    required this.selected,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  final Holding holding;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      color: selected
          ? colorScheme.primaryContainer.withValues(alpha: 0.35)
          : null,
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 620) {
            return InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        CompanyLogo(symbol: holding.symbol),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                holding.symbol,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              Text(
                                holding.name ?? holding.symbol,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'Edit',
                          onPressed: onEdit,
                          icon: const Icon(Icons.edit_outlined),
                        ),
                        IconButton(
                          tooltip: 'Delete',
                          onPressed: onDelete,
                          icon: const Icon(Icons.delete_outline),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 18,
                      runSpacing: 8,
                      children: [
                        StockDetailValue(
                          label: 'Shares',
                          value: holding.quantity.toStringAsFixed(2),
                        ),
                        StockDetailValue(
                          label: 'Value',
                          value: moneyFormat.format(holding.totalValue),
                        ),
                        StockDetailValue(
                          label: 'P/L',
                          value:
                              '${holding.profitLossPercent?.toStringAsFixed(2) ?? '0.00'}%',
                          positive: holding.profitLoss >= 0,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          }

          return ListTile(
            onTap: onTap,
            leading: CompanyLogo(symbol: holding.symbol),
            title: Text(holding.symbol),
            subtitle: Text(
              '${holding.name ?? holding.symbol} - ${holding.quantity.toStringAsFixed(2)} shares',
            ),
            trailing: Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(moneyFormat.format(holding.totalValue)),
                    Text(
                      '${holding.profitLossPercent?.toStringAsFixed(2) ?? '0.00'}%',
                      style: TextStyle(
                        color: holding.profitLoss >= 0
                            ? Colors.green.shade700
                            : Colors.red.shade700,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                IconButton(
                  tooltip: 'Edit',
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit_outlined),
                ),
                IconButton(
                  tooltip: 'Delete',
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class StockDetailValue extends StatelessWidget {
  const StockDetailValue({
    super.key,
    required this.label,
    required this.value,
    this.positive,
  });

  final String label;
  final String value;
  final bool? positive;

  @override
  Widget build(BuildContext context) {
    final valueColor = positive == null
        ? null
        : positive!
        ? Colors.green.shade700
        : Colors.red.shade700;
    return SizedBox(
      width: 132,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(color: valueColor),
          ),
        ],
      ),
    );
  }
}

class PortfolioHoldingDetail extends StatelessWidget {
  const PortfolioHoldingDetail({
    super.key,
    required this.holding,
    required this.detailFuture,
  });

  final Holding? holding;
  final Future<StockDetailBundle>? detailFuture;

  @override
  Widget build(BuildContext context) {
    if (holding == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: EmptyState(
            icon: Icons.touch_app_outlined,
            text: 'Select a holding to view its chart and market details.',
          ),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: FutureBuilder<StockDetailBundle>(
          future: detailFuture,
          builder: (context, snapshot) {
            final detail = snapshot.data;
            final stock = detail?.stock;
            final points = detail?.history ?? [];
            final latest = points.isEmpty ? null : points.last;
            final marketSnapshot = detail?.marketSnapshot;
            final news = detail?.news ?? [];
            final loading = snapshot.connectionState == ConnectionState.waiting;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CompanyLogo(symbol: holding!.symbol, size: 44),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            holding!.symbol,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          Text(holding!.name ?? stock?.name ?? holding!.symbol),
                        ],
                      ),
                    ),
                    if (loading)
                      const SizedBox.square(
                        dimension: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                SizedBox(
                  height: 240,
                  child: points.isEmpty
                      ? const EmptyState(
                          icon: Icons.show_chart,
                          text: 'No chart data available yet.',
                        )
                      : PriceChart(points: points),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    StockDetailValue(
                      label: 'Current',
                      value: stock?.lastPrice == null
                          ? 'Not available'
                          : moneyFormat.format(stock!.lastPrice),
                    ),
                    StockDetailValue(
                      label: 'Opening',
                      value: latest == null
                          ? 'Not available'
                          : moneyFormat.format(latest.open),
                    ),
                    StockDetailValue(
                      label: 'Closing',
                      value: latest == null
                          ? 'Not available'
                          : moneyFormat.format(latest.close),
                    ),
                    StockDetailValue(
                      label: 'Volume',
                      value: stock?.volume == null
                          ? 'Not available'
                          : compactFormat.format(stock!.volume),
                    ),
                    StockDetailValue(
                      label: 'Market cap',
                      value: stock?.marketCap == null
                          ? 'Not available'
                          : moneyFormat.format(stock!.marketCap),
                    ),
                    StockDetailValue(
                      label: 'Margin',
                      value: stock?.margin == null
                          ? 'Not available'
                          : '${stock!.margin!.toStringAsFixed(2)}%',
                    ),
                    StockDetailValue(
                      label: 'ASI',
                      value: marketSnapshot?.asi == null
                          ? 'Not available'
                          : compactFormat.format(marketSnapshot!.asi),
                    ),
                    StockDetailValue(
                      label: 'Deals',
                      value: marketSnapshot?.deals == null
                          ? 'Not available'
                          : compactFormat.format(marketSnapshot!.deals),
                    ),
                    StockDetailValue(
                      label: 'Market value',
                      value: marketSnapshot?.value == null
                          ? 'Not available'
                          : moneyFormat.format(marketSnapshot!.value),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Text(
                  'Company updates',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                if (news.isEmpty)
                  Text(
                    loading
                        ? 'Loading updates...'
                        : 'No recent updates available.',
                  )
                else
                  ...news.map((item) => CompanyNewsTile(item: item)),
              ],
            );
          },
        ),
      ),
    );
  }
}

class CompanyNewsTile extends StatelessWidget {
  const CompanyNewsTile({super.key, required this.item});

  final CompanyNewsItem item;

  @override
  Widget build(BuildContext context) {
    final modified = item.modified == null
        ? null
        : DateFormat.yMMMd().format(item.modified!);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.description_outlined, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title ?? 'Untitled update',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                Text(
                  [item.submissionType?.trim(), modified]
                      .whereType<String>()
                      .where((value) => value.isNotEmpty)
                      .join(' - '),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class StocksScreen extends StatefulWidget {
  const StocksScreen({super.key, required this.api});

  final ApiClient api;

  @override
  State<StocksScreen> createState() => _StocksScreenState();
}

class _StocksScreenState extends State<StocksScreen> {
  final search = TextEditingController();
  late Future<List<Stock>> future = widget.api.stocks();
  late Future<MarketStatus> marketStatusFuture = widget.api.marketStatus();
  Stock? selectedStock;
  Future<StockDetailBundle>? selectedDetailFuture;
  Timer? refreshTimer;
  Timer? searchDebounce;
  String? searchHint;

  @override
  void initState() {
    super.initState();
    refreshTimer = Timer.periodic(const Duration(minutes: 15), (_) {
      if (mounted) refresh();
    });
  }

  @override
  void dispose() {
    refreshTimer?.cancel();
    searchDebounce?.cancel();
    search.dispose();
    super.dispose();
  }

  void refresh() {
    setState(() {
      future = widget.api.stocks(search: search.text.trim());
      marketStatusFuture = widget.api.marketStatus();
      if (selectedStock != null) {
        selectedDetailFuture = widget.api.stockDetail(selectedStock!.symbol);
      }
    });
  }

  void selectStock(Stock stock) {
    setState(() {
      selectedStock = stock;
      selectedDetailFuture = widget.api.stockDetail(stock.symbol);
    });
  }

  Future<void> addStock(Stock stock) async {
    final result = await showDialog<HoldingInput>(
      context: context,
      builder: (context) => HoldingDialog(selectedStock: stock),
    );
    if (result == null) return;
    try {
      await widget.api.saveHolding(result);
      if (mounted) {
        showMessage(context, '${stock.symbol} added to your portfolio');
      }
    } catch (error) {
      if (mounted) showError(context, error.toString());
    }
  }

  void onSearchChanged(String value) {
    searchDebounce?.cancel();
    final trimmed = value.trim();
    if (trimmed.isNotEmpty && trimmed.length < 3) {
      setState(() {
        searchHint = 'Enter at least 3 characters to see suggestions.';
      });
      return;
    }
    setState(() {
      searchHint = null;
    });
    searchDebounce = Timer(const Duration(milliseconds: 250), refresh);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: search,
                  onChanged: onSearchChanged,
                  onSubmitted: (_) {
                    final trimmed = search.text.trim();
                    if (trimmed.isEmpty || trimmed.length >= 3) {
                      refresh();
                    } else {
                      setState(() {
                        searchHint =
                            'Enter at least 3 characters to see suggestions.';
                      });
                    }
                  },
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    labelText: 'Search stocks',
                    helperText:
                        searchHint ?? 'Suggestions start after 3 characters.',
                  ),
                ),
              ),
            ],
          ),
        ),
        FutureBuilder<MarketStatus>(
          future: marketStatusFuture,
          builder: (context, snapshot) {
            final status = snapshot.data;
            if (status == null) {
              return const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: LinearProgressIndicator(),
              );
            }
            return MarketStatusBanner(status: status);
          },
        ),
        Expanded(
          child: FutureBuilder<List<Stock>>(
            future: future,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              final stocks = snapshot.data ?? [];
              if (stocks.isEmpty) {
                return const EmptyState(
                  icon: Icons.format_list_bulleted,
                  text: 'No stocks loaded yet.',
                );
              }
              if (selectedStock != null &&
                  !stocks.any(
                    (stock) => stock.symbol == selectedStock!.symbol,
                  )) {
                selectedStock = null;
                selectedDetailFuture = null;
              }
              return RefreshIndicator(
                onRefresh: () async => refresh(),
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (selectedStock != null) ...[
                      PortfolioHoldingDetail(
                        holding: Holding.fromStock(selectedStock!),
                        detailFuture: selectedDetailFuture,
                      ),
                      const SizedBox(height: 12),
                    ],
                    ...stocks.map(
                      (stock) => StockTile(
                        stock: stock,
                        selected: stock.symbol == selectedStock?.symbol,
                        onTap: () => selectStock(stock),
                        onAdd: () => addStock(stock),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class ChartsScreen extends StatefulWidget {
  const ChartsScreen({super.key, required this.api});

  final ApiClient api;

  @override
  State<ChartsScreen> createState() => _ChartsScreenState();
}

class _ChartsScreenState extends State<ChartsScreen> {
  static const List<int> rangeOptionsMonths = [3, 6, 12, 24];

  late Future<List<Stock>> stocksFuture = widget.api.stocks();
  Future<List<PricePoint>>? historyFuture;
  String? selectedSymbol;
  int selectedRangeMonths = 12;

  void selectStock(String? symbol) {
    setState(() {
      selectedSymbol = symbol;
      historyFuture = symbol == null
          ? null
          : widget.api.history(symbol, months: selectedRangeMonths);
    });
  }

  void selectRange(int months) {
    if (months == selectedRangeMonths) return;
    setState(() {
      selectedRangeMonths = months;
      historyFuture = selectedSymbol == null
          ? null
          : widget.api.history(selectedSymbol!, months: selectedRangeMonths);
    });
  }

  String rangeLabel(int months) {
    switch (months) {
      case 3:
        return '3M';
      case 6:
        return '6M';
      case 12:
        return '1Y';
      case 24:
        return '2Y';
      default:
        return '${months}M';
    }
  }

  String get _historySelectionKey =>
      '${selectedSymbol ?? 'none'}-$selectedRangeMonths';

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Stock>>(
      future: stocksFuture,
      builder: (context, snapshot) {
        final stocks = (snapshot.data ?? [])
            .where((stock) => stock.hasChart)
            .toList();
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (stocks.isEmpty) {
          return const EmptyState(
            icon: Icons.show_chart,
            text: 'No chart-enabled stocks loaded yet.',
          );
        }
        if (selectedSymbol == null ||
            !stocks.any((stock) => stock.symbol == selectedSymbol)) {
          selectedSymbol = stocks.first.symbol;
          historyFuture = widget.api.history(
            selectedSymbol!,
            months: selectedRangeMonths,
          );
        }
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            DropdownButtonFormField<String>(
              initialValue: selectedSymbol,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.business),
                labelText: 'Stock',
              ),
              items: stocks
                  .map(
                    (stock) => DropdownMenuItem(
                      value: stock.symbol,
                      child: Text(stockPickerLabel(stock)),
                    ),
                  )
                  .toList(),
              onChanged: selectStock,
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: rangeOptionsMonths
                  .map(
                    (months) => ChoiceChip(
                      label: Text(rangeLabel(months)),
                      selected: selectedRangeMonths == months,
                      onSelected: (_) => selectRange(months),
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 8),
            Text(
              'NGX public history currently backfills about 1 year. The 2Y view will deepen automatically as daily snapshots continue to accumulate in your database.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 360,
              child: Card(
                key: ValueKey(_historySelectionKey),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: historyFuture == null
                      ? const EmptyState(
                          icon: Icons.show_chart,
                          text: 'Select a stock to view price history.',
                        )
                      : FutureBuilder<List<PricePoint>>(
                          future: historyFuture,
                          builder: (context, historySnapshot) {
                            if (historySnapshot.connectionState ==
                                ConnectionState.waiting) {
                              return const Center(
                                child: CircularProgressIndicator(),
                              );
                            }
                            final points = historySnapshot.data ?? [];
                            if (points.isEmpty) {
                              return EmptyState(
                                icon: Icons.show_chart,
                                text:
                                    'No history available for the selected ${rangeLabel(selectedRangeMonths)} range yet.',
                              );
                            }
                            return PriceChart(
                              key: ValueKey(
                                '$_historySelectionKey-${points.length}-${points.first.date.toIso8601String()}-${points.last.date.toIso8601String()}',
                              ),
                              points: points,
                              rangeLabel: rangeLabel(selectedRangeMonths),
                            );
                          },
                        ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class AdminScreen extends StatefulWidget {
  const AdminScreen({
    super.key,
    required this.api,
    required this.pushSetupFuture,
  });

  final ApiClient api;
  final Future<PushRegistrationResult> pushSetupFuture;

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  late Future<SyncStatus> statusFuture = widget.api.syncStatus();
  late Future<List<SyncLogEntry>> logsFuture = widget.api.syncLogs();
  late Future<PushStatusSummary> pushStatusFuture = widget.api.pushStatus();
  late Future<List<AccountDeletionRequestEntry>> deletionRequestsFuture = widget
      .api
      .accountDeletionRequests();
  bool syncing = false;
  bool backfillingHistory = false;
  bool sendingTestPush = false;

  void refresh() {
    setState(() {
      statusFuture = widget.api.syncStatus();
      logsFuture = widget.api.syncLogs();
      pushStatusFuture = widget.api.pushStatus();
      deletionRequestsFuture = widget.api.accountDeletionRequests();
    });
  }

  Future<void> sync() async {
    setState(() => syncing = true);
    try {
      final message = await widget.api.syncStocks(includeHistory: false);
      refresh();
      if (mounted) showMessage(context, message);
    } catch (error) {
      if (mounted) showError(context, error.toString());
    } finally {
      if (mounted) setState(() => syncing = false);
    }
  }

  Future<void> backfillHistory() async {
    setState(() => backfillingHistory = true);
    try {
      final message = await widget.api.syncStocks(includeHistory: true);
      refresh();
      if (mounted) showMessage(context, message);
    } catch (error) {
      if (mounted) showError(context, error.toString());
    } finally {
      if (mounted) setState(() => backfillingHistory = false);
    }
  }

  Future<void> sendTestPush() async {
    setState(() => sendingTestPush = true);
    try {
      final message = await widget.api.sendTestPush();
      refresh();
      if (mounted) showMessage(context, message);
    } catch (error) {
      if (mounted) showError(context, error.toString());
    } finally {
      if (mounted) setState(() => sendingTestPush = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async => refresh(),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton.icon(
                onPressed: syncing ? null : sync,
                icon: syncing
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync),
                label: const Text('Sync NGX stocks'),
              ),
              OutlinedButton.icon(
                onPressed: backfillingHistory ? null : backfillHistory,
                icon: backfillingHistory
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.history),
                label: const Text('Backfill 1Y history'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          FutureBuilder<SyncStatus>(
            future: statusFuture,
            builder: (context, snapshot) {
              final status = snapshot.data;
              if (status == null) {
                return const Card(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: LinearProgressIndicator(),
                  ),
                );
              }
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            status.isStale
                                ? Icons.warning_amber
                                : Icons.check_circle_outline,
                            color: status.isStale
                                ? Colors.orange.shade800
                                : Colors.green.shade700,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            'Sync status: ${status.status}',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text('Stocks in database: ${status.stocksCount}'),
                      if (status.source != null)
                        Text('Source: ${status.source}'),
                      if (status.lastSuccessAt != null)
                        Text(
                          'Last success: ${DateFormat.yMd().add_jm().format(status.lastSuccessAt!.toLocal())}',
                        ),
                      if (status.message != null && status.message!.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(status.message!),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          FutureBuilder<PushStatusSummary>(
            future: pushStatusFuture,
            builder: (context, snapshot) {
              final pushStatus = snapshot.data;
              if (pushStatus == null) {
                return const Card(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: LinearProgressIndicator(),
                  ),
                );
              }
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            pushStatus.enabled
                                ? Icons.notifications_active_outlined
                                : Icons.notifications_off_outlined,
                            color: pushStatus.enabled
                                ? Colors.green.shade700
                                : Colors.orange.shade800,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            'Push notifications',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        pushStatus.enabled
                            ? 'Firebase push is configured on the backend.'
                            : 'Firebase push is not configured yet.',
                      ),
                      Text(
                        'Registered devices: ${pushStatus.registeredDevices}',
                      ),
                      Text(
                        'Users with devices: ${pushStatus.usersWithDevices}',
                      ),
                      Text(
                        'Alert threshold: ${pushStatus.thresholdPercent.toStringAsFixed(0)}%',
                      ),
                      if (pushStatus.projectId != null &&
                          pushStatus.projectId!.isNotEmpty)
                        Text('Project: ${pushStatus.projectId}'),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: pushStatus.enabled && !sendingTestPush
                            ? sendTestPush
                            : null,
                        icon: sendingTestPush
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.send_outlined),
                        label: const Text('Send test push'),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          FutureBuilder<List<AccountDeletionRequestEntry>>(
            future: deletionRequestsFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Card(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: LinearProgressIndicator(),
                  ),
                );
              }
              final requests = snapshot.data ?? [];
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Account deletion requests',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      if (requests.isEmpty)
                        const Text('No deletion requests yet.')
                      else
                        ...requests.map(
                          (request) => ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(
                              request.status == 'pending'
                                  ? Icons.pending_actions_outlined
                                  : Icons.check_circle_outline,
                            ),
                            title: Text(request.email),
                            subtitle: Text(
                              [
                                DateFormat.yMd().add_jm().format(
                                  request.createdAt.toLocal(),
                                ),
                                'Source: ${request.source}',
                                if (request.reason != null &&
                                    request.reason!.isNotEmpty)
                                  request.reason!,
                              ].join('\n'),
                            ),
                            isThreeLine:
                                request.reason != null &&
                                request.reason!.isNotEmpty,
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          FutureBuilder<List<SyncLogEntry>>(
            future: logsFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: CircularProgressIndicator(),
                  ),
                );
              }
              final logs = snapshot.data ?? [];
              if (logs.isEmpty) {
                return const EmptyState(
                  icon: Icons.manage_search,
                  text: 'No sync logs yet.',
                );
              }
              return Column(
                children: logs
                    .map(
                      (log) => Card(
                        child: ListTile(
                          leading: Icon(
                            log.status == 'success'
                                ? Icons.check_circle_outline
                                : Icons.warning_amber,
                            color: log.status == 'success'
                                ? Colors.green.shade700
                                : Colors.orange.shade800,
                          ),
                          title: Text('${log.status} - ${log.source}'),
                          subtitle: Text(
                            [
                              DateFormat.yMd().add_jms().format(
                                log.createdAt.toLocal(),
                              ),
                              '${log.stocksUpserted} stocks',
                              if (log.message != null &&
                                  log.message!.isNotEmpty)
                                log.message!,
                            ].join('\n'),
                          ),
                          isThreeLine:
                              log.message != null && log.message!.isNotEmpty,
                        ),
                      ),
                    )
                    .toList(),
              );
            },
          ),
        ],
      ),
    );
  }
}

class MarketStatusBanner extends StatelessWidget {
  const MarketStatusBanner({super.key, required this.status});

  final MarketStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = marketStatusPalette(
      theme,
      status.status,
      stale: status.stale,
    );
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.container,
        border: Border.all(color: palette.base.withValues(alpha: 0.24)),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: palette.base.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(palette.icon, color: palette.base),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Market status: ${status.status}',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: palette.content,
                  ),
                ),
                if (status.updatedAt != null)
                  Text(
                    'Updated ${DateFormat.yMd().add_jms().format(status.updatedAt!.toLocal())}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: palette.content.withValues(alpha: 0.88),
                    ),
                  ),
                if (status.message != null && status.message!.isNotEmpty)
                  Text(
                    status.message!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: palette.content.withValues(alpha: 0.88),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class HoldingDialog extends StatefulWidget {
  const HoldingDialog({super.key, this.initial, this.selectedStock});

  final Holding? initial;
  final Stock? selectedStock;

  @override
  State<HoldingDialog> createState() => _HoldingDialogState();
}

class _HoldingDialogState extends State<HoldingDialog> {
  bool get fromStockList => widget.selectedStock != null;

  late final symbol = TextEditingController(
    text: widget.initial?.symbol ?? widget.selectedStock?.symbol ?? '',
  );
  late final name = TextEditingController(
    text: widget.initial?.name ?? widget.selectedStock?.name ?? '',
  );
  late final quantity = TextEditingController(
    text: widget.initial?.quantity.toString() ?? '',
  );
  late final avgPrice = TextEditingController(
    text: widget.initial?.avgPurchasePrice.toString() ?? '',
  );
  late final currentPrice = TextEditingController(
    text:
        widget.initial?.currentPrice?.toString() ??
        widget.selectedStock?.lastPrice?.toString() ??
        '',
  );
  late final notes = TextEditingController(text: widget.initial?.notes ?? '');

  void submit() {
    final parsedQuantity = double.tryParse(quantity.text);
    final parsedAvgPrice = double.tryParse(avgPrice.text);
    if (symbol.text.trim().isEmpty ||
        parsedQuantity == null ||
        parsedAvgPrice == null) {
      showError(context, 'Symbol, quantity, and average price are required.');
      return;
    }
    Navigator.of(context).pop(
      HoldingInput(
        symbol: symbol.text.trim().toUpperCase(),
        quantity: parsedQuantity,
        avgPurchasePrice: parsedAvgPrice,
        manualName: fromStockList
            ? null
            : (name.text.trim().isEmpty ? null : name.text.trim()),
        manualCurrentPrice: fromStockList
            ? null
            : double.tryParse(currentPrice.text),
        notes: notes.text.trim().isEmpty ? null : notes.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.initial == null
            ? (fromStockList
                  ? 'Add ${widget.selectedStock!.symbol}'
                  : 'Add holding')
            : 'Edit holding',
      ),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: symbol,
                readOnly: fromStockList,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.tag),
                  labelText: 'Symbol',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: name,
                readOnly: fromStockList,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.business),
                  labelText: 'Name',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: quantity,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.numbers),
                  labelText: 'Quantity',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: avgPrice,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.price_change),
                  labelText: 'Average purchase price',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: currentPrice,
                readOnly: fromStockList,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  prefixIcon: Icon(Icons.payments),
                  labelText: fromStockList
                      ? 'Current NGX price'
                      : 'Manual current price',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: notes,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.notes),
                  labelText: 'Notes',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: submit,
          icon: const Icon(Icons.save),
          label: const Text('Save'),
        ),
      ],
    );
  }
}

class LegalSection {
  const LegalSection({required this.heading, required this.body});

  final String heading;
  final String body;
}

class LegalDocumentScreen extends StatelessWidget {
  const LegalDocumentScreen({
    super.key,
    required this.title,
    required this.sections,
    this.footerText,
  });

  final String title;
  final List<LegalSection> sections;
  final String? footerText;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final section in sections) ...[
                    Text(
                      section.heading,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(section.body),
                    const SizedBox(height: 16),
                  ],
                  if (footerText != null && footerText!.isNotEmpty)
                    SelectableText(footerText!),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class AccountDeletionInput {
  const AccountDeletionInput({required this.password});

  final String password;
}

class AccountDeletionDialog extends StatefulWidget {
  const AccountDeletionDialog({super.key, required this.email});

  final String email;

  @override
  State<AccountDeletionDialog> createState() => _AccountDeletionDialogState();
}

class _AccountDeletionDialogState extends State<AccountDeletionDialog> {
  final password = TextEditingController();
  bool confirmed = false;

  @override
  void dispose() {
    password.dispose();
    super.dispose();
  }

  void submit() {
    if (!confirmed) {
      showError(
        context,
        'Please confirm that you want to permanently delete the account.',
      );
      return;
    }
    if (password.text.isEmpty) {
      showError(context, 'Enter your current password to continue.');
      return;
    }
    Navigator.of(context).pop(AccountDeletionInput(password: password.text));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Delete account'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This will permanently delete the account ${widget.email} and the associated portfolio records.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: password,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Current password',
                prefixIcon: Icon(Icons.lock_outline),
              ),
            ),
            const SizedBox(height: 12),
            CheckboxListTile(
              value: confirmed,
              contentPadding: EdgeInsets.zero,
              onChanged: (value) => setState(() => confirmed = value ?? false),
              title: const Text('I understand this action is permanent.'),
              controlAffinity: ListTileControlAffinity.leading,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: submit,
          icon: const Icon(Icons.delete_forever_outlined),
          label: const Text('Delete account'),
        ),
      ],
    );
  }
}

class PasswordInput {
  const PasswordInput({
    required this.currentPassword,
    required this.newPassword,
  });

  final String currentPassword;
  final String newPassword;
}

class PasswordDialog extends StatefulWidget {
  const PasswordDialog({super.key});

  @override
  State<PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<PasswordDialog> {
  final currentPassword = TextEditingController();
  final newPassword = TextEditingController();
  final confirmPassword = TextEditingController();

  @override
  void dispose() {
    currentPassword.dispose();
    newPassword.dispose();
    confirmPassword.dispose();
    super.dispose();
  }

  void submit() {
    if (newPassword.text.length < 8) {
      showError(context, 'New password must be at least 8 characters.');
      return;
    }
    if (newPassword.text != confirmPassword.text) {
      showError(context, 'New passwords do not match.');
      return;
    }
    Navigator.of(context).pop(
      PasswordInput(
        currentPassword: currentPassword.text,
        newPassword: newPassword.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Change password'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: currentPassword,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Current password',
                prefixIcon: Icon(Icons.lock_outline),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: newPassword,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'New password',
                prefixIcon: Icon(Icons.lock_reset),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: confirmPassword,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Confirm new password',
                prefixIcon: Icon(Icons.verified_user_outlined),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: submit,
          icon: const Icon(Icons.lock_reset),
          label: const Text('Update password'),
        ),
      ],
    );
  }
}

class ProfileLine extends StatelessWidget {
  const ProfileLine({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 10),
          SizedBox(
            width: 94,
            child: Text(label, style: Theme.of(context).textTheme.labelMedium),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

class ProfileAvatar extends StatelessWidget {
  const ProfileAvatar({
    super.key,
    this.imageProvider,
    required this.imageUrl,
    required this.fallbackText,
    this.radius = 24,
  });

  final ImageProvider<Object>? imageProvider;
  final String? imageUrl;
  final String fallbackText;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final provider = imageProvider ?? profileImageProvider(imageUrl);
    final trimmed = fallbackText.trim();
    final firstLetter = trimmed.isEmpty
        ? '?'
        : trimmed.substring(0, 1).toUpperCase();
    return CircleAvatar(
      radius: radius,
      backgroundImage: provider,
      child: provider == null ? Text(firstLetter) : null,
    );
  }
}

class _PortfolioOverviewHero extends StatelessWidget {
  const _PortfolioOverviewHero({
    required this.totalValue,
    required this.profitLoss,
    required this.profitPercent,
    required this.holdingCount,
    required this.bestHolding,
    required this.weakestHolding,
    required this.hideFinancialValues,
    required this.onToggleVisibility,
  });

  final double totalValue;
  final double profitLoss;
  final double profitPercent;
  final int holdingCount;
  final Holding? bestHolding;
  final Holding? weakestHolding;
  final bool hideFinancialValues;
  final Future<void> Function() onToggleVisibility;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final positive = profitLoss >= 0;
    final accent = positive
        ? (theme.brightness == Brightness.dark
              ? const Color(0xFF6AF0C1)
              : _gainColor)
        : (theme.brightness == Brightness.dark
              ? const Color(0xFFFFA0B5)
              : _lossColor);
    final background = theme.brightness == Brightness.dark
        ? const LinearGradient(
            colors: [Color(0xFF0D2E33), Color(0xFF10251A), Color(0xFF161328)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          )
        : const LinearGradient(
            colors: [Color(0xFF041E42), Color(0xFF006F7A), Color(0xFF00A86B)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          );
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        gradient: background,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(
              alpha: theme.brightness == Brightness.dark ? 0.22 : 0.14,
            ),
            blurRadius: 26,
            offset: const Offset(0, 16),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  Icons.account_balance_wallet_outlined,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Portfolio snapshot',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$holdingCount holdings across your active watchlist.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: Colors.white.withValues(alpha: 0.78),
                      ),
                    ),
                  ],
                ),
              ),
              Chip(
                label: Text(
                  '${profitPercent.toStringAsFixed(2)}%',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                backgroundColor: accent.withValues(alpha: 0.28),
                side: BorderSide(color: accent.withValues(alpha: 0.42)),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                onPressed: onToggleVisibility,
                tooltip: hideFinancialValues ? 'Reveal totals' : 'Hide totals',
                icon: Icon(
                  hideFinancialValues
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
                style: IconButton.styleFrom(
                  backgroundColor: Colors.white.withValues(alpha: 0.12),
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          Text(
            hideFinancialValues ? '*****' : moneyFormat.format(totalValue),
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            hideFinancialValues
                ? '***** unrealized ${positive ? 'gain' : 'loss'}'
                : '${positive ? '+' : '-'}${moneyFormat.format(profitLoss.abs())} unrealized ${positive ? 'gain' : 'loss'}',
            style: theme.textTheme.titleMedium?.copyWith(
              color: accent,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _HeroInfoPill(
                icon: Icons.rocket_launch_outlined,
                label: 'Best today',
                value: bestHolding == null
                    ? '-'
                    : '${bestHolding!.symbol} ${(bestHolding!.profitLossPercent ?? 0).toStringAsFixed(2)}%',
              ),
              _HeroInfoPill(
                icon: Icons.remove_red_eye_outlined,
                label: 'Watch closely',
                value: weakestHolding == null
                    ? '-'
                    : '${weakestHolding!.symbol} ${(weakestHolding!.profitLossPercent ?? 0).toStringAsFixed(2)}%',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeroInfoPill extends StatelessWidget {
  const _HeroInfoPill({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      constraints: const BoxConstraints(minWidth: 190),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(
          alpha: theme.brightness == Brightness.dark ? 0.08 : 0.14,
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: Colors.white),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: Colors.white.withValues(alpha: 0.72),
                  ),
                ),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class MetricCard extends StatelessWidget {
  const MetricCard({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.positive,
    this.onTap,
  });

  final String label;
  final String value;
  final IconData icon;
  final bool? positive;
  final Future<void> Function()? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = positive == null
        ? theme.colorScheme.primary
        : (positive! ? _gainColor : _lossColor);
    return SizedBox(
      width: 260,
      child: Card(
        child: InkWell(
          onTap: onTap == null ? null : () => onTap!.call(),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: color.withValues(alpha: 0.12),
                  child: Icon(icon, color: color),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 4),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          value,
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class MarketLeaderPanel extends StatefulWidget {
  const MarketLeaderPanel({
    super.key,
    required this.title,
    required this.icon,
    required this.stocks,
    required this.positive,
    this.onStockTap,
  });

  final String title;
  final IconData icon;
  final List<Stock> stocks;
  final bool positive;
  final ValueChanged<Stock>? onStockTap;

  @override
  State<MarketLeaderPanel> createState() => _MarketLeaderPanelState();
}

class _MarketLeaderPanelState extends State<MarketLeaderPanel> {
  Timer? _rotationTimer;
  int _activeIndex = 0;

  @override
  void initState() {
    super.initState();
    _configureRotation();
  }

  @override
  void didUpdateWidget(covariant MarketLeaderPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.stocks.length != widget.stocks.length ||
        !_sameStockSequence(oldWidget.stocks, widget.stocks)) {
      _activeIndex = 0;
      _configureRotation();
    }
  }

  @override
  void dispose() {
    _rotationTimer?.cancel();
    super.dispose();
  }

  bool _sameStockSequence(List<Stock> previous, List<Stock> next) {
    if (previous.length != next.length) return false;
    for (var i = 0; i < previous.length; i++) {
      if (previous[i].symbol != next[i].symbol) return false;
    }
    return true;
  }

  void _configureRotation() {
    _rotationTimer?.cancel();
    if (widget.stocks.length <= 1) return;
    _rotationTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted || widget.stocks.length <= 1) return;
      setState(() {
        _activeIndex = (_activeIndex + 1) % widget.stocks.length;
      });
    });
  }

  void _selectIndex(int value) {
    if (value < 0 || value >= widget.stocks.length || value == _activeIndex) {
      return;
    }
    setState(() => _activeIndex = value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = widget.positive ? _gainColor : _lossColor;
    final cardGradient = widget.positive
        ? (theme.brightness == Brightness.dark
              ? const LinearGradient(
                  colors: [Color(0xFF0D2C27), Color(0xFF123E35)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                )
              : const LinearGradient(
                  colors: [Color(0xFFE7FFF5), Color(0xFFD9FFF0)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ))
        : (theme.brightness == Brightness.dark
              ? const LinearGradient(
                  colors: [Color(0xFF321822), Color(0xFF22141F)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                )
              : const LinearGradient(
                  colors: [Color(0xFFFFEEF3), Color(0xFFFFE4EB)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ));
    final stocks = widget.stocks;
    final activeIndex = stocks.isEmpty
        ? 0
        : _activeIndex.clamp(0, stocks.length - 1);
    final activeStock = stocks.isEmpty ? null : stocks[activeIndex];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(widget.icon, color: color),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (stocks.length > 1)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      'Live 5s',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: color,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              stocks.length > 1
                  ? 'Auto-rotating market pulse. Tap any card to open details.'
                  : 'Tap to open details.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 14),
            if (activeStock == null)
              const Text('No market leaders available yet.')
            else
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 550),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0.08, 0),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                ),
                child: InkWell(
                  key: ValueKey('${widget.title}-${activeStock.symbol}'),
                  onTap: widget.onStockTap == null
                      ? null
                      : () => widget.onStockTap!(activeStock),
                  borderRadius: BorderRadius.circular(24),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      gradient: cardGradient,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: color.withValues(alpha: 0.22)),
                      boxShadow: [
                        BoxShadow(
                          color: color.withValues(alpha: 0.1),
                          blurRadius: 20,
                          offset: const Offset(0, 12),
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            CompanyLogo(symbol: activeStock.symbol, size: 44),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    activeStock.symbol,
                                    style: theme.textTheme.titleLarge?.copyWith(
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    activeStock.name ?? activeStock.symbol,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: _LeaderValueChip(
                                label: 'Last price',
                                value: activeStock.lastPrice == null
                                    ? 'No price'
                                    : moneyFormat.format(activeStock.lastPrice),
                                accent: color,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _LeaderValueChip(
                                label: 'Change',
                                value:
                                    '${activeStock.percentChange?.toStringAsFixed(2) ?? '0.00'}%',
                                accent: color,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (stocks.length > 1) ...[
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var i = 0; i < stocks.length; i++)
                    _LeaderTickerChip(
                      stock: stocks[i],
                      selected: i == activeIndex,
                      accent: color,
                      onTap: () => _selectIndex(i),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  for (var i = 0; i < stocks.length; i++) ...[
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      width: i == activeIndex ? 22 : 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: i == activeIndex
                            ? color
                            : color.withValues(alpha: 0.22),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                    if (i != stocks.length - 1) const SizedBox(width: 6),
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _LeaderValueChip extends StatelessWidget {
  const _LeaderValueChip({
    required this.label,
    required this.value,
    required this.accent,
  });

  final String label;
  final String value;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accent.withValues(alpha: 0.16)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: theme.textTheme.titleSmall?.copyWith(
              color: accent,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _LeaderTickerChip extends StatelessWidget {
  const _LeaderTickerChip({
    required this.stock,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  final Stock stock;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: selected
              ? accent.withValues(alpha: 0.14)
              : theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected
                ? accent.withValues(alpha: 0.42)
                : theme.colorScheme.outlineVariant,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              stock.symbol,
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${stock.percentChange?.toStringAsFixed(2) ?? '0.00'}%',
              style: theme.textTheme.labelMedium?.copyWith(
                color: accent,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class MarketIdeasPanel extends StatelessWidget {
  const MarketIdeasPanel({super.key, required this.bundle});

  final MarketIdeasBundle bundle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.insights_outlined, color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Potential buy setups',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Analyzing ${bundle.stocksAnalyzed} NGX stocks',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              bundle.disclaimer,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 14),
            ...bundle.ideas.map(
              (idea) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest.withValues(
                      alpha: 0.28,
                    ),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  idea.stock.symbol,
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                if ((idea.stock.name ?? '').isNotEmpty)
                                  Text(
                                    idea.stock.name!,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              'Score ${idea.score.toStringAsFixed(1)}',
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: theme.colorScheme.onPrimaryContainer,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: idea.rationale
                            .map(
                              (reason) => Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.surface,
                                  borderRadius: BorderRadius.circular(999),
                                  border: Border.all(
                                    color: theme.colorScheme.outlineVariant,
                                  ),
                                ),
                                child: Text(
                                  reason,
                                  style: theme.textTheme.labelMedium,
                                ),
                              ),
                            )
                            .toList(),
                      ),
                      if (idea.webSummary != null &&
                          idea.webSummary!.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Text(
                          'Latest company update',
                          style: theme.textTheme.labelLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          idea.webSummary!,
                          style: theme.textTheme.bodyMedium,
                        ),
                      ],
                      if (idea.fundamentalNote != null &&
                          idea.fundamentalNote!.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Text(
                          idea.fundamentalNote!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class StockTile extends StatelessWidget {
  const StockTile({
    super.key,
    required this.stock,
    this.selected = false,
    this.onTap,
    this.onAdd,
  });

  final Stock stock;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final change = stock.percentChange ?? 0;
    final changeColor = change >= 0
        ? Colors.green.shade700
        : Colors.red.shade700;
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      color: selected
          ? colorScheme.primaryContainer.withValues(alpha: 0.35)
          : null,
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 620) {
            return InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        CompanyLogo(symbol: stock.symbol),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                stock.symbol,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              Text(
                                '${stock.name ?? stock.symbol}${stock.sector == null ? '' : ' - ${stock.sector}'}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        IconButton.filledTonal(
                          tooltip: 'Add to portfolio',
                          onPressed: onAdd,
                          icon: const Icon(Icons.add),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 18,
                      runSpacing: 8,
                      children: [
                        StockDetailValue(
                          label: 'Price',
                          value: stock.lastPrice == null
                              ? 'No price'
                              : moneyFormat.format(stock.lastPrice),
                        ),
                        StockDetailValue(
                          label: 'Change',
                          value: '${change.toStringAsFixed(2)}%',
                          positive: change >= 0,
                        ),
                        StockDetailValue(
                          label: 'Margin',
                          value: '${(stock.margin ?? 0).toStringAsFixed(2)}%',
                        ),
                        StockDetailValue(
                          label: 'Volume',
                          value: stock.volume == null
                              ? '-'
                              : compactFormat.format(stock.volume),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          }

          return ListTile(
            onTap: onTap,
            leading: CompanyLogo(symbol: stock.symbol),
            title: Text(stock.symbol),
            subtitle: Text(
              '${stock.name ?? stock.symbol}${stock.sector == null ? '' : ' - ${stock.sector}'}',
            ),
            trailing: Wrap(
              spacing: 18,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      stock.lastPrice == null
                          ? 'No price'
                          : moneyFormat.format(stock.lastPrice),
                    ),
                    Text(
                      '${change.toStringAsFixed(2)}%',
                      style: TextStyle(
                        color: changeColor,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    const Text('Margin'),
                    Text('${(stock.margin ?? 0).toStringAsFixed(2)}%'),
                  ],
                ),
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    const Text('Volume'),
                    Text(
                      stock.volume == null
                          ? '-'
                          : compactFormat.format(stock.volume),
                    ),
                  ],
                ),
                IconButton.filledTonal(
                  tooltip: 'Add to portfolio',
                  onPressed: onAdd,
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class PriceChart extends StatelessWidget {
  const PriceChart({super.key, required this.points, this.rangeLabel});

  final List<PricePoint> points;
  final String? rangeLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final values = [
      ...points.map((point) => point.open),
      ...points.map((point) => point.close),
    ];
    final minPrice = values.reduce(min);
    final maxPrice = values.reduce(max);
    final yPadding = max(1.0, (maxPrice - minPrice) * 0.12);
    final primary = Theme.of(context).colorScheme.primary;
    final secondary = Theme.of(context).colorScheme.tertiary;
    final latest = points.last;
    final earliest = points.first;
    final dateRangeLabel =
        '${DateFormat.MMMd().format(earliest.date)} - ${DateFormat.MMMd().format(latest.date)}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (rangeLabel != null)
              Text(
                '$rangeLabel view',
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            Text(
              dateRangeLabel,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 14,
          runSpacing: 8,
          children: [
            ChartLegendDot(
              color: secondary,
              label: 'Opening price: ${moneyFormat.format(latest.open)}',
            ),
            ChartLegendDot(
              color: primary,
              label: 'Closing price: ${moneyFormat.format(latest.close)}',
            ),
          ],
        ),
        const SizedBox(height: 10),
        Expanded(
          child: LineChart(
            LineChartData(
              minY: minPrice - yPadding,
              maxY: maxPrice + yPadding,
              gridData: FlGridData(
                show: true,
                drawVerticalLine: false,
                getDrawingHorizontalLine: (_) =>
                    FlLine(color: chartGridColor(theme), strokeWidth: 1),
              ),
              borderData: FlBorderData(show: false),
              titlesData: FlTitlesData(
                topTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
                rightTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 56,
                    getTitlesWidget: (value, meta) => Text(
                      compactFormat.format(value),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 32,
                    interval: max(1, points.length / 4).toDouble(),
                    getTitlesWidget: (value, meta) {
                      final index = value.round();
                      if (index < 0 || index >= points.length) {
                        return const SizedBox.shrink();
                      }
                      return Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          DateFormat.MMM().format(points[index].date),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              lineBarsData: [
                LineChartBarData(
                  spots: [
                    for (var i = 0; i < points.length; i++)
                      FlSpot(i.toDouble(), points[i].open),
                  ],
                  isCurved: true,
                  barWidth: 2,
                  color: secondary,
                  dotData: const FlDotData(show: false),
                ),
                LineChartBarData(
                  spots: [
                    for (var i = 0; i < points.length; i++)
                      FlSpot(i.toDouble(), points[i].close),
                  ],
                  isCurved: true,
                  barWidth: 3,
                  color: primary,
                  dotData: const FlDotData(show: false),
                  belowBarData: BarAreaData(
                    show: true,
                    color: primary.withValues(alpha: 0.12),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class ChartLegendDot extends StatelessWidget {
  const ChartLegendDot({super.key, required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label),
      ],
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 42, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

void showError(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), backgroundColor: Colors.red.shade700),
  );
}

void showMessage(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}
