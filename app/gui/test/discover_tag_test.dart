// 发现页「剧集 → 全部」空白回归护栏
//
// 背景：豆瓣 /j/search_subjects 的 tv 侧只有「热门」这一个全量 tag 有数据，
// 而旧实现把 sort（最新 / 豆瓣高分）当 tag 用，导致「剧集 - 全部」永远空白。
// 这里把实测矩阵固化成断言，避免改回去。
import 'package:flutter_test/flutter_test.dart';

import 'package:magnetic115hub/features/discover/discover_page.dart' as d;
import 'package:magnetic115hub/ui/widgets.dart' as ui;

void main() {
  group('doubanTagCandidates', () {
    test('movie「全部」沿用 sort 作 tag（三种维度均实测有数据）', () {
      expect(d.doubanTagCandidates('movie', '热门', '全部'), <String>['热门']);
      expect(d.doubanTagCandidates('movie', '最新', '全部'), <String>['最新']);
      expect(d.doubanTagCandidates('movie', '豆瓣高分', '全部'), <String>['豆瓣高分']);
    });

    test('tv「全部」必须固定走「热门」，不得沿用 sort', () {
      // 这三个 case 就是缺陷 5 的全部组合
      expect(d.doubanTagCandidates('tv', '热门', '全部'), <String>['热门']);
      expect(d.doubanTagCandidates('tv', '最新', '全部'), <String>['热门']);
      expect(d.doubanTagCandidates('tv', '豆瓣高分', '全部'), <String>['热门']);
    });

    test('tv 细分：分类优先，全量 tag 兜底', () {
      expect(d.doubanTagCandidates('tv', '最新', '国产剧'), <String>['国产剧', '热门']);
      expect(d.doubanTagCandidates('tv', '豆瓣高分', '美剧'), <String>['美剧', '热门']);
    });

    test('movie 细分：分类优先，sort 兜底', () {
      expect(d.doubanTagCandidates('movie', '热门', '华语'), <String>['华语', '热门']);
    });

    test('分类恰好等于全量 tag 时不产生重复请求', () {
      expect(d.doubanTagCandidates('tv', '最新', '热门'), <String>['热门']);
    });

    test('tv 全量 tag 常量不被误改', () {
      expect(d.kDoubanTvAllTag, '热门');
    });
  });

  group('发现页视图源', () {
    test('默认视图是海报墙', () {
      expect(d.kDiscoverViews.first.id, 'poster');
    });

    test('已启用三个源：海报墙 + 人物分类 + 热搜榜；其余为预留项（灰显）', () {
      final enabled = d.kDiscoverViews.where((v) => v.enabled).toList();
      expect(enabled.map((v) => v.id).toList(), <String>[
        'poster',
        'person',
        'hot',
      ]);
      expect(
        d.kDiscoverViews.length,
        greaterThan(enabled.length),
        reason: '应保留至少一个待接入的预留项',
      );
      expect(
        d.kDiscoverViews.where((v) => !v.enabled).every((v) => v.id == 'tmdb'),
        isTrue,
        reason: '当前唯一预留项是 TMDB',
      );
    });
  });

  group('copyPreview', () {
    test('空串与空白串返回空', () {
      expect(ui.copyPreview(''), '');
      expect(ui.copyPreview('   '), '');
    });
    test('短文本原样返回', () {
      expect(
        ui.copyPreview('magnet:?xt=urn:btih:abc'),
        'magnet:?xt=urn:btih:abc',
      );
    });
    test('超长文本截断并加省略号', () {
      final long = 'x' * 100;
      final out = ui.copyPreview(long, max: 20);
      expect(out.length, 21);
      expect(out.endsWith('…'), isTrue);
    });
    test('换行与连续空白压成单空格', () {
      expect(ui.copyPreview('a\n\n  b\tc'), 'a b c');
    });
  });
}
