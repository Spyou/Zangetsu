import 'package:equatable/equatable.dart';

enum RoomRole { none, host, client }

class RoomState extends Equatable {
  const RoomState({
    required this.code, required this.hostId, required this.hostName,
    required this.hostAvatar, required this.sourceId, required this.sourceLabel,
    required this.showUrl, required this.showTitle, required this.cover,
    required this.episodeId, required this.episodeNumber, required this.episodeUrl,
    required this.category, required this.malId, required this.tmdbId,
    required this.positionMs, required this.playing, required this.rate,
    required this.updatedAt, required this.status,
  });

  final String code, hostId, hostName, hostAvatar, sourceId, sourceLabel;
  final String showUrl, showTitle, cover, episodeId, episodeUrl, category, status;
  final double? episodeNumber;
  final int? malId, tmdbId;
  final int positionMs, updatedAt;
  final bool playing;
  final double rate;

  Map<String, dynamic> toMap() => {
        'code': code, 'hostId': hostId, 'hostName': hostName,
        'hostAvatar': hostAvatar, 'sourceId': sourceId, 'sourceLabel': sourceLabel,
        'showUrl': showUrl, 'showTitle': showTitle, 'cover': cover,
        'episodeId': episodeId, 'episodeNumber': episodeNumber, 'episodeUrl': episodeUrl,
        'category': category, 'malId': malId, 'tmdbId': tmdbId,
        'positionMs': positionMs, 'playing': playing, 'rate': rate,
        'updatedAt': updatedAt, 'status': status,
      };

  static RoomState fromMap(Map m) => RoomState(
        code: '${m['code'] ?? m['\$id'] ?? ''}',
        hostId: '${m['hostId'] ?? ''}', hostName: '${m['hostName'] ?? ''}',
        hostAvatar: '${m['hostAvatar'] ?? ''}', sourceId: '${m['sourceId'] ?? ''}',
        sourceLabel: '${m['sourceLabel'] ?? ''}', showUrl: '${m['showUrl'] ?? ''}',
        showTitle: '${m['showTitle'] ?? ''}', cover: '${m['cover'] ?? ''}',
        episodeId: '${m['episodeId'] ?? ''}',
        episodeNumber: (m['episodeNumber'] as num?)?.toDouble(),
        episodeUrl: '${m['episodeUrl'] ?? ''}', category: '${m['category'] ?? 'sub'}',
        malId: (m['malId'] as num?)?.toInt(), tmdbId: (m['tmdbId'] as num?)?.toInt(),
        positionMs: (m['positionMs'] as num?)?.toInt() ?? 0,
        playing: m['playing'] == true, rate: (m['rate'] as num?)?.toDouble() ?? 1.0,
        updatedAt: (m['updatedAt'] as num?)?.toInt() ?? 0,
        status: '${m['status'] ?? 'active'}',
      );

  RoomState copyWith({
    int? positionMs, bool? playing, double? rate, int? updatedAt, String? status,
    String? hostId, String? hostName, String? hostAvatar, String? episodeId,
    double? episodeNumber, String? episodeUrl,
  }) =>
      RoomState(
        code: code, hostId: hostId ?? this.hostId, hostName: hostName ?? this.hostName,
        hostAvatar: hostAvatar ?? this.hostAvatar, sourceId: sourceId,
        sourceLabel: sourceLabel, showUrl: showUrl, showTitle: showTitle, cover: cover,
        episodeId: episodeId ?? this.episodeId,
        episodeNumber: episodeNumber ?? this.episodeNumber,
        episodeUrl: episodeUrl ?? this.episodeUrl, category: category,
        malId: malId, tmdbId: tmdbId, positionMs: positionMs ?? this.positionMs,
        playing: playing ?? this.playing, rate: rate ?? this.rate,
        updatedAt: updatedAt ?? this.updatedAt, status: status ?? this.status,
      );

  @override
  List<Object?> get props => [code, hostId, hostName, hostAvatar, sourceId,
        sourceLabel, showUrl, showTitle, cover, episodeId, episodeNumber,
        episodeUrl, category, malId, tmdbId, positionMs, playing, rate, updatedAt, status];
}

class RoomParticipant extends Equatable {
  const RoomParticipant({required this.userId, required this.name,
    required this.avatar, required this.state, required this.joinedAt,
    required this.lastSeenAt});
  final String userId, name, avatar, state;
  final int joinedAt, lastSeenAt;
  Map<String, dynamic> toMap() => {'userId': userId, 'name': name,
        'avatar': avatar, 'state': state, 'joinedAt': joinedAt, 'lastSeenAt': lastSeenAt};
  static RoomParticipant fromMap(Map m) => RoomParticipant(
        userId: '${m['userId'] ?? ''}', name: '${m['name'] ?? ''}',
        avatar: '${m['avatar'] ?? ''}', state: '${m['state'] ?? 'watching'}',
        joinedAt: (m['joinedAt'] as num?)?.toInt() ?? 0,
        lastSeenAt: (m['lastSeenAt'] as num?)?.toInt() ?? 0);
  RoomParticipant copyWith({String? state, int? lastSeenAt}) => RoomParticipant(
        userId: userId, name: name, avatar: avatar, state: state ?? this.state,
        joinedAt: joinedAt, lastSeenAt: lastSeenAt ?? this.lastSeenAt);
  @override
  List<Object?> get props => [userId, name, avatar, state, joinedAt, lastSeenAt];
}

class RoomMessage extends Equatable {
  const RoomMessage({required this.userId, required this.name,
    required this.avatar, required this.text, required this.createdAt});
  final String userId, name, avatar, text;
  final int createdAt;
  Map<String, dynamic> toMap() => {'userId': userId, 'name': name,
        'avatar': avatar, 'text': text, 'createdAt': createdAt};
  static RoomMessage fromMap(Map m) => RoomMessage(
        userId: '${m['userId'] ?? ''}', name: '${m['name'] ?? ''}',
        avatar: '${m['avatar'] ?? ''}', text: '${m['text'] ?? ''}',
        createdAt: (m['createdAt'] as num?)?.toInt() ?? 0);
  @override
  List<Object?> get props => [userId, name, avatar, text, createdAt];
}
