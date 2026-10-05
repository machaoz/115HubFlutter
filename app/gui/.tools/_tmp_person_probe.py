import json, urllib.request, urllib.parse, time, sys

UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"


def get(url, ref):
    r = urllib.request.Request(url, headers={
        'user-agent': UA, 'referer': ref,
        'accept': 'application/json, text/plain, */*',
        'accept-language': 'zh-CN,zh;q=0.9'})
    return urllib.request.urlopen(r, timeout=25).read().decode('utf-8', 'ignore')


def suggest(n):
    for _ in range(4):
        try:
            s = json.loads(get('https://movie.douban.com/j/subject_suggest?q=' + urllib.parse.quote(n), 'https://movie.douban.com/'))
            if s:
                return s
        except Exception:
            pass
        time.sleep(2.5)
    return None


names = {
    'DIR_CN': ['姜文', '侯孝贤', '徐克', '冯小刚', '刁亦男', '杜琪峰', '杨德昌', '娄烨', '宁浩', '陈可辛', '张艺谋', '陈凯歌', '王家卫', '李安', '贾樟柯'],
    'ACT_CN': ['梁朝伟', '巩俐', '周润发', '张国荣', '章子怡', '周星驰', '刘德华', '张曼玉', '黄渤', '舒淇', '葛优', '梁家辉'],
    'DIR_WEST': ['克里斯托弗·诺兰', '史蒂文·斯皮尔伯格', '马丁·斯科塞斯', '詹姆斯·卡梅隆', '昆汀·塔伦蒂诺', '大卫·芬奇', '雷德利·斯科特', '韦斯·安德森', '彼得·杰克逊', '弗朗西斯·福特·科波拉', '伍迪·艾伦', '丹尼斯·维伦纽瓦'],
    'ACT_WEST': ['莱昂纳多·迪卡普里奥', '汤姆·汉克斯', '梅丽尔·斯特里普', '罗伯特·德尼罗', '布拉德·皮特', '凯特·布兰切特', '摩根·弗里曼', '娜塔莉·波特曼', '丹尼尔·戴-刘易斯', '朱迪·福斯特', '汤姆·克鲁斯', '艾玛·斯通'],
    'DIR_JK': ['黑泽明', '宫崎骏', '是枝裕和', '奉俊昊', '朴赞郁', '李沧东', '北野武', '新海诚', '细田守', '金基德', '小津安二郎', '沟口健二'],
    'ACT_JK': ['宋康昊', '全度妍', '李秉宪', '裴斗娜', '役所广司', '长泽雅美', '渡边谦', '树木希林', '安藤樱', '孔侑', '三船敏郎', '原节子'],
}

for grp, ns in names.items():
    print('##', grp, flush=True)
    for n in ns:
        s = suggest(n)
        if not s:
            print('  ', n, '| EMPTY', flush=True)
            continue
        cel = [x for x in s if x.get('type') == 'celebrity']
        if not cel:
            print('  ', n, '| NO_CEL first=', (s[0].get('title'), s[0].get('type')) if s else None, flush=True)
            continue
        cid = cel[0]['id']
        ct = cel[0].get('title', '')
        time.sleep(1.8)
        try:
            w = json.loads(get('https://m.douban.com/rexxar/api/v2/celebrity/%s/works?start=0&count=50' % cid,
                               'https://m.douban.com/movie/celebrity/%s/' % cid))
            roles = set()
            for it in w.get('works', []):
                for r in it.get('roles', []):
                    roles.add(r.split(' - ')[0])
            print('  ', n, '| OK id=%s hit=%s total=%s dir=%s act=%s'
                  % (cid, ct, w.get('total'), '导演' in roles, '演员' in roles), flush=True)
        except Exception as e:
            print('  ', n, '| WORKS_ERR id=%s' % cid, str(e)[:50], flush=True)
        time.sleep(1.8)
print('DONE', flush=True)
