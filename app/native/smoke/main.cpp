// 原生冒烟：逐项调用 hub_api 导出面，全部通过返回 0
//
// 【为什么这里不 include <windows.h>】
// 旧写法为用 Sleep() 引入过 windows.h，结果它经 rpcndr.h 带出
// `#define small char`，把本地变量 `std::vector<char> small(4, '\0')`
// 直接替换成 `std::vector<char> char(...)` —— MSVC 报出一串看不懂的
// 「vector<char> 后面接 char 非法」。规律记住：**Windows 头文件会污染
// 小写字面量标识符（small / min / max / near / far…）**，能不引就不引。
// 轮询间隔改用 std::this_thread::sleep_for，零宏污染。
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <direct.h>
#include <string>
#include <thread>
#include <vector>

#include "hub/hub_api.h"

#define CHECK(expr, msg)                                     \
  do {                                                      \
    if (!(expr)) {                                           \
      std::fprintf(stderr, "[SMOKE-FAIL] %s\n", msg);       \
      return 1;                                             \
    }                                                       \
  } while (0)

#define CHECK_EQ(actual, expected, msg)                                       \
  do {                                                                        \
    const int a_ = (actual);                                                  \
    const int e_ = (expected);                                                \
    if (a_ != e_) {                                                           \
      std::fprintf(stderr, "[SMOKE-FAIL] %s（实际=%d 期望=%d）\n", msg, a_,     \
                   e_);                                                       \
      return 1;                                                               \
    }                                                                         \
  } while (0)

// ---- 媒体目录扫描（media 模块）----
// 在 %TEMP% 下搭一棵形状已知的小树，逐条断言「该收的收到、该跳的跳过、该截断的截断」，
// 跑完按逆序删干净 —— 冒烟要能重复跑，不能往用户临时目录里留垃圾。
namespace {

struct SmokeNode {
  bool dir;
  const char* rel;  // 相对 root；一律用 '/' 书写，落地前换成平台分隔符
};

// 目录必须在文件之前登记：_mkdir 建不了多级，父目录要先存在
const SmokeNode kMediaTree[] = {
    {true, "a"},
    {true, "a/b"},
    {true, "a/b/c"},
    {true, "a/b/c/d"},
    {true, "a/b/c/d/e"},
    {true, "a/b/c/d/e/f"},
    {true, "a/b/c/d/e/f/g"},
    {true, ".hidden"},
    {true, "$RECYCLE.BIN"},
    {true, "System Volume Information"},
    {false, "top.mp4"},
    {false, "a/1.mp4"},
    {false, "a/b/2.mkv"},
    {false, "a/b/c/3.txt"},                 // 非视频 → 忽略
    {false, "a/b/c/d/e/f/g/deep.mp4"},      // 深度 8 → 默认深度下才收
    {false, ".hidden/4.mp4"},               // 隐藏目录 → 跳过
    {false, "$RECYCLE.BIN/x.mp4"},          // 回收站 → 跳过
    {false, "System Volume Information/y.mp4"},  // 系统目录 → 跳过
};

std::string join_rel(const std::string& root, const char* rel) {
  std::string s = root;
  s += '\\';
  for (const char* p = rel; *p != '\0'; ++p) s += (*p == '/') ? '\\' : *p;
  return s;
}

bool make_tree(const std::string& root) {
  _mkdir(root.c_str());
  bool ok = true;
  for (const SmokeNode& n : kMediaTree) {
    const std::string p = join_rel(root, n.rel);
    if (n.dir) {
      if (_mkdir(p.c_str()) != 0) ok = false;
    } else {
      std::FILE* f = std::fopen(p.c_str(), "wb");
      if (f == nullptr) {
        ok = false;
      } else {
        std::fputs("hub", f);
        std::fclose(f);
      }
    }
  }
  return ok;
}

// 逆序清理：先文件后目录、先深层后浅层
void clean_tree(const std::string& root) {
  for (int i = static_cast<int>(sizeof(kMediaTree) / sizeof(kMediaTree[0])) - 1;
       i >= 0; --i) {
    const std::string p = join_rel(root, kMediaTree[i].rel);
    if (kMediaTree[i].dir) {
      _rmdir(p.c_str());
    } else {
      std::remove(p.c_str());
    }
  }
  _rmdir(root.c_str());
}

int count_of(const std::string& s, const char* needle) {
  int n = 0;
  size_t pos = 0;
  for (;;) {
    const size_t p = s.find(needle, pos);
    if (p == std::string::npos) break;
    ++n;
    pos = p + 1;
  }
  return n;
}

/// 取某条目（用 path 片段定位）之后紧跟的 "depth" 值
int depth_of(const std::string& json, const char* needle) {
  const size_t p = json.find(needle);
  if (p == std::string::npos) return -1;
  const size_t d = json.find("\"depth\":", p);
  if (d == std::string::npos) return -1;
  return std::atoi(json.c_str() + d + 8);
}

/// 取第一个 "mtime" 值（秒）
long long mtime_of(const std::string& json) {
  const size_t p = json.find("\"mtime\":");
  if (p == std::string::npos) return -1;
  return std::atoll(json.c_str() + p + 8);
}

/// 两段式：先 out=null 问容量，再按容量取数
int media_scan_json(const std::string& root, int max_depth, int max_files,
                    std::string* json) {
  int32_t need = 0;
  const int32_t probe =
      hub_media_scan(root.c_str(), max_depth, max_files, nullptr, 0, &need);
  if (probe != HUB_ERR_BUFFER_TOO_SMALL) return probe;
  if (need <= 1) return HUB_ERR_IO;
  std::vector<char> buf(static_cast<size_t>(need), '\0');
  int32_t got = need;
  const int32_t r = hub_media_scan(root.c_str(), max_depth, max_files,
                                   buf.data(), need, &got);
  if (r != HUB_OK) return r;
  json->assign(buf.data());
  return HUB_OK;
}

/// 会话两段式取 JSON（poll / result 共用形态）
int session_fetch_json(int32_t (*fn)(int32_t, char*, int32_t, int32_t*),
                       int32_t sid, std::string* json) {
  int32_t need = 0;
  const int32_t probe = fn(sid, nullptr, 0, &need);
  if (probe != HUB_ERR_BUFFER_TOO_SMALL) return probe;
  if (need <= 1) return HUB_ERR_IO;
  std::vector<char> buf(static_cast<size_t>(need), '\0');
  int32_t got = need;
  const int32_t r = fn(sid, buf.data(), need, &got);
  if (r != HUB_OK) return r;
  json->assign(buf.data());
  return HUB_OK;
}

/// 轮询会话直到结束（最长 ~10s），返回终态 JSON
int session_wait_done(int32_t sid, std::string* last) {
  for (int i = 0; i < 1000; ++i) {
    const int rc = session_fetch_json(hub_scan_poll, sid, last);
    if (rc != HUB_OK) return rc;
    if (last->find("\"state\":\"running\"") == std::string::npos &&
        last->find("\"state\":\"paused\"") == std::string::npos) {
      return HUB_OK;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  return HUB_ERR_IO;
}

}  // namespace

int main() {
  const char* ver = hub_version();
  CHECK(ver != nullptr && ver[0] != '\0', "hub_version");

  int32_t bits = hub_self_check();
  CHECK((bits & 0x01) != 0, "self_check baselib");
  CHECK((bits & 0x02) != 0, "self_check network");
  CHECK((bits & 0x04) != 0, "self_check system");

  char os[64] = {0};
  int32_t n = hub_sys_os_version(os, sizeof(os));
  CHECK(n > 0, "os_version");

  const char* data_dir = hub_sys_app_data_dir();
  CHECK(data_dir != nullptr && data_dir[0] != '\0', "app_data_dir");

  char hex[41] = {0};
  int32_t r = hub_parse_magnet_infohash(
      "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=test", hex);
  CHECK(r == 40 && std::strlen(hex) == 40, "parse_magnet");
  CHECK(std::strcmp(hex, "0123456789abcdef0123456789abcdef01234567") == 0, "magnet hash value");

  r = hub_parse_pan115_sha1(
      "115://fedcba9876543210fedcba9876543210fedcba98|12345|name.iso", hex);
  CHECK(r == 40, "parse_pan115");

  // 解析失败路径
  CHECK(hub_parse_magnet_infohash("not-a-magnet", hex) == HUB_ERR_INVALID_ARG, "magnet reject");

  // 限流器：第一次 0，第二次 > 0
  int32_t w1 = hub_net_rate_acquire("example.com", 1000);
  int32_t w2 = hub_net_rate_acquire("example.com", 1000);
  CHECK(w1 == 0 && w2 > 0, "rate limiter");

  // vNext 占位
  CHECK(hub_sha1_file(nullptr, nullptr, nullptr) == HUB_ERR_NOT_IMPLEMENTED, "sha1 placeholder");

  // ---- 系统级密钥保护（DPAPI）：加密 → 解密 往返 + 密文非明文 + 篡改必须失败 ----
  char backend[16] = {0};
  CHECK(hub_secret_backend(backend, sizeof(backend)) > 0, "secret_backend");
  CHECK(std::strcmp(backend, "dpapi") == 0, "secret_backend value");

  const char* plain = "UID=1_A1_2; CID=abcdef; SEID=zzzz";
  const int32_t plain_len = static_cast<int32_t>(std::strlen(plain));

  // 第一次调用只问容量（out=nullptr）
  int32_t cap = 0;
  CHECK(hub_secret_protect(reinterpret_cast<const uint8_t*>(plain), plain_len, nullptr, &cap) ==
            HUB_ERR_BUFFER_TOO_SMALL,
        "secret_protect size query");
  CHECK(cap > plain_len, "ciphertext longer than plaintext");

  uint8_t cipher[512] = {0};
  int32_t cipher_len = sizeof(cipher);
  CHECK(hub_secret_protect(reinterpret_cast<const uint8_t*>(plain), plain_len, cipher,
                           &cipher_len) == HUB_OK,
        "secret_protect");
  CHECK(cipher_len > plain_len, "secret_protect length");
  CHECK(std::memcmp(cipher, plain, static_cast<size_t>(plain_len)) != 0,
        "ciphertext must not equal plaintext");

  uint8_t back[512] = {0};
  int32_t back_len = sizeof(back);
  CHECK(hub_secret_unprotect(cipher, cipher_len, back, &back_len) == HUB_OK,
        "secret_unprotect");
  CHECK(back_len == plain_len, "secret_unprotect length");
  CHECK(std::memcmp(back, plain, static_cast<size_t>(plain_len)) == 0, "roundtrip value");

  // 篡改密文（翻转最后一字节）必须解密失败，绝不返回脏数据
  cipher[cipher_len - 1] ^= 0xFF;
  int32_t tampered_len = sizeof(back);
  CHECK(hub_secret_unprotect(cipher, cipher_len, back, &tampered_len) != HUB_OK,
        "tampered blob rejected");
  cipher[cipher_len - 1] ^= 0xFF;

  // 入参边界
  CHECK(hub_secret_unprotect(nullptr, 0, back, &tampered_len) == HUB_ERR_INVALID_ARG,
        "unprotect invalid arg");

  // ---- 媒体目录递归扫描（media 模块）----
  const char* tmp_env = std::getenv("TEMP");
  const std::string tmp = (tmp_env != nullptr && tmp_env[0] != '\0')
                              ? std::string(tmp_env)
                              : std::string(".");
  const std::string media_root = tmp + "\\hub_smoke_media";
  clean_tree(media_root);  // 上一次跑失败的残留会污染计数，先清一遍
  CHECK(make_tree(media_root), "构造媒体扫描样本树");

  std::string json;
  // 两段式第一段：只问容量
  int32_t need = 0;
  CHECK(hub_media_scan(media_root.c_str(), 3, 2000, nullptr, 0, &need) ==
            HUB_ERR_BUFFER_TOO_SMALL,
        "media_scan 第一段只问容量");
  CHECK(need > 2, "media_scan 报出所需容量");

  // 第二段：按容量取数
  CHECK(media_scan_json(media_root, 3, 2000, &json) == HUB_OK, "media_scan 第二段取数");
  CHECK(!json.empty() && json.front() == '[' && json.back() == ']', "media_scan 输出 JSON 数组");
  CHECK(static_cast<int>(json.size()) + 1 == need, "media_scan 长度与所报容量一致");
  CHECK_EQ(count_of(json, "{\"path\":"), 3, "深度上限 3 → 收 3 条");
  CHECK(json.find("/top.mp4") != std::string::npos, "  收到 top.mp4");
  CHECK(json.find("/a/1.mp4") != std::string::npos, "  收到 a/1.mp4");
  CHECK(json.find("/a/b/2.mkv") != std::string::npos, "  收到 a/b/2.mkv");
  CHECK(json.find("3.txt") == std::string::npos, "  非视频 .txt 被忽略");
  CHECK(json.find(".hidden") == std::string::npos, "  以 . 开头的目录被跳过");
  CHECK(json.find("RECYCLE") == std::string::npos, "  $RECYCLE.BIN 被跳过");
  CHECK(json.find("System Volume Information") == std::string::npos,
        "  System Volume Information 被跳过");
  CHECK(json.find("deep.mp4") == std::string::npos, "  超出 max_depth 的深层文件被截断");
  // 路径统一正斜杠：整段 JSON 里不该出现任何反斜杠（转义的 \\ 也不该有）
  CHECK(json.find('\\') == std::string::npos, "  path 统一正斜杠（JSON 内无反斜杠）");
  CHECK_EQ(depth_of(json, "/top.mp4"), 1, "  depth(top.mp4)=1");
  CHECK_EQ(depth_of(json, "/a/1.mp4"), 2, "  depth(a/1.mp4)=2");
  CHECK_EQ(depth_of(json, "/a/b/2.mkv"), 3, "  depth(a/b/2.mkv)=3");
  CHECK(mtime_of(json) > 0, "  mtime 取到真实修改时间（Unix 秒）");
  CHECK(json.find("\"name\":\"2.mkv\"") != std::string::npos, "  name 字段只带文件名");

  // 放宽到默认深度：深层文件应当出现，且深度正好 8
  std::string json8;
  CHECK(media_scan_json(media_root, 8, 2000, &json8) == HUB_OK, "media_scan max_depth=8");
  CHECK_EQ(count_of(json8, "{\"path\":"), 4, "  深度 8 → 收 4 条");
  CHECK_EQ(depth_of(json8, "/a/b/c/d/e/f/g/deep.mp4"), 8, "  depth(deep.mp4)=8");

  // max_files 上限
  std::string json1;
  CHECK(media_scan_json(media_root, 8, 1, &json1) == HUB_OK, "media_scan max_files=1");
  CHECK_EQ(count_of(json1, "{\"path\":"), 1, "  max_files=1 → 只收 1 条");

  // max_depth=1 → 只扫一层
  std::string json_flat;
  CHECK(media_scan_json(media_root, 1, 2000, &json_flat) == HUB_OK, "media_scan max_depth=1");
  CHECK_EQ(count_of(json_flat, "{\"path\":"), 1, "  max_depth=1 → 只收根下 1 条");
  CHECK(json_flat.find("/top.mp4") != std::string::npos, "  根下 top.mp4 仍在");
  CHECK(json_flat.find("/a/1.mp4") == std::string::npos, "  子目录里的 1.mp4 不在");

  // 入参与错误路径
  int32_t dummy_len = 0;
  CHECK(hub_media_scan(nullptr, 8, 2000, nullptr, 0, &dummy_len) == HUB_ERR_INVALID_ARG,
        "media_scan root=null → INVALID_ARG");
  CHECK(hub_media_scan(media_root.c_str(), 8, 2000, nullptr, 0, nullptr) ==
            HUB_ERR_INVALID_ARG,
        "media_scan out_len=null → INVALID_ARG");
  const std::string missing = media_root + "\\不存在的目录";
  CHECK(hub_media_scan(missing.c_str(), 8, 2000, nullptr, 0, &dummy_len) == HUB_ERR_IO,
        "media_scan 目录不存在 → IO");
  // 缓冲区给小了：必须报 BUFFER_TOO_SMALL，且仍然回填所需容量
  std::vector<char> small(4, '\0');
  int32_t small_len = 0;
  CHECK(hub_media_scan(media_root.c_str(), 8, 2000, small.data(),
                       static_cast<int32_t>(small.size()), &small_len) ==
            HUB_ERR_BUFFER_TOO_SMALL,
        "media_scan 缓冲不足 → BUFFER_TOO_SMALL");
  CHECK(small_len > 4, "  缓冲不足时仍回填所需容量");

  // ---- 会话式扫描（进度/暂停/恢复/取消/结果）----
  int32_t sid = hub_scan_start(media_root.c_str(), 8, 2000);
  CHECK(sid > 0, "scan_start");
  // 暂停/恢复 API 可用（小树可能瞬间完成：只要不挂死即通过）
  CHECK(hub_scan_pause(sid) == HUB_OK, "scan_pause");
  CHECK(hub_scan_resume(sid) == HUB_OK, "scan_resume");
  std::string sjson;
  CHECK(session_wait_done(sid, &sjson) == HUB_OK, "scan_poll 轮询到终态");
  CHECK(sjson.find("\"state\":\"done\"") != std::string::npos, "  终态 done");
  CHECK(sjson.find("\"files\":4") != std::string::npos, "  files=4");
  std::string rjson;
  CHECK(session_fetch_json(hub_scan_result, sid, &rjson) == HUB_OK, "scan_result");
  CHECK_EQ(count_of(rjson, "{\"path\":"), 4, "  会话结果 4 条");
  CHECK_EQ(depth_of(rjson, "/a/b/c/d/e/f/g/deep.mp4"), 8, "  会话 depth 与一段式一致");
  CHECK(rjson.find("\\") == std::string::npos, "  会话 path 同样统一正斜杠");
  CHECK(hub_scan_close(sid) == HUB_OK, "scan_close");
  CHECK(hub_scan_close(sid) == HUB_OK, "scan_close 幂等");
  int32_t closed_len = 0;
  CHECK(hub_scan_poll(sid, nullptr, 0, &closed_len) == HUB_ERR_INVALID_ARG,
        "  close 后 poll 拒绝");

  // max_files 截断经会话同样生效
  int32_t sid1 = hub_scan_start(media_root.c_str(), 8, 1);
  CHECK(sid1 > 0, "scan_start max_files=1");
  std::string s1;
  CHECK(session_wait_done(sid1, &s1) == HUB_OK, "  poll");
  CHECK(s1.find("\"files\":1") != std::string::npos, "  files=1（上限截断）");
  CHECK(hub_scan_close(sid1) == HUB_OK, "  close");

  // 入参与错误路径
  CHECK(hub_scan_start(nullptr, 8, 2000) == HUB_ERR_INVALID_ARG, "scan_start null");
  CHECK(hub_scan_start("Z:\\不存在的目录\\nope", 8, 2000) == HUB_ERR_IO,
        "scan_start 目录不存在 → IO");
  CHECK(hub_scan_pause(999999) == HUB_ERR_INVALID_ARG, "未知会话 pause");
  CHECK(hub_scan_result(999999, nullptr, 0, &dummy_len) == HUB_ERR_INVALID_ARG,
        "未知会话 result");
  CHECK(hub_scan_cancel(999999) == HUB_ERR_INVALID_ARG, "未知会话 cancel");

  clean_tree(media_root);
  // 清理必须真的生效：冒烟要能反复跑，残留会让下一轮计数失真
  std::FILE* leftover = std::fopen(join_rel(media_root, "top.mp4").c_str(), "rb");
  if (leftover != nullptr) std::fclose(leftover);
  CHECK(leftover == nullptr, "样本树已清理干净");

  std::printf("[SMOKE-OK] version=%s os=%s appdata=%s secret=%s\n", ver, os, data_dir,
              backend);
  return 0;
}
