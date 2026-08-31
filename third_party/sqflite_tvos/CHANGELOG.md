## 0.0.2

* **Fix:** `getDatabasesPath()` now resolves under `Library/Caches` instead of
  Documents. On a physical Apple TV the tvOS sandbox does not permit writes to
  Documents, so the canonical
  `openDatabase(join(await getDatabasesPath(), 'x.db'))` failed with
  `SQLITE_CANTOPEN`. The simulator sandbox permits the write, which masked this.
* **Behaviour change:** apps that created a database against the simulator under
  the old Documents path will resolve to a new, empty database. tvOS storage is
  purgeable by platform contract — data that must survive belongs on a server or
  in iCloud Key-Value Storage.

## 0.0.1

Initial release — tvOS implementation of `sqflite` for
[flutter-tvos](https://github.com/fluttertv/flutter-tvos). Generated
by `flutter-tvos plugin port` (modular-SwiftPM podspec) from
`sqflite_darwin`.

* **Supported:** full SQLite — `openDatabase`, `execute`, `rawQuery`,
  `query`, `insert`, `update`, `delete`, transactions, batches
  (`sqlite3` ships with tvOS).
* **Differs from iOS:** the tvOS sandbox is constrained and
  OS-managed caches can be purged — put the database under a
  `path_provider` directory (Documents / Application Support),
  **not** in a cache / temp dir, if you need durability.
* **Not supported on tvOS:** none for core SQLite usage.

14/14 integration tests pass. See `README.md` and
`PORTING_REPORT.md` for detail.
