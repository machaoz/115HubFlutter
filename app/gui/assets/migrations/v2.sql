-- 115HubFlutter · 迁移 v2 —— M3 演示源种子（仅 INSERT，非 DDL）
-- 【红线】双端单一来源，禁止修改历史版本 SQL。
-- 对应 Electron: src/main/store/schema.ts MIGRATIONS[1]

INSERT OR IGNORE INTO source_site (id, name, kind, enabled, priority, rate_limit_rps, timeout_ms, health, config_json) VALUES
  ('demo-magnet-a', '演示 · 磁力源 A', 'magnet', 1, 10, 0, 2000, '{"ok":true}', '{"demo":true}'),
  ('demo-magnet-b', '演示 · 磁力源 B', 'magnet', 1, 20, 0, 2000, '{"ok":true}', '{"demo":true}'),
  ('demo-pan115',   '演示 · 115 分享源', 'pan115', 1, 30, 0, 2000, '{"ok":true}', '{"demo":true}');
