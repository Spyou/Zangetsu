import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseService {
  SupabaseClient get client => Supabase.instance.client;
  String? currentUserId() => client.auth.currentUser?.id;

  /// Public URL for an avatar Storage object path (bucket public-read).
  String avatarUrl(String path) =>
      client.storage.from('avatars').getPublicUrl(path);
}
