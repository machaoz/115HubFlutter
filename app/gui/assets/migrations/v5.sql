-- 115HubFlutter · 迁移 v5 —— M6 favorites_fts 触发器同步（初版）
-- 【红线】双端单一来源，只追加不改历史。
-- 注意：本版删除触发器使用 contentful FTS5 的 'delete' 写法，后被 v6 修正。
-- 历史包袱必须保留：Electron 版与 Flutter 版都必须先跑完 v5 再跑 v6。
-- 对应 Electron: src/main/store/schema.ts MIGRATIONS[4]

CREATE TRIGGER IF NOT EXISTS favorites_fts_ai AFTER INSERT ON favorites BEGIN
  INSERT INTO favorites_fts(rowid, title, clean_title) VALUES (new.rowid, new.title, new.clean_title);
END;

CREATE TRIGGER IF NOT EXISTS favorites_fts_ad AFTER DELETE ON favorites BEGIN
  INSERT INTO favorites_fts(favorites_fts, rowid, title, clean_title)
    VALUES ('delete', old.rowid, old.title, old.clean_title);
END;

CREATE TRIGGER IF NOT EXISTS favorites_fts_au AFTER UPDATE OF title, clean_title ON favorites BEGIN
  INSERT INTO favorites_fts(favorites_fts, rowid, title, clean_title)
    VALUES ('delete', old.rowid, old.title, old.clean_title);
  INSERT INTO favorites_fts(rowid, title, clean_title) VALUES (new.rowid, new.title, new.clean_title);
END;
