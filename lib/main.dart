import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:provider/provider.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_config.dart';
import 'sync_bus.dart';

part 'leanly_supabase.dart';

final FlutterLocalNotificationsPlugin notifications =
    FlutterLocalNotificationsPlugin();

/* ===================== Main ===================== */

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Hive
  await Hive.initFlutter();
  await Hive.openBox(Storage.boxName);

  if (SupabaseConfig.isConfigured) {
    await Supabase.initialize(
      url: SupabaseConfig.url,
      anonKey: SupabaseConfig.anonKey,
      authOptions: const FlutterAuthClientOptions(
        authFlowType: AuthFlowType.pkce,
      ),
    );
  }

  // Initialize timezone
  tz.initializeTimeZones();

  // Initialize notifications
  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  const iosInit = DarwinInitializationSettings(
    requestAlertPermission: true,
    requestBadgePermission: true,
    requestSoundPermission: false,
  );
  const initSettings = InitializationSettings(
    android: androidInit,
    iOS: iosInit,
  );
  await notifications.initialize(initSettings);

  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  bool _darkMode = Storage.loadDarkMode();
  AppTheme _theme = Storage.loadTheme();
  late final PremiumController _premiumController;

  @override
  void initState() {
    super.initState();
    _premiumController = PremiumController();
    // Listen to premium changes to update theme if needed
    _premiumController.addListener(_onPremiumChanged);
  }

  @override
  void dispose() {
    _premiumController.removeListener(_onPremiumChanged);
    _premiumController.dispose();
    super.dispose();
  }

  void _onPremiumChanged() {
    // If user loses premium, reset to default theme
    if (!_premiumController.isPremium && _theme != AppTheme.calm) {
      setState(() {
        _theme = AppTheme.calm;
      });
      Storage.saveTheme(AppTheme.calm);
    }
  }

  void toggleDarkMode(bool value) {
    setState(() {
      _darkMode = value;
    });
    Storage.saveDarkMode(value);
  }

  void setTheme(AppTheme theme) {
    setState(() {
      _theme = theme;
    });
    Storage.saveTheme(theme);
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: _premiumController),
        ChangeNotifierProvider(
          create: (_) {
            final auth = SupabaseAuthController();
            auth.attach();
            return auth;
          },
        ),
        ChangeNotifierProvider<CloudLoginGateNotifier>.value(
          value: CloudLoginGateNotifier.instance,
        ),
      ],
      child: MaterialApp(
        title: 'Leanly: Agile Planner',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(_theme, false),
        darkTheme: buildTheme(_theme, true),
        themeMode: _darkMode ? ThemeMode.dark : ThemeMode.light,
        home: AppShell(
          onDarkModeChanged: toggleDarkMode,
          onThemeChanged: setTheme,
        ),
      ),
    );
  }
}

/* ===================== Models ===================== */

enum TaskStatus { todo, doing, done }
enum Focus { work, personal, learning }
enum DayMood { good, meh, hard }
enum FlowMode { scrum, kanban }

FlowMode parseFlowMode(String name) {
  if (name == 'xp') return FlowMode.kanban;
  return FlowMode.values.firstWhere(
    (e) => e.name == name,
    orElse: () => FlowMode.kanban,
  );
}
enum AppTheme { calm, ocean, forest, sunset, darkProfessional }

IconData moodToIcon(DayMood m) {
  switch (m) {
    case DayMood.good:
      return Icons.sentiment_satisfied_alt_rounded;
    case DayMood.meh:
      return Icons.sentiment_neutral_rounded;
    case DayMood.hard:
      return Icons.sentiment_dissatisfied_rounded;
  }
}

String moodToLabel(DayMood m) {
  switch (m) {
    case DayMood.good:
      return 'Good';
    case DayMood.meh:
      return 'Meh';
    case DayMood.hard:
      return 'Hard';
  }
}

String titleCase(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + (s.length > 1 ? s.substring(1) : '');

class Task {
  final String id;
  String title;
  TaskStatus status;
  Focus focus;

  DateTime createdAt;
  DateTime updatedAt;

  // rollover metadata
  bool rolledOver;
  String? carriedOverFromDay; // YYYY-MM-DD

  // Scrum daily commitment
  bool committedToday;

  Task({
    required this.id,
    required this.title,
    required this.status,
    required this.focus,
    required this.createdAt,
    required this.updatedAt,
    this.rolledOver = false,
    this.carriedOverFromDay,
    this.committedToday = false,
  });

  Task copyWith({
    String? title,
    TaskStatus? status,
    Focus? focus,
    DateTime? updatedAt,
    bool? rolledOver,
    String? carriedOverFromDay,
    bool? committedToday,
  }) {
    return Task(
      id: id,
      title: title ?? this.title,
      status: status ?? this.status,
      focus: focus ?? this.focus,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rolledOver: rolledOver ?? this.rolledOver,
      carriedOverFromDay: carriedOverFromDay ?? this.carriedOverFromDay,
      committedToday: committedToday ?? this.committedToday,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'status': status.name,
        'focus': focus.name,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'rolledOver': rolledOver,
        'carriedOverFromDay': carriedOverFromDay,
        'committedToday': committedToday,
      };

  static Task fromJson(Map<String, dynamic> json) => Task(
        id: json['id'] as String,
        title: json['title'] as String,
        status: TaskStatus.values
            .firstWhere((e) => e.name == (json['status'] as String)),
        focus:
            Focus.values.firstWhere((e) => e.name == (json['focus'] as String)),
        createdAt: DateTime.parse(json['createdAt'] as String),
        updatedAt: DateTime.parse(
            (json['updatedAt'] as String?) ?? (json['createdAt'] as String)),
        rolledOver: (json['rolledOver'] as bool?) ?? false,
        carriedOverFromDay: json['carriedOverFromDay'] as String?,
        committedToday: (json['committedToday'] as bool?) ?? false,
      );
}

class DayLog {
  final String dayKey; // YYYY-MM-DD
  final DayMood mood;
  final FlowMode mode;
  final List<Map<String, dynamic>> tasksSnapshot;
  final DateTime archivedAt;

  DayLog({
    required this.dayKey,
    required this.mood,
    required this.mode,
    required this.tasksSnapshot,
    required this.archivedAt,
  });

  int get doneCount =>
      tasksSnapshot.where((t) => t['status'] == TaskStatus.done.name).length;

  int get committedCount => tasksSnapshot.where((t) {
        final committed = (t['committedToday'] as bool?) ?? false;
        return committed;
      }).length;

  int get committedDoneCount => tasksSnapshot.where((t) {
        final committed = (t['committedToday'] as bool?) ?? false;
        final done = (t['status'] as String?) == TaskStatus.done.name;
        return committed && done;
      }).length;

  Map<String, dynamic> toJson() => {
        'dayKey': dayKey,
        'mood': mood.name,
        'mode': mode.name,
        'tasksSnapshot': tasksSnapshot,
        'archivedAt': archivedAt.toIso8601String(),
      };

  static DayLog fromJson(Map<String, dynamic> json) => DayLog(
        dayKey: json['dayKey'] as String,
        mood: DayMood.values
            .firstWhere((e) => e.name == (json['mood'] as String)),
        mode: parseFlowMode(json['mode'] as String),
        tasksSnapshot: (json['tasksSnapshot'] as List)
            .map((e) => Map<String, dynamic>.from(e))
            .toList(),
        archivedAt: DateTime.parse(json['archivedAt'] as String),
      );
}

enum PomodoroPhase { work, breakTime }

class PomodoroSession {
  final String dayKey; // YYYY-MM-DD
  final String? taskId;
  final PomodoroPhase phase;
  final int minutes;
  final DateTime startedAt;
  final DateTime endedAt;

  PomodoroSession({
    required this.dayKey,
    required this.taskId,
    required this.phase,
    required this.minutes,
    required this.startedAt,
    required this.endedAt,
  });

  Map<String, dynamic> toJson() => {
        'dayKey': dayKey,
        'taskId': taskId,
        'phase': phase.name,
        'minutes': minutes,
        'startedAt': startedAt.toIso8601String(),
        'endedAt': endedAt.toIso8601String(),
      };

  static PomodoroSession fromJson(Map<String, dynamic> json) => PomodoroSession(
        dayKey: json['dayKey'] as String,
        taskId: json['taskId'] as String?,
        phase: PomodoroPhase.values
            .firstWhere((e) => e.name == (json['phase'] as String)),
        minutes: json['minutes'] as int,
        startedAt: DateTime.parse(json['startedAt'] as String),
        endedAt: DateTime.parse(json['endedAt'] as String),
      );
}

/* ===================== Storage ===================== */

class Storage {
  static const boxName = 'dailyflow';
  static const activeTasksKey = 'active_tasks_v1';
  static const settingsKey = 'settings_v1';

  static String dayLogKey(String dayKey) => 'daylog_$dayKey';
  static String pomodoroKey(String dayKey) => 'pomodoro_$dayKey';

  static Box get box => Hive.box(boxName);

  static List<Task> loadActiveTasks() {
    final raw = box.get(activeTasksKey, defaultValue: <dynamic>[]) as List;
    return raw
        .map((e) => Task.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  static Future<void> saveActiveTasks(List<Task> tasks) async {
    await box.put(activeTasksKey, tasks.map((t) => t.toJson()).toList());
  }

  static FlowMode loadMode() {
    final raw = box.get(settingsKey);
    if (raw is Map) {
      final m = raw['mode'] as String?;
      if (m != null) {
        return parseFlowMode(m);
      }
    }
    return FlowMode.kanban;
  }

  static Future<void> saveMode(FlowMode mode) async {
    final existing = box.get(settingsKey);
    final map = <String, dynamic>{};
    if (existing is Map) map.addAll(Map<String, dynamic>.from(existing));
    map['mode'] = mode.name;
    await box.put(settingsKey, map);
  }

  static bool loadDarkMode() {
    final raw = box.get(settingsKey);
    if (raw is Map) {
      return (raw['darkMode'] as bool?) ?? false;
    }
    return false;
  }

  static Future<void> saveDarkMode(bool darkMode) async {
    final existing = box.get(settingsKey);
    final map = <String, dynamic>{};
    if (existing is Map) map.addAll(Map<String, dynamic>.from(existing));
    map['darkMode'] = darkMode;
    await box.put(settingsKey, map);
  }

  static bool loadPremiumStatus() {
    final raw = box.get(settingsKey);
    if (raw is Map) {
      return (raw['isPremium'] as bool?) ?? false;
    }
    return false;
  }

  static Future<void> savePremiumStatus(bool isPremium) async {
    final existing = box.get(settingsKey);
    final map = <String, dynamic>{};
    if (existing is Map) map.addAll(Map<String, dynamic>.from(existing));
    map['isPremium'] = isPremium;
    await box.put(settingsKey, map);
  }

  static AppTheme loadTheme() {
    final raw = box.get(settingsKey);
    if (raw is Map) {
      final t = raw['theme'] as String?;
      if (t != null) {
        return AppTheme.values.firstWhere(
          (e) => e.name == t,
          orElse: () => AppTheme.calm,
        );
      }
    }
    return AppTheme.calm;
  }

  static Future<void> saveTheme(AppTheme theme) async {
    final existing = box.get(settingsKey);
    final map = <String, dynamic>{};
    if (existing is Map) map.addAll(Map<String, dynamic>.from(existing));
    map['theme'] = theme.name;
    await box.put(settingsKey, map);
  }

  static bool hasSeenOnboarding() {
    final raw = box.get(settingsKey);
    if (raw is Map) {
      return (raw['hasSeenOnboarding'] as bool?) ?? false;
    }
    return false;
  }

  static Future<void> setOnboardingSeen() async {
    final existing = box.get(settingsKey);
    final map = <String, dynamic>{};
    if (existing is Map) map.addAll(Map<String, dynamic>.from(existing));
    map['hasSeenOnboarding'] = true;
    await box.put(settingsKey, map);
  }

  /// When true, full-screen cloud login is skipped (local-only or dismissed).
  /// Default: skip if Supabase is not configured; otherwise show gate until set.
  static bool loadSkipCloudLogin() {
    final raw = box.get(settingsKey);
    if (raw is Map && raw.containsKey('skipCloudLogin')) {
      return (raw['skipCloudLogin'] as bool?) ?? false;
    }
    return !SupabaseConfig.isConfigured;
  }

  static Future<void> saveSkipCloudLogin(bool value) async {
    final existing = box.get(settingsKey);
    final map = <String, dynamic>{};
    if (existing is Map) map.addAll(Map<String, dynamic>.from(existing));
    map['skipCloudLogin'] = value;
    await box.put(settingsKey, map);
  }

  static Future<void> saveDayLog(DayLog log) async {
    await box.put(dayLogKey(log.dayKey), log.toJson());
  }

  static DayLog? loadDayLog(String dayKey) {
    final raw = box.get(dayLogKey(dayKey));
    if (raw is! Map) return null;
    return DayLog.fromJson(Map<String, dynamic>.from(raw));
  }

  static List<DayLog> loadAllDayLogs() {
    final keys = box.keys
        .whereType<String>()
        .where((k) => k.startsWith('daylog_'))
        .toList();

    final logs = <DayLog>[];
    for (final k in keys) {
      final raw = box.get(k);
      if (raw is Map) {
        logs.add(DayLog.fromJson(Map<String, dynamic>.from(raw)));
      }
    }
    logs.sort((a, b) => b.dayKey.compareTo(a.dayKey));
    return logs;
  }

  static List<PomodoroSession> loadPomodoroSessions(String dayKey) {
    final raw = box.get(pomodoroKey(dayKey), defaultValue: <dynamic>[]) as List;
    return raw
        .map((e) => PomodoroSession.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  static Future<void> appendPomodoroSession(PomodoroSession s) async {
    final key = pomodoroKey(s.dayKey);
    final raw = box.get(key, defaultValue: <dynamic>[]) as List;
    final list = raw.map((e) => Map<String, dynamic>.from(e)).toList();
    list.add(s.toJson());
    await box.put(key, list);
  }

  static Map<String, dynamic>? loadSettingsMap() {
    final raw = box.get(settingsKey);
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return null;
  }

  static Future<void> replaceSettingsMap(Map<String, dynamic> map) async {
    await box.put(settingsKey, map);
  }

  static List<String> pomodoroStorageDayKeys() {
    return box.keys
        .whereType<String>()
        .where((k) => k.startsWith('pomodoro_'))
        .map((k) => k.substring('pomodoro_'.length))
        .toList();
  }

  static Future<void> replacePomodoroSessions(
    String dayKey,
    List<PomodoroSession> sessions,
  ) async {
    await box.put(
      pomodoroKey(dayKey),
      sessions.map((s) => s.toJson()).toList(),
    );
  }
}

/* ===================== Premium ===================== */

// Product ID - App Store Connect'te oluşturduğun ürün ID'si
const String _kPremiumProductId = 'leanly_pro_lifetime';

class PremiumController extends ChangeNotifier {
  bool _isPremium = false;
  final InAppPurchase _inAppPurchase = InAppPurchase.instance;
  StreamSubscription<List<PurchaseDetails>>? _subscription;
  String? _lastPurchaseError;

  bool get isPremium => _isPremium;
  String? get lastPurchaseError => _lastPurchaseError;

  PremiumController() {
    _loadPremiumStatus();
    _initializePurchaseListener();
  }

  void _loadPremiumStatus() {
    _isPremium = Storage.loadPremiumStatus();
    notifyListeners();
  }

  void _initializePurchaseListener() {
    _subscription = _inAppPurchase.purchaseStream.listen(
      _onPurchaseUpdate,
      onDone: () => _subscription?.cancel(),
      onError: (error) {
        debugPrint('Purchase stream error: $error');
        _lastPurchaseError = 'Connection error. Please check your internet connection.';
        notifyListeners();
      },
    );
  }

  Future<void> _onPurchaseUpdate(List<PurchaseDetails> purchases) async {
    for (final purchase in purchases) {
      if (purchase.status == PurchaseStatus.purchased ||
          purchase.status == PurchaseStatus.restored) {
        if (purchase.productID == _kPremiumProductId) {
          _lastPurchaseError = null; // Clear error on success
          await _setPremiumStatus(true);
          if (purchase.pendingCompletePurchase) {
            await _inAppPurchase.completePurchase(purchase);
          }
          notifyListeners();
        }
      } else if (purchase.status == PurchaseStatus.error) {
        final error = purchase.error;
        debugPrint('Purchase error: $error');
        if (error != null) {
          _lastPurchaseError = _getErrorMessage(error);
        } else {
          _lastPurchaseError = 'Purchase failed. Please try again.';
        }
        notifyListeners();
      } else if (purchase.status == PurchaseStatus.pending) {
        debugPrint('Purchase pending: ${purchase.productID}');
      }
    }
  }

  String _getErrorMessage(IAPError error) {
    final code = error.code;
    final message = error.message ?? 'Unknown error';
    
    // Map common error codes to user-friendly messages
    switch (code) {
      case 'storekit_unknown':
        return 'Purchase failed. Please try again later.';
      case 'storekit_product_not_available':
        return 'Product not available. Please contact support.';
      case 'storekit_purchase_invalid':
        return 'Purchase invalid. Please try again.';
      case 'storekit_purchase_not_allowed':
        return 'Purchase not allowed. Please check your device settings.';
      case 'storekit_purchase_cancelled':
        return 'Purchase cancelled.';
      default:
        return 'Purchase failed: $message. Please try again.';
    }
  }

  Future<void> _setPremiumStatus(bool value) async {
    _isPremium = value;
    await Storage.savePremiumStatus(value);
    notifyListeners();
  }

  // Debug only: Manually set premium status for testing
  Future<void> setPremiumStatusForDebug(bool value) async {
    await _setPremiumStatus(value);
  }

  Future<bool> buyPremium() async {
    try {
      _lastPurchaseError = null; // Clear previous error
      notifyListeners();
      
      final available = await _inAppPurchase.isAvailable();
      if (!available) {
        _lastPurchaseError = 'In-app purchases are not available on this device.';
        notifyListeners();
        debugPrint('In-app purchases not available');
        return false;
      }

      final productDetailsResponse = await _inAppPurchase.queryProductDetails(
        {_kPremiumProductId},
      );

      if (productDetailsResponse.error != null) {
        final error = productDetailsResponse.error!;
        _lastPurchaseError = 'Failed to load product: ${error.message ?? "Unknown error"}. Please try again.';
        notifyListeners();
        debugPrint('Product query error: ${error.code} - ${error.message}');
        return false;
      }

      if (productDetailsResponse.productDetails.isEmpty) {
        _lastPurchaseError = 'Product not found. Please make sure the app is up to date.';
        notifyListeners();
        debugPrint('Product not found: $_kPremiumProductId');
        return false;
      }

      final productDetails = productDetailsResponse.productDetails.first;
      final purchaseParam = PurchaseParam(
        productDetails: productDetails,
      );

      final result = await _inAppPurchase.buyNonConsumable(purchaseParam: purchaseParam);
      
      if (!result) {
        _lastPurchaseError = 'Failed to initiate purchase. Please try again.';
        notifyListeners();
      }
      
      return result;
    } catch (e) {
      _lastPurchaseError = 'An unexpected error occurred: $e. Please try again.';
      notifyListeners();
      debugPrint('Buy premium error: $e');
      return false;
    }
  }

  Future<bool> restorePurchases() async {
    try {
      _lastPurchaseError = null; // Clear previous error
      notifyListeners();
      
      await _inAppPurchase.restorePurchases();
      // Note: restorePurchases() doesn't return a value, 
      // the purchase stream will notify us of restored purchases
      return true;
    } catch (e) {
      _lastPurchaseError = 'Failed to restore purchases: $e. Please try again.';
      notifyListeners();
      debugPrint('Restore purchases error: $e');
      return false;
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}

/* ===================== Rules ===================== */

class ModeRules {
  final FlowMode mode;
  const ModeRules(this.mode);

  String get displayName {
    switch (mode) {
      case FlowMode.scrum:
        return 'Scrum';
      case FlowMode.kanban:
        return 'Kanban';
    }
  }

  int? get wipLimit {
    switch (mode) {
      case FlowMode.kanban:
        return 2;
      case FlowMode.scrum:
        return null;
    }
  }

  int? get dailyCommitLimit => mode == FlowMode.scrum ? 3 : null;

  bool canMoveToDoing(List<Task> all) {
    final limit = wipLimit;
    if (limit == null) return true;
    final doing = all.where((t) => t.status == TaskStatus.doing).length;
    return doing < limit;
  }

  bool canCommitMore(List<Task> all) {
    final limit = dailyCommitLimit;
    if (limit == null) return true;
    final committed = all.where((t) => t.committedToday).length;
    return committed < limit;
  }

  String blockedWip() => 'WIP limit is protecting you.';
  String blockedCommit() => 'Commit limit reached (3 per day).';
}

/* ===================== Pomodoro Controller ===================== */

class PomodoroController extends ChangeNotifier {
  static const int workMinutes = 25;
  static const int breakMinutes = 5;

  final String Function() dayKeyProvider;
  final List<Task> Function() doingTasksProvider;
  final Future<void> Function(PomodoroSession) onAppendSession;

  PomodoroPhase phase = PomodoroPhase.work;
  int remainingSeconds = workMinutes * 60;
  bool running = false;

  Timer? _timer;
  DateTime? _phaseStartedAt;
  String? selectedDoingTaskId;

  PomodoroController({
    required this.dayKeyProvider,
    required this.doingTasksProvider,
    required this.onAppendSession,
  }) {
    sync();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void sync() {
    final doing = doingTasksProvider();
    if (doing.isEmpty) {
      selectedDoingTaskId = null;
    } else {
      final exists = doing.any((t) => t.id == selectedDoingTaskId);
      if (!exists) selectedDoingTaskId = doing.first.id;
    }
    notifyListeners();
  }

  int get _phaseMinutes =>
      phase == PomodoroPhase.work ? workMinutes : breakMinutes;

  int get _phaseTotalSeconds => _phaseMinutes * 60;

  /// How many seconds have elapsed in the CURRENT phase (work or break).
  int get currentPhaseElapsedSeconds {
    final elapsed = _phaseTotalSeconds - remainingSeconds;
    return elapsed.clamp(0, _phaseTotalSeconds);
  }

  /// Live elapsed seconds ONLY for work phase (0 while on break).
  int get currentWorkElapsedSeconds =>
      phase == PomodoroPhase.work ? currentPhaseElapsedSeconds : 0;

  String get remainingText {
    final m = (remainingSeconds ~/ 60).toString().padLeft(2, '0');
    final s = (remainingSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String get phaseLabel => phase == PomodoroPhase.work ? 'Work' : 'Break';

  void setSelectedTask(String? id) {
    selectedDoingTaskId = id;
    notifyListeners();
  }

  void reset() {
    _timer?.cancel();
    running = false;
    _phaseStartedAt = null;
    remainingSeconds = _phaseMinutes * 60;
    notifyListeners();
  }

  void pause() {
    if (!running) return;
    running = false;
    _timer?.cancel();
    notifyListeners();
  }

  void start({required void Function(String message) onError}) {
    if (running) return;

    // Ensure selection is valid
    sync();

    if (phase == PomodoroPhase.work && selectedDoingTaskId == null) {
      onError('Start a Doing task to use Pomodoro.');
      return;
    }

    running = true;
    _phaseStartedAt ??= DateTime.now();
    notifyListeners();

    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (!running) return;

      remainingSeconds = (remainingSeconds - 1).clamp(0, 1 << 30);
      notifyListeners();

      if (remainingSeconds <= 0) {
        final started = _phaseStartedAt ?? DateTime.now();
        final ended = DateTime.now();

        _timer?.cancel();

        // log completed phase
        final session = PomodoroSession(
          dayKey: dayKeyProvider(),
          taskId: (phase == PomodoroPhase.work) ? selectedDoingTaskId : null,
          phase: phase,
          minutes: _phaseMinutes,
          startedAt: started,
          endedAt: ended,
        );
        await onAppendSession(session);

        // switch phase
        phase = (phase == PomodoroPhase.work)
            ? PomodoroPhase.breakTime
            : PomodoroPhase.work;

        remainingSeconds = _phaseMinutes * 60;
        _phaseStartedAt = DateTime.now();

        // If back to work but no Doing task, stop.
        sync();
        if (phase == PomodoroPhase.work && selectedDoingTaskId == null) {
          running = false;
          notifyListeners();
          return;
        }

        // auto-continue
        start(onError: onError);
      }
    });
  }
}



/* ===================== Shell ===================== */

class AppShell extends StatefulWidget {
  final void Function(bool) onDarkModeChanged;
  final void Function(AppTheme)? onThemeChanged;

  const AppShell({
    super.key,
    required this.onDarkModeChanged,
    this.onThemeChanged,
  });

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;
  bool _showOnboarding = !Storage.hasSeenOnboarding();
  void _go(int i) => setState(() => _index = i);

  void _completeOnboarding() {
    setState(() {
      _showOnboarding = false;
    });
    Storage.setOnboardingSeen();
  }

  @override
  Widget build(BuildContext context) {
    if (_showOnboarding) {
      return OnboardingScreen(onComplete: _completeOnboarding);
    }

    return ListenableBuilder(
      listenable: CloudLoginGateNotifier.instance,
      builder: (context, _) {
        return Consumer<SupabaseAuthController>(
          builder: (context, auth, _) {
            final skip = Storage.loadSkipCloudLogin();
            final needCloudGate =
                auth.isConfigured && !auth.isSignedIn && !skip;
            if (needCloudGate) {
              return const _CloudGateScreen();
            }
            return _buildAppShellBody();
          },
        );
      },
    );
  }

  Widget _buildAppShellBody() {
    final pages = [
      TodayScreen(
        onOpenHistory: () => _go(1),
        onDarkModeChanged: widget.onDarkModeChanged,
      ),
      const HistoryScreen(),
      SettingsScreen(
        onDarkModeChanged: widget.onDarkModeChanged,
        onThemeChanged: widget.onThemeChanged,
      ),
    ];

    return Scaffold(
      body: pages[_index],
      bottomNavigationBar: NavigationBar(
        height: 72,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        selectedIndex: _index,
        onDestinationSelected: _go,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.today_outlined),
            selectedIcon: Icon(Icons.today),
            label: 'Today',
          ),
          NavigationDestination(
            icon: Icon(Icons.history_outlined),
            selectedIcon: Icon(Icons.history),
            label: 'History',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}

/// Full-screen sign-in before the main tabs when Supabase is configured.
class _CloudGateScreen extends StatefulWidget {
  const _CloudGateScreen();

  @override
  State<_CloudGateScreen> createState() => _CloudGateScreenState();
}

class _CloudGateScreenState extends State<_CloudGateScreen> {
  bool _busy = false;

  Future<void> _onAppleSignIn() async {
    final messenger = ScaffoldMessenger.of(context);
    final auth = context.read<SupabaseAuthController>();
    setState(() => _busy = true);
    final err = await auth.signInWithApple();
    if (!mounted) return;
    setState(() => _busy = false);
    messenger.showSnackBar(
      SnackBar(
        content: Text(err ?? 'Signed in.'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _onContinueOffline() async {
    await Storage.saveSkipCloudLogin(true);
    CloudLoginGateNotifier.instance.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<SupabaseAuthController>();
    final canApple = !kIsWeb && (Platform.isIOS || Platform.isMacOS);

    return Scaffold(
      backgroundColor: context.themeBg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 24),
              Text(
                'Leanly',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w800,
                  color: context.themeAccent,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Sign in to sync',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                auth.isConfigured
                    ? 'Use your Apple account to back up tasks, history, and settings to the cloud. You can use the app offline instead if you prefer.'
                    : 'Cloud is not configured.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  height: 1.45,
                  color: context.themeTextMuted,
                ),
              ),
              const Spacer(),
              if (auth.isConfigured && canApple)
                FilledButton.icon(
                  onPressed: _busy ? null : _onAppleSignIn,
                  icon: _busy
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Theme.of(context).colorScheme.onPrimary,
                          ),
                        )
                      : const Icon(Icons.apple, size: 26),
                  label: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(_busy ? 'Signing in…' : 'Sign in with Apple'),
                  ),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                )
              else if (auth.isConfigured)
                Text(
                  'Sign in with Apple is only available on iOS and Mac.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: context.themeTextMuted),
                ),
              const SizedBox(height: 14),
              TextButton(
                onPressed: _busy ? null : _onContinueOffline,
                child: const Text('Continue without account'),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

/* ===================== Today Screen ===================== */

/// Bottom margin so floating snackbars clear the Today quick-add bar.
const double _kQuickAddBarHeight = 56;
const double _kQuickAddOuterPadding = 8;
const double _kTodaySnackGap = 12;

double todaySnackBarBottomMargin(BuildContext context) =>
    _kQuickAddBarHeight + _kQuickAddOuterPadding + _kTodaySnackGap;

SnackBar todaySnackBar(
  BuildContext context, {
  required Widget content,
  Color? backgroundColor,
  Duration duration = const Duration(seconds: 2),
  SnackBarAction? action,
}) {
  return SnackBar(
    content: content,
    behavior: SnackBarBehavior.floating,
    margin: EdgeInsets.fromLTRB(16, 0, 16, todaySnackBarBottomMargin(context)),
    backgroundColor: backgroundColor,
    duration: duration,
    action: action,
  );
}

class TodayScreen extends StatefulWidget {
  final VoidCallback onOpenHistory;
  final void Function(bool) onDarkModeChanged;

  const TodayScreen({
    super.key,
    required this.onOpenHistory,
    required this.onDarkModeChanged,
  });

  @override
  State<TodayScreen> createState() => _TodayScreenState();
}


class _TodayScreenState extends State<TodayScreen> {
  final List<Task> _tasks = [];
  Focus _focus = Focus.work;
  String _searchQuery = '';
  bool _searchExpanded = false;
  bool _showCommittedOnly = false;
  bool _showRolledOverOnly = false;
  bool _isLoadingTasks = true;

  late FlowMode _mode;
  late ModeRules _rules;

  late final PomodoroController _pomo;

  String _dateKey(DateTime d) {
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }

  String get _todayKey => _dateKey(DateTime.now());

  int get doingCount =>
      _tasks.where((t) => t.status == TaskStatus.doing).length;
  int get doneCount => _tasks.where((t) => t.status == TaskStatus.done).length;

  int get committedCount => _tasks.where((t) => t.committedToday).length;
  int get committedDoneCount => _tasks
      .where((t) => t.committedToday && t.status == TaskStatus.done)
      .length;

  void _openDeepFocus() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PomodoroScreen(
          mode: _mode,
          controller: _pomo,
          dayKeyProvider: () => _todayKey,
        ),
      ),
    );
  }


  @override
  void initState() {
    super.initState();

    _mode = Storage.loadMode();
    _rules = ModeRules(_mode);

    _pomo = PomodoroController(
      dayKeyProvider: () => _todayKey,
      doingTasksProvider: () =>
          _tasks.where((t) => t.status == TaskStatus.doing).toList(),
      onAppendSession: (s) => Storage.appendPomodoroSession(s),
    );
    
    // Listen to pomodoro updates to refresh UI
    _pomo.addListener(_onPomodoroUpdate);

    _loadActive();
    _scheduleDailyEndDayNotification();
    SyncBus.instance.addListener(_onSyncBus);
  }

  void _onSyncBus() {
    if (!mounted) return;
    _mode = Storage.loadMode();
    _rules = ModeRules(_mode);
    _loadActive();
  }
  
  void _onPomodoroUpdate() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    SyncBus.instance.removeListener(_onSyncBus);
    _pomo.removeListener(_onPomodoroUpdate);
    _pomo.dispose();
    super.dispose();
  }

  Future<void> _scheduleDailyEndDayNotification() async {
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'dailyflow_endday',
        'End of day',
        channelDescription: 'Daily reminder to close the day',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: false,
      ),
    );

    final now = tz.TZDateTime.now(tz.local);
    var scheduled =
        tz.TZDateTime(tz.local, now.year, now.month, now.day, 23, 59);

    if (scheduled.isBefore(now)) {
      scheduled = scheduled.add(const Duration(days: 1));
    }

    await notifications.zonedSchedule(
      999,
      'End your day',
      'How was your day? Open Leanly to log your mood.',
      scheduled,
      details,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.time,
    );
  }

  Future<void> _loadActive() async {
    final loaded = Storage.loadActiveTasks();
    setState(() {
      _tasks
        ..clear()
        ..addAll(loaded);
      _isLoadingTasks = false;
    });
    _pomo.sync();
  }

  Future<void> _persist() async {
    await Storage.saveActiveTasks(_tasks);
    _pomo.sync();
  }

  void _openAddSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        return _AddTaskSheet(
          onAdd: (text) {
            _addTask(text);
                    Navigator.pop(ctx);
                  },
        );
      },
    );
  }

  void _addTask(String text) {
    final title = text.trim();
    if (title.isEmpty) return;

    // Premium gate: Free users limited to 15 tasks
    final premium = Provider.of<PremiumController>(context, listen: false);
    const freeTaskLimit = 15;
    if (!premium.isPremium && _tasks.length >= freeTaskLimit) {
      ScaffoldMessenger.of(context).showSnackBar(
        todaySnackBar(
          context,
          content: Row(
            children: [
              const Icon(Icons.lock_outline, color: Colors.white),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Task limit reached ($freeTaskLimit tasks). Upgrade to Pro for unlimited tasks.'),
              ),
            ],
          ),
          backgroundColor: context.themeWarning,
          action: SnackBarAction(
            label: 'Upgrade',
            textColor: Colors.white,
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const PremiumScreen()),
              );
            },
          ),
        ),
      );
      return;
    }

    HapticFeedback.lightImpact();
    setState(() {
      _tasks.add(
        Task(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          title: title,
          status: TaskStatus.todo,
          focus: _focus,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );
    });
    _persist();
  }

  void _editTask(Task t) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        return _EditTaskSheet(
          task: t,
          onSave: (newTitle, newFocus) {
                        setState(() {
                          t.title = newTitle;
              t.focus = newFocus;
                          t.updatedAt = DateTime.now();
                        });
                        _persist();
                        Navigator.pop(ctx);
                      },
        );
      },
    );
  }

  void _deleteTask(Task t) {
    HapticFeedback.mediumImpact();
    setState(() => _tasks.removeWhere((x) => x.id == t.id));
    _persist();
    ScaffoldMessenger.of(context).showSnackBar(
      todaySnackBar(
        context,
        content: Text('Deleted "${t.title}"'),
        duration: const Duration(seconds: 1),
        action: SnackBarAction(
          label: 'Undo',
          textColor: Colors.white,
          onPressed: () {
            HapticFeedback.lightImpact();
            setState(() {
              _tasks.add(t);
            });
            _persist();
          },
        ),
      ),
    );
  }

  void _toggleCommit(Task t) {
    if (_mode != FlowMode.scrum) return;

    final next = !t.committedToday;
    if (next && !_rules.canCommitMore(_tasks)) {
      HapticFeedback.heavyImpact();
      ScaffoldMessenger.of(context).showSnackBar(
        todaySnackBar(
          context,
          content: Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: context.themeWarning),
              const SizedBox(width: 8),
              Expanded(child: Text(_rules.blockedCommit())),
            ],
          ),
          backgroundColor: context.themeWarning.withOpacity(0.1),
        ),
      );
      return;
    }

    HapticFeedback.selectionClick();
    setState(() {
      t.committedToday = next;
      t.updatedAt = DateTime.now();
    });
    _persist();
  }

  void _toTodo(Task t) {
    HapticFeedback.lightImpact();
    setState(() {
      t.status = TaskStatus.todo;
      t.updatedAt = DateTime.now();
    });
    _persist();
    ScaffoldMessenger.of(context).showSnackBar(
      todaySnackBar(
        context,
        content: Text('Moved "${t.title}" to To do'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  void _toDoing(Task t) {
    if (!_rules.canMoveToDoing(_tasks)) {
      HapticFeedback.heavyImpact();
      ScaffoldMessenger.of(context).showSnackBar(
        todaySnackBar(
          context,
          content: Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: context.themeWarning),
              const SizedBox(width: 8),
              Expanded(child: Text(_rules.blockedWip())),
            ],
          ),
          backgroundColor: context.themeWarning.withOpacity(0.1),
        ),
      );
      return;
    }
    HapticFeedback.mediumImpact();
    setState(() {
      t.status = TaskStatus.doing;
      t.updatedAt = DateTime.now();
    });
    _persist();
    ScaffoldMessenger.of(context).showSnackBar(
      todaySnackBar(
        context,
        content: Text('Started working on "${t.title}"'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  void _toDone(Task t) {
    HapticFeedback.mediumImpact();
    setState(() {
      t.status = TaskStatus.done;
      t.updatedAt = DateTime.now();
    });
    _persist();
    ScaffoldMessenger.of(context).showSnackBar(
      todaySnackBar(
        context,
        content: Row(
          children: [
            Icon(Icons.check_circle, color: context.themeSuccess),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Completed "${t.title}"',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ),
          ],
        ),
        backgroundColor: context.themeSuccess.withOpacity(0.1),
      ),
    );
  }

  Future<void> _endDay() async {
    // Stop focus without logging partial sessions
    _pomo.pause();
    _pomo.reset();

    final mood = await showModalBottomSheet<DayMood>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('How was your day?',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                children: [
                  _MoodChip(
                    icon: moodToIcon(DayMood.good),
                    label: 'Good',
                    onTap: () => Navigator.pop(ctx, DayMood.good),
                  ),
                  _MoodChip(
                    icon: moodToIcon(DayMood.meh),
                    label: 'Meh',
                    onTap: () => Navigator.pop(ctx, DayMood.meh),
                  ),
                  _MoodChip(
                    icon: moodToIcon(DayMood.hard),
                    label: 'Hard',
                    onTap: () => Navigator.pop(ctx, DayMood.hard),
                  ),
                ],
              ),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );

    if (mood == null) return;

    final todayKey = _todayKey;

    // Archive snapshot (read-only)
    final log = DayLog(
      dayKey: todayKey,
      mood: mood,
      mode: _mode,
      tasksSnapshot: _tasks.map((t) => t.toJson()).toList(),
      archivedAt: DateTime.now(),
    );
    await Storage.saveDayLog(log);

    // Rollover: keep todo + doing, drop done. Reset commitment for new day.
    final carried = _tasks
        .where((t) => t.status != TaskStatus.done)
        .map((t) => t.copyWith(
              updatedAt: DateTime.now(),
              rolledOver: true,
              carriedOverFromDay: todayKey,
              committedToday: false,
            ))
        .toList();

    setState(() {
      _tasks
        ..clear()
        ..addAll(carried);
    });
    await Storage.saveActiveTasks(_tasks);

    _pomo.sync();

   if (!mounted) return;

    // Show summary screen
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DaySummaryScreen(
          dayKey: todayKey,
          mood: mood,
          doneCount: doneCount,
          totalTasks: _tasks.length + doneCount,
          rolledOverCount: carried.length,
          onClose: () {
            Navigator.pop(context);
widget.onOpenHistory();
          },
        ),
      ),
    );
  }

  Future<void> _openPomodoro() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PomodoroScreen(
          mode: _mode,
          controller: _pomo,
          dayKeyProvider: () => _todayKey,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // Sync mode if settings changed while screen was alive.
    final currentMode = Storage.loadMode();
    if (currentMode != _mode) {
      _mode = currentMode;
      _rules = ModeRules(_mode);
    }

    // Apply filters
    var visible = _tasks.where((t) => t.focus == _focus).toList();
    
    // Search filter
    if (_searchQuery.isNotEmpty) {
      visible = visible.where((t) => 
        t.title.toLowerCase().contains(_searchQuery.toLowerCase())
      ).toList();
    }
    
    // Committed only filter
    if (_showCommittedOnly) {
      visible = visible.where((t) => t.committedToday).toList();
    }
    
    // Rolled over only filter
    if (_showRolledOverOnly) {
      visible = visible.where((t) => t.rolledOver).toList();
    }
    
    final todo = visible.where((t) => t.status == TaskStatus.todo).toList();
    final doing = visible.where((t) => t.status == TaskStatus.doing).toList();
    final done = visible.where((t) => t.status == TaskStatus.done).toList();

    final focusDoingCount = doing.length;
    final focusDoneCount = done.length;
    final focusTotalCount = visible.length;

    final wip = _rules.wipLimit;

    final commitLimit = _rules.dailyCommitLimit;
    final focusCommittedDone = visible
        .where((t) => t.committedToday && t.status == TaskStatus.done)
        .length;
    final focusCommittedCount = visible.where((t) => t.committedToday).length;

    final pomodoroStatus = _pomo.running
        ? 'Focus ${_pomo.remainingText}'
        : null;

    return Scaffold(
      backgroundColor: context.themeBg,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _ModeSegmentedControl(
                      selected: _mode,
                      onSelected: (m) async {
                        setState(() {
                          _mode = m;
                          _rules = ModeRules(m);
                        });
                        await Storage.saveMode(m);
                      },
                    ),
                    const SizedBox(height: AppSpacing.md),
                    _HeaderCard(
                      title: 'Today',
                      mode: _mode,
                      doingCount: focusDoingCount,
                      wipLimit: wip,
                      doneCount: focusDoneCount,
                      committedDone: focusCommittedDone,
                      commitLimit: commitLimit,
                      committedCount: focusCommittedCount,
                      focusLabel: titleCase(_focus.name),
                      totalCount: focusTotalCount,
                      pomodoroLabel: pomodoroStatus,
                      onPomodoro: _openDeepFocus,
                      onEndDay: _endDay,
                      onToggleDarkMode: () {
                        widget.onDarkModeChanged(!Storage.loadDarkMode());
                      },
                      onSearch: () => setState(() => _searchExpanded = true),
                      searchActive: _searchExpanded ||
                          _searchQuery.isNotEmpty ||
                          _showCommittedOnly ||
                          _showRolledOverOnly,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    _FocusPills(
                      selected: _focus,
                      onSelect: (f) => setState(() => _focus = f),
                    ),
                    if (_searchExpanded ||
                        _searchQuery.isNotEmpty ||
                        _showCommittedOnly ||
                        _showRolledOverOnly) ...[
                      const SizedBox(height: AppSpacing.sm),
                      _SearchAndFilterBar(
                        taskCount: _tasks.length,
                        searchQuery: _searchQuery,
                        showCommittedOnly: _showCommittedOnly,
                        showRolledOverOnly: _showRolledOverOnly,
                        onSearchChanged: (query) =>
                            setState(() => _searchQuery = query),
                        onCommittedToggle: (value) =>
                            setState(() => _showCommittedOnly = value),
                        onRolledOverToggle: (value) =>
                            setState(() => _showRolledOverOnly = value),
                        onCollapse: () {
                          setState(() {
                            _searchExpanded = false;
                            _searchQuery = '';
                            _showCommittedOnly = false;
                            _showRolledOverOnly = false;
                          });
                        },
                      ),
                    ],
                    const SizedBox(height: 12),
                    if (_isLoadingTasks)
                      const _TodaySkeleton()
                    else ...[
                      _SectionCard(
                        title: 'To do',
                        count: todo.length,
                        child: _TaskList(
                          tasks: todo,
                          mode: _mode,
                          onMoveForward: _toDoing,
                          onMoveBack: null,
                          onTapTask: _editTask,
                          onDeleteTask: _deleteTask,
                          onToggleCommit: _toggleCommit,
                        ),
                      ),
                      const SizedBox(height: 12),
                      _SectionCard(
                        title: 'Doing',
                        count: doing.length,
                        child: _TaskList(
                          tasks: doing,
                          mode: _mode,
                          onMoveForward: _toDone,
                          onMoveBack: _toTodo,
                          onTapTask: _editTask,
                          onDeleteTask: _deleteTask,
                          onToggleCommit: _toggleCommit,
                        ),
                      ),
                      const SizedBox(height: 12),
                      _SectionCard(
                        title: 'Done',
                        count: done.length,
                        child: _TaskList(
                          tasks: done,
  mode: _mode,
  onMoveForward: null,
  onMoveBack: _toDoing,
  dimmed: true,
                                disableSwipeForward:
                                    true, // ✅ Done’da swipe right kapalı
  onTapTask: _editTask,
  onDeleteTask: _deleteTask,
  onToggleCommit: _toggleCommit,
),
                      ),
                      const SizedBox(height: 24),
                    ],
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
              child: _QuickAddBar(onTap: _openAddSheet),
            ),
          ],
        ),
      ),
    );
  }
}

/* ===================== Pomodoro Screen (Deep Focus) ===================== */

class PomodoroScreen extends StatefulWidget {
  final FlowMode mode;
  final PomodoroController controller;
  final String Function() dayKeyProvider;

  const PomodoroScreen({
    super.key,
    required this.mode,
    required this.controller,
    required this.dayKeyProvider,
  });

  @override
  State<PomodoroScreen> createState() => _PomodoroScreenState();
}

class _PomodoroScreenState extends State<PomodoroScreen> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_tick);
    widget.controller.sync();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_tick);
    super.dispose();
  }

  void _tick() {
    if (!mounted) return;
    setState(() {});
  }

  int _todayFocusMinutes() {
    final dayKey = widget.dayKeyProvider();

    // stored (completed work sessions)
    final sessions = Storage.loadPomodoroSessions(dayKey)
        .where((s) => s.phase == PomodoroPhase.work)
        .toList();
    final storedMinutes = sessions.fold<int>(0, (sum, s) => sum + s.minutes);

    // live (current running work phase)
    final liveSeconds = widget.controller.currentWorkElapsedSeconds;
    final liveMinutes = (liveSeconds / 60).floor();

    return storedMinutes + liveMinutes;
  }


  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final doing = c.doingTasksProvider();
    final isWork = c.phase == PomodoroPhase.work;

    final focusMinutes = _todayFocusMinutes();

    return Scaffold(
      backgroundColor: context.themeBg,
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.timer_rounded,
              size: 22,
              color: Theme.of(context).colorScheme.onSurface,
            ),
            const SizedBox(width: 8),
            const Text('Deep Focus'),
          ],
        ),
        backgroundColor: Colors.transparent,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: context.themeCard,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(
                  children: [
                    Text(
                      '${ModeRules(widget.mode).displayName} • ${c.phaseLabel}',
                      style: TextStyle(color: context.themeTextMuted),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      c.remainingText,
                      style: const TextStyle(
                        fontSize: 56,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Today focused: $focusMinutes min',
                      style: TextStyle(color: context.themeTextMuted),
                    ),
                    const SizedBox(height: 14),
                    if (isWork)
                      _FocusTaskPicker(
                        doing: doing,
                        selectedId: c.selectedDoingTaskId,
                        onChanged: (id) => c.setSelectedTask(id),
                      )
                    else
                      Text(
                        'Break time. No task binding.',
                        style: TextStyle(color: context.themeTextMuted),
                      ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton(
                            onPressed: () {
                              if (c.running) {
                                c.pause();
                              } else {
                                c.start(onError: (msg) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text(msg)),
                                  );
                                });
                              }
                            },
                            child: Text(c.running ? 'Pause' : 'Start'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        OutlinedButton(
                          onPressed: c.reset,
                          child: const Text('Reset'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: context.themeCard,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('How it works',
                          style: TextStyle(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 10),
                      Text(
                        'Deep Focus is optional.\n'
                        'Move a task to Doing, then tap the timer on Today when you want to focus.\n'
                        'Work sessions are logged; breaks are not tied to tasks.',
                        style: TextStyle(color: context.themeTextMuted),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FocusTaskPicker extends StatelessWidget {
  final List<Task> doing;
  final String? selectedId;
  final ValueChanged<String?> onChanged;

  const _FocusTaskPicker({
    required this.doing,
    required this.selectedId,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    if (doing.isEmpty) {
      return Text(
        'Move a task to Doing to start a work session.',
        style: TextStyle(color: context.themeTextMuted),
      );
    }

    if (doing.length == 1) {
      return Text(
        'Task: ${doing.first.title}',
        style: const TextStyle(fontWeight: FontWeight.w700),
      );
    }

    return Row(
      children: [
        Text('Task:', style: TextStyle(color: context.themeTextMuted)),
        const SizedBox(width: 10),
        Expanded(
          child: DropdownButton<String>(
            isExpanded: true,
            value: selectedId ?? doing.first.id,
            onChanged: onChanged,
            items: doing
                .map(
                  (t) => DropdownMenuItem(
                    value: t.id,
                    child: Text(t.title, overflow: TextOverflow.ellipsis),
                  ),
                )
                .toList(),
          ),
        ),
      ],
    );
  }
}

/* ===================== History ===================== */

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  FlowMode? _filter; // null = All
  List<DayLog>? _logs;

  @override
  void initState() {
    super.initState();
    SyncBus.instance.addListener(_onSyncBus);
    // Simulate async load so we can show skeletons on first frame
    Future.microtask(() {
    final allLogs = Storage.loadAllDayLogs();
    final logs = [...allLogs]..sort((a, b) => b.dayKey.compareTo(a.dayKey));
      if (mounted) {
        setState(() {
          _logs = logs;
        });
      }
    });
  }

  void _onSyncBus() {
    if (!mounted) return;
    setState(() => _logs = null);
    Future.microtask(() {
      final allLogs = Storage.loadAllDayLogs();
      final logs = [...allLogs]..sort((a, b) => b.dayKey.compareTo(a.dayKey));
      if (mounted) {
        setState(() {
          _logs = logs;
        });
      }
    });
  }

  @override
  void dispose() {
    SyncBus.instance.removeListener(_onSyncBus);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final logs = _logs;

    final visibleLogs = (logs == null)
        ? <DayLog>[]
        : _filter == null
        ? logs
        : logs.where((l) => l.mode == _filter).toList();

    // Calculate statistics - Premium: 30 days, Free: 7 days
    final premium = Provider.of<PremiumController>(context);
    final daysToShow = premium.isPremium ? 30 : 7;
    final lastDays = logs == null ? <DayLog>[] : logs.take(daysToShow).toList();
    final totalTasksDone = lastDays.fold<int>(0, (sum, log) => sum + log.doneCount);
    final avgTasksPerDay = lastDays.isEmpty ? 0.0 : totalTasksDone / lastDays.length;
    final totalPomodoros = lastDays.fold<int>(0, (sum, log) {
      final sessions = Storage.loadPomodoroSessions(log.dayKey)
          .where((s) => s.phase == PomodoroPhase.work)
          .length;
      return sum + sessions;
    });
    final moodCounts = <DayMood, int>{
      DayMood.good: 0,
      DayMood.meh: 0,
      DayMood.hard: 0,
    };
    for (final log in lastDays) {
      moodCounts[log.mood] = (moodCounts[log.mood] ?? 0) + 1;
    }
    final mostCommonMood = moodCounts.entries
        .reduce((a, b) => a.value > b.value ? a : b)
        .key;

    return Scaffold(
      backgroundColor: context.themeBg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'History',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _HistoryFilterChip(
                      label: 'All',
                      selected: _filter == null,
                      onSelected: () {
                        setState(() => _filter = null);
                      },
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    _HistoryFilterChip(
                      label: 'Scrum',
                      selected: _filter == FlowMode.scrum,
                      onSelected: () {
                        setState(() => _filter = FlowMode.scrum);
                      },
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    _HistoryFilterChip(
                      label: 'Kanban',
                      selected: _filter == FlowMode.kanban,
                      onSelected: () {
                        setState(() => _filter = FlowMode.kanban);
                      },
                    ),
                    const SizedBox(width: AppSpacing.sm),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              if (lastDays.isNotEmpty)
                _StatsCard(
                  totalTasksDone: totalTasksDone,
                  avgTasksPerDay: avgTasksPerDay,
                  totalPomodoros: totalPomodoros,
                  mostCommonMood: mostCommonMood,
                  daysShown: daysToShow,
                  isPremium: premium.isPremium,
                ),
              const SizedBox(height: 12),

              // şimdilik filtre UI yok — önce build alalım.
              // sonra ekleriz.

              Expanded(
                child: _logs == null
                    ? const _HistorySkeleton()
                    : visibleLogs.isEmpty
                        ? Center(
                    child: Text(
                      'No archived days yet.',
                              style: TextStyle(
                                color: context.themeTextMuted,
                    ),
                  ),
                )
                        : ListView.separated(
                    itemCount: visibleLogs.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 10),
                    itemBuilder: (_, i) {
                      final log = visibleLogs[i];

                              final workSessions =
                                  Storage.loadPomodoroSessions(log.dayKey)
                                      .where((s) =>
                                          s.phase == PomodoroPhase.work)
                          .toList();

                      final pomos = workSessions.length;
                      final focusMinutes =
                                  workSessions.fold<int>(
                                      0, (sum, s) => sum + s.minutes);

                              final commitBadge =
                                  (log.mode == FlowMode.scrum)
                          ? ' • Committed ${log.committedDoneCount}/${log.committedCount}'
                          : '';

                      return _HistoryCard(
                        dayKey: log.dayKey,
                        moodIcon: moodToIcon(log.mood),
                        subtitle:
                            '${ModeRules(log.mode).displayName} • Done ${log.doneCount} • Focus $pomos ($focusMinutes min)$commitBadge',
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                                      builder: (_) => DayDetailScreen(
                                        dayKey: log.dayKey,
                                      ),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}


class DayDetailScreen extends StatefulWidget {
  final String dayKey;
  const DayDetailScreen({super.key, required this.dayKey});

  @override
  State<DayDetailScreen> createState() => _DayDetailScreenState();
}

class _DayDetailScreenState extends State<DayDetailScreen> {
  DayLog? _log;
  Focus _focus = Focus.work;
  late List<PomodoroSession> _sessions;

  @override
  void initState() {
    super.initState();
    _log = Storage.loadDayLog(widget.dayKey);
    _sessions = Storage.loadPomodoroSessions(widget.dayKey);
  }

  @override
  Widget build(BuildContext context) {
    final log = _log;
    if (log == null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.dayKey)),
        body: const Center(child: Text('Day log not found.')),
      );
    }

    final tasks = log.tasksSnapshot.map(Task.fromJson).toList();
    final visible = tasks.where((t) => t.focus == _focus).toList();

    final todo = visible.where((t) => t.status == TaskStatus.todo).toList();
    final doing = visible.where((t) => t.status == TaskStatus.doing).toList();
    final done = visible.where((t) => t.status == TaskStatus.done).toList();

    final workSessions =
        _sessions.where((s) => s.phase == PomodoroPhase.work).toList();
    final pomos = workSessions.length;
    final focusMinutes = workSessions.fold<int>(0, (sum, s) => sum + s.minutes);

    final commitInfo = (log.mode == FlowMode.scrum)
        ? ' • Committed ${log.committedDoneCount}/${log.committedCount}'
        : '';

    return Scaffold(
      backgroundColor: context.themeBg,
      appBar: AppBar(
        title: Text(widget.dayKey),
        backgroundColor: Colors.transparent,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            children: [
              _DaySummaryCard(
                moodIcon: moodToIcon(log.mood),
                subtitle:
                    '${ModeRules(log.mode).displayName} • Done ${done.length} • Focus $pomos ($focusMinutes min)$commitInfo',
              ),
              const SizedBox(height: 12),
              _FocusPills(
                selected: _focus,
                onSelect: (f) => setState(() => _focus = f),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      _SectionCard(
                        title: 'To do',
                        count: todo.length,
                        child: _ReadOnlyTaskList(tasks: todo),
                      ),
                      const SizedBox(height: 12),
                      _SectionCard(
                        title: 'Doing',
                        count: doing.length,
                        child: _ReadOnlyTaskList(tasks: doing),
                      ),
                      const SizedBox(height: 12),
                      _SectionCard(
                        title: 'Done',
                        count: done.length,
                        child: _ReadOnlyTaskList(tasks: done, dimmed: true),
                      ),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/* ===================== Settings ===================== */

class SettingsScreen extends StatefulWidget {
  final void Function(bool) onDarkModeChanged;
  final void Function(AppTheme)? onThemeChanged;

  const SettingsScreen({
    super.key,
    required this.onDarkModeChanged,
    this.onThemeChanged,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late FlowMode _mode;
  late bool _darkMode;
  late AppTheme _theme;

  @override
  void initState() {
    super.initState();
    _mode = Storage.loadMode();
    _darkMode = Storage.loadDarkMode();
    _theme = Storage.loadTheme();
  }

  Future<void> _setMode(FlowMode m) async {
    setState(() => _mode = m);
    await Storage.saveMode(m);
  }

  Future<void> _setDarkMode(bool value) async {
    setState(() => _darkMode = value);
    await Storage.saveDarkMode(value);
    widget.onDarkModeChanged(value);
  }

  Future<void> _setTheme(AppTheme theme) async {
    setState(() => _theme = theme);
    await Storage.saveTheme(theme);
    widget.onThemeChanged?.call(theme);
  }

  @override
  Widget build(BuildContext context) {
    final rules = ModeRules(_mode);
    final wip = rules.wipLimit;
    final commit = rules.dailyCommitLimit;

    final detail = [
      'WIP: ${wip == null ? 'none' : wip}',
      if (commit != null) 'Commit/day: $commit',
    ].join(' • ');

    return Scaffold(
      backgroundColor: context.themeBg,
      body: SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
              const Text('Settings',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              Consumer<SupabaseAuthController>(
                builder: (context, auth, _) {
                  if (!auth.isConfigured) {
                    return _SectionCard(
                      title: 'Sign in & account sync',
                      count: 0,
                      child: Text(
                        'Supabase is not set up in this build. Run with '
                        '--dart-define=SUPABASE_URL=... and '
                        '--dart-define=SUPABASE_ANON_KEY=... then apply supabase/schema.sql in the dashboard.',
                        style: TextStyle(
                          color: context.themeTextMuted,
                          fontSize: 13,
                        ),
                      ),
                    );
                  }
                  return _SectionCard(
                    title: 'Sign in & account sync',
                    count: 0,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (auth.isSignedIn) ...[
                          Text(
                            auth.userLabel ?? 'Signed in',
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 15,
                              height: 1.3,
                            ),
                          ),
                          const SizedBox(height: 12),
                        ] else ...[
                          Text(
                            'Sign in with Apple to sync tasks, day history, Pomodoro logs, and settings across devices.',
                            style: TextStyle(
                              color: context.themeTextMuted,
                              fontSize: 13,
                              height: 1.45,
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                        if (!auth.isSignedIn) ...[
                          FilledButton.icon(
                            onPressed: () async {
                              final err = await auth.signInWithApple();
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    err ?? 'Signed in and synced.',
                                  ),
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                            },
                            icon: const Icon(Icons.apple),
                            label: const Text('Sign in with Apple'),
                          ),
                          if (Storage.loadSkipCloudLogin()) ...[
                            const SizedBox(height: 8),
                            TextButton(
                              onPressed: () async {
                                await Storage.saveSkipCloudLogin(false);
                                CloudLoginGateNotifier.instance.refresh();
                              },
                              child: const Text('Show full-screen sign-in'),
                            ),
                          ],
                        ] else ...[
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: () async {
                                    final err = await auth.syncNowPull();
                                    if (!context.mounted) return;
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          err ?? 'Downloaded from cloud.',
                                        ),
                                        behavior: SnackBarBehavior.floating,
                                      ),
                                    );
                                  },
                                  icon: const Icon(
                                    Icons.cloud_download_outlined,
                                  ),
                                  label: const Text('Pull'),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: () async {
                                    final err = await auth.syncNowPush();
                                    if (!context.mounted) return;
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          err ?? 'Uploaded to cloud.',
                                        ),
                                        behavior: SnackBarBehavior.floating,
                                      ),
                                    );
                                  },
                                  icon: const Icon(
                                    Icons.cloud_upload_outlined,
                                  ),
                                  label: const Text('Push'),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          TextButton(
                            onPressed: () async {
                              final err = await auth.signOut();
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(err ?? 'Signed out.'),
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                            },
                            child: const Text('Sign out'),
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              _SectionCard(
                title: 'Appearance',
                count: 0,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Dark Mode',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                        Switch(
                          value: _darkMode,
                          onChanged: _setDarkMode,
                        ),
                      ],
                    ),
                    Consumer<PremiumController>(
                      builder: (context, premium, _) {
                        if (!premium.isPremium) {
                          return Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Row(
                              children: [
                                Icon(Icons.lock_outline, size: 16, color: context.themeTextMuted),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    'Themes are available in Leanly Pro',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: context.themeTextMuted,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        }
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 16),
                            const Text(
                              'Theme',
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 10,
                              runSpacing: 10,
                              children: AppTheme.values.map((theme) {
                                final isSelected = theme == _theme;
                                return ChoiceChip(
                                  selected: isSelected,
                                  label: Text(AppThemes.getDisplayName(theme)),
                                  onSelected: (_) => _setTheme(theme),
                                  selectedColor: context.themeAccent,
                                  backgroundColor: context.themeCard,
                                  labelStyle: TextStyle(
                                    color: isSelected ? Colors.white : null,
                                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                                  ),
                                );
                              }).toList(),
                            ),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _SectionCard(
                title: 'Mode',
                count: 0,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 10,
                      children: FlowMode.values.map((m) {
                        final on = m == _mode;
                        return ChoiceChip(
                          selected: on,
                          label: Text(ModeRules(m).displayName),
                          onSelected: (_) => _setMode(m),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      detail,
                      style: TextStyle(
                        color: context.themeTextMuted,
                        fontSize: 13,
                        height: 1.35,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Kanban: WIP limits tasks in Doing.\n'
                      'Scrum: commit up to 3 tasks per day.',
                      style: TextStyle(
                        color: context.themeTextMuted,
                        fontSize: 12,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Consumer<PremiumController>(
                builder: (context, premium, _) {
                  if (premium.isPremium) {
                    return _SectionCard(
                      title: 'Premium',
                      count: 0,
                      child: Row(
                        children: [
                          Icon(Icons.verified, color: context.themeAccent),
                          const SizedBox(width: 8),
                          const Text(
                            'Leanly Pro Active',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
                    );
                  }
                  return _SectionCard(
                    title: 'Premium',
                    count: 0,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Unlock Leanly Pro',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '• 30-day advanced statistics\n• Custom Pomodoro settings\n• Unlimited tasks & limits\n• Extra themes',
                          style: TextStyle(
                            fontSize: 13,
                            color: context.themeTextMuted,
                          ),
                        ),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => PremiumScreen(),
                              ),
                            );
                          },
                          icon: const Icon(Icons.star),
                          label: const Text('Go Premium'),
                        ),
                        const SizedBox(height: 8),
                        TextButton.icon(
                          onPressed: () async {
                            final controller = Provider.of<PremiumController>(context, listen: false);
                            final success = await controller.restorePurchases();
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(success
                                      ? 'Purchases restored'
                                      : 'No purchases found'),
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                            }
                          },
                          icon: const Icon(Icons.restore),
                          label: const Text('Restore Purchases'),
                        ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              _SectionCard(
                title: 'About',
                count: 0,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: const [
                        Text(
                          'Leanly: Agile Planner',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          'v1.2.3',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Personal task planner inspired by agile workflows (Scrum, Kanban).',
                      style: TextStyle(
                        fontSize: 13,
                        color: context.themeTextMuted,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Icon(
                          Icons.privacy_tip_outlined,
                          size: 18,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'Tasks stay on this device by default. If you use Cloud sync (Sign in with Apple), data is stored in your Supabase project under your account.',
                            style: TextStyle(
                              fontSize: 13,
                              color: context.themeTextMuted,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // Debug: Premium toggle (only in debug mode)
              if (kDebugMode) ...[
                const SizedBox(height: 12),
                _SectionCard(
                  title: 'Debug',
                  count: 0,
                  child: Consumer<PremiumController>(
                    builder: (context, premium, _) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                'Premium Status (Debug)',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Switch(
                                value: premium.isPremium,
                                onChanged: (value) async {
                                  final controller = Provider.of<PremiumController>(context, listen: false);
                                  await controller.setPremiumStatusForDebug(value);
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            premium.isPremium
                                ? 'Premium is ACTIVE (Debug Mode)'
                                : 'Premium is INACTIVE (Debug Mode)',
                            style: TextStyle(
                              fontSize: 13,
                              color: context.themeTextMuted,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ],
            ),
          ),
        ),
      ),
    );
  }
}

/* ===================== Premium Screen ===================== */

class PremiumScreen extends StatefulWidget {
  const PremiumScreen({super.key});

  @override
  State<PremiumScreen> createState() => _PremiumScreenState();
}

class _PremiumScreenState extends State<PremiumScreen> {
  bool _isLoading = false;

  @override
  Widget build(BuildContext context) {
    final premium = Provider.of<PremiumController>(context);

    return Scaffold(
      backgroundColor: context.themeBg,
      appBar: AppBar(
        title: const Text('Leanly Pro'),
        backgroundColor: Colors.transparent,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Icon(
                Icons.star_rounded,
                size: 80,
                color: context.themeAccent,
              ),
              const SizedBox(height: 16),
              const Text(
                'Unlock Leanly Pro',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Get the most out of your productivity',
                style: TextStyle(
                  fontSize: 16,
                  color: context.themeTextMuted,
                ),
              ),
              const SizedBox(height: 32),
              _FeatureItem(
                icon: Icons.analytics_outlined,
                title: 'Advanced Statistics',
                description: '30-day insights, trends, and mood analysis',
              ),
              const SizedBox(height: 16),
              _FeatureItem(
                icon: Icons.timer_outlined,
                title: 'Custom Pomodoro',
                description: 'Set custom work/break times and daily goals',
              ),
              const SizedBox(height: 16),
              _FeatureItem(
                icon: Icons.all_inclusive,
                title: 'Unlimited Tasks',
                description: 'Remove daily limits and customize WIP/commit limits',
              ),
              const SizedBox(height: 16),
              _FeatureItem(
                icon: Icons.palette_outlined,
                title: 'Extra Themes',
                description: 'Additional color themes for personalization',
              ),
              const Spacer(),
              if (premium.isPremium)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: context.themeSuccess.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.check_circle, color: context.themeSuccess),
                      const SizedBox(width: 8),
                      Text(
                        'You already have Leanly Pro',
                        style: TextStyle(
                          color: context.themeSuccess,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                )
              else
                Column(
                  children: [
                    FilledButton(
                      onPressed: _isLoading ? null : () async {
                        setState(() => _isLoading = true);
                        final success = await premium.buyPremium();
                        setState(() => _isLoading = false);
                        if (mounted) {
                          if (success) {
                            Navigator.pop(context);
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Purchase initiated'),
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          } else {
                            // Show detailed error message if available
                            final errorMessage = premium.lastPurchaseError ?? 
                                'Purchase failed. Please try again.';
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(errorMessage),
                                behavior: SnackBarBehavior.floating,
                                duration: const Duration(seconds: 4),
                              ),
                            );
                          }
                        }
                      },
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(double.infinity, 50),
                      ),
                      child: _isLoading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Unlock Leanly Pro'),
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: () async {
                        final success = await premium.restorePurchases();
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(success
                                  ? 'Purchases restored'
                                  : 'No purchases found'),
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                        }
                      },
                      child: const Text('Restore Purchases'),
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

class _FeatureItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;

  const _FeatureItem({
    required this.icon,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: context.themeAccent, size: 24),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                description,
                style: TextStyle(
                  fontSize: 13,
                  color: context.themeTextMuted,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/* ===================== UI Widgets ===================== */

class _MoodChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _MoodChip({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      avatar: Icon(icon, size: 22, color: context.themeTextMuted),
      label: Text(label),
      onPressed: onTap,
    );
  }
}

class _ModeSegmentedControl extends StatelessWidget {
  final FlowMode selected;
  final ValueChanged<FlowMode> onSelected;

  const _ModeSegmentedControl({
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final accent = context.themeAccent;
    final onSurface = Theme.of(context).colorScheme.onSurface;

    return SegmentedButton<FlowMode>(
      segments: const [
        ButtonSegment(
          value: FlowMode.scrum,
          label: Text('Scrum'),
          icon: Icon(Icons.view_timeline_rounded, size: 18),
        ),
        ButtonSegment(
          value: FlowMode.kanban,
          label: Text('Kanban'),
          icon: Icon(Icons.view_kanban_rounded, size: 18),
        ),
      ],
      selected: {selected},
      onSelectionChanged: (modes) => onSelected(modes.first),
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return Colors.white;
          }
          return onSurface.withValues(alpha: 0.75);
        }),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return accent;
          }
          return context.themeCard;
        }),
        side: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return BorderSide(color: accent);
          }
          return BorderSide(
            color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2),
          );
        }),
      ),
    );
  }
}

class _ModeStatusPanel extends StatelessWidget {
  final FlowMode mode;
  final int doingCount;
  final int? wipLimit;
  final int doneCount;
  final int totalCount;
  final int committedDone;
  final int? commitLimit;
  final int committedCount;
  final String? pomodoroLabel;

  const _ModeStatusPanel({
    required this.mode,
    required this.doingCount,
    required this.wipLimit,
    required this.doneCount,
    required this.totalCount,
    required this.committedDone,
    required this.commitLimit,
    required this.committedCount,
    this.pomodoroLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (pomodoroLabel != null) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: context.themeAccent.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.timer_outlined, size: 16, color: context.themeAccent),
                const SizedBox(width: 6),
                Text(
                  pomodoroLabel!,
                  style: TextStyle(
                    fontSize: AppTypography.sm,
                    fontWeight: FontWeight.w600,
                    color: context.themeAccent,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
        if (wipLimit != null) ...[
          _StatusMeter(
            fraction: '$doingCount/$wipLimit',
            progress: doingCount / wipLimit!,
            accent: doingCount >= wipLimit!
                ? context.themeError
                : doingCount / wipLimit! >= 0.8
                    ? context.themeWarning
                    : context.themeAccent,
          ),
          const SizedBox(height: AppSpacing.sm),
        ] else if (commitLimit != null && totalCount > 0) ...[
          _StatusMeter(
            fraction: '$doneCount/$totalCount',
            progress: doneCount / totalCount,
            accent: context.themeAccent,
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
      ],
    );
  }
}

class _StatusMeter extends StatelessWidget {
  final String fraction;
  final double progress;
  final Color accent;

  const _StatusMeter({
    required this.fraction,
    required this.progress,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final clamped = progress.clamp(0.0, 1.0);

    return Row(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: clamped,
              minHeight: 8,
              backgroundColor: context.themeSoftRow,
              color: accent,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          fraction,
          style: TextStyle(
            fontSize: AppTypography.sm,
            fontWeight: FontWeight.w800,
            color: accent,
            letterSpacing: 0.2,
          ),
        ),
      ],
    );
  }
}

class _HeaderCard extends StatelessWidget {
  final String title;
  final FlowMode mode;
  final int doingCount;
  final int? wipLimit;
  final int doneCount;
  final int totalCount;
  final int committedDone;
  final int? commitLimit;
  final int committedCount;
  final String focusLabel;
  final String? pomodoroLabel;

  final VoidCallback onEndDay;
  final VoidCallback onPomodoro;
  final VoidCallback onToggleDarkMode;
  final VoidCallback onSearch;
  final bool searchActive;

  const _HeaderCard({
    required this.title,
    required this.mode,
    required this.doingCount,
    required this.wipLimit,
    required this.doneCount,
    required this.totalCount,
    required this.committedDone,
    required this.commitLimit,
    required this.committedCount,
    required this.focusLabel,
    this.pomodoroLabel,
    required this.onEndDay,
    required this.onPomodoro,
    required this.onToggleDarkMode,
    required this.onSearch,
    this.searchActive = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: context.themeCard,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(
          color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.12),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: AppTypography.xl,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              TopIconButton(
                icon: Icons.search_rounded,
                tooltip: 'Search tasks',
                onTap: onSearch,
                highlighted: searchActive,
              ),
              TopIconButton(
                icon: Icons.timer_rounded,
                tooltip: 'Deep Focus',
                onTap: onPomodoro,
              ),
              TopIconButton(
                icon: Icons.flag_rounded,
                tooltip: 'End day',
                onTap: onEndDay,
              ),
              TopIconButton(
                icon: isDark
                    ? Icons.light_mode_rounded
                    : Icons.dark_mode_rounded,
                tooltip: isDark ? 'Light mode' : 'Dark mode',
                onTap: onToggleDarkMode,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          _ModeStatusPanel(
            mode: mode,
            doingCount: doingCount,
            wipLimit: wipLimit,
            doneCount: doneCount,
            totalCount: totalCount,
            committedDone: committedDone,
            commitLimit: commitLimit,
            committedCount: committedCount,
            pomodoroLabel: pomodoroLabel,
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                child: _CompactStat(
                  icon: Icons.play_circle_rounded,
                  label: 'Doing',
                  value: wipLimit == null
                      ? '$doingCount'
                      : '$doingCount/$wipLimit',
                  accent: context.themeInfo,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _CompactStat(
                  icon: Icons.check_circle_rounded,
                  label: 'Done',
                  value: '$doneCount',
                  accent: context.themeSuccess,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _CompactStat(
                  icon: Icons.label_rounded,
                  label: 'Focus',
                  value: focusLabel,
                  accent: context.themeAccent,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CompactStat extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color accent;

  const _CompactStat({
    required this.icon,
    required this.label,
    required this.value,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: context.themeSoftRow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: accent),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: context.themeTextMuted,
                  ),
                ),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppTypography.md,
                    fontWeight: FontWeight.w800,
                    height: 1.1,
                    color: Theme.of(context).colorScheme.onSurface,
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

class _QuickAddBar extends StatelessWidget {
  final VoidCallback onTap;

  const _QuickAddBar({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.themeCard,
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.card),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(
              color: context.themeAccent.withValues(alpha: 0.35),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Add a new task...',
                  style: TextStyle(
                    fontSize: AppTypography.md,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.55),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Icon(Icons.add_circle_rounded, color: context.themeAccent, size: 28),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  final String label;
  final String value;
  final int? wipLimit;
  final int? doingCount;

  const _MiniStat({
    required this.label,
    required this.value,
    this.wipLimit,
    this.doingCount,
  });

  Color _getWipColor(BuildContext context) {
    if (wipLimit == null || doingCount == null) {
      return context.themeSoftRow;
    }
    final ratio = doingCount! / wipLimit!;
    if (ratio >= 1.0) {
      return Colors.red.withOpacity(0.2);
    } else if (ratio >= 0.8) {
      return Colors.orange.withOpacity(0.2);
    }
    return context.themeSoftRow;
  }

  Color _getWipBorderColor() {
    if (wipLimit == null || doingCount == null) {
      return Colors.transparent;
    }
    final ratio = doingCount! / wipLimit!;
    if (ratio >= 1.0) {
      return Colors.red;
    } else if (ratio >= 0.8) {
      return Colors.orange;
    }
    return Colors.transparent;
  }

  @override
  Widget build(BuildContext context) {
    final hasWipWarning = wipLimit != null && doingCount != null && doingCount! / wipLimit! >= 0.8;
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: _getWipColor(context),
        borderRadius: BorderRadius.circular(14),
        border: hasWipWarning
            ? Border.all(color: _getWipBorderColor(), width: 2)
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
        children: [
          Text(label,
                  style: TextStyle(fontSize: 11, color: context.themeTextMuted)),
              if (hasWipWarning) ...[
                const SizedBox(width: 4),
                Icon(
                  doingCount! >= wipLimit! ? Icons.warning : Icons.info_outline,
                  size: 12,
                  color: _getWipBorderColor(),
                ),
              ],
            ],
          ),
          const SizedBox(height: 2),
          Row(
            children: [
          Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
              if (wipLimit != null && doingCount != null) ...[
                const SizedBox(width: 6),
                SizedBox(
                  width: 40,
                  height: 4,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: doingCount! / wipLimit!,
                      backgroundColor: context.themeSoftRow,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        doingCount! >= wipLimit!
                            ? Colors.red
                            : doingCount! / wipLimit! >= 0.8
                                ? Colors.orange
                                : context.themeAccent,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _FocusPills extends StatelessWidget {
  final Focus selected;
  final ValueChanged<Focus> onSelect;

  const _FocusPills({required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final outline = Theme.of(context).colorScheme.outline;

    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: Focus.values.map((f) {
          final isOn = f == selected;
          final label = titleCase(f.name);
          return Padding(
            padding: const EdgeInsets.only(right: 10),
            child: ChoiceChip(
              selected: isOn,
              label: Text(label),
              onSelected: (_) => onSelect(f),
              labelStyle: TextStyle(
                fontWeight: FontWeight.w600,
                color: isOn ? Colors.white : onSurface,
              ),
              selectedColor: context.themeAccent,
              backgroundColor: context.themeCard,
              side: BorderSide(
                color: isOn
                    ? context.themeAccent
                    : outline.withValues(alpha: 0.45),
                width: isOn ? 1.5 : 1,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final int count;
  final Widget child;

  const _SectionCard({
    required this.title,
    required this.count,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      color: context.themeCard,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                height: 1.2,
              ),
            ),
            if (count > 0) ...[
              const SizedBox(height: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: context.themeSoftRow,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '$count',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

// ===================== Empty States =====================

class _EmptyTaskState extends StatelessWidget {
  final String message;
  final IconData icon;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _EmptyTaskState({
    required this.message,
    required this.icon,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        vertical: AppSpacing.xxl,
        horizontal: AppSpacing.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  context.themeAccent.withValues(alpha: 0.18),
                  context.themeSoftRow,
                ],
              ),
            ),
            child: Icon(
              icon,
              size: 36,
              color: context.themeAccent.withValues(alpha: 0.85),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            message,
            style: TextStyle(
              fontSize: AppTypography.md,
              color: context.themeTextMuted,
              fontWeight: FontWeight.w600,
            ),
            textAlign: TextAlign.center,
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: AppSpacing.lg),
            OutlinedButton.icon(
              onPressed: onAction,
              icon: const Icon(Icons.add, size: 18),
              label: Text(actionLabel!),
            ),
          ],
        ],
      ),
    );
  }
}

class _TodaySkeleton extends StatelessWidget {
  const _TodaySkeleton();

  @override
  Widget build(BuildContext context) {
    Widget skeletonCard() {
      return Container(
        margin: const EdgeInsets.only(bottom: AppSpacing.sm),
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: context.themeSoftRow,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: context.themeSoftRowDim,
                borderRadius: BorderRadius.circular(6),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Container(
                height: 12,
                decoration: BoxDecoration(
                  color: context.themeSoftRowDim,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
          ],
        ),
      );
    }

    Widget columnSkeleton(String title) {
      return _SectionCard(
        title: title,
        count: 0,
        child: Column(
          children: [
            skeletonCard(),
            skeletonCard(),
            skeletonCard(),
          ],
        ),
      );
    }

    return SingleChildScrollView(
      child: Column(
        children: [
          columnSkeleton('To do'),
          const SizedBox(height: AppSpacing.md),
          columnSkeleton('Doing'),
          const SizedBox(height: AppSpacing.md),
          columnSkeleton('Done'),
          const SizedBox(height: AppSpacing.xl),
        ],
      ),
    );
  }
}

class _HistorySkeleton extends StatelessWidget {
  const _HistorySkeleton();

  @override
  Widget build(BuildContext context) {
    Widget cardSkeleton() {
      return Container(
        padding: const EdgeInsets.all(AppSpacing.lg),
        decoration: BoxDecoration(
          color: context.themeCard,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: context.themeSoftRow,
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            const SizedBox(width: AppSpacing.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    height: 12,
                    width: 120,
                    decoration: BoxDecoration(
                      color: context.themeSoftRow,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Container(
                    height: 10,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: context.themeSoftRow,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      itemCount: 4,
      separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.md),
      itemBuilder: (_, __) => cardSkeleton(),
    );
  }
}

class _HistoryFilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onSelected;

  const _HistoryFilterChip({
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onSelected(),
      labelStyle: TextStyle(
        fontSize: AppTypography.sm,
        fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
      ),
    );
  }
}

class _TaskList extends StatelessWidget {
  final List<Task> tasks;
  final FlowMode mode;
  final bool disableSwipeForward;


  final void Function(Task)? onMoveForward;
  final void Function(Task)? onMoveBack;
  final void Function(Task) onTapTask;
  final void Function(Task) onDeleteTask;
  final void Function(Task) onToggleCommit;

  final bool dimmed;

  const _TaskList({
  required this.tasks,
  required this.mode,
  required this.onMoveForward,
  required this.onMoveBack,
  required this.onTapTask,
  required this.onDeleteTask,
  required this.onToggleCommit,
  this.dimmed = false,
  this.disableSwipeForward = false,
});


  @override
Widget build(BuildContext context) {
  if (tasks.isEmpty) {
      return _EmptyTaskState(
        message: 'No tasks yet',
        icon: Icons.playlist_add_check_rounded,
    );
  }

  final showCommit = mode == FlowMode.scrum;

  return Column(
    children: tasks.map((t) {
      final isDone = t.status == TaskStatus.done;

      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
          child: Semantics(
            label:
                'Task: ${t.title}. Status: ${t.status.name}. ${t.committedToday ? "Committed" : ""}',
        child: Dismissible(
              key: ValueKey('${t.id}_dismissible'),
  direction: disableSwipeForward
      ? DismissDirection.endToStart
      : DismissDirection.horizontal,

          // swipe right (move forward)
          background: Container(
            decoration: BoxDecoration(
              color: context.themeSuccess.withValues(alpha: 0.22),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: context.themeSuccess.withValues(alpha: 0.4),
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            alignment: Alignment.centerLeft,
            child: Row(
              children: [
                Icon(Icons.arrow_forward, color: context.themeSuccess),
                const SizedBox(width: 8),
                Text(
                  'Move forward',
                  style: TextStyle(
                    color: context.themeSuccess,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),

          // swipe left (move back)
          secondaryBackground: Container(
            decoration: BoxDecoration(
              color: context.themeInfo.withValues(alpha: 0.22),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: context.themeInfo.withValues(alpha: 0.4),
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            alignment: Alignment.centerRight,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(
                  'Move back',
                  style: TextStyle(
                    color: context.themeInfo,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.arrow_back, color: context.themeInfo),
              ],
            ),
          ),

          confirmDismiss: (direction) async {
  if (direction == DismissDirection.startToEnd) {
    if (disableSwipeForward) return false;
    if (onMoveForward != null) onMoveForward!(t);
  } else {
    if (onMoveBack != null) onMoveBack!(t);
  }
  return false;
},

              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => onTapTask(t),
          child: Container(
            decoration: BoxDecoration(
                      color: dimmed
                          ? context.themeSoftRowDim
                          : context.themeSoftRow,
              borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: Theme.of(context)
                            .colorScheme
                            .outline
                            .withValues(alpha: 0.15),
                        width: 1,
                      ),
            ),
            child: ListTile(
              dense: true,
                      visualDensity: const VisualDensity(
                        horizontal: 0,
                        vertical: -1,
                      ),
              title: Row(
                children: [
                  Expanded(
                    child: Text(
                      t.title,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                                color: dimmed
                                    ? context.themeTextMuted
                                    : null,
                                decoration: isDone
                                    ? TextDecoration.lineThrough
                                    : null,
                      ),
                    ),
                  ),
                  if (showCommit && t.committedToday)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                                color: context.themeAccent,
                        borderRadius: BorderRadius.circular(999),
                      ),
                              child: Text(
                        'Committed',
                        style: TextStyle(
                                  color: context.themeCard,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
                      subtitle: (t.rolledOver &&
                              t.carriedOverFromDay != null)
                  ? Text(
                      'Rolled from ${t.carriedOverFromDay}',
                              style: TextStyle(
                                color: context.themeTextMuted,
                              ),
                    )
                  : null,
              trailing: PopupMenuButton<String>(
                icon: const Icon(Icons.more_horiz_rounded),
                onSelected: (v) {
                  if (v == 'delete') onDeleteTask(t);
                  if (v == 'commit') onToggleCommit(t);
                },
                itemBuilder: (ctx) => [
                  if (showCommit)
                    PopupMenuItem(
                      value: 'commit',
                              child: Text(
                                t.committedToday
                                    ? 'Uncommit'
                                    : 'Commit',
                              ),
                    ),
                  const PopupMenuItem(
                    value: 'delete',
                    child: Text('Delete'),
                  ),
                ],
                      ),
                    ),
                  ),
              ),
            ),
          ),
        ),
      );
    }).toList(),
  );
}
}

class _ReadOnlyTaskList extends StatelessWidget {
  final List<Task> tasks;
  final bool dimmed;

  const _ReadOnlyTaskList({required this.tasks, this.dimmed = false});

  @override
  Widget build(BuildContext context) {
    if (tasks.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(10),
        child: Text('Nothing here.',
            style: TextStyle(color: context.themeTextMuted)),
      );
    }

    return Column(
      children: tasks.map((t) {
        final isDone = t.status == TaskStatus.done;

        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Container(
  decoration: BoxDecoration(
    color: dimmed ? context.themeSoftRowDim : context.themeSoftRow,
    borderRadius: BorderRadius.circular(14),
    border: Border.all(
      color: const Color(0xFFE5E7EB), // very light border
      width: 1,
    ),
  ),
child: ListTile(
    dense: true,
    visualDensity: const VisualDensity(horizontal: 0, vertical: -1),
                title: Row(
                children: [
                  Expanded(
                    child: Text(
                      t.title,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: dimmed ? context.themeTextMuted : null,
                        decoration:
                            isDone ? TextDecoration.lineThrough : null,
                      ),
                    ),
                  ),
                  if (t.committedToday)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: context.themeAccent,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        'Committed',
                        style: TextStyle(
                          color: context.themeCard,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
              subtitle: (t.rolledOver && t.carriedOverFromDay != null)
                  ? Text(
                      'Rolled from ${t.carriedOverFromDay}',
                      style: TextStyle(color: context.themeTextMuted),
                    )
                  : null,
            ),
          ),
        );
      }).toList(),
    );
  }
}

class _HistoryCard extends StatelessWidget {
  final String dayKey;
  final IconData moodIcon;
  final String subtitle;
  final VoidCallback onTap;

  const _HistoryCard({
    required this.dayKey,
    required this.moodIcon,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: context.themeCard,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          children: [
            Icon(moodIcon, size: 28, color: context.themeTextMuted),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
  dayKey,
  style: const TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w700,
  ),
),

                  const SizedBox(height: 4),
                  Text(
  subtitle,
  maxLines: 2,
  overflow: TextOverflow.ellipsis,
  style: TextStyle(
    color: context.themeTextMuted,
    height: 1.3,
  ),
),

                ],
              ),
            ),
            Icon(
  Icons.chevron_right_rounded,
  color: context.themeTextMuted,
),

          ],
        ),
      ),
    );
  }
}

class _DaySummaryCard extends StatelessWidget {
  final IconData moodIcon;
  final String subtitle;

  const _DaySummaryCard({
    required this.moodIcon,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.themeCard,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
Icon(moodIcon, size: 36, color: context.themeAccent),
          const SizedBox(width: 12),
          Expanded(
  child: Text(
    subtitle,
    maxLines: 2,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(
      color: context.themeTextMuted,
      height: 1.3,
    ),
  ),
),

        ],
      ),
    );
  }
}

// ===================== UI PATCH (Calm Minimal + Lilac) =====================

// Spacing system (4px base)
class AppSpacing {
  static const double xs = 4.0;
  static const double sm = 8.0;
  static const double md = 12.0;
  static const double lg = 16.0;
  static const double xl = 24.0;
  static const double xxl = 32.0;
}

class AppRadius {
  static const double card = 20.0;
  static const double control = 12.0;
}

// Typography scale
class AppTypography {
  static const double xs = 10.0;
  static const double sm = 12.0;
  static const double base = 14.0;
  static const double md = 16.0;
  static const double lg = 18.0;
  static const double xl = 22.0;
  static const double xxl = 28.0;
  static const double xxxl = 32.0;
}

// ===================== Theme System =====================

// Theme color palettes
class ThemePalette {
  final Color accent;
  final Color bg;
  final Color card;
  final Color softRow;
  final Color softRowDim;
  final Color textMuted;

  const ThemePalette({
    required this.accent,
    required this.bg,
    required this.card,
    required this.softRow,
    required this.softRowDim,
    required this.textMuted,
  });
}

// Theme definitions
class AppThemes {
  // Calm (Default) - Lilac
  static const ThemePalette calmLight = ThemePalette(
    accent: Color(0xFF7C7EF2),
    bg: Color(0xFFF1F3F5),
    card: Colors.white,
    softRow: Color(0xFFF0F2F5),
    softRowDim: Color(0xFFE8EAED),
    textMuted: Color(0xFF64748B),
  );
  static const ThemePalette calmDark = ThemePalette(
    accent: Color(0xFF9B9DFF),
    bg: Color(0xFF0B1120),
    card: Color(0xFF1A2438),
    softRow: Color(0xFF243049),
    softRowDim: Color(0xFF2F3D56),
    textMuted: Color(0xFFB8C5D9),
  );

  // Ocean - Blue/Teal
  static const ThemePalette oceanLight = ThemePalette(
    accent: Color(0xFF06B6D4),
    bg: Color(0xFFF0F9FF),
    card: Colors.white,
    softRow: Color(0xFFE0F2FE),
    softRowDim: Color(0xFFBAE6FD),
    textMuted: Color(0xFF475569),
  );
  static const ThemePalette oceanDark = ThemePalette(
    accent: Color(0xFF22D3EE),
    bg: Color(0xFF0C1E2A),
    card: Color(0xFF1E3A4A),
    softRow: Color(0xFF2D4A5A),
    softRowDim: Color(0xFF3D5A6A),
    textMuted: Color(0xFF94A3B8),
  );

  // Forest - Green
  static const ThemePalette forestLight = ThemePalette(
    accent: Color(0xFF10B981),
    bg: Color(0xFFF0FDF4),
    card: Colors.white,
    softRow: Color(0xFFDCFCE7),
    softRowDim: Color(0xFFBBF7D0),
    textMuted: Color(0xFF475569),
  );
  static const ThemePalette forestDark = ThemePalette(
    accent: Color(0xFF34D399),
    bg: Color(0xFF0F1F15),
    card: Color(0xFF1E3A2A),
    softRow: Color(0xFF2D4A3A),
    softRowDim: Color(0xFF3D5A4A),
    textMuted: Color(0xFF94A3B8),
  );

  // Sunset - Orange/Pink
  static const ThemePalette sunsetLight = ThemePalette(
    accent: Color(0xFFF97316),
    bg: Color(0xFFFFF7ED),
    card: Colors.white,
    softRow: Color(0xFFFFEDD5),
    softRowDim: Color(0xFFFFD7B5),
    textMuted: Color(0xFF64748B),
  );
  static const ThemePalette sunsetDark = ThemePalette(
    accent: Color(0xFFFB923C),
    bg: Color(0xFF1F0F0A),
    card: Color(0xFF3A1F15),
    softRow: Color(0xFF4A2F25),
    softRowDim: Color(0xFF5A3F35),
    textMuted: Color(0xFF94A3B8),
  );

  // Dark Professional - Monochrome
  static const ThemePalette darkProfessionalLight = ThemePalette(
    accent: Color(0xFF6366F1),
    bg: Color(0xFFFAFAFA),
    card: Colors.white,
    softRow: Color(0xFFF5F5F5),
    softRowDim: Color(0xFFE5E5E5),
    textMuted: Color(0xFF6B7280),
  );
  static const ThemePalette darkProfessionalDark = ThemePalette(
    accent: Color(0xFF818CF8),
    bg: Color(0xFF0A0A0A),
    card: Color(0xFF1A1A1A),
    softRow: Color(0xFF2A2A2A),
    softRowDim: Color(0xFF3A3A3A),
    textMuted: Color(0xFF9CA3AF),
  );

  static ThemePalette getPalette(AppTheme theme, bool isDark) {
    switch (theme) {
      case AppTheme.calm:
        return isDark ? calmDark : calmLight;
      case AppTheme.ocean:
        return isDark ? oceanDark : oceanLight;
      case AppTheme.forest:
        return isDark ? forestDark : forestLight;
      case AppTheme.sunset:
        return isDark ? sunsetDark : sunsetLight;
      case AppTheme.darkProfessional:
        return isDark ? darkProfessionalDark : darkProfessionalLight;
    }
  }

  static String getDisplayName(AppTheme theme) {
    switch (theme) {
      case AppTheme.calm:
        return 'Calm';
      case AppTheme.ocean:
        return 'Ocean';
      case AppTheme.forest:
        return 'Forest';
      case AppTheme.sunset:
        return 'Sunset';
      case AppTheme.darkProfessional:
        return 'Dark Professional';
    }
  }
}

// Semantic colors (same for all themes)
const Color kSuccess = Color(0xFF10B981);
const Color kWarning = Color(0xFFF59E0B);
const Color kError = Color(0xFFEF4444);
const Color kInfo = Color(0xFF3B82F6);

const Color kSuccessDark = Color(0xFF34D399);
const Color kWarningDark = Color(0xFFFBBF24);
const Color kErrorDark = Color(0xFFF87171);
const Color kInfoDark = Color(0xFF60A5FA);

// Helper extension to get theme-aware colors
extension ThemeColors on BuildContext {
  ThemePalette get _palette {
    final premium = Provider.of<PremiumController>(this, listen: false);
    final appTheme = premium.isPremium ? Storage.loadTheme() : AppTheme.calm;
    final isDark = Theme.of(this).brightness == Brightness.dark;
    return AppThemes.getPalette(appTheme, isDark);
  }

  Color get themeBg => _palette.bg;
  Color get themeCard => _palette.card;
  Color get themeSoftRow => _palette.softRow;
  Color get themeSoftRowDim => _palette.softRowDim;
  Color get themeTextMuted => _palette.textMuted;
  Color get themeAccent => _palette.accent;
  
  // Semantic colors
  Color get themeSuccess => Theme.of(this).brightness == Brightness.dark ? kSuccessDark : kSuccess;
  Color get themeWarning => Theme.of(this).brightness == Brightness.dark ? kWarningDark : kWarning;
  Color get themeError => Theme.of(this).brightness == Brightness.dark ? kErrorDark : kError;
  Color get themeInfo => Theme.of(this).brightness == Brightness.dark ? kInfoDark : kInfo;
}

ThemeData buildTheme(AppTheme theme, bool isDark) {
  final palette = AppThemes.getPalette(theme, isDark);
  return ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: palette.accent,
      brightness: isDark ? Brightness.dark : Brightness.light,
    ),
    scaffoldBackgroundColor: palette.bg,
    navigationBarTheme: NavigationBarThemeData(
      height: 72,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      iconTheme: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return IconThemeData(color: palette.accent, size: 26);
        }
        return IconThemeData(color: palette.textMuted, size: 24);
      }),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final base = TextStyle(
          fontSize: 12,
          fontWeight:
              states.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500,
        );
        return base.copyWith(
          color: states.contains(WidgetState.selected)
              ? palette.accent
              : palette.textMuted,
        );
      }),
    ),
  );
}

// Legacy functions for backward compatibility
ThemeData buildCalmTheme() => buildTheme(AppTheme.calm, false);
ThemeData buildCalmDarkTheme() => buildTheme(AppTheme.calm, true);

class TopIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool highlighted;

  const TopIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.highlighted = false,
  });

  @override
  Widget build(BuildContext context) {
    final accent = context.themeAccent;

    return IconButton(
      onPressed: onTap,
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      icon: Icon(icon, size: 22),
      color: highlighted ? accent : Theme.of(context).colorScheme.onSurface,
      style: IconButton.styleFrom(
        padding: const EdgeInsets.all(8),
        minimumSize: const Size(40, 40),
        backgroundColor: highlighted
            ? accent.withValues(alpha: 0.15)
            : context.themeSoftRow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.control),
        ),
      ),
    );
  }
}


class _SettingsSheet extends StatelessWidget {
  const _SettingsSheet();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Settings',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          Text('Settings UI goes here.',
              style: TextStyle(color: context.themeTextMuted)),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class _AddTaskSheet extends StatefulWidget {
  final void Function(String) onAdd;

  const _AddTaskSheet({required this.onAdd});

  @override
  State<_AddTaskSheet> createState() => _AddTaskSheetState();
}

class _AddTaskSheetState extends State<_AddTaskSheet> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  final List<String> _templates = [
    'Daily standup',
    'Code review',
    'Write documentation',
    'Fix bug',
    'Team meeting',
    'Plan sprint',
    'Learn new skill',
    'Exercise',
    'Read book',
  ];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 8,
        bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: 'Add a new task...',
                  ),
                  onSubmitted: (v) {
                    widget.onAdd(v);
                  },
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: () {
                  widget.onAdd(_controller.text);
                },
                child: const Text('Add'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 36,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: _templates.map((template) {
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ActionChip(
                    label: Text(template),
                    onPressed: () {
                      _controller.text = template;
                    },
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }
}

class _EditTaskSheet extends StatefulWidget {
  final Task task;
  final void Function(String, Focus) onSave;

  const _EditTaskSheet({
    required this.task,
    required this.onSave,
  });

  @override
  State<_EditTaskSheet> createState() => _EditTaskSheetState();
}

class _EditTaskSheetState extends State<_EditTaskSheet> {
  late final TextEditingController _titleController;
  late Focus _selectedFocus;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.task.title);
    _selectedFocus = widget.task.focus;
  }

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 10,
        bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Edit task',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          TextField(
            controller: _titleController,
            decoration: const InputDecoration(labelText: 'Title'),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            children: Focus.values.map((f) {
              final on = f == _selectedFocus;
              return ChoiceChip(
                selected: on,
                label: Text(titleCase(f.name)),
                onSelected: (_) {
                  setState(() {
                    _selectedFocus = f;
                  });
                },
              );
            }).toList(),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: () {
                    final newTitle = _titleController.text.trim();
                    if (newTitle.isEmpty) return;
                    widget.onSave(newTitle, _selectedFocus);
                  },
                  child: const Text('Save'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ===================== Search and Filter Bar =====================

class _SearchAndFilterBar extends StatefulWidget {
  final int taskCount;
  final String searchQuery;
  final bool showCommittedOnly;
  final bool showRolledOverOnly;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<bool> onCommittedToggle;
  final ValueChanged<bool> onRolledOverToggle;
  final VoidCallback onCollapse;

  const _SearchAndFilterBar({
    required this.taskCount,
    required this.searchQuery,
    required this.showCommittedOnly,
    required this.showRolledOverOnly,
    required this.onSearchChanged,
    required this.onCommittedToggle,
    required this.onRolledOverToggle,
    required this.onCollapse,
  });

  @override
  State<_SearchAndFilterBar> createState() => _SearchAndFilterBarState();
}

class _SearchAndFilterBarState extends State<_SearchAndFilterBar> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.searchQuery);
  }

  @override
  void didUpdateWidget(covariant _SearchAndFilterBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.searchQuery != _controller.text) {
      _controller.text = widget.searchQuery;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.themeCard,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(
          color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.12),
        ),
      ),
      child: Column(
        children: [
          TextField(
            controller: _controller,
            autofocus: widget.searchQuery.isEmpty,
            onChanged: widget.onSearchChanged,
            decoration: InputDecoration(
              hintText: 'Search tasks...',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.searchQuery.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.clear_rounded),
                      tooltip: 'Clear search',
                      onPressed: () => widget.onSearchChanged(''),
                    ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    tooltip: 'Close search',
                    onPressed: widget.onCollapse,
                  ),
                ],
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.control),
                borderSide: BorderSide.none,
              ),
              filled: true,
              fillColor: context.themeSoftRow,
            ),
          ),
          if (widget.taskCount >= 3)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilterChip(
                    label: const Text('Committed'),
                    selected: widget.showCommittedOnly,
                    onSelected: widget.onCommittedToggle,
                  ),
                  FilterChip(
                    label: const Text('Rolled over'),
                    selected: widget.showRolledOverOnly,
                    onSelected: widget.onRolledOverToggle,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ===================== Day Summary Screen =====================

class DaySummaryScreen extends StatelessWidget {
  final String dayKey;
  final DayMood mood;
  final int doneCount;
  final int totalTasks;
  final int rolledOverCount;
  final VoidCallback onClose;

  const DaySummaryScreen({
    super.key,
    required this.dayKey,
    required this.mood,
    required this.doneCount,
    required this.totalTasks,
    required this.rolledOverCount,
    required this.onClose,
  });

  String _getTomorrowSuggestion() {
    if (rolledOverCount == 0) {
      return 'Great job! You completed everything. Start fresh tomorrow!';
    } else if (rolledOverCount <= 2) {
      return 'You have $rolledOverCount task${rolledOverCount > 1 ? 's' : ''} rolling over. Focus on completing them first tomorrow.';
    } else {
      return 'You have $rolledOverCount tasks rolling over. Consider breaking them down into smaller tasks.';
    }
  }

  String _getMoodMessage() {
    switch (mood) {
      case DayMood.good:
        return 'You had a productive day! Keep up the momentum.';
      case DayMood.meh:
        return 'Some days are like that. Tomorrow is a fresh start.';
      case DayMood.hard:
        return 'Tough days make us stronger. Rest well and come back refreshed.';
    }
  }

  @override
  Widget build(BuildContext context) {
    final completionRate = totalTasks > 0 ? (doneCount / totalTasks * 100) : 0.0;

    return Scaffold(
      backgroundColor: context.themeBg,
      appBar: AppBar(
        title: Text(dayKey),
        backgroundColor: Colors.transparent,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: context.themeCard,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(
                  children: [
                    Icon(
                      moodToIcon(mood),
                      size: 64,
                      color: context.themeAccent,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _getMoodMessage(),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: context.themeCard,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Today\'s Summary',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: _SummaryStat(
                            icon: Icons.check_circle,
                            label: 'Completed',
                            value: doneCount.toString(),
                            color: Colors.green,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _SummaryStat(
                            icon: Icons.arrow_forward,
                            label: 'Rolled Over',
                            value: rolledOverCount.toString(),
                            color: Colors.orange,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Completion Rate',
                            style: TextStyle(
                              fontSize: 14,
                              color: context.themeTextMuted,
                            ),
                          ),
                        ),
                        Text(
                          '${completionRate.toStringAsFixed(0)}%',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: completionRate / 100,
                        minHeight: 8,
                        backgroundColor: context.themeSoftRow,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          completionRate >= 80
                              ? Colors.green
                              : completionRate >= 50
                                  ? Colors.orange
                                  : Colors.red,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: context.themeCard,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.lightbulb_outline,
                            color: context.themeAccent),
                        const SizedBox(width: 8),
                        const Text(
                          'Tomorrow\'s Suggestion',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _getTomorrowSuggestion(),
                      style: TextStyle(
                        fontSize: 14,
                        color: context.themeTextMuted,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              FilledButton(
                onPressed: onClose,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(double.infinity, 50),
                ),
                child: const Text('View History'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SummaryStat extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _SummaryStat({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 24),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: context.themeTextMuted,
            ),
          ),
        ],
      ),
    );
  }
}

// ===================== Stats Card =====================

class _StatsCard extends StatelessWidget {
  final int totalTasksDone;
  final double avgTasksPerDay;
  final int totalPomodoros;
  final DayMood mostCommonMood;
  final int daysShown;
  final bool isPremium;

  const _StatsCard({
    required this.totalTasksDone,
    required this.avgTasksPerDay,
    required this.totalPomodoros,
    required this.mostCommonMood,
    required this.daysShown,
    required this.isPremium,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.themeCard,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Last $daysShown Days',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              if (!isPremium) ...[
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const PremiumScreen()),
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: context.themeAccent.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.star, size: 12, color: context.themeAccent),
                        const SizedBox(width: 4),
                        Text(
                          'PRO',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: context.themeAccent,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (!isPremium && daysShown < 30)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Upgrade to Pro for 30-day statistics',
                style: TextStyle(
                  fontSize: 11,
                  color: context.themeTextMuted,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _StatItem(
                  icon: Icons.check_circle,
                  label: 'Tasks Done',
                  value: totalTasksDone.toString(),
                ),
              ),
              Expanded(
                child: _StatItem(
                  icon: Icons.trending_up,
                  label: 'Avg/Day',
                  value: avgTasksPerDay.toStringAsFixed(1),
                ),
              ),
              Expanded(
                child: _StatItem(
                  icon: Icons.timer,
                  label: 'Pomodoros',
                  value: totalPomodoros.toString(),
                ),
              ),
              Expanded(
                child: _StatItem(
                  icon: Icons.mood,
                  label: 'Mood',
                  value: moodToLabel(mostCommonMood),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _StatItem({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, size: 20, color: context.themeAccent),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            color: context.themeTextMuted,
          ),
        ),
      ],
    );
  }
}

// ===================== Onboarding Screen =====================

class OnboardingScreen extends StatefulWidget {
  final VoidCallback onComplete;

  const OnboardingScreen({super.key, required this.onComplete});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  int _currentPage = 0;
  final PageController _pageController = PageController();

  final List<_OnboardingPage> _pages = [
    _OnboardingPage(
      icon: Icons.today,
      title: 'Welcome to Leanly',
      description: 'Your agile task management companion. Organize your day with Scrum or Kanban.',
    ),
    _OnboardingPage(
      icon: Icons.swipe,
      title: 'Swipe to Move Tasks',
      description: 'Swipe right to move tasks forward (To do → Doing → Done). Swipe left to move them back.',
    ),
    _OnboardingPage(
      icon: Icons.timer,
      title: 'Deep Focus Mode',
      description:
          'Use the timer button on Today to start Pomodoro sessions. Track your focused work time throughout the day.',
    ),
    _OnboardingPage(
      icon: Icons.nightlight_round,
      title: 'End Your Day',
      description: 'Close your day with a mood check. Unfinished tasks will roll over to tomorrow automatically.',
    ),
  ];

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _nextPage() {
    if (_currentPage < _pages.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      widget.onComplete();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.themeBg,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                onPageChanged: (index) {
                  setState(() {
                    _currentPage = index;
                  });
                },
                itemCount: _pages.length,
                itemBuilder: (context, index) {
                  final page = _pages[index];
                  return Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          page.icon,
                          size: 80,
                          color: context.themeAccent,
                        ),
                        const SizedBox(height: 32),
                        Text(
                          page.title,
                          style: const TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w700,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          page.description,
                          style: TextStyle(
                            fontSize: 16,
                            color: context.themeTextMuted,
                            height: 1.5,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(
                      _pages.length,
                      (index) => Container(
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        width: _currentPage == index ? 24 : 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: _currentPage == index
                              ? context.themeAccent
                              : context.themeTextMuted.withOpacity(0.3),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _nextPage,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(double.infinity, 50),
                    ),
                    child: Text(
                      _currentPage == _pages.length - 1
                          ? 'Get Started'
                          : 'Next',
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

class _OnboardingPage {
  final IconData icon;
  final String title;
  final String description;

  _OnboardingPage({
    required this.icon,
    required this.title,
    required this.description,
  });
}

// ===================== END UI PATCH =====================

