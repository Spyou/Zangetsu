/// Public Appwrite configuration. These are NOT secrets — the project id and
/// endpoint ship in every Appwrite client app. Auth uses email/password
/// sessions; the server API key is never embedded here.
class Environment {
  static const String appwriteProjectId = '6a1ed44f0029b50bccde';
  static const String appwriteProjectName = 'Zangetsu';
  static const String appwritePublicEndpoint = 'https://sgp.cloud.appwrite.io/v1';

  // Provisioned backend ids (see docs / setup).
  static const String databaseId = 'main';
  static const String mylistCollectionId = 'mylist';
  static const String historyCollectionId = 'history';
  static const String avatarsBucketId = 'avatars';
}
