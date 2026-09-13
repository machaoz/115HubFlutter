-- 115HubFlutter · 迁移 v1 —— 初始 schema
-- 【红线】本文件为 Electron 版与 Flutter 版「单一来源」，两端必须逐字一致；只允许追加新版本文件，禁止修改历史。
-- 对应 Electron: src/main/store/schema.ts MIGRATIONS[0]
-- WAL + foreign_keys=ON 由连接层设置。

CREATE TABLE IF NOT EXISTS source_site (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  kind TEXT NOT NULL CHECK(kind IN ('magnet','pan115')),
  enabled INTEGER NOT NULL DEFAULT 1,
  priority INTEGER NOT NULL DEFAULT 100,
  rate_limit_rps REAL NOT NULL DEFAULT 1,
  timeout_ms INTEGER NOT NULL DEFAULT 8000,
  health TEXT NOT NULL DEFAULT '{"ok":true}',
  config_json TEXT NOT NULL DEFAULT '{}'
);

CREATE TABLE IF NOT EXISTS search_cache (
  cache_key TEXT NOT NULL,
  source_id TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  cached_at INTEGER NOT NULL,
  PRIMARY KEY (cache_key, source_id)
);
CREATE INDEX IF NOT EXISTS idx_search_cache_at ON search_cache(cached_at);

CREATE TABLE IF NOT EXISTS history (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  query TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS favorites (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  clean_title TEXT NOT NULL DEFAULT '',
  item_json TEXT NOT NULL,
  note TEXT NOT NULL DEFAULT '',
  group_name TEXT NOT NULL DEFAULT '默认分组',
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

-- 收藏标题全文索引（rowid 与 favorites.rowid 对齐，自 v5 起由触发器同步，v6 修正删除方式）
CREATE VIRTUAL TABLE IF NOT EXISTS favorites_fts USING fts5(
  title,
  clean_title,
  tokenize = 'trigram'
);

CREATE TABLE IF NOT EXISTS hot_snapshot (
  board TEXT NOT NULL,
  category TEXT NOT NULL DEFAULT 'video',
  rank INTEGER NOT NULL,
  item_json TEXT NOT NULL,
  snapshot_at INTEGER NOT NULL,
  PRIMARY KEY (board, category, rank)
);

CREATE TABLE IF NOT EXISTS app_settings (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  settings_json TEXT NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS import_task (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL,
  target TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  error TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

-- 凭证保险箱（value 为 DPAPI 加密后的 BLOB，明文永不落库）
CREATE TABLE IF NOT EXISTS secret_kv (
  key TEXT PRIMARY KEY,
  value BLOB NOT NULL,
  updated_at INTEGER NOT NULL
);
