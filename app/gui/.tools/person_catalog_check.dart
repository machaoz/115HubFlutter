// 纯 Dart 复跑 test/person_catalog_test.dart 的核心断言（发现页人物分类护栏）。
//
// 用途：本机 flutter_tester 被安全策略拦住时，用 Dart VM 等价验证纯函数逻辑。
// 运行：cd app/gui && dart run .tools/person_catalog_check.dart
//
// 与 search_fallback_check.dart 不同：person_catalog.dart **不依赖 Flutter**，
// 因此这里直接 import lib 源码断言，不做逻辑复刻，保证与实现零漂移。
// 用相对路径而非 package: URI —— 不依赖 package_config，更容易在受限环境跑起来。
import '../lib/features/discover/person_catalog.dart';

int _pass = 0;
int _fail = 0;

void check(bool ok, String label, [String detail = '']) {
  if (ok) {
    _pass++;
    print('  [ok]   $label');
  } else {
    _fail++;
    print('  [FAIL] $label${detail.isEmpty ? '' : ' -> $detail'}');
  }
}

void checkEq(Object? actual, Object? expected, String label) {
  check('$actual' == '$expected', label, '实际 $actual，期望 $expected');
}

List<Object?> _rawWorks() => <Object?>[
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

void main() {
  print('== 人物目录 ==');
  checkEq(kPersonCategories.join(','), '全部,华语,欧美,日韩', '类别常量');
  for (final role in PersonRole.values) {
    for (final cat in kPersonCategories.where((c) => c != '全部')) {
      final n = personCatalogOf(role: role, category: cat).length;
      check(n >= 6, '$cat / ${role.label} 至少 6 人', '实际 $n 人');
    }
  }
  for (final role in PersonRole.values) {
    final all = personCatalogOf(role: role).length;
    final sum = kPersonCategories
        .where((c) => c != '全部')
        .map((c) => personCatalogOf(role: role, category: c).length)
        .fold<int>(0, (a, b) => a + b);
    check(all == sum, '${role.label}「全部」= 三个类别之和', '$all vs $sum');
  }
  check(
    kPersonCatalog.every((p) => p.name.isNotEmpty && p.roles.isNotEmpty),
    '目录不硬编码 id，且每人至少一个角色',
  );
  check(
    personCatalogOf(role: PersonRole.director)
            .map((p) => p.name)
            .contains('姜文') &&
        personCatalogOf(role: PersonRole.actor)
            .map((p) => p.name)
            .contains('姜文'),
    '导演兼演员的人物同时出现在两个维度',
  );
  check(
    personCatalogOf(
      role: PersonRole.director,
      category: '华语',
    ).every((p) => p.category == '华语'),
    '类别筛选不串味',
  );

  print('');
  print('== 角色匹配 ==');
  check(PersonRole.director.matches('导演'), '导演命中「导演」');
  check(!PersonRole.director.matches('演员 - 自己'), '导演不命中「演员」');
  check(PersonRole.actor.matches('演员 - 自己 (饰 自己)'), '演员命中复合写法');
  check(PersonRole.actor.matches('演员 - 配音'), '演员命中配音');
  check(!PersonRole.actor.matches('导演'), '演员不命中「导演」');
  checkEq(PersonRole.director.worksTitle, '导演代表作', '导演区块标题');
  checkEq(PersonRole.actor.worksTitle, '参演代表作', '演员区块标题');

  print('');
  print('== parseCelebritySuggest ==');
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
  checkEq(hit?.id, '1054524', '取首个 celebrity 的 id');
  checkEq(hit?.name, '克里斯托弗·诺兰', '取首个 celebrity 的名字');
  checkEq(hit?.subTitle, 'Christopher Nolan', '取 sub_title');
  check(
    parseCelebritySuggest(<Object?>[
          <String, Object?>{'type': 'movie', 'id': '1', 'title': '某片'},
        ]) ==
        null,
    '无 celebrity → null',
  );
  check(
    parseCelebritySuggest(null) == null &&
        parseCelebritySuggest(<Object?>[]) == null &&
        parseCelebritySuggest('x') == null,
    '空 / 非法结构 → null',
  );

  print('');
  print('== parseCelebrityProfile ==');
  final profile = parseCelebrityProfile(<String, Object?>{
    'title': '克里斯托弗·诺兰',
    'latin_title': 'Christopher Nolan',
    'cover': <String, Object?>{
      'normal': <String, Object?>{'url': 'https://img/n.jpg'},
    },
    'extra': <String, Object?>{
      'short_info': '制片人 导演 编剧 作者',
      'info': <Object?>[
        <Object?>['性别', '男'],
        <Object?>['IMDb编号', 'nm0634240'],
      ],
    },
  });
  checkEq(profile.name, '克里斯托弗·诺兰', '资料名');
  checkEq(profile.latinName, 'Christopher Nolan', '外文名');
  checkEq(profile.avatar, 'https://img/n.jpg', '头像取 cover.normal');
  checkEq(profile.summary, '制片人 导演 编剧 作者', '一句话简介');
  checkEq(profile.facts.length, 2, '结构化信息条数');
  final degraded = parseCelebrityProfile(
    null,
    fallbackName: '张艺谋',
    fallbackAvatar: 'https://img/zyg.jpg',
    fallbackLatinName: 'Zhang Yimou',
  );
  checkEq(degraded.name, '张艺谋', '资料失败 → 退化名字');
  checkEq(degraded.avatar, 'https://img/zyg.jpg', '资料失败 → 退化头像');
  check(
    parseCelebrityProfile(<String, Object?>{
          'title': '某人物',
          'cover_img': <String, Object?>{'url': 'https://img/ci.jpg'},
        }).avatar ==
        'https://img/ci.jpg',
    'cover 缺失 → 回退 cover_img',
  );

  print('');
  print('== parseCelebrityWorks ==');
  final dir = parseCelebrityWorks(<String, Object?>{
    'works': _rawWorks(),
  }, role: PersonRole.director);
  checkEq(dir.map((w) => w.title).join(','), '盗梦空间,星际穿越', '导演维度过滤');
  final act = parseCelebrityWorks(<String, Object?>{
    'works': _rawWorks(),
  }, role: PersonRole.actor);
  checkEq(act.map((w) => w.title).join(','), '某纪录片', '演员维度过滤');
  check(dir.every((w) => w.cover.isNotEmpty), '无封面条目被丢弃（哪怕评分最高）');
  check(dir.first.title == '盗梦空间', '同分按评分人数降序');
  check(
    parseCelebrityWorks(
          <String, Object?>{'works': _rawWorks()},
          role: PersonRole.director,
          limit: 1,
        ).length ==
        1,
    'limit 截断生效',
  );
  final dup = parseCelebrityWorks(<String, Object?>{
    'works': <Object?>[
      <String, Object?>{
        'roles': <Object?>['导演'],
        'work': <String, Object?>{
          'id': '77',
          'title': '重复条目',
          'cover_url': 'https://img/a.jpg',
        },
      },
      <String, Object?>{
        'roles': <Object?>['导演', '编剧'],
        'work': <String, Object?>{
          'id': '77',
          'title': '重复条目',
          'cover_url': 'https://img/a.jpg',
        },
      },
    ],
  }, role: PersonRole.director);
  checkEq(dup.length, 1, '按作品 id 去重');
  check(
    parseCelebrityWorks(null, role: PersonRole.director).isEmpty &&
        parseCelebrityWorks(
          <String, Object?>{},
          role: PersonRole.director,
        ).isEmpty &&
        parseCelebrityWorks(<String, Object?>{
          'works': 'oops',
        }, role: PersonRole.director).isEmpty,
    '空 / 非法响应返回空列表',
  );
  final noRate = parseCelebrityWorks(<String, Object?>{
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
  check(noRate.first.title == '有评分', '无评分作品排在后面');
  check(
    noRate.last.rate == '' && noRate.last.ratingValue == 0,
    '无评分时 rate 为空串',
  );

  print('');
  print('通过 $_pass 条，失败 $_fail 条');
  if (_fail > 0) throw StateError('person_catalog_check 存在失败断言');
}
