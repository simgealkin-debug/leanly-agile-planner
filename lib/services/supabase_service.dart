import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../main.dart';

/// Supabase service for syncing data across devices
class SupabaseService {
  static SupabaseClient get client => Supabase.instance.client;
  
  /// Check if user is authenticated
  static bool get isAuthenticated => client.auth.currentUser != null;
  
  /// Get current user ID
  static String? get userId => client.auth.currentUser?.id;
  
  // ===================== AUTH =====================
  
  /// Sign in with Apple
  /// Returns true if successful, false otherwise
  static Future<bool> signInWithApple({
    required String idToken,
    required String accessToken,
  }) async {
    try {
      final response = await client.auth.signInWithIdToken(
        provider: OAuthProvider.apple,
        idToken: idToken,
        accessToken: accessToken,
      );
      return response.user != null;
    } catch (e) {
      debugPrint('Sign in with Apple error: $e');
      return false;
    }
  }
  
  /// Sign out
  static Future<void> signOut() async {
    await client.auth.signOut();
  }
  
  /// Get current session
  static Session? get currentSession => client.auth.currentSession;
  
  // ===================== TASKS =====================
  
  /// Convert Supabase JSON (snake_case) to Task JSON (camelCase)
  static Map<String, dynamic> _supabaseToTaskJson(Map<String, dynamic> supabaseJson) {
    return {
      'id': supabaseJson['id'],
      'title': supabaseJson['title'],
      'status': supabaseJson['status'],
      'focus': supabaseJson['focus'],
      'createdAt': supabaseJson['created_at'],
      'updatedAt': supabaseJson['updated_at'],
      'rolledOver': supabaseJson['rolled_over'] ?? false,
      'carriedOverFromDay': supabaseJson['carried_over_from_day'],
      'committedToday': supabaseJson['committed_today'] ?? false,
      'tags': supabaseJson['tags'] ?? [],
      'dueDate': supabaseJson['due_date'],
    };
  }
  
  /// Convert Task JSON (camelCase) to Supabase JSON (snake_case)
  static Map<String, dynamic> _taskToSupabaseJson(Map<String, dynamic> taskJson) {
    return {
      'id': taskJson['id'],
      'user_id': taskJson['user_id'],
      'title': taskJson['title'],
      'status': taskJson['status'],
      'focus': taskJson['focus'],
      'created_at': taskJson['createdAt'],
      'updated_at': taskJson['updatedAt'],
      'rolled_over': taskJson['rolledOver'] ?? false,
      'carried_over_from_day': taskJson['carriedOverFromDay'],
      'committed_today': taskJson['committedToday'] ?? false,
      'tags': taskJson['tags'] ?? [],
      'due_date': taskJson['dueDate'],
    };
  }
  
  /// Fetch all tasks for current user
  static Future<List<Task>> fetchTasks() async {
    if (!isAuthenticated) return [];
    
    try {
      final response = await client
          .from('tasks')
          .select()
          .eq('user_id', userId!)
          .order('created_at', ascending: false);
      
      return (response as List)
          .map((json) => Task.fromJson(_supabaseToTaskJson(json)))
          .toList();
    } catch (e) {
      debugPrint('Fetch tasks error: $e');
      return [];
    }
  }
  
  /// Save/update a task
  static Future<bool> saveTask(Task task) async {
    if (!isAuthenticated) return false;
    
    try {
      final taskJson = task.toJson();
      taskJson['user_id'] = userId;
      final supabaseJson = _taskToSupabaseJson(taskJson);
      
      await client.from('tasks').upsert(supabaseJson);
      return true;
    } catch (e) {
      debugPrint('Save task error: $e');
      return false;
    }
  }
  
  /// Delete a task
  static Future<bool> deleteTask(String taskId) async {
    if (!isAuthenticated) return false;
    
    try {
      await client
          .from('tasks')
          .delete()
          .eq('id', taskId)
          .eq('user_id', userId!);
      return true;
    } catch (e) {
      debugPrint('Delete task error: $e');
      return false;
    }
  }
  
  /// Batch save tasks
  static Future<bool> saveTasks(List<Task> tasks) async {
    if (!isAuthenticated) return false;
    
    try {
      final tasksJson = tasks.map((task) {
        final json = task.toJson();
        json['user_id'] = userId;
        return _taskToSupabaseJson(json);
      }).toList();
      
      await client.from('tasks').upsert(tasksJson);
      return true;
    } catch (e) {
      debugPrint('Batch save tasks error: $e');
      return false;
    }
  }
  
  // ===================== DAY LOGS =====================
  
  /// Convert Supabase JSON (snake_case) to DayLog JSON (camelCase)
  static Map<String, dynamic> _supabaseToDayLogJson(Map<String, dynamic> supabaseJson) {
    return {
      'dayKey': supabaseJson['day_key'],
      'mood': supabaseJson['mood'],
      'mode': supabaseJson['mode'],
      'tasksSnapshot': supabaseJson['tasks_snapshot'],
      'archivedAt': supabaseJson['archived_at'],
    };
  }
  
  /// Convert DayLog JSON (camelCase) to Supabase JSON (snake_case)
  static Map<String, dynamic> _dayLogToSupabaseJson(Map<String, dynamic> logJson) {
    return {
      'id': logJson['id'],
      'user_id': logJson['user_id'],
      'day_key': logJson['dayKey'],
      'mood': logJson['mood'],
      'mode': logJson['mode'],
      'tasks_snapshot': logJson['tasksSnapshot'],
      'archived_at': logJson['archivedAt'],
    };
  }
  
  /// Fetch day log for a specific day
  static Future<DayLog?> fetchDayLog(String dayKey) async {
    if (!isAuthenticated) return null;
    
    try {
      final response = await client
          .from('day_logs')
          .select()
          .eq('user_id', userId!)
          .eq('day_key', dayKey)
          .maybeSingle();
      
      if (response == null) return null;
      return DayLog.fromJson(_supabaseToDayLogJson(response));
    } catch (e) {
      debugPrint('Fetch day log error: $e');
      return null;
    }
  }
  
  /// Save day log
  static Future<bool> saveDayLog(DayLog log) async {
    if (!isAuthenticated) return false;
    
    try {
      final logJson = log.toJson();
      logJson['user_id'] = userId;
      final supabaseJson = _dayLogToSupabaseJson(logJson);
      
      await client.from('day_logs').upsert(supabaseJson);
      return true;
    } catch (e) {
      debugPrint('Save day log error: $e');
      return false;
    }
  }
  
  /// Fetch all day logs
  static Future<List<DayLog>> fetchAllDayLogs() async {
    if (!isAuthenticated) return [];
    
    try {
      final response = await client
          .from('day_logs')
          .select()
          .eq('user_id', userId!)
          .order('day_key', ascending: false);
      
      return (response as List)
          .map((json) => DayLog.fromJson(_supabaseToDayLogJson(json)))
          .toList();
    } catch (e) {
      debugPrint('Fetch all day logs error: $e');
      return [];
    }
  }
  
  // ===================== PREMIUM =====================
  
  /// Check premium status from backend
  static Future<bool> fetchPremiumStatus() async {
    if (!isAuthenticated) return false;
    
    try {
      final response = await client
          .from('premium_entitlements')
          .select('is_premium')
          .eq('user_id', userId!)
          .maybeSingle();
      
      return (response?['is_premium'] as bool?) ?? false;
    } catch (e) {
      debugPrint('Fetch premium status error: $e');
      return false;
    }
  }
  
  /// Set premium status (called after successful purchase)
  static Future<bool> setPremiumStatus({
    required bool isPremium,
    String? platform,
  }) async {
    if (!isAuthenticated) return false;
    
    try {
      await client.from('premium_entitlements').upsert({
        'user_id': userId,
        'is_premium': isPremium,
        'purchase_date': isPremium ? DateTime.now().toIso8601String() : null,
        'platform': platform ?? 'ios',
        'updated_at': DateTime.now().toIso8601String(),
      });
      return true;
    } catch (e) {
      debugPrint('Set premium status error: $e');
      return false;
    }
  }
  
  // ===================== REAL-TIME SYNC =====================
  
  /// Subscribe to task changes (real-time sync)
  static RealtimeChannel subscribeToTasks({
    required Function(Map<String, dynamic>) onTaskChanged,
  }) {
    if (!isAuthenticated) {
      throw Exception('User must be authenticated to subscribe');
    }
    
    return client
        .channel('tasks_${userId}')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'tasks',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: (payload) {
            onTaskChanged(payload.newRecord);
          },
        )
        .subscribe();
  }
  
  // ===================== SYNC HELPERS =====================
  
  /// Sync local tasks to remote
  static Future<bool> syncTasksToRemote(List<Task> localTasks) async {
    if (!isAuthenticated) return false;
    
    try {
      return await saveTasks(localTasks);
    } catch (e) {
      debugPrint('Sync tasks to remote error: $e');
      return false;
    }
  }
  
  /// Sync remote tasks to local
  static Future<List<Task>> syncTasksFromRemote() async {
    if (!isAuthenticated) return [];
    
    try {
      return await fetchTasks();
    } catch (e) {
      debugPrint('Sync tasks from remote error: $e');
      return [];
    }
  }
}
