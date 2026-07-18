/// App-owned auth user model — decoupled from the Supabase SDK types so the
/// rest of the app (cubits, cache) never imports `supabase_flutter` directly.
class AuthUser {
  const AuthUser({
    required this.id,
    required this.name,
    required this.email,
    this.avatarPath,
  });

  final String id;
  final String name;
  final String email;
  final String? avatarPath;

  String get displayName => name.isNotEmpty ? name : email;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'email': email,
        'avatarPath': avatarPath,
      };

  factory AuthUser.fromJson(Map<String, dynamic> json) => AuthUser(
        id: json['id'] as String,
        name: json['name'] as String,
        email: json['email'] as String,
        avatarPath: json['avatarPath'] as String?,
      );
}
