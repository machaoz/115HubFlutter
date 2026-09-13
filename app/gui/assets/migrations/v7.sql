-- 115HubFlutter · 迁移 v7 —— M7 真源接入（公共磁力索引，演示源默认停用）
-- 【红线】双端单一来源，只追加不改历史。
-- 出厂默认仅启用 torrent-index-1（真源）；演示源保留在库中，可在「设置-数据源」手动开启。
-- 对应 Electron: src/main/store/schema.ts MIGRATIONS[6]

INSERT OR IGNORE INTO source_site (id, name, kind, enabled, priority, rate_limit_rps, timeout_ms, health, config_json) VALUES
  ('torrent-index-1', '公共磁力索引 · 实时', 'magnet', 1, 40, 2, 10000, '{"ok":true}', '{"demo":false,"baseUrl":""}');

UPDATE source_site SET enabled = 0 WHERE config_json LIKE '%"demo":true%';
