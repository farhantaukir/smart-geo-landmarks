// =============================================================================
// CSE 489 — Mobile Application Development
// Smart Geo-Tagged Landmarks  •  Student ID: 22299207
//
// Single-file Flutter implementation (lib/main.dart).
//
// Architecture (single source of truth):
//
//   API (Api)  ─┐
//               ├─►  SyncEngine.runSync()  ─►  SQLite (Db)  ─►  AppState  ─► UI
//   WorkManager ┘         (top-level, isolate-safe)             (Listenable)
//
//   • Room-equivalent local store = sqflite. The database is the ONLY thing the
//     UI reads from, so the app renders identically online and offline.
//   • Every network mutation is written to the DB first (status = 'queued'),
//     then drained by SyncEngine. Nothing is lost if the process dies.
//   • SyncEngine is a top-level function with no Flutter/UI dependencies, so
//     the exact same code runs in the WorkManager background isolate and in
//     the foreground.
//   • The background isolate pings the UI isolate through IsolateNameServer so
//     the screen refreshes as soon as a job resolves.
// =============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show DartPluginRegistrant, IsolateNameServer;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:workmanager/workmanager.dart';

// =============================================================================
// 1. CONFIGURATION
// =============================================================================

/// Faculty-provided endpoint. Every request also carries `key`.
const String kApiEndpoint = 'https://labs.anontech.info/cse489/exm3/api.php';

/// Base used to resolve relative image paths returned by the server.
const String kAssetBase = 'https://labs.anontech.info/cse489/exm3/';

/// Personal API key (student ID), valid for this semester only.
const String kApiKey = '22299207';

/// Map centre: geographic middle of Bangladesh.
final LatLng kBangladeshCentre = LatLng(23.6850, 90.3563);
const double kBangladeshZoom = 6.6;

/// WorkManager identifiers.
const String kTaskSync = 'smartgeo.sync';
const String kUniqueOneOff = 'smartgeo.sync.oneoff';
const String kUniquePeriodic = 'smartgeo.sync.periodic';

/// Name the background isolate uses to find the UI isolate's port.
const String kSyncPortName = 'smartgeo.sync.port';

const Duration kHttpTimeout = Duration(seconds: 20);

// =============================================================================
// 2. SMALL UTILITIES
// =============================================================================

double? asDouble(Object? v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString().trim());
}

int? asInt(Object? v) {
  if (v == null) return null;
  if (v is num) return v.toInt();
  return int.tryParse(v.toString().trim()) ??
      double.tryParse(v.toString().trim())?.toInt();
}

String asText(Object? v) => v?.toString().trim() ?? '';

int nowMs() => DateTime.now().millisecondsSinceEpoch;

const List<String> _kMonths = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// "14 Aug, 9:05 PM" — kept dependency-free on purpose (no `intl`, which
/// often conflicts with the Flutter SDK's own pinned version).
String formatStamp(DateTime t) {
  var hour = t.hour % 12;
  if (hour == 0) hour = 12;
  final suffix = t.hour >= 12 ? 'PM' : 'AM';
  final minute = t.minute.toString().padLeft(2, '0');
  return '${t.day} ${_kMonths[t.month - 1]}, $hour:$minute $suffix';
}

/// Metres, formatted for a human. The server returns metres.
String formatDistance(double metres) {
  if (metres >= 1000) {
    return '${(metres / 1000).toStringAsFixed(2)} km';
  }
  return '${metres.toStringAsFixed(1)} m';
}

/// Turns whatever the server put in `image` into something fetchable.
String? resolveImageUrl(String raw) {
  final value = raw.trim();
  if (value.isEmpty || value.toLowerCase() == 'null') return null;
  if (value.startsWith('http://') || value.startsWith('https://')) return value;
  if (value.startsWith('/')) {
    return 'https://labs.anontech.info${Uri.encodeFull(value)}';
  }
  return '$kAssetBase${Uri.encodeFull(value)}';
}

// =============================================================================
// 3. MODELS
// =============================================================================

class Landmark {
  const Landmark({
    required this.id,
    required this.title,
    required this.lat,
    required this.lon,
    required this.image,
    required this.score,
    required this.visitCount,
    required this.avgDistance,
    this.localImage,
    this.deleted = false,
  });

  final int id;
  final String title;
  final double lat;
  final double lon;
  final String image;
  final double score;
  final int visitCount;
  final double avgDistance;

  /// Absolute path of the cached copy on disk, once downloaded.
  final String? localImage;
  final bool deleted;

  LatLng get position => LatLng(lat, lon);
  String? get imageUrl => resolveImageUrl(image);

  /// Tolerant parser: the API may return numbers as strings, and the score /
  /// stats fields may be missing entirely on a freshly created landmark.
  static Landmark? tryFromApi(Object? raw) {
    if (raw is! Map) return null;
    final map = raw.cast<String, Object?>();
    final id = asInt(map['id'] ?? map['landmark_id']);
    final lat = asDouble(map['lat'] ?? map['latitude']);
    final lon = asDouble(map['lon'] ?? map['lng'] ?? map['longitude']);
    if (id == null || lat == null || lon == null) return null;
    return Landmark(
      id: id,
      title: asText(map['title'] ?? map['name']).isEmpty
          ? 'Untitled landmark'
          : asText(map['title'] ?? map['name']),
      lat: lat,
      lon: lon,
      image: asText(map['image'] ?? map['image_url'] ?? map['photo']),
      score: asDouble(map['score']) ?? 0,
      visitCount: asInt(map['visit_count'] ?? map['visits']) ?? 0,
      avgDistance: asDouble(map['avg_distance'] ?? map['average_distance']) ?? 0,
      // get_landmarks only returns active rows, so is_active is normally 1.
      // Respecting it anyway means a soft-deleted row that does come back is
      // filed correctly instead of reappearing on the map.
      deleted: asInt(map['is_active']) == 0,
    );
  }

  factory Landmark.fromDb(Map<String, Object?> r) => Landmark(
        id: r['id'] as int,
        title: r['title'] as String? ?? '',
        lat: (r['lat'] as num?)?.toDouble() ?? 0,
        lon: (r['lon'] as num?)?.toDouble() ?? 0,
        image: r['image'] as String? ?? '',
        score: (r['score'] as num?)?.toDouble() ?? 0,
        visitCount: (r['visit_count'] as num?)?.toInt() ?? 0,
        avgDistance: (r['avg_distance'] as num?)?.toDouble() ?? 0,
        localImage: r['local_image'] as String?,
        deleted: (r['deleted'] as int? ?? 0) == 1,
      );

  Map<String, Object?> toDb() => {
        'id': id,
        'title': title,
        'lat': lat,
        'lon': lon,
        'image': image,
        'score': score,
        'visit_count': visitCount,
        'avg_distance': avgDistance,
        'local_image': localImage,
        'deleted': deleted ? 1 : 0,
        'updated_at': nowMs(),
      };
}

/// One row of the visit table. The same row is, in order:
/// the offline queue entry → the pending background job → the history entry.
class VisitRecord {
  const VisitRecord({
    required this.id,
    required this.landmarkId,
    required this.landmarkTitle,
    required this.userLat,
    required this.userLon,
    required this.createdAt,
    required this.status,
    this.jobId,
    this.distance,
    this.message,
    this.attempts = 0,
  });

  final int id;
  final int landmarkId;
  final String landmarkTitle;
  final double userLat;
  final double userLon;
  final DateTime createdAt;

  /// queued → not sent yet (offline or send failed)
  /// pending → server accepted it, job_id assigned, waiting for the result
  /// done → distance available
  /// failed → server rejected it permanently
  final String status;
  final int? jobId;
  final double? distance;
  final String? message;
  final int attempts;

  bool get isSettled => status == 'done' || status == 'failed';

  factory VisitRecord.fromDb(Map<String, Object?> r) => VisitRecord(
        id: r['id'] as int,
        landmarkId: (r['landmark_id'] as num?)?.toInt() ?? 0,
        landmarkTitle: r['landmark_title'] as String? ?? 'Landmark',
        userLat: (r['user_lat'] as num?)?.toDouble() ?? 0,
        userLon: (r['user_lon'] as num?)?.toDouble() ?? 0,
        createdAt:
            DateTime.fromMillisecondsSinceEpoch((r['created_at'] as num).toInt()),
        status: r['status'] as String? ?? 'queued',
        jobId: (r['job_id'] as num?)?.toInt(),
        distance: (r['distance'] as num?)?.toDouble(),
        message: r['message'] as String?,
        attempts: (r['attempts'] as num?)?.toInt() ?? 0,
      );
}

/// Result of one `get_job_status` poll.
/// Result of one `get_job_status` poll. The API documents exactly three
/// states: pending, done (carries `distance` in metres), and failed (carries
/// an `error` string, e.g. "landmark not found").
class JobStatus {
  const JobStatus({
    required this.status,
    this.distance,
    this.error,
  });

  final String status;
  final double? distance;
  final String? error;

  bool get isDone => status == 'done';
  bool get isFailed => status == 'failed';
  bool get isPending => !isDone && !isFailed;
}

// =============================================================================
// 4. LOCAL DATABASE  (offline single source of truth)
// =============================================================================

class Db {
  Db._();

  static Database? _database;
  static Future<Database>? _opening;

  static Future<Database> get instance {
    final existing = _database;
    if (existing != null && existing.isOpen) return Future.value(existing);
    return _opening ??= _open().catchError((Object e) {
      _opening = null; // let the next caller try again
      throw e;
    });
  }

  static Future<Database> _open() async {
    final dir = await getDatabasesPath();
    final path = p.join(dir, 'smart_geo.db');
    final db = await openDatabase(
      path,
      version: 1,
      onConfigure: (db) async {
        // Both the UI isolate and the WorkManager isolate open this file.
        // WAL + a busy timeout keep concurrent access from throwing.
        await db.execute('PRAGMA journal_mode = WAL');
        await db.execute('PRAGMA busy_timeout = 8000');
      },
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE landmarks(
            id           INTEGER PRIMARY KEY,
            title        TEXT NOT NULL,
            lat          REAL NOT NULL,
            lon          REAL NOT NULL,
            image        TEXT,
            score        REAL DEFAULT 0,
            visit_count  INTEGER DEFAULT 0,
            avg_distance REAL DEFAULT 0,
            local_image  TEXT,
            deleted      INTEGER DEFAULT 0,
            updated_at   INTEGER
          )''');
        await db.execute('''
          CREATE TABLE visits(
            id             INTEGER PRIMARY KEY AUTOINCREMENT,
            landmark_id    INTEGER NOT NULL,
            landmark_title TEXT,
            user_lat       REAL,
            user_lon       REAL,
            created_at     INTEGER NOT NULL,
            status         TEXT NOT NULL,
            job_id         INTEGER,
            distance       REAL,
            message        TEXT,
            attempts       INTEGER DEFAULT 0,
            updated_at     INTEGER
          )''');
        await db.execute(
            'CREATE INDEX idx_visits_status ON visits(status, created_at)');
        await db.execute('CREATE TABLE meta(k TEXT PRIMARY KEY, v TEXT)');
      },
    );
    _database = db;
    return db;
  }

  // ---- landmarks ------------------------------------------------------------

  static Future<List<Landmark>> readLandmarks({bool deleted = false}) async {
    final db = await instance;
    final rows = await db.query('landmarks',
        where: 'deleted = ?', whereArgs: [deleted ? 1 : 0], orderBy: 'title ASC');
    return rows.map(Landmark.fromDb).toList();
  }

  static Future<void> markDeleted(int id, bool deleted) async {
    final db = await instance;
    await db.update(
      'landmarks',
      {'deleted': deleted ? 1 : 0, 'updated_at': nowMs()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Replaces the cached list with what the server just returned.
  ///
  /// Soft delete handling: anything the server stops returning is flagged
  /// `deleted = 1` locally instead of being dropped, so the Add/View tab can
  /// still offer to restore it and no foreign key ever dangles.
  static Future<void> replaceLandmarks(List<Landmark> fresh) async {
    final db = await instance;
    await db.transaction((txn) async {
      await txn.update('landmarks', {'deleted': 1});
      for (final l in fresh) {
        final prior = await txn.query('landmarks',
            columns: ['image', 'local_image'],
            where: 'id = ?',
            whereArgs: [l.id],
            limit: 1);
        String? cached;
        if (prior.isNotEmpty && prior.first['image'] == l.image) {
          cached = prior.first['local_image'] as String?;
        }
        await txn.insert(
          'landmarks',
          {...l.toDb(), 'local_image': cached, 'deleted': l.deleted ? 1 : 0},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  static Future<void> setLocalImage(int id, String path) async {
    final db = await instance;
    await db.update('landmarks', {'local_image': path},
        where: 'id = ?', whereArgs: [id]);
  }

  // ---- visits ---------------------------------------------------------------

  static Future<int> enqueueVisit({
    required int landmarkId,
    required String landmarkTitle,
    required double lat,
    required double lon,
  }) async {
    final db = await instance;
    return db.insert('visits', {
      'landmark_id': landmarkId,
      'landmark_title': landmarkTitle,
      'user_lat': lat,
      'user_lon': lon,
      'created_at': nowMs(),
      'status': 'queued',
      'message': 'Waiting to be sent',
      'attempts': 0,
      'updated_at': nowMs(),
    });
  }

  static Future<List<VisitRecord>> readVisits({int limit = 200}) async {
    final db = await instance;
    final rows = await db.query('visits',
        orderBy: 'created_at DESC, id DESC', limit: limit);
    return rows.map(VisitRecord.fromDb).toList();
  }

  static Future<List<Map<String, Object?>>> readByStatus(String status) async {
    final db = await instance;
    return db.query('visits',
        where: 'status = ?', whereArgs: [status], orderBy: 'created_at ASC');
  }

  static Future<void> updateVisit(int id, Map<String, Object?> values) async {
    final db = await instance;
    await db.update('visits', {...values, 'updated_at': nowMs()},
        where: 'id = ?', whereArgs: [id]);
  }

  static Future<int> unsettledCount() async {
    final db = await instance;
    return Sqflite.firstIntValue(await db.rawQuery(
          "SELECT COUNT(*) FROM visits WHERE status IN ('queued','pending')",
        )) ??
        0;
  }

  static Future<void> deleteVisit(int id) async {
    final db = await instance;
    await db.delete('visits', where: 'id = ?', whereArgs: [id]);
  }

  // ---- meta -----------------------------------------------------------------

  static Future<void> putMeta(String key, String value) async {
    final db = await instance;
    await db.insert('meta', {'k': key, 'v': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<String?> getMeta(String key) async {
    final db = await instance;
    final rows =
        await db.query('meta', where: 'k = ?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? null : rows.first['v'] as String?;
  }
}

// =============================================================================
// 5. NETWORK LAYER
// =============================================================================

/// `retryable` decides whether SyncEngine keeps the row in the queue (transient
/// network problem) or marks it failed (server said no, retrying won't help).
class ApiException implements Exception {
  ApiException(this.message, {this.statusCode, this.retryable = true});
  final String message;
  final int? statusCode;
  final bool retryable;

  @override
  String toString() => message;
}

class Api {
  static Uri _uri(String action, [Map<String, String>? extra]) =>
      Uri.parse(kApiEndpoint).replace(queryParameters: <String, String>{
        'action': action,
        'key': kApiKey,
        ...?extra,
      });

  /// Decodes a response, converting anything unexpected into an ApiException.
  ///
  /// [allowNonJson] is for the write endpoints (create/delete/restore), which
  /// only need to report success or failure. A 2xx reply that isn't JSON —
  /// "ok", an empty body, a stray PHP notice — is treated as success there,
  /// but is still an error for the endpoints whose payload we actually read.
  static Object? _decode(
    http.Response r, {
    bool allowNonJson = false,
    bool errorKeyIsFatal = true,
  }) {
    if (r.statusCode == 403) {
      throw ApiException(
        'The server rejected this API key (403). It may have expired.',
        statusCode: 403,
        retryable: false,
      );
    }
    if (r.statusCode == 404) {
      throw ApiException(
          'The server does not have that landmark or job (404).',
          statusCode: 404,
          retryable: false);
    }
    if (r.statusCode == 400) {
      throw ApiException('The request was missing required fields (400).',
          statusCode: 400, retryable: false);
    }
    if (r.statusCode >= 500) {
      throw ApiException('The server is having trouble (${r.statusCode}).',
          statusCode: r.statusCode);
    }
    final body = r.body.trim();
    if (body.isEmpty) {
      if (allowNonJson && r.statusCode < 400) return null;
      throw ApiException('The server returned an empty response.',
          statusCode: r.statusCode);
    }
    Object? parsed;
    try {
      parsed = jsonDecode(body);
    } on FormatException {
      if (allowNonJson && r.statusCode < 400) return null;
      throw ApiException(
        'The server returned something that is not JSON.',
        statusCode: r.statusCode,
        retryable: r.statusCode < 400,
      );
    }
    // A failed visit job answers 200 with {job_id, status: "failed", error},
    // where `error` is part of the payload rather than a transport failure.
    // Callers that read `status` themselves opt out of this check.
    if (parsed is Map && parsed['error'] != null && errorKeyIsFatal) {
      throw ApiException(
        _humanError(asText(parsed['error'])),
        statusCode: r.statusCode,
        retryable: false,
      );
    }
    if (r.statusCode >= 400) {
      throw ApiException('Request rejected (${r.statusCode}).',
          statusCode: r.statusCode, retryable: false);
    }
    return parsed;
  }

  static String _humanError(String code) {
    switch (code) {
      case 'invalid_or_expired_key':
        return 'This API key is invalid or has expired.';
      case 'job_not_found':
        return 'The server no longer has this job.';
      default:
        return code.isEmpty ? 'The server reported an error.' : code;
    }
  }

  /// Wraps socket/timeout failures so callers only ever see ApiException.
  static Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on ApiException {
      rethrow;
    } on SocketException {
      throw ApiException('No connection to the server.');
    } on HttpException {
      throw ApiException('The connection dropped mid-request.');
    } on TimeoutException {
      throw ApiException('The server took too long to answer.');
    }
  }

  // ---- 1. get_landmarks -----------------------------------------------------

  static Future<List<Landmark>> getLandmarks() => _guard(() async {
        final r =
            await http.get(_uri('get_landmarks')).timeout(kHttpTimeout);
        final decoded = _decode(r);

        // Accept a bare array, or an object wrapping the array under any of the
        // usual keys.
        List<Object?> raw;
        if (decoded is List) {
          raw = decoded;
        } else if (decoded is Map) {
          final candidate = decoded['landmarks'] ??
              decoded['data'] ??
              decoded['result'] ??
              decoded['records'];
          raw = candidate is List ? candidate : const [];
        } else {
          raw = const [];
        }

        final parsed = <Landmark>[];
        for (final item in raw) {
          final l = Landmark.tryFromApi(item);
          if (l != null) parsed.add(l);
        }
        return parsed;
      });

  // ---- 2. visit_landmark (async, returns a job id) --------------------------

  static Future<int> visitLandmark({
    required int landmarkId,
    required double userLat,
    required double userLon,
  }) =>
      _guard(() async {
        final r = await http
            .post(
              _uri('visit_landmark'),
              headers: const {'Content-Type': 'application/json'},
              body: jsonEncode({
                'landmark_id': landmarkId,
                'user_lat': userLat,
                'user_lon': userLon,
              }),
            )
            .timeout(kHttpTimeout);
        final decoded = _decode(r);
        if (decoded is! Map) {
          throw ApiException('The visit response had an unexpected shape.',
              retryable: false);
        }
        final jobId = asInt(decoded['job_id'] ?? decoded['jobId']);
        if (jobId == null) {
          throw ApiException('The server did not return a job id.',
              retryable: false);
        }
        return jobId;
      });

  // ---- 3. get_job_status ----------------------------------------------------

  static Future<JobStatus> getJobStatus(int jobId) => _guard(() async {
        final r = await http
            .get(_uri('get_job_status', {'job_id': '$jobId'}))
            .timeout(kHttpTimeout);
        final decoded = _decode(r, errorKeyIsFatal: false);
        if (decoded is! Map) {
          throw ApiException('The job response had an unexpected shape.');
        }
        return JobStatus(
          status: asText(decoded['status']).toLowerCase(),
          distance: asDouble(decoded['distance']),
          error: decoded['error'] == null ? null : asText(decoded['error']),
        );
      });

  // ---- 4. create_landmark ---------------------------------------------------

  /// Sent as multipart/form-data, never raw JSON — the server reads the image
  /// through PHP's `$_FILES`, which is empty for a JSON body.
  ///
  /// Per the API reference: `title`, `lat` and `lon` are required, `image` is
  /// optional (jpeg/png/webp, 2 MB maximum). Returns the new id.
  static Future<int?> createLandmark({
    required String title,
    required double lat,
    required double lon,
    File? image,
  }) =>
      _guard(() async {
        final request = http.MultipartRequest('POST', _uri('create_landmark'))
          ..fields['title'] = title
          ..fields['lat'] = lat.toString()
          ..fields['lon'] = lon.toString();

        if (image != null) {
          request.files
              .add(await http.MultipartFile.fromPath('image', image.path));
        }

        final streamed = await request.send().timeout(kHttpTimeout);
        final r = await http.Response.fromStream(streamed);
        final decoded = _decode(r, allowNonJson: true);
        // The server answers {"id": "11"} — note the id arrives as a string.
        return decoded is Map ? asInt(decoded['id']) : null;
      });

  // ---- 5 & 6. delete_landmark / restore_landmark ---------------------------

  /// Both take `id` as an application/x-www-form-urlencoded body field.
  /// http encodes a Map body as form-urlencoded automatically.
  static Future<void> _idAction(String action, int id) => _guard(() async {
        final r = await http
            .post(_uri(action), body: {'id': '$id'}).timeout(kHttpTimeout);
        _decode(r, allowNonJson: true);
      });

  static Future<void> deleteLandmark(int id) => _idAction('delete_landmark', id);

  static Future<void> restoreLandmark(int id) =>
      _idAction('restore_landmark', id);
}

// =============================================================================
// 6. IMAGE CACHE  (so the list and map still show pictures offline)
// =============================================================================

class ImageStore {
  static Future<Directory> _dir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, 'landmark_images'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static String _fileName(String url) {
    final ext = p.extension(Uri.parse(url).path);
    final safeExt = ext.isEmpty || ext.length > 5 ? '.img' : ext;
    return '${url.hashCode.toUnsigned(32)}$safeExt';
  }

  /// Downloads once and returns the local path, or null if it can't.
  static Future<String?> download(String url) async {
    try {
      final dir = await _dir();
      final file = File(p.join(dir.path, _fileName(url)));
      if (await file.exists() && await file.length() > 0) return file.path;
      final r = await http.get(Uri.parse(url)).timeout(kHttpTimeout);
      if (r.statusCode != 200 || r.bodyBytes.isEmpty) return null;
      await file.writeAsBytes(r.bodyBytes, flush: true);
      return file.path;
    } catch (_) {
      return null;
    }
  }
}

// =============================================================================
// 7. SYNC ENGINE  (runs in the WorkManager isolate AND in the foreground)
// =============================================================================

class SyncOutcome {
  const SyncOutcome({
    required this.allSettled,
    this.changed = false,
    this.completedJobs = 0,
    this.error,
  });

  /// True when nothing is left queued or pending. WorkManager uses this to
  /// decide whether it should schedule another attempt.
  final bool allSettled;
  final bool changed;
  final int completedJobs;
  final String? error;
}

bool _syncInFlight = false;

/// Drains the offline visit queue, polls every outstanding job, then refreshes
/// the landmark cache. Pure logic — no BuildContext, no widgets — so it is safe
/// to call from a background isolate.
Future<SyncOutcome> runSync({bool refreshLandmarks = true}) async {
  if (_syncInFlight) {
    return SyncOutcome(allSettled: await Db.unsettledCount() == 0);
  }
  _syncInFlight = true;
  var changed = false;
  var completed = 0;
  String? firstError;

  try {
    // -- Step 1: send anything that was queued while offline ------------------
    for (final row in await Db.readByStatus('queued')) {
      final id = row['id'] as int;
      final attempts = (row['attempts'] as num?)?.toInt() ?? 0;
      try {
        final jobId = await Api.visitLandmark(
          landmarkId: (row['landmark_id'] as num).toInt(),
          userLat: (row['user_lat'] as num).toDouble(),
          userLon: (row['user_lon'] as num).toDouble(),
        );
        await Db.updateVisit(id, {
          'status': 'pending',
          'job_id': jobId,
          'message': 'Server is working on it',
          'attempts': 0,
        });
        changed = true;
      } on ApiException catch (e) {
        firstError ??= e.message;
        if (!e.retryable) {
          await Db.updateVisit(id, {'status': 'failed', 'message': e.message});
          changed = true;
        } else {
          await Db.updateVisit(id, {
            'attempts': attempts + 1,
            'message': 'Will retry — ${e.message}',
          });
        }
      }
    }

    // -- Step 2: poll every job the server accepted ---------------------------
    for (final row in await Db.readByStatus('pending')) {
      final id = row['id'] as int;
      final jobId = (row['job_id'] as num?)?.toInt();
      final attempts = (row['attempts'] as num?)?.toInt() ?? 0;
      if (jobId == null) {
        await Db.updateVisit(id, {'status': 'queued', 'message': 'Resending'});
        continue;
      }
      try {
        final job = await Api.getJobStatus(jobId);
        if (job.isDone) {
          await Db.updateVisit(id, {
            'status': 'done',
            'distance': job.distance,
            'message': null,
          });
          changed = true;
          completed++;
        } else if (job.isFailed) {
          // Terminal. Without this the job would be polled forever, because
          // "not done" would otherwise keep the row pending.
          await Db.updateVisit(id, {
            'status': 'failed',
            'message': job.error == null || job.error!.isEmpty
                ? 'The server could not process this visit.'
                : 'The server rejected it: ${job.error}',
          });
          changed = true;
        } else {
          await Db.updateVisit(id, {
            'attempts': attempts + 1,
            'message': 'Server is working on it',
          });
        }
      } on ApiException catch (e) {
        firstError ??= e.message;
        if (!e.retryable) {
          await Db.updateVisit(id, {'status': 'failed', 'message': e.message});
          changed = true;
        } else {
          await Db.updateVisit(id, {'attempts': attempts + 1});
        }
      }
    }

    // -- Step 3: refresh the landmark cache -----------------------------------
    // A completed visit changes score / visit_count / avg_distance, so always
    // refresh after one lands.
    if (refreshLandmarks || completed > 0) {
      try {
        final fresh = await Api.getLandmarks();
        await Db.replaceLandmarks(fresh);
        await Db.putMeta('last_sync', '${nowMs()}');
        changed = true;
        await _cacheMissingImages();
      } on ApiException catch (e) {
        firstError ??= e.message;
      }
    }
  } catch (e) {
    firstError ??= e.toString();
  } finally {
    _syncInFlight = false;
  }

  final remaining = await Db.unsettledCount();
  return SyncOutcome(
    allSettled: remaining == 0,
    changed: changed,
    completedJobs: completed,
    error: firstError,
  );
}

/// Pulls down images that aren't on disk yet, a few at a time so a slow
/// connection never stalls the sync.
Future<void> _cacheMissingImages({int budget = 12}) async {
  final db = await Db.instance;
  final rows = await db.query(
    'landmarks',
    columns: ['id', 'image'],
    where: 'deleted = 0 AND local_image IS NULL AND image IS NOT NULL',
    limit: budget,
  );
  for (final row in rows) {
    final url = resolveImageUrl(asText(row['image']));
    if (url == null) continue;
    final path = await ImageStore.download(url);
    if (path != null) await Db.setLocalImage(row['id'] as int, path);
  }
}

// =============================================================================
// 8. WORKMANAGER WIRING
// =============================================================================

/// Entry point of the background isolate.
///
/// Returning `false` tells WorkManager the task is unfinished, so it reschedules
/// with exponential backoff. That is the polling loop: no Thread, no Timer, and
/// it survives the app being killed.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    // Background isolates don't get plugins registered automatically.
    DartPluginRegistrant.ensureInitialized();
    try {
      final outcome = await runSync();
      _pingUiIsolate();
      return outcome.allSettled;
    } catch (e) {
      debugPrint('Background sync failed: $e');
      return false;
    }
  });
}

/// Lets the UI isolate know the database changed underneath it.
void _pingUiIsolate() {
  IsolateNameServer.lookupPortByName(kSyncPortName)?.send('synced');
}

Future<void> scheduleSyncNow({Duration delay = Duration.zero}) async {
  try {
    await Workmanager().registerOneOffTask(
      kUniqueOneOff,
      kTaskSync,
      initialDelay: delay,
      existingWorkPolicy: ExistingWorkPolicy.replace,
      constraints: Constraints(networkType: NetworkType.connected),
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: const Duration(seconds: 10),
      tag: 'smartgeo',
    );
  } catch (e) {
    debugPrint('Could not schedule sync: $e');
  }
}

Future<void> schedulePeriodicSync() async {
  try {
    await Workmanager().registerPeriodicTask(
      kUniquePeriodic,
      kTaskSync,
      frequency: const Duration(minutes: 15), // Android's floor
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      constraints: Constraints(networkType: NetworkType.connected),
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: const Duration(seconds: 30),
      tag: 'smartgeo',
    );
  } catch (e) {
    debugPrint('Could not schedule periodic sync: $e');
  }
}

// =============================================================================
// 9. APP STATE
// =============================================================================

enum SortMode { scoreHigh, scoreLow, title }

extension SortModeLabel on SortMode {
  String get label => switch (this) {
        SortMode.scoreHigh => 'Score, high first',
        SortMode.scoreLow => 'Score, low first',
        SortMode.title => 'Title, A–Z',
      };

  String get shortLabel => switch (this) {
        SortMode.scoreHigh => 'Score ↓',
        SortMode.scoreLow => 'Score ↑',
        SortMode.title => 'A–Z',
      };
}

/// Everything the UI watches. Reads only from the database; writes go through
/// the API + database and then trigger a reload.
class AppState extends ChangeNotifier {
  List<Landmark> landmarks = const [];
  List<Landmark> removedLandmarks = const [];
  List<VisitRecord> visits = const [];

  bool booting = true;
  bool syncing = false;
  bool online = true;
  String? lastError;
  DateTime? lastSync;

  double minScore = 0;
  SortMode sortMode = SortMode.scoreHigh;

  ReceivePort? _port;
  StreamSubscription<Object?>? _connectivity;
  bool _assistRunning = false;

  // ---- lifecycle ------------------------------------------------------------

  Future<void> boot() async {
    // Register a port so the WorkManager isolate can wake the UI up.
    IsolateNameServer.removePortNameMapping(kSyncPortName);
    _port = ReceivePort();
    IsolateNameServer.registerPortWithName(_port!.sendPort, kSyncPortName);
    _port!.listen((_) => reloadFromCache());

    await reloadFromCache();
    booting = false;
    notifyListeners();

    _connectivity = Connectivity().onConnectivityChanged.listen((results) {
      final connected = results.any((r) => r != ConnectivityResult.none);
      final wasOffline = !online;
      online = connected;
      notifyListeners();
      if (connected && wasOffline) {
        // Back online: hand the queue to WorkManager, and also try right away
        // so the user sees it drain.
        scheduleSyncNow();
        unawaited(sync());
      }
    });

    final results = await Connectivity().checkConnectivity();
    online = results.any((r) => r != ConnectivityResult.none);

    await sync();
  }

  @override
  void dispose() {
    _connectivity?.cancel();
    IsolateNameServer.removePortNameMapping(kSyncPortName);
    _port?.close();
    super.dispose();
  }

  // ---- reads ----------------------------------------------------------------

  Future<void> reloadFromCache() async {
    landmarks = await Db.readLandmarks();
    removedLandmarks = await Db.readLandmarks(deleted: true);
    visits = await Db.readVisits();
    final stamp = await Db.getMeta('last_sync');
    if (stamp != null) {
      lastSync = DateTime.fromMillisecondsSinceEpoch(int.tryParse(stamp) ?? 0);
    }
    notifyListeners();
  }

  /// Landmarks after the minimum-score filter and the chosen sort order.
  List<Landmark> get visibleLandmarks {
    final list = landmarks.where((l) => l.score >= minScore).toList();
    switch (sortMode) {
      case SortMode.scoreHigh:
        list.sort((a, b) => b.score.compareTo(a.score));
        break;
      case SortMode.scoreLow:
        list.sort((a, b) => a.score.compareTo(b.score));
        break;
      case SortMode.title:
        list.sort(
            (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
        break;
    }
    return list;
  }

  double get maxScore =>
      landmarks.isEmpty ? 0 : landmarks.map((l) => l.score).reduce(_max);
  double get lowestScore =>
      landmarks.isEmpty ? 0 : landmarks.map((l) => l.score).reduce(_min);
  static double _max(double a, double b) => a > b ? a : b;
  static double _min(double a, double b) => a < b ? a : b;

  int get pendingVisits =>
      visits.where((v) => v.status == 'queued' || v.status == 'pending').length;

  void setMinScore(double value) {
    minScore = value;
    notifyListeners();
  }

  void setSortMode(SortMode mode) {
    sortMode = mode;
    notifyListeners();
  }

  // ---- writes ---------------------------------------------------------------

  Future<void> sync({bool silent = false}) async {
    if (!silent) {
      syncing = true;
      notifyListeners();
    }
    final outcome = await runSync();
    lastError = outcome.error;
    syncing = false;
    await reloadFromCache();
  }

  /// Records the visit locally first, then lets WorkManager carry it to the
  /// server. Works identically online and offline.
  Future<void> recordVisit(Landmark landmark, Position position) async {
    await Db.enqueueVisit(
      landmarkId: landmark.id,
      landmarkTitle: landmark.title,
      lat: position.latitude,
      lon: position.longitude,
    );
    await reloadFromCache();
    await scheduleSyncNow();
    unawaited(_foregroundAssist());
  }

  /// WorkManager owns the guaranteed polling. This is only so the screen
  /// updates within a couple of seconds while the user is still looking at it;
  /// it is bounded, cancels itself, and the result is identical either way.
  Future<void> _foregroundAssist() async {
    if (_assistRunning || !online) return;
    _assistRunning = true;
    try {
      const steps = [
        Duration(seconds: 1),
        Duration(seconds: 3),
        Duration(seconds: 4),
        Duration(seconds: 6),
      ];
      for (final step in steps) {
        await Future<void>.delayed(step);
        final outcome = await runSync(refreshLandmarks: false);
        await reloadFromCache();
        if (outcome.allSettled) break;
      }
    } finally {
      _assistRunning = false;
    }
  }

  Future<void> addLandmark({
    required String title,
    required double lat,
    required double lon,
    File? image,
  }) async {
    await Api.createLandmark(title: title, lat: lat, lon: lon, image: image);
    await sync();
  }

  Future<void> deleteLandmark(Landmark landmark) async {
    await Api.deleteLandmark(landmark.id);
    await Db.markDeleted(landmark.id, true);
    await reloadFromCache();
    unawaited(sync(silent: true));
  }

  Future<void> restoreLandmark(Landmark landmark) async {
    await Api.restoreLandmark(landmark.id);
    await Db.markDeleted(landmark.id, false);
    await reloadFromCache();
    unawaited(sync(silent: true));
  }

  Future<void> discardVisit(VisitRecord visit) async {
    await Db.deleteVisit(visit.id);
    await reloadFromCache();
  }
}

/// One instance for the whole app; every screen listens to it.
final AppState app = AppState();

// =============================================================================
// 10. LOCATION
// =============================================================================

class LocationDenied implements Exception {
  LocationDenied(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Asks for permission if needed, then returns a fix. Falls back to the last
/// known position when the GPS can't get a fresh one quickly.
Future<Position> currentPosition() async {
  if (!await Geolocator.isLocationServiceEnabled()) {
    throw LocationDenied('Turn on location services to continue.');
  }
  var permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
  }
  if (permission == LocationPermission.denied) {
    throw LocationDenied('Location permission is needed to record a visit.');
  }
  if (permission == LocationPermission.deniedForever) {
    throw LocationDenied(
        'Location is blocked for this app. Enable it in system settings.');
  }
  try {
    return await Geolocator.getCurrentPosition(
      locationSettings: LocationSettings(accuracy: LocationAccuracy.high),
    ).timeout(const Duration(seconds: 20));
  } catch (_) {
    final last = await Geolocator.getLastKnownPosition();
    if (last != null) return last;
    throw LocationDenied('Could not get a GPS fix. Try again outdoors.');
  }
}

// =============================================================================
// 11. THEME
// =============================================================================

// Deep slate + a warm signal colour. The score ramp below is the one piece of
// colour that carries data, so everything else stays quiet.
const Color kInk = Color(0xFF11212D);
const Color kSurface = Color(0xFFF4F6F8);
const Color kAccent = Color(0xFF0F6E6E);
const Color kScoreLow = Color(0xFFC2410C);
const Color kScoreMid = Color(0xFFCA8A04);
const Color kScoreHigh = Color(0xFF15803D);

/// Maps a score onto the low→high ramp, relative to the current dataset.
Color scoreColor(double score, double lowest, double highest) {
  if (highest <= lowest) return kScoreMid;
  final t = ((score - lowest) / (highest - lowest)).clamp(0.0, 1.0);
  if (t < 0.5) {
    return Color.lerp(kScoreLow, kScoreMid, t * 2)!;
  }
  return Color.lerp(kScoreMid, kScoreHigh, (t - 0.5) * 2)!;
}

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: kAccent,
    primary: kAccent,
    surface: kSurface,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: kSurface,
    appBarTheme: const AppBarTheme(
      backgroundColor: kInk,
      foregroundColor: Colors.white,
      elevation: 0,
      centerTitle: false,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.white,
      indicatorColor: kAccent.withValues(alpha: 0.14),
    ),
  );
}

/// Bordered surface used for every list row. Defined here rather than through
/// `ThemeData.cardTheme` because that field's type changed between Flutter
/// releases, and this app should build on any recent SDK.
class AppCard extends StatelessWidget {
  const AppCard({super.key, required this.child, this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFE2E8F0)),
          ),
          child: child,
        ),
      ),
    );
  }
}

// =============================================================================
// 12. APP ENTRY
// =============================================================================

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Workmanager().initialize(callbackDispatcher);
    await schedulePeriodicSync();
  } catch (e) {
    debugPrint('WorkManager unavailable: $e');
  }
  runApp(const SmartGeoApp());
}

class SmartGeoApp extends StatelessWidget {
  const SmartGeoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Geo-Tagged Landmarks',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: const HomeShell(),
    );
  }
}

// =============================================================================
// 13. SHELL + BOTTOM NAVIGATION
// =============================================================================

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int _tab = 0;
  final MapController _mapController = MapController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(app.boot());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back to the app is a good moment to pick up anything the
    // background worker finished while we were away.
    if (state == AppLifecycleState.resumed && !app.booting) {
      unawaited(app.sync(silent: true));
    }
  }

  void _showOnMap(Landmark landmark) {
    setState(() => _tab = 0);
    // Wait for the map tab to be laid out before moving the camera.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _mapController.move(landmark.position, 14);
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        if (app.booting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return Scaffold(
          body: Column(
            children: [
              const _ConnectionBanner(),
              Expanded(
                child: IndexedStack(
                  index: _tab,
                  children: [
                    MapTab(controller: _mapController),
                    LandmarksTab(onShowOnMap: _showOnMap),
                    const ActivityTab(),
                    const ManageTab(),
                  ],
                ),
              ),
            ],
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            destinations: [
              const NavigationDestination(
                icon: Icon(Icons.map_outlined),
                selectedIcon: Icon(Icons.map),
                label: 'Map',
              ),
              const NavigationDestination(
                icon: Icon(Icons.place_outlined),
                selectedIcon: Icon(Icons.place),
                label: 'Landmarks',
              ),
              NavigationDestination(
                icon: Badge(
                  isLabelVisible: app.pendingVisits > 0,
                  label: Text('${app.pendingVisits}'),
                  child: const Icon(Icons.history_outlined),
                ),
                selectedIcon: const Icon(Icons.history),
                label: 'Activity',
              ),
              const NavigationDestination(
                icon: Icon(Icons.add_location_alt_outlined),
                selectedIcon: Icon(Icons.add_location_alt),
                label: 'Add/View',
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Only appears when it has something to say.
class _ConnectionBanner extends StatelessWidget {
  const _ConnectionBanner();

  @override
  Widget build(BuildContext context) {
    if (app.online) return const SizedBox.shrink();
    final queued = app.pendingVisits;
    return Material(
      color: const Color(0xFF7C2D12),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              const Icon(Icons.cloud_off, color: Colors.white, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  queued > 0
                      ? 'Offline — showing saved data. $queued visit${queued == 1 ? '' : 's'} will send when you reconnect.'
                      : 'Offline — showing saved data.',
                  style: const TextStyle(color: Colors.white, fontSize: 12.5),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// 14. SHARED WIDGETS
// =============================================================================

/// Cached image first, network second, monogram last.
class LandmarkImage extends StatelessWidget {
  const LandmarkImage({
    super.key,
    required this.landmark,
    this.width = 64,
    this.height = 64,
    this.radius = 12,
  });

  final Landmark landmark;
  final double width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final url = landmark.imageUrl;
    final local = landmark.localImage;

    Widget fallback() => Container(
          width: width,
          height: height,
          color: const Color(0xFFE2E8F0),
          alignment: Alignment.center,
          child: Text(
            landmark.title.isEmpty ? '?' : landmark.title[0].toUpperCase(),
            style: TextStyle(
              fontSize: width * 0.4,
              fontWeight: FontWeight.w700,
              color: kInk.withValues(alpha: 0.45),
            ),
          ),
        );

    Widget network() {
      if (url == null) return fallback();
      return Image.network(
        url,
        width: width,
        height: height,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => fallback(),
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return Container(
            width: width,
            height: height,
            color: const Color(0xFFE2E8F0),
          );
        },
      );
    }

    Widget content;
    if (local != null) {
      content = Image.file(
        File(local),
        width: width,
        height: height,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => network(),
      );
    } else {
      content = network();
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: content,
    );
  }
}

class ScorePill extends StatelessWidget {
  const ScorePill({super.key, required this.score, this.dense = false});

  final double score;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final color = scoreColor(score, app.lowestScore, app.maxScore);
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: dense ? 8 : 10, vertical: dense ? 3 : 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.bolt, size: dense ? 13 : 15, color: color),
          const SizedBox(width: 3),
          Text(
            score.toStringAsFixed(score.truncateToDouble() == score ? 0 : 1),
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w700,
              fontSize: dense ? 12 : 13.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _AppBarTitle extends StatelessWidget {
  const _AppBarTitle({required this.title, required this.detail});

  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, style: const TextStyle(fontSize: 19)),
        Text(
          detail,
          style: const TextStyle(fontSize: 11.5, color: Color(0xFFB6C2CC)),
        ),
      ],
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.action,
  });

  final IconData icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: kInk.withValues(alpha: 0.25)),
            const SizedBox(height: 14),
            Text(title,
                style: const TextStyle(
                    fontSize: 17, fontWeight: FontWeight.w700, color: kInk)),
            const SizedBox(height: 6),
            Text(
              body,
              textAlign: TextAlign.center,
              style: TextStyle(color: kInk.withValues(alpha: 0.6), height: 1.4),
            ),
            if (action != null) ...[const SizedBox(height: 18), action!],
          ],
        ),
      ),
    );
  }
}

void showToast(BuildContext context, String message, {bool error = false}) {
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? const Color(0xFF7F1D1D) : kInk,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(12),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
}

Future<void> showErrorDialog(
    BuildContext context, String title, String message) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

/// Shared visit action: get GPS, queue the visit, tell the user what happens
/// next. Used by both the map sheet and the list.
Future<void> visitLandmarkFlow(BuildContext context, Landmark landmark) async {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const Center(child: CircularProgressIndicator()),
  );
  try {
    final position = await currentPosition();
    await app.recordVisit(landmark, position);
    if (!context.mounted) return;
    Navigator.pop(context);
    showToast(
      context,
      app.online
          ? 'Visit sent. The distance appears in Activity once the server finishes.'
          : 'Visit saved. It will send as soon as you are back online.',
    );
  } on LocationDenied catch (e) {
    if (!context.mounted) return;
    Navigator.pop(context);
    await showErrorDialog(context, 'Location needed', e.message);
  } catch (e) {
    if (!context.mounted) return;
    Navigator.pop(context);
    await showErrorDialog(context, 'Could not record the visit', '$e');
  }
}

/// Detail sheet shared by the map and the list.
void showLandmarkSheet(
  BuildContext context,
  Landmark landmark, {
  VoidCallback? onShowOnMap,
}) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetContext) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFFCBD5E1),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LandmarkImage(landmark: landmark, width: 82, height: 82),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          landmark.title,
                          style: const TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.w700,
                              color: kInk),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${landmark.lat.toStringAsFixed(5)}, ${landmark.lon.toStringAsFixed(5)}',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: kInk.withValues(alpha: 0.6),
                          ),
                        ),
                        const SizedBox(height: 8),
                        ScorePill(score: landmark.score),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  _StatBox(
                      label: 'Visits', value: '${landmark.visitCount}'),
                  const SizedBox(width: 10),
                  _StatBox(
                    label: 'Avg distance',
                    value: landmark.avgDistance > 0
                        ? formatDistance(landmark.avgDistance)
                        : '—',
                  ),
                ],
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: () {
                  Navigator.pop(sheetContext);
                  visitLandmarkFlow(context, landmark);
                },
                icon: const Icon(Icons.near_me),
                label: const Text('Visit from where I am'),
              ),
              if (onShowOnMap != null) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () {
                    Navigator.pop(sheetContext);
                    onShowOnMap();
                  },
                  icon: const Icon(Icons.map_outlined),
                  label: const Text('Show on the map'),
                  style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(46)),
                ),
              ],
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () async {
                  Navigator.pop(sheetContext);
                  await removeLandmarkFlow(context, landmark);
                },
                icon: const Icon(Icons.delete_outline, size: 19),
                label: const Text('Remove this landmark'),
                style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFFB91C1C)),
              ),
            ],
          ),
        ),
      );
    },
  );
}

Future<void> removeLandmarkFlow(BuildContext context, Landmark landmark) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Remove this landmark?'),
      content: Text(
        '"${landmark.title}" disappears from the map and the list. '
        'You can restore it later from the Add/View tab.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Keep'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFB91C1C),
              minimumSize: const Size(88, 40)),
          child: const Text('Remove'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;
  try {
    await app.deleteLandmark(landmark);
    if (context.mounted) showToast(context, 'Removed "${landmark.title}".');
  } on ApiException catch (e) {
    if (context.mounted) {
      await showErrorDialog(context, 'Could not remove it', e.message);
    }
  }
}

class _StatBox extends StatelessWidget {
  const _StatBox({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
        decoration: BoxDecoration(
          color: const Color(0xFFF1F5F9),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: TextStyle(
                    fontSize: 11.5,
                    letterSpacing: 0.3,
                    color: kInk.withValues(alpha: 0.55))),
            const SizedBox(height: 3),
            Text(value,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w700, color: kInk)),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// 15. TAB 1 — MAP
// =============================================================================

class MapTab extends StatelessWidget {
  const MapTab({super.key, required this.controller});

  final MapController controller;

  @override
  Widget build(BuildContext context) {
    final landmarks = app.landmarks;

    return Scaffold(
      appBar: AppBar(
        title: _AppBarTitle(
          title: 'Map',
          detail:
              '${landmarks.length} landmark${landmarks.length == 1 ? '' : 's'}',
        ),
        actions: [
          IconButton(
            tooltip: 'Centre on Bangladesh',
            onPressed: () =>
                controller.move(kBangladeshCentre, kBangladeshZoom),
            icon: const Icon(Icons.center_focus_strong_outlined),
          ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: () => app.sync(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: controller,
            options: MapOptions(
              initialCenter: kBangladeshCentre,
              initialZoom: kBangladeshZoom,
              minZoom: 3,
              maxZoom: 18,
            ),
            children: [
              TileLayer(
                urlTemplate:
                    'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'info.anontech.cse489.smartgeo',
                maxZoom: 19,
              ),
              MarkerLayer(
                markers: [
                  for (final l in landmarks)
                    Marker(
                      point: l.position,
                      width: 46,
                      height: 46,
                      child: _ScoreMarker(landmark: l),
                    ),
                ],
              ),
            ],
          ),
          const Positioned(left: 12, bottom: 12, child: _ScoreLegend()),
          if (landmarks.isEmpty)
            Positioned(
              left: 16,
              right: 16,
              top: 16,
              child: Material(
                borderRadius: BorderRadius.circular(12),
                color: Colors.white,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Text(
                    app.online
                        ? 'No landmarks yet. Add the first one from the Add/View tab.'
                        : 'Nothing cached yet. Connect once to download the landmarks.',
                    style: const TextStyle(color: kInk),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ScoreMarker extends StatelessWidget {
  const _ScoreMarker({required this.landmark});
  final Landmark landmark;

  @override
  Widget build(BuildContext context) {
    final color = scoreColor(landmark.score, app.lowestScore, app.maxScore);
    return GestureDetector(
      onTap: () => showLandmarkSheet(context, landmark),
      child: Container(
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2.5),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        alignment: Alignment.center,
        child: Text(
          landmark.score.toStringAsFixed(0),
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w800,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}

class _ScoreLegend extends StatelessWidget {
  const _ScoreLegend();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('SCORE',
              style: TextStyle(
                  fontSize: 10,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w700,
                  color: kInk.withValues(alpha: 0.55))),
          const SizedBox(height: 6),
          Row(
            children: [
              const Text('low', style: TextStyle(fontSize: 10.5, color: kInk)),
              const SizedBox(width: 6),
              Container(
                width: 74,
                height: 8,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  gradient: const LinearGradient(
                    colors: [kScoreLow, kScoreMid, kScoreHigh],
                  ),
                ),
              ),
              const SizedBox(width: 6),
              const Text('high', style: TextStyle(fontSize: 10.5, color: kInk)),
            ],
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// 16. TAB 2 — LANDMARKS LIST (sort + filter)
// =============================================================================

class LandmarksTab extends StatelessWidget {
  const LandmarksTab({super.key, required this.onShowOnMap});

  final void Function(Landmark) onShowOnMap;

  @override
  Widget build(BuildContext context) {
    final items = app.visibleLandmarks;
    final ceiling = app.maxScore <= 0 ? 100.0 : app.maxScore;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Landmarks'),
        actions: [
          if (app.syncing)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 18),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                ),
              ),
            )
          else
            IconButton(
              tooltip: 'Refresh',
              onPressed: () => app.sync(),
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      body: Column(
        children: [
          _FilterBar(ceiling: ceiling, shown: items.length),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => app.sync(),
              child: items.isEmpty
                  ? ListView(
                      children: [
                        SizedBox(
                          height: 340,
                          child: EmptyState(
                            icon: Icons.filter_alt_off_outlined,
                            title: app.landmarks.isEmpty
                                ? 'No landmarks saved yet'
                                : 'Nothing above that score',
                            body: app.landmarks.isEmpty
                                ? 'Pull down to fetch them from the server, or add your own from the Add/View tab.'
                                : 'Lower the minimum score to see more of them.',
                          ),
                        ),
                      ],
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
                      itemCount: items.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (context, i) {
                        final l = items[i];
                        return _LandmarkCard(
                          landmark: l,
                          onTap: () => showLandmarkSheet(
                            context,
                            l,
                            onShowOnMap: () => onShowOnMap(l),
                          ),
                          onVisit: () => visitLandmarkFlow(context, l),
                          onShowOnMap: () => onShowOnMap(l),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({required this.ceiling, required this.shown});

  final double ceiling;
  final int shown;

  @override
  Widget build(BuildContext context) {
    final value = app.minScore.clamp(0.0, ceiling);
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: SegmentedButton<SortMode>(
                  segments: [
                    for (final mode in SortMode.values)
                      ButtonSegment(value: mode, label: Text(mode.shortLabel)),
                  ],
                  selected: {app.sortMode},
                  showSelectedIcon: false,
                  style: ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    textStyle: const WidgetStatePropertyAll(
                        TextStyle(fontSize: 12.5)),
                  ),
                  onSelectionChanged: (selection) =>
                      app.setSortMode(selection.first),
                ),
              ),
              const SizedBox(width: 12),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '$shown shown',
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 12.5, color: kInk),
                ),
              ),
            ],
          ),
          Row(
            children: [
              Text('Min score',
                  style: TextStyle(
                      fontSize: 12.5, color: kInk.withValues(alpha: 0.7))),
              Expanded(
                child: Slider(
                  value: value.toDouble(),
                  min: 0,
                  max: ceiling,
                  divisions: ceiling >= 1 ? ceiling.round().clamp(1, 100).toInt() : 1,
                  label: value.toStringAsFixed(0),
                  onChanged: (v) => app.setMinScore(v),
                ),
              ),
              SizedBox(
                width: 34,
                child: Text(
                  value.toStringAsFixed(0),
                  textAlign: TextAlign.end,
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, color: kInk),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LandmarkCard extends StatelessWidget {
  const _LandmarkCard({
    required this.landmark,
    required this.onTap,
    required this.onVisit,
    required this.onShowOnMap,
  });

  final Landmark landmark;
  final VoidCallback onTap;
  final VoidCallback onVisit;
  final VoidCallback onShowOnMap;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: onTap,
      child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LandmarkImage(landmark: landmark, width: 66, height: 66),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      landmark.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.w700,
                          color: kInk),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        ScorePill(score: landmark.score, dense: true),
                        const SizedBox(width: 8),
                        Icon(Icons.people_outline,
                            size: 14, color: kInk.withValues(alpha: 0.5)),
                        const SizedBox(width: 3),
                        Text('${landmark.visitCount}',
                            style: TextStyle(
                                fontSize: 12.5,
                                color: kInk.withValues(alpha: 0.65))),
                        if (landmark.avgDistance > 0) ...[
                          const SizedBox(width: 10),
                          Icon(Icons.straighten,
                              size: 14, color: kInk.withValues(alpha: 0.5)),
                          const SizedBox(width: 3),
                          Text(formatDistance(landmark.avgDistance),
                              style: TextStyle(
                                  fontSize: 12.5,
                                  color: kInk.withValues(alpha: 0.65))),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                icon: Icon(Icons.more_vert, color: kInk.withValues(alpha: 0.6)),
                onSelected: (value) async {
                  switch (value) {
                    case 'visit':
                      onVisit();
                      break;
                    case 'map':
                      onShowOnMap();
                      break;
                    case 'remove':
                      await removeLandmarkFlow(context, landmark);
                      break;
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'visit', child: Text('Visit')),
                  PopupMenuItem(value: 'map', child: Text('Show on map')),
                  PopupMenuItem(value: 'remove', child: Text('Remove')),
                ],
              ),
            ],
          ),
      ),
    );
  }
}

// =============================================================================
// 17. TAB 3 — ACTIVITY (visit history + queue state)
// =============================================================================

class ActivityTab extends StatelessWidget {
  const ActivityTab({super.key});

  @override
  Widget build(BuildContext context) {
    final visits = app.visits;

    return Scaffold(
      appBar: AppBar(
        title: _AppBarTitle(
          title: 'Activity',
          detail: app.lastSync == null
              ? 'Not synced yet'
              : 'Last sync ${formatStamp(app.lastSync!)}',
        ),
        actions: [
          IconButton(
            tooltip: 'Sync now',
            onPressed: () async {
              await app.sync();
              await scheduleSyncNow();
              if (context.mounted) {
                showToast(
                  context,
                  app.lastError == null
                      ? 'Up to date.'
                      : 'Sync problem: ${app.lastError}',
                  error: app.lastError != null,
                );
              }
            },
            icon: const Icon(Icons.sync),
          ),
        ],
      ),
      body: visits.isEmpty
          ? const EmptyState(
              icon: Icons.timeline_outlined,
              title: 'No visits yet',
              body:
                  'Open a landmark from the map or the list and tap "Visit from where I am". '
                  'Your distance shows up here once the server finishes the job.',
            )
          : RefreshIndicator(
              onRefresh: () => app.sync(),
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
                itemCount: visits.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, i) => _VisitCard(visit: visits[i]),
              ),
            ),
    );
  }
}

class _VisitCard extends StatelessWidget {
  const _VisitCard({required this.visit});
  final VisitRecord visit;

  ({Color color, String label, IconData icon}) get _badge {
    switch (visit.status) {
      case 'done':
        return (color: kScoreHigh, label: 'Done', icon: Icons.check_circle);
      case 'pending':
        return (
          color: const Color(0xFF1D4ED8),
          label: 'Processing',
          icon: Icons.hourglass_top
        );
      case 'failed':
        return (
          color: const Color(0xFFB91C1C),
          label: 'Failed',
          icon: Icons.error_outline
        );
      default:
        return (
          color: const Color(0xFF92400E),
          label: 'Queued',
          icon: Icons.cloud_upload_outlined
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final badge = _badge;
    return AppCard(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    visit.landmarkTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w700,
                        color: kInk),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                  decoration: BoxDecoration(
                    color: badge.color.withValues(alpha: 0.11),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(badge.icon, size: 13, color: badge.color),
                      const SizedBox(width: 4),
                      Text(
                        badge.label,
                        style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: badge.color),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(Icons.schedule,
                    size: 14, color: kInk.withValues(alpha: 0.5)),
                const SizedBox(width: 5),
                Text(
                  formatStamp(visit.createdAt),
                  style: TextStyle(
                      fontSize: 12.5, color: kInk.withValues(alpha: 0.65)),
                ),
                const SizedBox(width: 14),
                Icon(Icons.straighten,
                    size: 14, color: kInk.withValues(alpha: 0.5)),
                const SizedBox(width: 5),
                Text(
                  visit.distance != null
                      ? formatDistance(visit.distance!)
                      : 'Distance pending',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: visit.distance != null
                        ? FontWeight.w700
                        : FontWeight.w400,
                    color: visit.distance != null
                        ? kInk
                        : kInk.withValues(alpha: 0.55),
                  ),
                ),
              ],
            ),
            if (visit.jobId != null) ...[
              const SizedBox(height: 6),
              Text(
                'Job #${visit.jobId}',
                style: TextStyle(
                    fontSize: 11.5, color: kInk.withValues(alpha: 0.45)),
              ),
            ],
            if (visit.message != null && visit.status != 'done') ...[
              const SizedBox(height: 6),
              Text(
                visit.message!,
                style: TextStyle(
                    fontSize: 12, color: kInk.withValues(alpha: 0.6)),
              ),
            ],
            if (visit.status == 'failed') ...[
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => app.discardVisit(visit),
                  child: const Text('Remove from history'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// 18. TAB 4 — ADD / VIEW (create + restore)
// =============================================================================

class ManageTab extends StatefulWidget {
  const ManageTab({super.key});

  @override
  State<ManageTab> createState() => _ManageTabState();
}

class _ManageTabState extends State<ManageTab> {
  final _formKey = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _lat = TextEditingController();
  final _lon = TextEditingController();
  File? _image;
  bool _locating = false;
  bool _saving = false;

  @override
  void dispose() {
    _title.dispose();
    _lat.dispose();
    _lon.dispose();
    super.dispose();
  }

  Future<void> _fillFromGps() async {
    setState(() => _locating = true);
    try {
      final position = await currentPosition();
      _lat.text = position.latitude.toStringAsFixed(6);
      _lon.text = position.longitude.toStringAsFixed(6);
      if (mounted) showToast(context, 'Filled in your current position.');
    } on LocationDenied catch (e) {
      if (mounted) await showErrorDialog(context, 'Location needed', e.message);
    } catch (e) {
      if (mounted) {
        await showErrorDialog(context, 'Could not get your position', '$e');
      }
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final picked = await ImagePicker().pickImage(
        source: source,
        maxWidth: 1600,
        imageQuality: 85,
      );
      if (picked == null) return;
      final file = File(picked.path);

      // The API accepts jpeg/png/webp up to 2 MB. Catching it here gives a
      // clear message instead of a rejected upload.
      const allowed = {'.jpg', '.jpeg', '.png', '.webp'};
      final extension = p.extension(file.path).toLowerCase();
      if (extension.isNotEmpty && !allowed.contains(extension)) {
        if (mounted) {
          await showErrorDialog(
            context,
            'That file type will not upload',
            'The server accepts JPEG, PNG and WebP images. This one is $extension.',
          );
        }
        return;
      }

      final bytes = await file.length();
      if (bytes > 2 * 1024 * 1024) {
        if (mounted) {
          await showErrorDialog(
            context,
            'That image is too large',
            'The server caps uploads at 2 MB and this one is '
                '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB. '
                'Pick a smaller photo, or crop it before uploading.',
          );
        }
        return;
      }

      setState(() => _image = file);
    } catch (e) {
      if (mounted) await showErrorDialog(context, 'Could not open the picker', '$e');
    }
  }

  void _chooseImageSource() {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () {
                Navigator.pop(sheetContext);
                _pickImage(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              onTap: () {
                Navigator.pop(sheetContext);
                _pickImage(ImageSource.camera);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (!app.online) {
      await showErrorDialog(
        context,
        'You are offline',
        'Creating a landmark needs a live connection. Visits, on the other '
            'hand, are queued offline and sent automatically once you '
            'reconnect.',
      );
      return;
    }

    setState(() => _saving = true);
    try {
      await app.addLandmark(
        title: _title.text.trim(),
        lat: double.parse(_lat.text.trim()),
        lon: double.parse(_lon.text.trim()),
        image: _image,
      );
      if (!mounted) return;
      _title.clear();
      _lat.clear();
      _lon.clear();
      setState(() => _image = null);
      showToast(context, 'Landmark added.');
    } on ApiException catch (e) {
      if (mounted) await showErrorDialog(context, 'Could not add it', e.message);
    } catch (e) {
      if (mounted) await showErrorDialog(context, 'Could not add it', '$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String? _validateCoordinate(String? value, {required bool isLat}) {
    if (value == null || value.trim().isEmpty) return 'Required';
    final parsed = double.tryParse(value.trim());
    if (parsed == null) return 'Numbers only';
    if (isLat && (parsed < -90 || parsed > 90)) return '-90 to 90';
    if (!isLat && (parsed < -180 || parsed > 180)) return '-180 to 180';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final removed = app.removedLandmarks;

    return Scaffold(
      appBar: AppBar(title: const Text('Add / View')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'New landmark',
                  style: TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w700, color: kInk),
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _title,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Title',
                    hintText: 'Shat Gambuj Mosque',
                  ),
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? 'Give the landmark a name'
                      : null,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _lat,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true, signed: true),
                        decoration:
                            const InputDecoration(labelText: 'Latitude'),
                        validator: (v) => _validateCoordinate(v, isLat: true),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _lon,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true, signed: true),
                        decoration:
                            const InputDecoration(labelText: 'Longitude'),
                        validator: (v) => _validateCoordinate(v, isLat: false),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: _locating ? null : _fillFromGps,
                  icon: _locating
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.my_location, size: 19),
                  label: Text(_locating
                      ? 'Getting your position…'
                      : 'Use my current position'),
                  style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(46)),
                ),
                const SizedBox(height: 16),
                _ImagePickerBox(
                  image: _image,
                  onPick: _chooseImageSource,
                  onClear: () => setState(() => _image = null),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _saving ? null : _submit,
                  icon: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.cloud_upload_outlined),
                  label: Text(_saving ? 'Uploading…' : 'Add landmark'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          const Divider(height: 1),
          const SizedBox(height: 20),
          Row(
            children: [
              const Text(
                'Removed landmarks',
                style: TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w700, color: kInk),
              ),
              const SizedBox(width: 8),
              if (removed.isNotEmpty)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text('${removed.length}',
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w700)),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Soft-deleted on the server. They stay off the map and the list until you restore them.',
            style: TextStyle(fontSize: 12.5, color: kInk.withValues(alpha: 0.6)),
          ),
          const SizedBox(height: 14),
          if (removed.isEmpty)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFFF1F5F9),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                'Nothing removed. Landmarks you delete show up here.',
                style: TextStyle(color: kInk.withValues(alpha: 0.6)),
              ),
            )
          else
            for (final l in removed)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: AppCard(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        LandmarkImage(landmark: l, width: 48, height: 48),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(l.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: kInk)),
                              const SizedBox(height: 2),
                              Text(
                                '${l.lat.toStringAsFixed(4)}, ${l.lon.toStringAsFixed(4)}',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: kInk.withValues(alpha: 0.6)),
                              ),
                            ],
                          ),
                        ),
                        TextButton.icon(
                          onPressed: () async {
                            try {
                              await app.restoreLandmark(l);
                              if (context.mounted) {
                                showToast(context, 'Restored "${l.title}".');
                              }
                            } on ApiException catch (e) {
                              if (context.mounted) {
                                await showErrorDialog(
                                    context, 'Could not restore it', e.message);
                              }
                            }
                          },
                          icon: const Icon(Icons.restore, size: 18),
                          label: const Text('Restore'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

class _ImagePickerBox extends StatelessWidget {
  const _ImagePickerBox({
    required this.image,
    required this.onPick,
    required this.onClear,
  });

  final File? image;
  final VoidCallback onPick;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    if (image == null) {
      return InkWell(
        onTap: onPick,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          height: 132,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: const Color(0xFFCBD5E1), style: BorderStyle.solid),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.add_photo_alternate_outlined,
                  size: 30, color: kInk.withValues(alpha: 0.45)),
              const SizedBox(height: 8),
              Text('Add a photo (optional)',
                  style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: kInk.withValues(alpha: 0.75))),
              const SizedBox(height: 2),
              Text('JPEG, PNG or WebP, up to 2 MB',
                  style: TextStyle(
                      fontSize: 12, color: kInk.withValues(alpha: 0.5))),
            ],
          ),
        ),
      );
    }

    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.file(
            image!,
            height: 180,
            width: double.infinity,
            fit: BoxFit.cover,
          ),
        ),
        Positioned(
          top: 8,
          right: 8,
          child: Row(
            children: [
              _RoundIcon(icon: Icons.swap_horiz, onTap: onPick),
              const SizedBox(width: 6),
              _RoundIcon(icon: Icons.close, onTap: onClear),
            ],
          ),
        ),
      ],
    );
  }
}

class _RoundIcon extends StatelessWidget {
  const _RoundIcon({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.55),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(7),
          child: Icon(icon, size: 18, color: Colors.white),
        ),
      ),
    );
  }
}
