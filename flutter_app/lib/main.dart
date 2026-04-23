import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_version.dart';
import 'config.dart';
import 'stock_logo_assets.dart';

final apiBaseUrl = normalizeApiBaseUrl(configuredApiBaseUrl());

String stockLogoUrl(String symbol) =>
    '$apiBaseUrl/public/stocks/${Uri.encodeComponent(symbol)}/logo';

String stockLogoAssetPath(String symbol) =>
    'assets/company_logos/${symbol.trim().toUpperCase()}.png';

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

void main() {
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

  @override
  void initState() {
    super.initState();
    emailVerificationToken = Uri.base.queryParameters['verify_email_token'];
    _loadToken();
  }

  Future<void> _loadToken() async {
    await api.restoreToken();
    setState(() {
      authenticated = api.hasToken;
      loading = false;
    });
  }

  void _signedIn() {
    setState(() => authenticated = true);
  }

  Future<void> _signOut() async {
    await api.clearToken();
    setState(() => authenticated = false);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'NGX Portfolio',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0E7C66),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF7F8FA),
        cardTheme: const CardThemeData(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
            side: BorderSide(color: Color(0xFFE1E5EA)),
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
          : authenticated
          ? DashboardShell(api: api, onSignOut: _signOut)
          : AuthScreen(api: api, onSignedIn: _signedIn),
    );
  }
}

class ApiClient {
  ApiClient(this.baseUrl);

  final String baseUrl;
  String? _token;

  bool get hasToken => _token != null && _token!.isNotEmpty;

  Future<void> restoreToken() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString('access_token');
  }

  Future<void> clearToken() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('access_token');
    _token = null;
  }

  Future<void> _saveToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('access_token', token);
    _token = token;
  }

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    if (_token != null) 'Authorization': 'Bearer $_token',
  };

  Uri _uri(String path, [Map<String, String>? query]) {
    return Uri.parse('$baseUrl$path').replace(queryParameters: query);
  }

  Future<void> register(String email, String password, String? fullName) async {
    final response = await http.post(
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
    final response = await http.post(
      _uri('/auth/login'),
      headers: _headers,
      body: jsonEncode({'email': email, 'password': password}),
    );
    _expect(response, 200);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    await _saveToken(data['access_token'] as String);
  }

  Future<AppUser> me() async {
    final response = await http.get(_uri('/me'), headers: _headers);
    _expect(response, 200);
    return AppUser.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<AppUser> updateProfile(ProfileInput input) async {
    final response = await http.put(
      _uri('/me'),
      headers: _headers,
      body: jsonEncode(input.toJson()),
    );
    _expect(response, 200);
    return AppUser.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<String> changePassword(
    String currentPassword,
    String newPassword,
  ) async {
    final response = await http.post(
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

  Future<String> requestEmailVerification() async {
    final response = await http.post(
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
    final response = await http.get(
      _uri('/auth/verify-email', {'token': token}),
      headers: _headers,
    );
    _expect(response, 200);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return data['message']?.toString() ?? 'Email address verified.';
  }

  Future<String> emailPortfolioReport() async {
    final response = await http.post(
      _uri('/me/portfolio-report/email'),
      headers: _headers,
    );
    _expect(response, 200);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return data['message']?.toString() ?? 'Portfolio report request complete.';
  }

  Future<List<Stock>> stocks({String? search}) async {
    final response = await http.get(
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

  Future<Stock> stock(String symbol) async {
    final response = await http.get(_uri('/stocks/$symbol'), headers: _headers);
    _expect(response, 200);
    return Stock.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<List<Holding>> holdings() async {
    final response = await http.get(
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
    final response = await http.post(
      _uri('/portfolio/holdings'),
      headers: _headers,
      body: jsonEncode(input.toJson()),
    );
    _expect(response, 200);
    return Holding.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<void> deleteHolding(String symbol) async {
    final response = await http.delete(
      _uri('/portfolio/holdings/$symbol'),
      headers: _headers,
    );
    _expect(response, 204);
  }

  Future<List<PricePoint>> history(String symbol) async {
    final response = await http.get(
      _uri('/stocks/$symbol/history', {'months': '12'}),
      headers: _headers,
    );
    _expect(response, 200);
    final data = jsonDecode(response.body) as List<dynamic>;
    return data
        .map((item) => PricePoint.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<String> syncStocks({bool includeHistory = false}) async {
    final response = await http.post(
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
    return 'Synced ${data['stocks_upserted']} stocks from ${data['source']}';
  }

  Future<SyncStatus> syncStatus() async {
    final response = await http.get(
      _uri('/admin/sync/status'),
      headers: _headers,
    );
    _expect(response, 200);
    return SyncStatus.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<List<SyncLogEntry>> syncLogs() async {
    final response = await http.get(
      _uri('/admin/sync/logs', {'limit': '50'}),
      headers: _headers,
    );
    _expect(response, 200);
    final data = jsonDecode(response.body) as List<dynamic>;
    return data
        .map((item) => SyncLogEntry.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<MarketStatus> marketStatus() async {
    final response = await http.get(_uri('/market/status'), headers: _headers);
    _expect(response, 200);
    return MarketStatus.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<MarketSnapshot> marketSnapshot() async {
    final response = await http.get(
      _uri('/market/snapshot'),
      headers: _headers,
    );
    _expect(response, 200);
    return MarketSnapshot.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<List<CompanyNewsItem>> companyNews(String symbol) async {
    final response = await http.get(
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

extension StringFallback on String {
  String withFallback(String fallback) => isEmpty ? fallback : this;
}

class Stock {
  Stock({
    required this.symbol,
    this.name,
    this.lastPrice,
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

  factory AppUser.fromJson(Map<String, dynamic> json) {
    return AppUser(
      id: (json['id'] as num?)?.toInt() ?? 0,
      email: json['email']?.toString() ?? '',
      fullName: json['full_name'] as String?,
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
    this.phone,
    this.address,
    this.city,
    this.country,
  });

  final String? fullName;
  final String? phone;
  final String? address;
  final String? city;
  final String? country;

  Map<String, dynamic> toJson() => {
    'full_name': fullName,
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

final moneyFormat = NumberFormat.currency(symbol: 'NGN ', decimalDigits: 2);
final compactFormat = NumberFormat.compact();

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, required this.api, required this.onSignedIn});

  final ApiClient api;
  final VoidCallback onSignedIn;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final email = TextEditingController();
  final password = TextEditingController();
  final fullName = TextEditingController();
  bool registerMode = false;
  bool busy = false;

  Future<void> submit() async {
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'NGX Portfolio',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      registerMode
                          ? 'Create an account to track holdings.'
                          : 'Sign in to view your dashboard.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 24),
                    if (registerMode) ...[
                      TextField(
                        controller: fullName,
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
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.mail_outline),
                        labelText: 'Email',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: password,
                      obscureText: true,
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.lock_outline),
                        labelText: 'Password',
                      ),
                    ),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: busy ? null : submit,
                      icon: busy
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.login),
                      label: Text(registerMode ? 'Create account' : 'Sign in'),
                    ),
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => setState(() => registerMode = !registerMode),
                      child: Text(
                        registerMode
                            ? 'Use existing account'
                            : 'Create new account',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
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

class DashboardShell extends StatefulWidget {
  const DashboardShell({super.key, required this.api, required this.onSignOut});

  final ApiClient api;
  final Future<void> Function() onSignOut;

  @override
  State<DashboardShell> createState() => _DashboardShellState();
}

class _DashboardShellState extends State<DashboardShell> {
  int index = 0;
  late Future<AppUser> userFuture = widget.api.me();
  late final Future<PackageInfo> packageInfoFuture = PackageInfo.fromPlatform();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AppUser>(
      future: userFuture,
      builder: (context, snapshot) {
        final user = snapshot.data;
        final isAdmin = user?.isSuperuser ?? false;
        final screens = [
          HomeScreen(user: user, api: widget.api),
          PortfolioScreen(api: widget.api),
          StocksScreen(api: widget.api),
          ChartsScreen(api: widget.api),
          AccountScreen(
            api: widget.api,
            userFuture: userFuture,
            onProfileChanged: () {
              setState(() => userFuture = widget.api.me());
            },
          ),
          if (isAdmin) AdminScreen(api: widget.api),
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
            label: 'Account',
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
            label: Text('Account'),
          ),
          if (isAdmin)
            const NavigationRailDestination(
              icon: Icon(Icons.admin_panel_settings_outlined),
              label: Text('Admin'),
            ),
        ];

        return Scaffold(
          appBar: AppBar(
            title: Text(
              user == null ? 'NGX Portfolio' : 'Welcome, ${user.displayName}',
            ),
            actions: [
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
              if (MediaQuery.sizeOf(context).width < 900)
                NavigationBar(
                  selectedIndex: index,
                  onDestinationSelected: (value) =>
                      setState(() => index = value),
                  destinations: destinations,
                ),
              VersionLabel(packageInfoFuture: packageInfoFuture),
            ],
          ),
        );
      },
    );
  }
}

class VersionLabel extends StatelessWidget {
  const VersionLabel({super.key, required this.packageInfoFuture});

  final Future<PackageInfo> packageInfoFuture;

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
      child: FutureBuilder<PackageInfo>(
        future: packageInfoFuture,
        builder: (context, snapshot) {
          final info = snapshot.data;
          final packageVersion = info == null || info.version.isEmpty
              ? null
              : '${info.version}+${info.buildNumber}';
          final version = packageVersion ?? appDisplayVersion;
          return Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: SizedBox(
              width: double.infinity,
              child: Text(
                '$platformLabel version $version',
                textAlign: TextAlign.center,
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

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.user, required this.api});

  final AppUser? user;
  final ApiClient api;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Holding>>(
      future: api.holdings(),
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

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Welcome, ${user?.displayName ?? 'investor'}',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 4),
            Text(
              user?.email ?? '',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                MetricCard(
                  label: 'Portfolio value',
                  value: moneyFormat.format(totalValue),
                  icon: Icons.payments,
                ),
                MetricCard(
                  label: 'Holdings',
                  value: holdings.length.toString(),
                  icon: Icons.pie_chart_outline,
                ),
                MetricCard(
                  label: 'Profit / loss',
                  value: moneyFormat.format(profitLoss),
                  icon: profitLoss >= 0
                      ? Icons.trending_up
                      : Icons.trending_down,
                  positive: profitLoss >= 0,
                ),
              ],
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Profile',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    ProfileLine(
                      icon: Icons.verified_user_outlined,
                      label: 'Email status',
                      value: user?.emailVerified == true
                          ? 'Verified'
                          : 'Not verified',
                    ),
                    ProfileLine(
                      icon: Icons.phone_outlined,
                      label: 'Phone',
                      value: user?.phone ?? 'Not set',
                    ),
                    ProfileLine(
                      icon: Icons.location_on_outlined,
                      label: 'Location',
                      value: [user?.city, user?.country]
                          .whereType<String>()
                          .where((value) => value.isNotEmpty)
                          .join(', ')
                          .withFallback('Not set'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class AccountScreen extends StatefulWidget {
  const AccountScreen({
    super.key,
    required this.api,
    required this.userFuture,
    required this.onProfileChanged,
  });

  final ApiClient api;
  final Future<AppUser> userFuture;
  final VoidCallback onProfileChanged;

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final fullName = TextEditingController();
  final phone = TextEditingController();
  final address = TextEditingController();
  final city = TextEditingController();
  final country = TextEditingController();
  int? loadedUserId;
  bool savingProfile = false;
  bool sendingVerification = false;
  bool sendingReport = false;

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
    phone.text = user.phone ?? '';
    address.text = user.address ?? '';
    city.text = user.city ?? '';
    country.text = user.country ?? '';
  }

  Future<void> saveProfile() async {
    setState(() => savingProfile = true);
    try {
      await widget.api.updateProfile(
        ProfileInput(
          fullName: blankToNull(fullName.text),
          phone: blankToNull(phone.text),
          address: blankToNull(address.text),
          city: blankToNull(city.text),
          country: blankToNull(country.text),
        ),
      );
      loadedUserId = null;
      widget.onProfileChanged();
      if (mounted) showMessage(context, 'Profile updated.');
    } catch (error) {
      if (mounted) showError(context, error.toString());
    } finally {
      if (mounted) setState(() => savingProfile = false);
    }
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
                      children: [
                        CircleAvatar(
                          child: Text(
                            user.displayName.isEmpty
                                ? '?'
                                : user.displayName[0].toUpperCase(),
                          ),
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
                              Text(user.email),
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
                    const SizedBox(height: 16),
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
              ],
            ),
          ],
        );
      },
    );
  }
}

class PortfolioScreen extends StatefulWidget {
  const PortfolioScreen({super.key, required this.api});

  final ApiClient api;

  @override
  State<PortfolioScreen> createState() => _PortfolioScreenState();
}

class _PortfolioScreenState extends State<PortfolioScreen> {
  late Future<List<Holding>> future = widget.api.holdings();
  Holding? selectedHolding;
  Future<Stock>? selectedStockFuture;
  Future<List<PricePoint>>? selectedHistoryFuture;
  Future<MarketSnapshot>? selectedSnapshotFuture;
  Future<List<CompanyNewsItem>>? selectedNewsFuture;
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
        selectedStockFuture = widget.api.stock(selectedHolding!.symbol);
        selectedHistoryFuture = widget.api.history(selectedHolding!.symbol);
        selectedSnapshotFuture = widget.api.marketSnapshot();
        selectedNewsFuture = widget.api.companyNews(selectedHolding!.symbol);
      }
    });
  }

  void selectHolding(Holding holding) {
    setState(() {
      selectedHolding = holding;
      selectedStockFuture = widget.api.stock(holding.symbol);
      selectedHistoryFuture = widget.api.history(holding.symbol);
      selectedSnapshotFuture = widget.api.marketSnapshot();
      selectedNewsFuture = widget.api.companyNews(holding.symbol);
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
        selectedStockFuture = null;
        selectedHistoryFuture = null;
        selectedSnapshotFuture = null;
        selectedNewsFuture = null;
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
          selectedStockFuture = null;
          selectedHistoryFuture = null;
          selectedSnapshotFuture = null;
          selectedNewsFuture = null;
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
                    value: moneyFormat.format(totalValue),
                    icon: Icons.payments,
                  ),
                  MetricCard(
                    label: 'Amount invested',
                    value: moneyFormat.format(totalCost),
                    icon: Icons.savings,
                  ),
                  MetricCard(
                    label: 'Profit / loss',
                    value: moneyFormat.format(profitLoss),
                    icon: profitLoss >= 0
                        ? Icons.trending_up
                        : Icons.trending_down,
                    positive: profitLoss >= 0,
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
                      stockFuture: selectedStockFuture,
                      historyFuture: selectedHistoryFuture,
                      snapshotFuture: selectedSnapshotFuture,
                      newsFuture: selectedNewsFuture,
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
    required this.stockFuture,
    required this.historyFuture,
    required this.snapshotFuture,
    required this.newsFuture,
  });

  final Holding? holding;
  final Future<Stock>? stockFuture;
  final Future<List<PricePoint>>? historyFuture;
  final Future<MarketSnapshot>? snapshotFuture;
  final Future<List<CompanyNewsItem>>? newsFuture;

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
        child: FutureBuilder<Stock>(
          future: stockFuture,
          builder: (context, stockSnapshot) {
            final stock = stockSnapshot.data;
            return FutureBuilder<List<PricePoint>>(
              future: historyFuture,
              builder: (context, historySnapshot) {
                return FutureBuilder<MarketSnapshot>(
                  future: snapshotFuture,
                  builder: (context, snapshotSnapshot) {
                    return FutureBuilder<List<CompanyNewsItem>>(
                      future: newsFuture,
                      builder: (context, newsSnapshot) {
                        final points = historySnapshot.data ?? [];
                        final latest = points.isEmpty ? null : points.last;
                        final marketSnapshot = snapshotSnapshot.data;
                        final news = newsSnapshot.data ?? [];
                        final loading =
                            stockSnapshot.connectionState ==
                                ConnectionState.waiting ||
                            historySnapshot.connectionState ==
                                ConnectionState.waiting ||
                            snapshotSnapshot.connectionState ==
                                ConnectionState.waiting ||
                            newsSnapshot.connectionState ==
                                ConnectionState.waiting;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                CompanyLogo(symbol: holding!.symbol, size: 44),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        holding!.symbol,
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleLarge,
                                      ),
                                      Text(
                                        holding!.name ??
                                            stock?.name ??
                                            holding!.symbol,
                                      ),
                                    ],
                                  ),
                                ),
                                if (loading)
                                  const SizedBox.square(
                                    dimension: 22,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
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
                                      : compactFormat.format(
                                          marketSnapshot!.asi,
                                        ),
                                ),
                                StockDetailValue(
                                  label: 'Deals',
                                  value: marketSnapshot?.deals == null
                                      ? 'Not available'
                                      : compactFormat.format(
                                          marketSnapshot!.deals,
                                        ),
                                ),
                                StockDetailValue(
                                  label: 'Market value',
                                  value: marketSnapshot?.value == null
                                      ? 'Not available'
                                      : moneyFormat.format(
                                          marketSnapshot!.value,
                                        ),
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
                                newsSnapshot.connectionState ==
                                        ConnectionState.waiting
                                    ? 'Loading updates...'
                                    : 'No recent updates available.',
                              )
                            else
                              ...news.map(
                                (item) => CompanyNewsTile(item: item),
                              ),
                          ],
                        );
                      },
                    );
                  },
                );
              },
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
  Future<Stock>? selectedStockFuture;
  Future<List<PricePoint>>? selectedHistoryFuture;
  Future<MarketSnapshot>? selectedSnapshotFuture;
  Future<List<CompanyNewsItem>>? selectedNewsFuture;
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
    search.dispose();
    super.dispose();
  }

  void refresh() {
    setState(() {
      future = widget.api.stocks(search: search.text.trim());
      marketStatusFuture = widget.api.marketStatus();
      if (selectedStock != null) {
        selectedStockFuture = widget.api.stock(selectedStock!.symbol);
        selectedHistoryFuture = widget.api.history(selectedStock!.symbol);
        selectedSnapshotFuture = widget.api.marketSnapshot();
        selectedNewsFuture = widget.api.companyNews(selectedStock!.symbol);
      }
    });
  }

  void selectStock(Stock stock) {
    setState(() {
      selectedStock = stock;
      selectedStockFuture = widget.api.stock(stock.symbol);
      selectedHistoryFuture = widget.api.history(stock.symbol);
      selectedSnapshotFuture = widget.api.marketSnapshot();
      selectedNewsFuture = widget.api.companyNews(stock.symbol);
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
                  onSubmitted: (_) => refresh(),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    labelText: 'Search stocks',
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
                selectedStockFuture = null;
                selectedHistoryFuture = null;
                selectedSnapshotFuture = null;
                selectedNewsFuture = null;
              }
              return RefreshIndicator(
                onRefresh: () async => refresh(),
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (selectedStock != null) ...[
                      PortfolioHoldingDetail(
                        holding: Holding.fromStock(selectedStock!),
                        stockFuture: selectedStockFuture,
                        historyFuture: selectedHistoryFuture,
                        snapshotFuture: selectedSnapshotFuture,
                        newsFuture: selectedNewsFuture,
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
  late Future<List<Stock>> stocksFuture = widget.api.stocks();
  Future<List<PricePoint>>? historyFuture;
  String? selectedSymbol;

  void selectStock(String? symbol) {
    setState(() {
      selectedSymbol = symbol;
      historyFuture = symbol == null ? null : widget.api.history(symbol);
    });
  }

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
          historyFuture = widget.api.history(selectedSymbol!);
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
                      child: Text(
                        '${stock.symbol} ${stock.name ?? ''} (${stock.ngxId})',
                      ),
                    ),
                  )
                  .toList(),
              onChanged: selectStock,
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 360,
              child: Card(
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
                              return const EmptyState(
                                icon: Icons.show_chart,
                                text: 'No one-year history available.',
                              );
                            }
                            return PriceChart(points: points);
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
  const AdminScreen({super.key, required this.api});

  final ApiClient api;

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  late Future<SyncStatus> statusFuture = widget.api.syncStatus();
  late Future<List<SyncLogEntry>> logsFuture = widget.api.syncLogs();
  bool syncing = false;

  void refresh() {
    setState(() {
      statusFuture = widget.api.syncStatus();
      logsFuture = widget.api.syncLogs();
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

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async => refresh(),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: syncing ? null : sync,
              icon: syncing
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync),
              label: const Text('Sync NGX stocks'),
            ),
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
    final normalized = status.status.toUpperCase().replaceAll('-', '_');
    final isPreOpen = normalized.contains('PRE_OPEN');
    final isStartIndex = normalized.contains('START_INDEX');
    final isEndOfDay =
        normalized.contains('ENDOFDAY') || normalized.contains('END_OF_DAY');
    final color = status.stale
        ? Colors.orange
        : isEndOfDay
        ? Colors.red
        : isStartIndex
        ? Colors.green
        : isPreOpen
        ? Colors.lightGreen
        : Colors.blueGrey;
    final icon = status.stale
        ? Icons.warning_amber
        : isEndOfDay
        ? Icons.lock_clock
        : isStartIndex
        ? Icons.trending_up
        : isPreOpen
        ? Icons.schedule
        : Icons.info_outline;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.shade50,
        border: Border.all(color: color.shade200),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(icon, color: color.shade800),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Market status: ${status.status}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                if (status.updatedAt != null)
                  Text(
                    'Updated ${DateFormat.yMd().add_jms().format(status.updatedAt!.toLocal())}',
                  ),
                if (status.message != null && status.message!.isNotEmpty)
                  Text(status.message!),
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

class MetricCard extends StatelessWidget {
  const MetricCard({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.positive,
  });

  final String label;
  final String value;
  final IconData icon;
  final bool? positive;

  @override
  Widget build(BuildContext context) {
    final color = positive == null
        ? Theme.of(context).colorScheme.primary
        : (positive! ? Colors.green : Colors.red);
    return SizedBox(
      width: 260,
      child: Card(
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
                    Text(label, style: Theme.of(context).textTheme.labelMedium),
                    const SizedBox(height: 4),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        value,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
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
  const PriceChart({super.key, required this.points});

  final List<PricePoint> points;

  @override
  Widget build(BuildContext context) {
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

    return Column(
      children: [
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
              gridData: const FlGridData(show: true, drawVerticalLine: false),
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
                    getTitlesWidget: (value, meta) =>
                        Text(compactFormat.format(value)),
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
