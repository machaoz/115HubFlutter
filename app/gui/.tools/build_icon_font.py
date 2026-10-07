#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""HubIcons 图标字体构建脚本（4.0 B2 视觉配置）。

【为什么需要这个脚本】
`assets/icons/hub_icons.ttf` 是**生成物**，不是手写资产。字形源是第三方开源
图标库，码位 / index.json / lib/ui/hub_icons.dart 三者必须与它严格对齐，
手工改任何一处都会造成码位漂移 —— 因此统一由本脚本一次性产出。

【上游与许可】
上游：Fluent UI System Icons（Microsoft），npm 包 `@fluentui/svg-icons`。
许可：MIT（Copyright (c) 2020 Microsoft Corporation）。许可全文必须随包，
见 `assets/icons/LICENSE.txt`（本脚本会校验它存在，不存在即拒绝构建）。

**禁止把无明确许可的图标源接进本脚本。** 2026-10 B2 前用的 HarmonyOS Icons
676 SVG 包内不含任何 LICENSE 文件，属发版风险，已整体替换为 Fluent。

【用法】
  python .tools/build_icon_font.py --source <解压后的 icons 目录> [--check]

  --source  npm 包 `@fluentui/svg-icons` 解压后的 `package/icons` 目录
  --check   只校验映射表里每个图标在上游是否存在，不写任何文件

依赖：fontTools（仅构建期需要，运行时零依赖）。
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys

from fontTools.fontBuilder import FontBuilder
from fontTools.pens.cu2quPen import Cu2QuPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.pens.transformPen import TransformPen
from fontTools.svgLib.path import parse_path

# ------------------------------------------------------------------ 常量

UPEM = 1000
FIRST_CODEPOINT = 0xE000
GRID = 24.0  # Fluent 24px 图标的设计栅格

UPSTREAM_NAME = 'Fluent UI System Icons'
UPSTREAM_PACKAGE = '@fluentui/svg-icons'
UPSTREAM_LICENSE = 'MIT'

# 逻辑名 -> (上游基名, 变体)；**列表顺序即码位顺序**，追加只能加在末尾。
# 变体只有 regular / filled 两种：Fluent 的 color 变体已 deprecated 且带固定配色，不适用。
#
# 映射取舍见 docs 说明：HarmonyOS 里「尺寸变体」类的图标（如 loading_small）
# 在 Fluent 中没有对应物，不做凑数映射，直接从集合里移除。
MAPPING: list[tuple[str, str, str]] = [
    # ---- action（32）-------------------------------------------------
    ('action_add', 'add', 'regular'),
    ('action_cancel', 'dismiss', 'regular'),
    ('action_check', 'checkmark', 'regular'),
    ('action_check_filled', 'checkmark', 'filled'),
    ('action_close', 'dismiss_circle', 'regular'),
    ('action_copy', 'copy', 'regular'),
    ('action_delete', 'delete', 'regular'),
    ('action_deselect_all', 'select_all_off', 'regular'),
    ('action_detail', 'info', 'regular'),
    ('action_drag', 'drag', 'regular'),
    ('action_edit', 'edit', 'regular'),
    ('action_enlarge', 'zoom_in', 'regular'),
    ('action_filter', 'filter', 'regular'),
    ('action_forbid', 'prohibited', 'regular'),
    ('action_history', 'history', 'regular'),
    ('action_more', 'more_horizontal', 'regular'),
    ('action_more_list', 'more_vertical', 'regular'),
    ('action_move', 'arrow_move', 'regular'),
    ('action_reduce', 'zoom_out', 'regular'),
    ('action_refresh', 'arrow_clockwise', 'regular'),
    ('action_remove', 'subtract', 'regular'),
    ('action_reset', 'arrow_reset', 'regular'),
    ('action_rotate', 'arrow_rotate_clockwise', 'regular'),
    ('action_save', 'save', 'regular'),
    ('action_scan', 'scan', 'regular'),
    ('action_scan_input', 'scan_qr_code', 'regular'),
    ('action_select_all', 'select_all_on', 'regular'),
    ('action_share', 'share', 'regular'),
    ('action_sort', 'arrow_sort', 'regular'),
    ('action_sort_reverse', 'text_sort_descending', 'regular'),
    ('action_timer', 'timer', 'regular'),
    ('action_upload', 'arrow_upload', 'regular'),
    # ---- media（27）--------------------------------------------------
    ('media_audio_track', 'music_note_1', 'regular'),
    ('media_cast', 'cast', 'regular'),
    ('media_cloud_download', 'cloud_arrow_down', 'regular'),
    ('media_cloud_upload', 'cloud_arrow_up', 'regular'),
    ('media_fast', 'fast_forward', 'regular'),
    ('media_favorite', 'star', 'regular'),
    ('media_favorited', 'star', 'filled'),
    ('media_file', 'document', 'regular'),
    ('media_folder', 'folder', 'regular'),
    ('media_folder_filled', 'folder', 'filled'),
    ('media_fullscreen', 'full_screen_maximize', 'regular'),
    ('media_pause', 'pause', 'regular'),
    ('media_photo', 'image', 'regular'),
    ('media_play', 'play', 'regular'),
    ('media_play_last', 'previous', 'regular'),
    ('media_play_next', 'next', 'regular'),
    ('media_play_order', 'list', 'regular'),
    ('media_repeat', 'arrow_repeat_all', 'regular'),
    ('media_repeat_one', 'arrow_repeat_1', 'regular'),
    ('media_shuffle', 'arrow_shuffle', 'regular'),
    ('media_subtitle', 'subtitles', 'regular'),
    ('media_video', 'video', 'regular'),
    ('media_video_filled', 'video', 'filled'),
    ('media_volume', 'speaker_2', 'regular'),
    ('media_volume_down', 'speaker_1', 'regular'),
    ('media_volume_filled', 'speaker_2', 'filled'),
    ('media_volume_off', 'speaker_mute', 'regular'),
    # ---- nav（21）----------------------------------------------------
    ('nav_appstore', 'app_store', 'regular'),
    ('nav_arrow_left', 'chevron_left', 'regular'),
    ('nav_arrow_right', 'chevron_right', 'regular'),
    ('nav_back', 'arrow_left', 'regular'),
    ('nav_backtotop', 'arrow_up', 'regular'),
    ('nav_discover', 'compass_northwest', 'regular'),
    ('nav_drawer', 'panel_left', 'regular'),
    ('nav_favorite', 'star', 'regular'),
    ('nav_gallery', 'image_multiple', 'regular'),
    ('nav_home', 'home', 'regular'),
    ('nav_home_filled', 'home', 'filled'),
    ('nav_import', 'arrow_import', 'regular'),
    ('nav_import_filled', 'arrow_import', 'filled'),
    ('nav_library', 'library', 'regular'),
    ('nav_library_filled', 'library', 'filled'),
    ('nav_quit', 'sign_out', 'regular'),
    ('nav_search', 'search', 'regular'),
    ('nav_search_filled', 'search', 'filled'),
    ('nav_settings', 'settings', 'regular'),
    ('nav_settings_filled', 'settings', 'filled'),
    ('nav_todo', 'task_list_ltr', 'regular'),
    # ---- setting（24）------------------------------------------------
    ('setting_about', 'info', 'regular'),
    ('setting_account', 'person', 'regular'),
    ('setting_brightness', 'brightness_high', 'regular'),
    ('setting_calendar', 'calendar', 'regular'),
    ('setting_clean', 'broom', 'regular'),
    ('setting_clock', 'clock', 'regular'),
    ('setting_code', 'code', 'regular'),
    ('setting_face', 'emoji', 'regular'),
    ('setting_font', 'text_font', 'regular'),
    ('setting_keyboard', 'keyboard', 'regular'),
    ('setting_language', 'local_language', 'regular'),
    ('setting_network', 'wifi_1', 'regular'),
    ('setting_notes', 'note', 'regular'),
    ('setting_password_hide', 'eye_off', 'regular'),
    ('setting_password_show', 'eye', 'regular'),
    ('setting_quickstart', 'power', 'regular'),
    ('setting_sound', 'sound_wave_circle', 'regular'),
    ('setting_sound_off', 'speaker_off', 'regular'),
    ('setting_storage_manage', 'storage', 'regular'),
    ('setting_theme', 'color', 'regular'),
    ('setting_translate', 'translate', 'regular'),
    ('setting_unfold_reverse', 'chevron_up_down', 'regular'),
    ('setting_update', 'arrow_circle_up', 'regular'),
    ('setting_voice', 'mic', 'regular'),
    # ---- status（18）-------------------------------------------------
    ('status_cloud_off', 'cloud_off', 'regular'),
    ('status_cloud_sync', 'cloud_sync', 'regular'),
    ('status_connection', 'plug_connected', 'regular'),
    ('status_empty', 'collections_empty', 'regular'),
    ('status_error', 'error_circle', 'regular'),
    ('status_fail', 'dismiss_circle', 'regular'),
    ('status_help', 'question_circle', 'regular'),
    ('status_loading', 'arrow_sync', 'regular'),
    ('status_lock', 'lock_closed', 'regular'),
    ('status_message', 'comment', 'regular'),
    ('status_offline', 'globe_off', 'regular'),
    ('status_online', 'globe', 'regular'),
    ('status_privacy', 'incognito', 'regular'),
    ('status_security', 'shield', 'regular'),
    ('status_success', 'checkmark_circle', 'regular'),
    ('status_sync', 'arrow_sync_circle', 'regular'),
    ('status_unlock', 'lock_open', 'regular'),
    ('status_wlan_error', 'wifi_warning', 'regular'),
]

# ------------------------------------------------------------------ 工具

_VIEWBOX_RE = re.compile(r'viewBox\s*=\s*"([^"]+)"')
_D_RE = re.compile(r'\sd\s*=\s*"([^"]+)"')


def upstream_file(source_dir: str, base: str, variant: str) -> str:
    return os.path.join(source_dir, f'{base}_24_{variant}.svg')


def read_svg(path: str) -> str:
    with open(path, 'r', encoding='utf-8') as fp:
        return fp.read()


def path_data_of(svg: str) -> list[str]:
    """取出 SVG 里所有 `<path d="...">` 的路径数据（Fluent 图标恒为单路径）。"""
    return _D_RE.findall(svg)


def viewbox_of(svg: str) -> tuple[float, float, float, float]:
    m = _VIEWBOX_RE.search(svg)
    if not m:
        raise ValueError('找不到 viewBox')
    parts = [float(x) for x in m.group(1).replace(',', ' ').split()]
    if len(parts) != 4:
        raise ValueError(f'viewBox 解析失败: {m.group(1)!r}')
    return parts[0], parts[1], parts[2], parts[3]


def build_glyph(svg: str):
    """把 SVG 路径转成 TTF 字形。

    坐标变换：SVG 是 y 向下、以左上为原点；字体是 y 向上、以基线为原点。
    这里把整个 viewBox **等比**映射到 y ∈ [0, UPEM]，x 左对齐到 0：
      x' = scale * (x - minX)
      y' = UPEM - scale * (y - minY)
    等比（而不是各自拉伸到满格）是关键：Fluent 24 图标内部自带 ~1.5 单位留白，
    统一按 24 栅格缩放才能保证 122 个图标的光学大小一致。
    """
    min_x, min_y, w, h = viewbox_of(svg)
    if w <= 0 or h <= 0:
        raise ValueError('viewBox 宽高非法')
    scale = UPEM / h
    tt_pen = TTGlyphPen(None)
    # SVG 路径含三次贝塞尔（C/S/A），而 TrueType glyf 只存二次贝塞尔，
    # 必须先降次。0.5/1000 em 的误差在 24px 下远小于半个像素，肉眼不可见。
    pen = Cu2QuPen(tt_pen, max_err=0.5)
    # TransformPen 的变换元组是 (xx, xy, yx, yy, dx, dy)
    tpen = TransformPen(pen, (scale, 0.0, 0.0, -scale, -min_x * scale, UPEM + min_y * scale))
    for d in path_data_of(svg):
        parse_path(d, tpen)
    return tt_pen.glyph()


def build_font(source_dir: str):
    names = [n for n, _, _ in MAPPING]
    glyphs = {'.notdef': TTGlyphPen(None).glyph()}
    for name, base, variant in MAPPING:
        svg = read_svg(upstream_file(source_dir, base, variant))
        glyphs[name] = build_glyph(svg)

    cmap = {FIRST_CODEPOINT + i: n for i, n in enumerate(names)}
    fb = FontBuilder(UPEM, isTTF=True)
    fb.setupGlyphOrder(['.notdef'] + names)
    fb.setupCharacterMap(cmap)
    fb.setupGlyf(glyphs)
    # hmtx 的 lsb **必须**等于字形真实 xMin：两者不一致时，按规范解读的渲染器
    # 会把轮廓整体平移（fontTools 的 glyphSet 就是这么模拟的），图标会集体左偏。
    glyf = fb.font['glyf']
    fb.setupHorizontalMetrics(
        {n: (UPEM, glyf[n].xMin or 0) for n in ['.notdef'] + names}
    )
    # 字形铺满整个 em（y ∈ [0, UPEM]），因此 ascent = UPEM / descent = 0：
    # 这样 Icon(size: 24) 渲染出的图标正好占满 24 逻辑像素，不会被度量裁掉。
    fb.setupHorizontalHeader(ascent=UPEM, descent=0, lineGap=0)
    fb.setupNameTable(
        {
            'familyName': 'HubIcons',
            'styleName': 'Regular',
            'uniqueFontIdentifier': 'HubIcons-Regular-4.0',
            'fullName': 'HubIcons Regular',
            'psName': 'HubIcons-Regular',
            'version': 'Version 4.000',
        }
    )
    fb.setupOS2(
        sTypoAscender=UPEM,
        sTypoDescender=0,
        sTypoLineGap=0,
        usWinAscent=UPEM,
        usWinDescent=0,
    )
    fb.setupPost()
    return fb.font


# ------------------------------------------------------------------ 产出

def write_index(project: str) -> dict:
    """重建 assets/icons/index.json。

    分类与关键词**沿用旧表**（逻辑名没变，语义也就没变），只把 `source`
    换成上游新文件名 —— 避免为了换图标库而重写 122 条中文检索词。
    """
    index_path = os.path.join(project, 'assets', 'icons', 'index.json')
    old = {}
    if os.path.exists(index_path):
        with open(index_path, 'r', encoding='utf-8') as fp:
            old = json.load(fp).get('icons', {})

    colors: dict[str, int] = {}
    icons = {}
    for i, (name, base, variant) in enumerate(MAPPING):
        cp = FIRST_CODEPOINT + i
        meta = old.get(name, {})
        category = meta.get('category') or name.split('_', 1)[0]
        keywords = meta.get('keywords') or []
        colors[category] = colors.get(category, 0) + 1
        icons[name] = {
            'codepoint': cp,
            'code': f'0x{cp:X}',
            'file': f'{name}.svg',
            'source': f'{base}_24_{variant}.svg',
            'style': variant,
            'category': category,
            'keywords': keywords,
        }
    return {
        'meta': {
            'family': 'HubIcons',
            'fontFile': 'hub_icons.ttf',
            'upem': UPEM,
            'ascent': UPEM,
            'descent': 0,
            'firstCodepoint': f'0x{FIRST_CODEPOINT:X}',
            'count': len(MAPPING),
            'source': f'{UPSTREAM_NAME} ({UPSTREAM_PACKAGE}, 24px regular/filled)',
            'license': UPSTREAM_LICENSE,
            'licenseFile': 'LICENSE.txt',
            'colors': dict(sorted(colors.items())),
        },
        'icons': icons,
    }


def write_hub_icons_dart(index: dict, path: str) -> None:
    """生成 lib/ui/hub_icons.dart（GENERATED）。"""
    out = [
        '// GENERATED FILE —— 由 .tools/build_icon_font.py 生成，请勿手改。',
        '//',
        f'// 字形来源：{UPSTREAM_NAME}（{UPSTREAM_PACKAGE}）24px regular/filled 子集，',
        f'// 许可：{UPSTREAM_LICENSE}，全文见 assets/icons/LICENSE.txt。',
        '// 已预编译为图标字体 assets/icons/hub_icons.ttf（family: HubIcons）。',
        '// 码位映射与关键词检索见 assets/icons/index.json。',
        '//',
        '// 常量刻意沿用 snake_case：需与 assets/icons/index.json 的图标逻辑名逐字对应，',
        '// 否则 byName() 检索与构建脚本的码位对齐会失去唯一依据。',
        '// ignore_for_file: constant_identifier_names',
        '',
        "import 'package:flutter/widgets.dart';",
        '',
        '/// 图标字体 family 名（pubspec.yaml 中声明）',
        "const String kHubIconsFamily = 'HubIcons';",
        '',
        '/// 全部图标字形。用法：Icon(HubIcons.media_play, size: 20)',
        'class HubIcons {',
        '  HubIcons._();',
    ]
    for name, meta in index['icons'].items():
        cp = meta['code']
        doc = '/'.join(meta['keywords']) if meta['keywords'] else name
        out += [
            '',
            f'  /// {doc}',
            f'  static const IconData {name} = IconData(',
            f'    {cp},',
            '    fontFamily: kHubIconsFamily,',
            '  );',
        ]
    out += [
        '',
        '  /// 逻辑名 -> IconData 全量映射（供设置页/搜索按名取图标）',
        '  static const Map<String, IconData> byName = <String, IconData>{',
    ]
    for name in index['icons']:
        out.append(f"    '{name}': {name},")
    out += [
        '  };',
        '',
        '  /// 逻辑名 -> 分类（nav/media/action/status/setting）',
        '  static const Map<String, String> category = <String, String>{',
    ]
    for name, meta in index['icons'].items():
        out.append(f"    '{name}': '{meta['category']}',")
    out += ['  };', '}', '']
    with open(path, 'w', encoding='utf-8', newline='\n') as fp:
        fp.write('\n'.join(out))


# ------------------------------------------------------------------ main

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--source', required=True, help='上游 icons 目录')
    ap.add_argument('--project', default=None, help='Flutter 工程根（默认本文件上级）')
    ap.add_argument('--check', action='store_true', help='只校验，不写文件')
    args = ap.parse_args()

    project = args.project or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    source_dir = args.source
    if not os.path.isdir(source_dir):
        print(f'::error::上游目录不存在: {source_dir}')
        return 2

    # 1) 上游文件名与变体合法性
    missing = []
    for name, base, variant in MAPPING:
        if variant not in ('regular', 'filled'):
            print(f'::error::{name}: 变体非法 {variant}')
            return 2
        if not os.path.exists(upstream_file(source_dir, base, variant)):
            missing.append((name, base, variant))
    if missing:
        for name, base, variant in missing:
            print(f'::error::上游缺失: {name} -> {base}_24_{variant}.svg')
        return 2

    # 2) 逻辑名唯一
    names = [n for n, _, _ in MAPPING]
    dup = {n for n in names if names.count(n) > 1}
    if dup:
        print(f'::error::逻辑名重复: {sorted(dup)}')
        return 2

    print(f'映射校验通过：{len(MAPPING)} 个图标，上游 {source_dir}')
    if args.check:
        return 0

    # 3) 许可全文必须存在（发版硬门槛）
    license_path = os.path.join(project, 'assets', 'icons', 'LICENSE.txt')
    if not os.path.exists(license_path):
        print(f'::error::缺少许可全文 {license_path} —— 无许可的图标不许入库')
        return 2

    # 4) 构建并落盘
    font = build_font(source_dir)
    ttf_path = os.path.join(project, 'assets', 'icons', 'hub_icons.ttf')
    font.save(ttf_path)
    print(f'写出字体: {ttf_path} ({os.path.getsize(ttf_path)} bytes)')

    index = write_index(project)
    index_path = os.path.join(project, 'assets', 'icons', 'index.json')
    with open(index_path, 'w', encoding='utf-8', newline='\n') as fp:
        json.dump(index, fp, ensure_ascii=False, indent=2)
        fp.write('\n')
    print(f'写出索引: {index_path} ({index["meta"]["count"]} 个图标)')

    dart_path = os.path.join(project, 'lib', 'ui', 'hub_icons.dart')
    write_hub_icons_dart(index, dart_path)
    print(f'写出常量: {dart_path}')

    # 5) SVG 源文件（构建输入的可追溯副本，不在 pubspec 里声明为 asset）
    icons_dir = os.path.join(project, 'assets', 'icons')
    for name, base, variant in MAPPING:
        shutil.copyfile(upstream_file(source_dir, base, variant), os.path.join(icons_dir, f'{name}.svg'))
    # 清掉上一代遗留的 SVG（不在映射表里的）
    keep = {f'{n}.svg' for n in names} | {'hub_icons.ttf', 'index.json', 'LICENSE.txt'}
    for f in os.listdir(icons_dir):
        if f.endswith('.svg') and f not in keep:
            os.remove(os.path.join(icons_dir, f))
            print(f'清理遗留 SVG: {f}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
