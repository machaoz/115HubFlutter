// 发现页「人物分类」纯逻辑护栏
//
// 背景：人物 id 一律运行时经 suggest 动态解析、代表作按 roles 过滤后按评分降序，
// 这些口径一旦回归（比如改成硬编码 id、或按接口原序展示），页面就会出现
// 「点人物没反应 / 代表作是配音纪录片」这类问题。这里把口径固化成断言。
//
// 若本机 flutter_tester 被拦（沙箱/杀软），等价断言见
// `.tools/person_catalog_check.dart`（纯 Dart，`dart run` 即可跑）。
import 'package:flutter_test/flutter_test.dart';
import 'package:magnetic115hub/features/discover/person_catalog.dart';

void main() {
  group('人物目录', () {
    test('类别常量：全部 / 华语 / 欧美 / 日韩', () {
      expect(kPersonCategories, <String>['全部', '华语', '欧美', '日韩']);
    });

    test('每个「类别 × 角色」至少 6 人', () {
      for (final role in PersonRole.values) {
        for (final cat in kPersonCategories.where((c) => c != '全部')) {
          final n = personCatalogOf(role: role, category: cat).length;
          expect(
            n,
            greaterThanOrEqualTo(6),
            reason: '$cat / ${role.label} 只有 $n 人',
          );
        }
      }
    });

    test('「全部」等于三个类别之和', () {
      for (final role in PersonRole.values) {
        final all = personCatalogOf(role: role).length;
        final sum = kPersonCategories
            .where((c) => c != '全部')
            .map((c) => personCatalogOf(role: role, category: c).length)
            .fold<int>(0, (a, b) => a + b);
        expect(all, sum);
      }
    });

    test('目录不硬编码任何豆瓣 id', () {
      for (final p in kPersonCatalog) {
        expect(p.name, isNotEmpty);
        expect(kPersonCategories, contains(p.category));
        expect(p.roles, isNotEmpty);
      }
    });

    test('导演 / 演员两个维度各自有人', () {
      expect(personCatalogOf(role: PersonRole.director), isNotEmpty);
      expect(personCatalogOf(role: PersonRole.actor), isNotEmpty);
    });

    test('导演兼演员的人物会同时出现在两个维度', () {
      expect(
        personCatalogOf(role: PersonRole.director)
            .map((p) => p.name)
            .contains('姜文'),
        isTrue,
      );
      expect(
        personCatalogOf(role: PersonRole.actor)
            .map((p) => p.name)
            .contains('姜文'),
        isTrue,
      );
    });

    test('类别筛选不串味', () {
      final cn = personCatalogOf(role: PersonRole.director, category: '华语');
      expect(cn.every((p) => p.category == '华语'), isTrue);
      expect(cn.map((p) => p.name), isNot(contains('黑泽明')));
    });
  });

  group('角色匹配', () {
    test('导演：命中「导演」，不命中「演员」', () {
      expect(PersonRole.director.matches('导演'), isTrue);
      expect(PersonRole.director.matches('演员 - 自己'), isFalse);
    });

    test('演员：命中豆瓣的复合角色写法', () {
      expect(PersonRole.actor.matches('演员'), isTrue);
      expect(PersonRole.actor.matches('演员 - 自己'), isTrue);
      expect(PersonRole.actor.matches('演员 - 自己 (饰 自己)'), isTrue);
      expect(PersonRole.actor.matches('演员 - 配音'), isTrue);
      expect(PersonRole.actor.matches('导演'), isFalse);
    });

    test('展示文案', () {
      expect(PersonRole.director.label, '导演');
      expect(PersonRole.actor.label, '演员');
      expect(PersonRole.director.worksTitle, '导演代表作');
      expect(PersonRole.actor.worksTitle, '参演代表作');
    });
  });

  group('parseCelebritySuggest', () {
    test('取首个 type=celebrity', () {
      final hit = parseCelebritySuggest(<Object?>[
        <String, Object?>{'type': 'movie', 'id': '1292052', 'title': '肖申克的救赎'},
        <String, Object?>{
          'type': 'celebrity',
          'id': '1054524',
          'title': '克里斯托弗·诺兰',
          'sub_title': 'Christopher Nolan',
          'img': 'https://img2.doubanio.com/view/celebrity/m/public/p21241.jpg',
        },
      ]);
      expect(hit, isNotNull);
      expect(hit!.id, '1054524');
      expect(hit.name, '克里斯托弗·诺兰');
      expect(hit.subTitle, 'Christopher Nolan');
      expect(hit.avatar, isNotEmpty);
    });

    test('没有 celebrity → null（电影在前也不误取）', () {
      expect(
        parseCelebritySuggest(<Object?>[
          <String, Object?>{'type': 'movie', 'id': '1', 'title': '某片'},
        ]),
        isNull,
      );
    });

    test('空列表 / 非法结构 → null', () {
      expect(parseCelebritySuggest(<Object?>[]), isNull);
      expect(parseCelebritySuggest(null), isNull);
      expect(parseCelebritySuggest('not a list'), isNull);
    });

    test('缺 id 或名字的条目被跳过', () {
      expect(
        parseCelebritySuggest(<Object?>[
          <String, Object?>{'type': 'celebrity', 'id': '', 'title': '无名'},
        ]),
        isNull,
      );
    });
  });

  group('parseCelebrityProfile', () {
    test('解析名字 / 外文名 / 头像 / 一句话简介 / 结构化信息', () {
      final p = parseCelebrityProfile(<String, Object?>{
        'title': '克里斯托弗·诺兰',
        'latin_title': 'Christopher Nolan',
        'url': 'https://www.douban.com/personage/27260291',
        'cover': <String, Object?>{
          'normal': <String, Object?>{'url': 'https://img/n.jpg'},
          'large': <String, Object?>{'url': 'https://img/l.jpg'},
        },
        'extra': <String, Object?>{
          'short_info': '制片人 导演 编剧 作者 / 盗梦空间',
          'info': <Object?>[
            <Object?>['性别', '男'],
            <Object?>['出生日期', '1970年7月30日'],
            <Object?>['IMDb编号', 'nm0634240'],
          ],
        },
      });
      expect(p.name, '克里斯托弗·诺兰');
      expect(p.latinName, 'Christopher Nolan');
      expect(p.avatar, 'https://img/n.jpg');
      expect(p.summary, '制片人 导演 编剧 作者 / 盗梦空间');
      expect(p.facts.length, 3);
      expect(p.facts.first.$1, '性别');
      expect(p.facts.first.$2, '男');
    });

    test('资料接口失败 → 退化为 suggest 的名字与头像', () {
      final p = parseCelebrityProfile(
        null,
        fallbackName: '张艺谋',
        fallbackAvatar: 'https://img/zyg.jpg',
        fallbackLatinName: 'Zhang Yimou',
      );
      expect(p.name, '张艺谋');
      expect(p.avatar, 'https://img/zyg.jpg');
      expect(p.latinName, 'Zhang Yimou');
      expect(p.facts, isEmpty);
    });

    test('cover 缺失时回退 cover_img', () {
      final p = parseCelebrityProfile(<String, Object?>{
        'title': '某人物',
        'cover_img': <String, Object?>{'url': 'https://img/cover_img.jpg'},
      });
      expect(p.avatar, 'https://img/cover_img.jpg');
    });

    test('info 行长度不足被忽略', () {
      final p = parseCelebrityProfile(<String, Object?>{
        'title': '某人物',
        'extra': <String, Object?>{
          'info': <Object?>[
            <Object?>['只有键'],
            'not a list',
          ],
        },
      });
      expect(p.facts, isEmpty);
    });
  });

  group('parseCelebrityWorks', () {
    List<Object?> rawWorks() => <Object?>[
      <String, Object?>{
        'roles': <Object?>['导演', '编剧'],
        'work': <String, Object?>{
          'id': '3541415',
          'title': '盗梦空间',
          'year': '2010',
          'url': 'https://movie.douban.com/subject/3541415/',
          'cover_url': 'https://img/inception.jpg',
          'rating': <String, Object?>{'value': 9.4, 'count': 2361308},
        },
      },
      <String, Object?>{
        'roles': <Object?>['导演', '制片人'],
        'work': <String, Object?>{
          'id': '1889243',
          'title': '星际穿越',
          'year': '2014',
          'cover_url': 'https://img/interstellar.jpg',
          'rating': <String, Object?>{'value': 9.4, 'count': 1800000},
        },
      },
      <String, Object?>{
        'roles': <Object?>['演员 - 自己'],
        'work': <String, Object?>{
          'id': '9999999',
          'title': '某纪录片',
          'year': '2016',
          'cover_url': 'https://img/doc.jpg',
          'rating': <String, Object?>{'value': 8.9, 'count': 100},
        },
      },
      <String, Object?>{
        'roles': <Object?>['导演'],
        'work': <String, Object?>{
          'id': '8888888',
          'title': '无封面作品',
          'cover_url': '',
          'rating': <String, Object?>{'value': 9.9, 'count': 9999999},
        },
      },
    ];

    test('导演维度只保留 roles 含「导演」的条目', () {
      final list = parseCelebrityWorks(<String, Object?>{
        'works': rawWorks(),
      }, role: PersonRole.director);
      expect(list.map((w) => w.title).toList(), <String>['盗梦空间', '星际穿越']);
    });

    test('演员维度只保留 roles 含「演员」的条目', () {
      final list = parseCelebrityWorks(<String, Object?>{
        'works': rawWorks(),
      }, role: PersonRole.actor);
      expect(list.map((w) => w.title).toList(), <String>['某纪录片']);
    });

    test('无封面条目被丢弃（哪怕评分最高）', () {
      final list = parseCelebrityWorks(<String, Object?>{
        'works': rawWorks(),
      }, role: PersonRole.director);
      expect(list.map((w) => w.title), isNot(contains('无封面作品')));
      expect(list.every((w) => w.cover.isNotEmpty), isTrue);
    });

    test('按评分值降序；同分按评分人数降序', () {
      final list = parseCelebrityWorks(<String, Object?>{
        'works': rawWorks(),
      }, role: PersonRole.director);
      expect(list.first.title, '盗梦空间'); // 同为 9.4，人数更多者在前
      expect(comparePersonWorks(list[0], list[1]), lessThan(0));
    });

    test('评分缺失按 0 处理，排在后面', () {
      final list = parseCelebrityWorks(<String, Object?>{
        'works': <Object?>[
          <String, Object?>{
            'roles': <Object?>['导演'],
            'work': <String, Object?>{
              'id': '1',
              'title': '无评分',
              'cover_url': 'https://img/a.jpg',
            },
          },
          <String, Object?>{
            'roles': <Object?>['导演'],
            'work': <String, Object?>{
              'id': '2',
              'title': '有评分',
              'cover_url': 'https://img/b.jpg',
              'rating': <String, Object?>{'value': 7.5, 'count': 10},
            },
          },
        ],
      }, role: PersonRole.director);
      expect(list.first.title, '有评分');
      expect(list.last.rate, '');
      expect(list.last.ratingValue, 0);
    });

    test('同一作品多角色只保留一次（按 id 去重）', () {
      final list = parseCelebrityWorks(<String, Object?>{
        'works': <Object?>[
          <String, Object?>{
            'roles': <Object?>['导演'],
            'work': <String, Object?>{
              'id': '77',
              'title': '重复条目',
              'cover_url': 'https://img/a.jpg',
              'rating': <String, Object?>{'value': 8.0, 'count': 1},
            },
          },
          <String, Object?>{
            'roles': <Object?>['导演', '编剧'],
            'work': <String, Object?>{
              'id': '77',
              'title': '重复条目',
              'cover_url': 'https://img/a.jpg',
              'rating': <String, Object?>{'value': 8.0, 'count': 1},
            },
          },
        ],
      }, role: PersonRole.director);
      expect(list.length, 1);
    });

    test('pic.large/normal 作为 cover_url 的兜底', () {
      final list = parseCelebrityWorks(<String, Object?>{
        'works': <Object?>[
          <String, Object?>{
            'roles': <Object?>['演员'],
            'work': <String, Object?>{
              'id': '5',
              'title': '只有 pic',
              'pic': <String, Object?>{
                'large': 'https://img/large.jpg',
                'normal': 'https://img/normal.jpg',
              },
            },
          },
        ],
      }, role: PersonRole.actor);
      expect(list.single.cover, 'https://img/large.jpg');
    });

    test('limit 截断生效，且不超过实际条数', () {
      final list = parseCelebrityWorks(
        <String, Object?>{'works': rawWorks()},
        role: PersonRole.director,
        limit: 1,
      );
      expect(list.length, 1);
      expect(list.single.title, '盗梦空间');
    });

    test('空 / 非法响应返回空列表，不抛异常', () {
      expect(parseCelebrityWorks(null, role: PersonRole.director), isEmpty);
      expect(
        parseCelebrityWorks(<String, Object?>{}, role: PersonRole.director),
        isEmpty,
      );
      expect(
        parseCelebrityWorks(<String, Object?>{
          'works': 'oops',
        }, role: PersonRole.director),
        isEmpty,
      );
    });
  });
}
