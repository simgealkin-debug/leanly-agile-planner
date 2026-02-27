import 'package:flutter/foundation.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'supabase_service.dart';

/// Authentication service for Sign in with Apple
class AuthService {
  /// Sign in with Apple
  /// Returns true if successful, false otherwise
  static Future<bool> signInWithApple() async {
    try {
      // Request Apple ID credential
      final credential = await SignInWithApple.getAppleIDCredential(
        scopes: [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
      );

      // Sign in to Supabase with Apple credentials
      final success = await SupabaseService.signInWithApple(
        idToken: credential.identityToken!,
        accessToken: credential.authorizationCode!,
      );

      if (success && SupabaseService.isAuthenticated) {
        // Update user profile with name if available
        final user = SupabaseService.client.auth.currentUser;
        if (user != null && credential.givenName != null) {
          try {
            await SupabaseService.client.from('user_profiles').upsert({
              'id': user.id,
              'email': credential.email ?? user.email,
            });
          } catch (e) {
            debugPrint('Failed to update user profile: $e');
            // Non-critical error, continue
          }
        }
      }

      return success;
    } catch (e) {
      debugPrint('Sign in with Apple error: $e');
      return false;
    }
  }

  /// Sign out
  static Future<void> signOut() async {
    await SupabaseService.signOut();
  }

  /// Check if user is authenticated
  static bool get isAuthenticated => SupabaseService.isAuthenticated;

  /// Get current user
  static User? get currentUser => SupabaseService.client.auth.currentUser;
}
