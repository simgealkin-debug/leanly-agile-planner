part of 'main.dart';

/// Supabase Auth + Sign in with Apple + bidirectional Hive sync.
class SupabaseAuthController extends ChangeNotifier {
  StreamSubscription? _authSub;

  bool get isConfigured => SupabaseConfig.isConfigured;

  Session? get session =>
      isConfigured ? Supabase.instance.client.auth.currentSession : null;

  bool get isSignedIn => session != null;

  String? get userLabel {
    final u = session?.user;
    if (u == null) return null;
    return u.email ??
        (u.userMetadata?['full_name'] as String?) ??
        (u.userMetadata?['name'] as String?) ??
        'Signed in';
  }

  void attach() {
    if (!isConfigured) return;
    _authSub?.cancel();
    _authSub =
        Supabase.instance.client.auth.onAuthStateChange.listen((_) {
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }

  Future<String?> signInWithApple() async {
    if (!isConfigured) {
      return 'Supabase is not configured. Run with SUPABASE_URL and SUPABASE_ANON_KEY.';
    }
    if (kIsWeb || (!Platform.isIOS && !Platform.isMacOS)) {
      return 'Sign in with Apple is only available on iOS and macOS.';
    }
    try {
      final available = await SignInWithApple.isAvailable();
      if (!available) {
        return 'Sign in with Apple is not available on this device. Try a physical iPhone or sign into an Apple ID in Simulator (Settings app).';
      }

      final rawNonce = _randomNonce();
      final hashedNonce = sha256.convert(utf8.encode(rawNonce)).toString();

      final credential = await SignInWithApple.getAppleIDCredential(
        scopes: [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
        nonce: hashedNonce,
      );

      final idToken = credential.identityToken;
      if (idToken == null) {
        return 'Apple did not return an identity token. Check Sign in with Apple on your App ID and in Supabase Auth → Apple.';
      }

      await Supabase.instance.client.auth.signInWithIdToken(
        provider: OAuthProvider.apple,
        idToken: idToken,
        nonce: rawNonce,
      );

      await LeanlyCloudSync.pullAll();
      await LeanlyCloudSync.pushAll();
      SyncBus.instance.bump();
      return null;
    } on SignInWithAppleAuthorizationException catch (e) {
      return _friendlyAppleSignInMessage(e);
    } catch (e) {
      final s = e.toString();
      if (s.contains('AuthApiException') || s.contains('Invalid JWT')) {
        return 'Supabase rejected the Apple token. In Supabase: Authentication → Providers → Apple (Services ID, Team ID, Key, and redirect URLs must match Apple Developer).';
      }
      return 'Sign-in failed. Check your network and Supabase Apple provider settings.';
    }
  }

  Future<String?> signOut() async {
    if (!isConfigured) return null;
    try {
      await Supabase.instance.client.auth.signOut();
      await Storage.saveSkipCloudLogin(false);
      CloudLoginGateNotifier.instance.refresh();
      notifyListeners();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<String?> syncNowPull() async {
    if (!isSignedIn) return 'Sign in first.';
    try {
      await LeanlyCloudSync.pullAll();
      SyncBus.instance.bump();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<String?> syncNowPush() async {
    if (!isSignedIn) return 'Sign in first.';
    try {
      await LeanlyCloudSync.pushAll();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  /// Download from cloud, merge locally, then upload latest state.
  Future<String?> syncNow() async {
    if (!isSignedIn) return 'Sign in first.';
    try {
      await LeanlyCloudSync.pullAll();
      await LeanlyCloudSync.pushAll();
      SyncBus.instance.bump();
      return null;
    } catch (e) {
      return e.toString();
    }
  }
}

String _randomNonce([int length = 32]) {
  const charset =
      '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._';
  final random = Random.secure();
  return List.generate(
    length,
    (_) => charset[random.nextInt(charset.length)],
  ).join();
}

/// Maps Apple / ASAuthorization errors to short, actionable copy (not raw exceptions).
String _friendlyAppleSignInMessage(SignInWithAppleAuthorizationException e) {
  switch (e.code) {
    case AuthorizationErrorCode.canceled:
      return 'Sign in was canceled.';
    case AuthorizationErrorCode.failed:
      return 'Apple Sign In failed. In Xcode: open the Runner target → Signing & Capabilities → add “Sign in with Apple”, then clean build.';
    case AuthorizationErrorCode.invalidResponse:
      return 'Apple returned an unexpected response. Update the simulator or try again.';
    case AuthorizationErrorCode.notHandled:
      return 'This build cannot use Sign in with Apple. Add the capability in Xcode and enable Sign in with Apple on the App ID at developer.apple.com.';
    case AuthorizationErrorCode.unknown:
      return 'Apple Sign In could not complete (error 1000). '
          'Fix: (1) Simulator → Settings → sign in with a real Apple ID. '
          '(2) Xcode → Runner → Signing & Capabilities → “Sign in with Apple”. '
          '(3) developer.apple.com → Identifiers → your App ID → enable Sign in with Apple. '
          '(4) Supabase → Authentication → Providers → Apple: Services ID, Key, Team ID, and bundle ID must match.';
    case AuthorizationErrorCode.notInteractive:
      return 'Apple Sign In needs user interaction. Try again on this screen or use a physical device.';
  }
}

class LeanlyCloudSync {
  static SupabaseClient get _c => Supabase.instance.client;

  static Future<void> pushAll() async {
    final uid = _c.auth.currentUser?.id;
    if (uid == null) return;

    final tasks = Storage.loadActiveTasks();
    if (tasks.isNotEmpty) {
      await _c.from('leanly_tasks').upsert(
        tasks
            .map(
              (t) => {
                'user_id': uid,
                'task_id': t.id,
                'data': t.toJson(),
                'updated_at': t.updatedAt.toUtc().toIso8601String(),
              },
            )
            .toList(),
        onConflict: 'user_id,task_id',
      );
    }

    final settings = Storage.loadSettingsMap();
    if (settings != null && settings.isNotEmpty) {
      await _c.from('leanly_settings').upsert(
        {
          'user_id': uid,
          'data': settings,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        onConflict: 'user_id',
      );
    }

    for (final log in Storage.loadAllDayLogs()) {
      await _c.from('leanly_day_logs').upsert(
        {
          'user_id': uid,
          'day_key': log.dayKey,
          'data': log.toJson(),
          'updated_at': log.archivedAt.toUtc().toIso8601String(),
        },
        onConflict: 'user_id,day_key',
      );
    }

    for (final dayKey in Storage.pomodoroStorageDayKeys()) {
      final sessions = Storage.loadPomodoroSessions(dayKey);
      if (sessions.isEmpty) continue;
      await _c.from('leanly_pomodoro_days').upsert(
        {
          'user_id': uid,
          'day_key': dayKey,
          'sessions': sessions.map((s) => s.toJson()).toList(),
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        onConflict: 'user_id,day_key',
      );
    }
  }

  static Future<void> pullAll() async {
    final uid = _c.auth.currentUser?.id;
    if (uid == null) return;

    final taskRows = await _c.from('leanly_tasks').select().eq('user_id', uid);
    final localTasks = Storage.loadActiveTasks();
    final byId = {for (final t in localTasks) t.id: t};
    for (final row in taskRows as List) {
      final map = Map<String, dynamic>.from(row as Map);
      final data = Map<String, dynamic>.from(map['data'] as Map);
      final remote = Task.fromJson(data);
      final existing = byId[remote.id];
      if (existing == null || remote.updatedAt.isAfter(existing.updatedAt)) {
        byId[remote.id] = remote;
      }
    }
    await Storage.saveActiveTasks(byId.values.toList());

    final settingsRow = await _c
        .from('leanly_settings')
        .select()
        .eq('user_id', uid)
        .maybeSingle();
    if (settingsRow != null) {
      final map = Map<String, dynamic>.from(settingsRow);
      final data = map['data'];
      if (data is Map) {
        await Storage.replaceSettingsMap(Map<String, dynamic>.from(data));
      }
    }

    final logsRows = await _c.from('leanly_day_logs').select().eq('user_id', uid);
    for (final row in logsRows as List) {
      final map = Map<String, dynamic>.from(row as Map);
      final data = Map<String, dynamic>.from(map['data'] as Map);
      final log = DayLog.fromJson(data);
      final existing = Storage.loadDayLog(log.dayKey);
      if (existing == null || log.archivedAt.isAfter(existing.archivedAt)) {
        await Storage.saveDayLog(log);
      }
    }

    final pomRows =
        await _c.from('leanly_pomodoro_days').select().eq('user_id', uid);
    for (final row in pomRows as List) {
      final map = Map<String, dynamic>.from(row as Map);
      final dayKey = map['day_key'] as String;
      final sessionsJson = map['sessions'];
      if (sessionsJson is! List) continue;
      final local = Storage.loadPomodoroSessions(dayKey);
      final remote = sessionsJson
          .map(
            (e) => PomodoroSession.fromJson(
              Map<String, dynamic>.from(e as Map),
            ),
          )
          .toList();
      final merged = [...local];
      for (final r in remote) {
        final exists = merged.any(
          (l) => l.startedAt.toIso8601String() == r.startedAt.toIso8601String(),
        );
        if (!exists) merged.add(r);
      }
      merged.sort((a, b) => a.startedAt.compareTo(b.startedAt));
      await Storage.replacePomodoroSessions(dayKey, merged);
    }

    SyncBus.instance.bump();
  }
}
