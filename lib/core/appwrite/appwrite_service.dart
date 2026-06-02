import 'package:appwrite/appwrite.dart';

import '../environment.dart';

/// Thin holder for the shared Appwrite client + its service handles. The
/// client persists the session (cookie/JWT) across launches automatically.
class AppwriteService {
  AppwriteService() {
    client = Client()
        .setEndpoint(Environment.appwritePublicEndpoint)
        .setProject(Environment.appwriteProjectId);
    account = Account(client);
    databases = Databases(client);
    storage = Storage(client);
  }

  late final Client client;
  late final Account account;
  late final Databases databases;
  late final Storage storage;

  /// Public view URL for a file in the avatars bucket (read = Any), so it can
  /// be shown with a plain image widget.
  String avatarUrl(String fileId) =>
      '${Environment.appwritePublicEndpoint}/storage/buckets/'
      '${Environment.avatarsBucketId}/files/$fileId/view'
      '?project=${Environment.appwriteProjectId}';
}
