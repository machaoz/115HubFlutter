-- 115HubFlutter · 迁移 v6 —— M6 修复（FTS5 删除改普通 DELETE + 补齐遗漏行）
-- 【红线】双端单一来源，只追加不改历史。
-- 依据《概要设计》§4.2：FTS 删除一律普通 DELETE ... WHERE rowid=?。
-- 集成 contentful FTS5 的 'delete' 命令要求提供完整列值，遗漏列会导致索引残留。
-- 对应 Electron: src/main/store/schema.ts MIGRATIONS[5]

DROP TRIGGER IF EXISTS favorites_fts_ai;
DROP TRIGGER IF EXISTS favorites_fts_ad;
DROP TRIGGER IF EXISTS favorites_fts_au;

CREATE TRIGGER IF NOT EXISTS favorites_fts_ai AFTER INSERT ON favorites BEGIN
  INSERT INTO favorites_fts(rowid, title, clean_title) VALUES (new.rowid, new.title, new.clean_title);
END;

CREATE TRIGGER IF NOT EXISTS favorites_fts_ad AFTER DELETE ON favorites BEGIN
  DELETE FROM favorites_fts WHERE rowid = old.rowid;
END;

CREATE TRIGGER IF NOT EXISTS favorites_fts_au AFTER UPDATE OF title, clean_title ON favorites BEGIN
  DELETE FROM favorites_fts WHERE rowid = old.rowid;
  INSERT INTO favorites_fts(rowid, title, clean_title) VALUES (new.rowid, new.title, new.clean_title);
END;

-- 补齐 v5 阶段遗漏未进入索引的历史数据
INSERT INTO favorites_fts(rowid, title, clean_title)
  SELECT f.rowid, f.title, f.clean_title FROM favorites f
  WHERE NOT EXISTS (SELECT 1 FROM favorites_fts t WHERE t.rowid = f.rowid);
