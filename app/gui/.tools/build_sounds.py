#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""提示音资产构建脚本（4.0 B2 视觉配置）。

【为什么需要这个脚本】
`assets/sounds/*.wav` 是**生成物**。上游是 OGG，本工程落 16-bit PCM WAV
（Windows 桌面端最稳、无需额外解码器），且文件名是本项目语义名而非上游名。
映射关系固化在脚本里，换源 / 补音都能复跑。

【上游与许可】
上游：Kenney — Interface Sounds (1.0)，www.kenney.nl
许可：Creative Commons Zero (CC0 1.0 Universal)。
      - 可用于个人 / 教育 / **商业**项目
      - 署名**非强制**（"Support us by crediting Kenney ... this is not mandatory"）
      - 即公共领域奉献，作者已放弃一切著作权与相关权
许可全文：**必须**随包，见 assets/sounds/LICENSE.txt（上游 License.txt 逐字）
与 assets/sounds/CC0-1.0-legalcode.txt（CC0 法律文本全文）。

【为什么换掉 HarmonyOS tones】
原 10 个 HarmonyOS tones 来自 `res/sound/HarmonyOS-tones/`，该目录
**只有 168 个 WAV，没有任何 LICENSE 文件**；旧 `LICENSE-NOTICE.txt` 里的条款是
从「HarmonyOS Sans 字体许可」推测出来的，音效是否适用并无依据 —— 属发版风险。
按 B2 裁定（不卡法务、换明确可商用源），整体替换为 CC0 的 Kenney 音效。

【用法】
  python .tools/build_sounds.py --source <kenney_interface_sounds.zip 或解压目录> [--check]

依赖：soundfile + numpy（仅构建期需要）。
"""

from __future__ import annotations

import argparse
import os
import sys
import wave
import zipfile

import numpy as np
import soundfile as sf

UPSTREAM_NAME = 'Interface Sounds (1.0)'
UPSTREAM_AUTHOR = 'Kenney (www.kenney.nl)'
UPSTREAM_LICENSE = 'CC0 1.0 Universal (Creative Commons Zero)'

# 落地语义名 -> 上游文件名（不含扩展名）
# 语义名与旧版一致，调用点无需改动。
MAPPING: list[tuple[str, str, str]] = [
    ('startup', 'open_001', '应用启动完成'),
    ('success', 'confirmation_002', '通用操作成功'),
    ('error', 'error_002', '操作失败 / 错误'),
    ('warning', 'error_005', '警告 / 风险提示'),
    ('notify', 'bong_001', '通知提醒'),
    # click_001 是 0.100s 的按键音；click_002..005 只有 0.010s，是极短 tick，
    # 在 UI 上听感发"炸"，不做主点击音。
    ('click', 'click_001', '按钮点击'),
    ('task_start', 'pluck_001', '任务开始'),
    ('task_done', 'confirmation_004', '任务完成'),
    ('scan_done', 'confirmation_001', '扫描 / 索引完成'),
    ('import_done', 'confirmation_003', '导入完成'),
]


def load_source(source: str) -> dict[str, bytes]:
    """返回 {上游文件名(含 .ogg): 字节}；source 可以是 zip 或解压目录。"""
    out: dict[str, bytes] = {}
    if os.path.isdir(source):
        audio_dir = os.path.join(source, 'Audio')
        base = audio_dir if os.path.isdir(audio_dir) else source
        for f in os.listdir(base):
            if f.endswith('.ogg'):
                with open(os.path.join(base, f), 'rb') as fp:
                    out[f] = fp.read()
    else:
        with zipfile.ZipFile(source) as z:
            for n in z.namelist():
                if n.endswith('.ogg'):
                    out[os.path.basename(n)] = z.read(n)
    return out


def ogg_to_wav(data: bytes):
    """OGG -> (PCM16 字节, 采样率, 声道数, 时长秒)。"""
    import io

    x, sr = sf.read(io.BytesIO(data), dtype='float64', always_2d=True)
    channels = x.shape[1]
    duration = x.shape[0] / sr
    # 峰值归一到 -1 dBFS：Kenney 各音效响度不齐，直接混着播会有的听不见有的刺耳。
    peak = float(np.max(np.abs(x))) if x.size else 0.0
    if peak > 0:
        x = x * (10 ** (-1.0 / 20.0) / peak)
    pcm = np.clip(x, -1.0, 1.0)
    pcm = (pcm * 32767.0).astype('<i2')
    return pcm.tobytes(), int(sr), channels, duration


def write_wav(path: str, pcm: bytes, sr: int, channels: int) -> None:
    with wave.open(path, 'wb') as w:
        w.setnchannels(channels)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(pcm)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--source', required=True)
    ap.add_argument('--project', default=None)
    ap.add_argument('--check', action='store_true')
    args = ap.parse_args()

    project = args.project or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    src = load_source(args.source)
    if not src:
        print(f'::error::上游没有找到任何 .ogg: {args.source}')
        return 2

    missing = [u for _, u, _ in MAPPING if f'{u}.ogg' not in src]
    if missing:
        for u in missing:
            print(f'::error::上游缺失: {u}.ogg')
        return 2
    print(f'映射校验通过：{len(MAPPING)} 个音效，上游 {args.source}')
    if args.check:
        return 0

    out_dir = os.path.join(project, 'assets', 'sounds')
    for f in ('LICENSE.txt', 'CC0-1.0-legalcode.txt'):
        if not os.path.exists(os.path.join(out_dir, f)):
            print(f'::error::缺少许可全文 assets/sounds/{f} —— 无许可的音效不许入库')
            return 2

    total = 0
    rows = []
    for name, up, usage in MAPPING:
        pcm, sr, ch, dur = ogg_to_wav(src[f'{up}.ogg'])
        path = os.path.join(out_dir, f'{name}.wav')
        write_wav(path, pcm, sr, ch)
        size = os.path.getsize(path)
        total += size
        rows.append((name, up, dur, sr, ch, size))
        print(f'  {name:<12} <- {up:<20} {dur:5.3f}s  {sr}Hz x{ch}  {size/1024:6.1f} KiB')

    # 清掉不在映射表里的 wav（上一代 HarmonyOS tones 的残留）
    keep = {f'{n}.wav' for n, _, _ in MAPPING}
    for f in os.listdir(out_dir):
        if f.endswith('.wav') and f not in keep:
            os.remove(os.path.join(out_dir, f))
            print(f'清理遗留 wav: {f}')

    print(f'合计 {total/1024/1024:.2f} MiB -> {out_dir}')
    print('映射表（供 LICENSE-NOTICE.txt 引用）:')
    for name, up, dur, sr, ch, size in rows:
        print(f'  | {name}.wav | {up}.ogg | {dur:.3f}s | {sr}Hz x{ch} |')
    return 0


if __name__ == '__main__':
    sys.exit(main())
