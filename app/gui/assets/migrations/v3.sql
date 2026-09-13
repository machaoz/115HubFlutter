-- 115HubFlutter · 迁移 v3 —— M4 import_task 扩展为任务看板
-- 【红线】双端单一来源；新增列一律带 DEFAULT 或可空，保证旧库平滑升级。
-- 对应 Electron: src/main/store/schema.ts MIGRATIONS[2]

ALTER TABLE import_task ADD COLUMN backend TEXT NOT NULL DEFAULT '115';
ALTER TABLE import_task ADD COLUMN title TEXT NOT NULL DEFAULT '';
ALTER TABLE import_task ADD COLUMN attempts INTEGER NOT NULL DEFAULT 0;
ALTER TABLE import_task ADD COLUMN progress INTEGER NOT NULL DEFAULT 0;
ALTER TABLE import_task ADD COLUMN message TEXT NOT NULL DEFAULT '';
ALTER TABLE import_task ADD COLUMN remote_id TEXT;
ALTER TABLE import_task ADD COLUMN done_at INTEGER;
