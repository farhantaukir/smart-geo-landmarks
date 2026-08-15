===============================================================================
CSE 489: Mobile Application Development
Smart Geo-Tagged Landmarks
Student ID: 22299207
Framework: Flutter (Dart) - Android target
===============================================================================

-------------------------------------------------------------------------------
1. PROJECT OVERVIEW
-------------------------------------------------------------------------------
A Flutter application that talks to the faculty-provided REST API at
https://labs.anontech.info/cse489/exm3/api.php to browse, visit, create and
remove geo-tagged landmarks across Bangladesh.

Every landmark carries a title, a latitude/longitude, an image and a
server-computed activity score. The app renders them on a map, in a sortable
and filterable list, and records visits against the user's real GPS position.

Because the backend processes visits asynchronously, a visit does not return a
distance directly: it returns a job id. The app polls that job in guaranteed
background work until the server marks it done, then shows the distance.

The whole app is implemented in a single file, lib/main.dart, organised into
numbered sections (configuration, models, database, network, sync engine,
WorkManager wiring, state, UI tabs).

-------------------------------------------------------------------------------
2. FEATURES IMPLEMENTED
-------------------------------------------------------------------------------
Bottom navigation with four tabs: Map, Landmarks, Activity, Add/View.

MAP TAB
  - OpenStreetMap tiles via flutter_map, camera centred on Bangladesh
    (23.6850, 90.3563) at zoom 6.6.
  - One marker per landmark; marker fill runs along a low-to-high colour ramp
    (burnt orange -> amber -> green) computed against the current dataset's
    own minimum and maximum score, so the colours stay meaningful whatever
    range this API key produces.
  - Tapping a marker opens a detail sheet with the image, coordinates, score,
    visit count and average distance, plus a Visit action.
  - A permanent legend explains the colour ramp.
  - "Centre on Bangladesh" button returns the camera home.

LANDMARKS TAB
  - Every landmark as a card with image, title, score, visit count and average
    distance.
  - Sorting: score descending, score ascending, or title A-Z.
  - Filtering: minimum-score slider, with a live count of what is shown.
  - Per-item menu: Visit, Show on map, Remove.
  - Pull to refresh.

ACTIVITY TAB
  - Visit history, newest first: landmark name, visit time, and distance.
  - Each entry carries its live state - Queued (not sent yet), Processing
    (server has it, job id shown), Done (distance shown), or Failed with the
    reason.
  - "Sync now" action drains the queue and polls outstanding jobs on demand.
  - The tab icon carries a badge with the number of unfinished visits.

ADD/VIEW TAB
  - Create a landmark: title, latitude, longitude, and an optional image from
    camera or gallery, with validation on all fields. The image is checked
    against the server's jpeg/png/webp and 2 MB limits before upload.
  - "Use my current position" fills the coordinates from GPS.
  - Removed landmarks are listed underneath with a Restore action, which is
    where the soft-delete/restore endpoints are exercised.

CROSS-CUTTING
  - Offline banner that also reports how many visits are waiting to send.
  - Success feedback through SnackBars, failures through dialogs that say what
    went wrong and what to do next.
  - Images cached to disk so the list and map still show pictures offline.

-------------------------------------------------------------------------------
3. API USAGE
-------------------------------------------------------------------------------
All calls go through the Api class. Server base is
https://labs.anontech.info/cse489/exm3 and the physical endpoint is always
/api.php - the action is a query parameter, not a REST path. Every request
carries action and key, injected by a single Api._uri() helper so no call site
can omit them.

  GET  /api.php?action=get_landmarks&key=22299207
       Returns a JSON array of active landmarks, each with id, title, lat, lon,
       image, is_active, visit_count, avg_distance and score. is_active is
       respected on parse, so a soft-deleted row that does come back is filed
       as removed rather than reappearing on the map.
       image is a path relative to the server base (e.g.
       "uploads/1786430640_5629.jpg") and is resolved against it before load.

  POST /api.php?action=visit_landmark&key=22299207
       application/json body: {landmark_id, user_lat, user_lon}.
       Returns {job_id, status:"pending"}. The distance is deliberately NOT
       read from this response. 400 means required fields are missing, 404
       means the landmark_id does not exist.

  GET  /api.php?action=get_job_status&key=22299207&job_id=42
       Three documented states, all three handled:
         pending  -> keep polling
         done     -> {job_id, status, distance} in METRES; written to the row
         failed   -> {job_id, status, error}; the visit is marked Failed with
                     the server's reason and polling stops
       404 means the job is unknown or belongs to a different key, which is
       also terminal. job_id is scoped to the key that created it.

  POST /api.php?action=create_landmark&key=22299207
       multipart/form-data, NOT raw JSON - the server reads the image through
       PHP $_FILES, which is empty for a JSON body.
       Required: title, lat, lon. Optional: image (jpeg/png/webp, max 2MB;
       both limits are checked in the picker before upload).
       Returns {"id": "11"} - note the id comes back as a string, so it is
       parsed leniently.

  POST /api.php?action=delete_landmark&key=22299207
  POST /api.php?action=restore_landmark&key=22299207
       application/x-www-form-urlencoded body with a single field, id.
       Return {"status":"deleted"} and {"status":"restored"}.

ERROR HANDLING
  Every endpoint returns HTTP 403 {"error":"invalid_or_expired_key"} for a
  missing, mistyped or previous-semester key. 403, 400, 404 and any
  {"error": ...} payload are treated as permanent: the queued row is marked
  Failed rather than retried forever. Timeouts, socket errors and 5xx are
  treated as transient and retried with backoff.

  One exception: a failed visit job legitimately answers 200 with both a
  status and an error field, so the job-status call opts out of the generic
  "an error key means the request failed" rule and reads status itself.

-------------------------------------------------------------------------------
4. OFFLINE STRATEGY
-------------------------------------------------------------------------------
The SQLite database is the only thing the UI reads from. The network never
feeds a widget directly, so the app behaves identically online and offline.

READS
  Landmarks are cached in the landmarks table on every successful fetch, and
  their images are downloaded to the app documents directory with the local
  path stored alongside the row. Opening the app offline shows the last known
  landmarks, scores and pictures. Only the map tiles themselves need a
  connection.

WRITES (visits)
  A visit is written to the visits table with status 'queued' BEFORE any
  network call. The row then moves through its own lifecycle:

      queued  -> pending -> done
        |          |
        +----------+-----> failed (server rejected it permanently)

  The same row is the offline queue entry, the outstanding job, and the
  history entry. Nothing is lost if the app is killed mid-flight, because the
  state lives in the database rather than in memory.

RECONNECTION
  connectivity_plus reports when the device comes back online, which enqueues
  a WorkManager task. WorkManager's own NetworkType.connected constraint means
  even a task scheduled while offline simply waits until there is a network.

SOFT DELETE
  Landmarks the server stops returning are flagged deleted = 1 locally instead
  of being dropped. They vanish from the map and the list, remain available to
  restore in the Add/View tab, and no visit history row is ever orphaned.

-------------------------------------------------------------------------------
5. ARCHITECTURE USED
-------------------------------------------------------------------------------
Repository / single-source-of-truth, with the database in the middle:

    Api  ------------\
                      >--- runSync() ---> sqflite ---> AppState ---> Widgets
    WorkManager -----/                       ^
                                             |
                       (background isolate writes here too)

  Api          Thin HTTP layer. Every failure becomes an ApiException carrying
               a retryable flag, which is what tells the sync engine whether
               to retry or give up.

  Db           sqflite wrapper. Tables: landmarks, visits, meta. Opened with
               WAL and a busy timeout because two isolates use the same file.

  runSync()    A top-level function with no Flutter dependencies: drain the
               queue, poll every outstanding job, refresh the landmark cache.
               Being top-level is what lets the identical code run inside the
               WorkManager isolate and in the foreground.

  AppState     A ChangeNotifier holding the current lists plus the sort and
               filter settings. It reads from the database and never from the
               network.

  UI           Four tabs under a NavigationBar, rebuilt by a ListenableBuilder
               watching AppState.

BACKGROUND WORK (requirement 10)
  One WorkManager mechanism serves both jobs, because they are the same
  problem: work that has to survive app restarts and flaky connectivity.

  - callbackDispatcher runs runSync() in a background isolate.
  - It returns false while anything is still queued or pending. In
    WorkManager terms false means "retry", so the plugin reschedules with
    exponential backoff (10s, 20s, 40s ...). That IS the polling loop: no
    Thread, no Timer, and it keeps going after the app is closed.
  - A one-off task is enqueued whenever a visit is recorded or connectivity
    returns, with Constraints(networkType: NetworkType.connected).
  - A 15-minute periodic task acts as a safety net if every one-off is lost.
  - When the background isolate finishes, it sends a message through
    IsolateNameServer to the UI isolate, which reloads from the database. That
    is how the screen updates while the app is open without polling the DB.

  There is one bounded foreground helper (_foregroundAssist): after a visit it
  re-runs the same runSync() a few times over roughly fifteen seconds so the
  distance appears while the user is still looking at the screen. It is a
  responsiveness nicety only - it calls the same function, it stops as soon as
  everything is settled, and WorkManager remains the mechanism that guarantees
  completion.

-------------------------------------------------------------------------------
6. CHALLENGES FACED
-------------------------------------------------------------------------------
ASYNCHRONOUS VISITS
  The obvious implementation - await the visit response and read a distance -
  does not work here, since visit_landmark only returns a job id. Splitting
  the visit into a persisted state machine (queued -> pending -> done) turned
  out to solve the offline-queue requirement at the same time, so both live in
  one table and one worker.

TWO ISOLATES, ONE DATABASE
  The WorkManager callback runs in a separate isolate that does not share
  memory with the UI, so plugins are not registered there by default and the
  UI has no idea when the background writes something. Both needed fixing:
  DartPluginRegistrant.ensureInitialized() inside the task, and an
  IsolateNameServer port so the worker can wake the UI. WAL mode plus a busy
  timeout prevents lock contention on the shared file.

MULTIPART UPLOAD
  Sending create_landmark as JSON produced a silent no-op: the row appeared
  with no image because $_FILES was empty server-side. It has to be
  multipart/form-data with a real file part.

THREE JOB STATES, NOT TWO
  The first version of the poller only distinguished done from not-done. The
  API reference documents a third state, failed, which carries an error string
  instead of a distance. Treating it as not-done meant a rejected visit would
  be polled forever and WorkManager would keep rescheduling. Failed is now
  terminal and surfaces the server's reason in the Activity tab.

TYPES THAT DO NOT MATCH THEIR SCHEMA
  create_landmark returns {"id": "11"} - an integer id delivered as a string.
  Parsing is done through helpers that coerce rather than cast, so a value
  arriving as a string instead of a number does not throw.

MAP WITHOUT A BILLING ACCOUNT
  Google Maps for Android needs an API key tied to a billing account. The spec
  allows OpenStreetMap, so flutter_map with OSM tiles was used instead: no key,
  no quota, and it builds on any machine that clones the repository.

-------------------------------------------------------------------------------
BUILD AND RUN
-------------------------------------------------------------------------------
  flutter create .            # only if you need the android/ios scaffolding
  flutter pub get
  flutter run

The API key is the kApiKey constant at the top of lib/main.dart.

Copy the AndroidManifest.xml in this repository over
android/app/src/main/AndroidManifest.xml, or merge the four uses-permission
lines into your own. Set minSdkVersion to at least 23 in
android/app/build.gradle.

Package versions in pubspec.yaml are given as ranges. If resolution fails on a
newer SDK, run: flutter pub upgrade --major-versions
