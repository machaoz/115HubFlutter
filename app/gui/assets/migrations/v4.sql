-- 115HubFlutter · 迁移 v4 —— M5 首页推荐板块级元信息
-- 【红线】双端单一来源，只追加不改历史。
-- 说明：hot_board_meta 记录板块状态/失败原因/热词/钩沉( outcomes )，
--       使「板块级失败降级」可以只写 meta 而保留上次成功的快照条目。
-- 对应 Electron: src/main/store/schema.ts MIGRATIONS[3]

CREATE TABLE IF NOT EXISTS hot_board_meta (
  board TEXT PRIMARY KEY,
  category TEXT NOT NULL DEFAULT 'video',
  state TEXT NOT NULL,
  message TEXT NOT NULL DEFAULT '',
  item_count INTEGER NOT NULL DEFAULT 0,
  keywords TEXT NOT NULL DEFAULT '[]',
  outcomes TEXT NOT NULL DEFAULT '[]',
  refreshed_at INTEGER NOT NULL DEFAULT 0
);
