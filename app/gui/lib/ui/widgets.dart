import 'package:flutter/material.dart';

import 'theme.dart';

/// 通用玻璃卡片
class HubCard extends StatelessWidget {
  const HubCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.glow = false,
    this.onTap,
    this.dashed = false,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool glow;
  final VoidCallback? onTap;
  final bool dashed;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    Widget content = DecoratedBox(
      decoration: BoxDecoration(
        color: t.surfaceSolid,
        borderRadius: BorderRadius.circular(18),
        border: dashed
            ? Border.all(color: t.border, style: BorderStyle.solid)
            : Border.all(color: t.border),
        boxShadow: glow
            ? <BoxShadow>[
                if (t.isDark)
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.45),
                    blurRadius: 34,
                    offset: const Offset(0, 12),
                  ),
              ]
            : null,
      ),
      child: Padding(padding: padding, child: child),
    );
    if (onTap == null) return content;
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: content,
    );
  }
}

/// 主行动按钮（115 橙渐变，高对比跳出）
class AccentButton extends StatelessWidget {
  const AccentButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.expand = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final disabled = onPressed == null;
    Widget child = Container(
      constraints: const BoxConstraints(minHeight: 44),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      decoration: BoxDecoration(
        gradient: disabled
            ? LinearGradient(colors: <Color>[t.border, t.border])
            : LinearGradient(colors: <Color>[t.accent, t.accent2]),
        borderRadius: BorderRadius.circular(12),
        boxShadow: disabled
            ? null
            : <BoxShadow>[
                BoxShadow(
                  color: t.accent.withValues(alpha: 0.32),
                  blurRadius: 22,
                  offset: const Offset(0, 8),
                ),
              ],
      ),
      child: Row(
        mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 18, color: disabled ? t.textDim : Colors.white),
            const SizedBox(width: 8),
          ],
          Text(
            label,
            style: TextStyle(
              color: disabled ? t.textDim : Colors.white,
              fontWeight: FontWeight.w600,
              fontSize: 15,
            ),
          ),
        ],
      ),
    );
    if (expand) child = SizedBox(width: double.infinity, child: child);
    return Semantics(
      button: true,
      enabled: !disabled,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onPressed,
        child: child,
      ),
    );
  }
}

class GhostButton extends StatelessWidget {
  const GhostButton({super.key, required this.label, this.onPressed, this.icon});

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final disabled = onPressed == null;
    return Semantics(
      button: true,
      enabled: !disabled,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onPressed,
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.symmetric(horizontal: 18),
          decoration: BoxDecoration(
            border: Border.all(color: t.border),
            borderRadius: BorderRadius.circular(12),
            color: t.surface,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (icon != null) ...<Widget>[
                Icon(icon, size: 18, color: disabled ? t.textDim : t.textHi),
                const SizedBox(width: 8),
              ],
              Text(
                label,
                style: TextStyle(
                  color: disabled ? t.textDim : t.textHi,
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class HubChip extends StatelessWidget {
  const HubChip({
    super.key,
    required this.label,
    this.selected = false,
    this.icon,
    this.color,
    this.onTap,
  });

  final String label;
  final bool selected;
  final IconData? icon;
  final Color? color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final c = color ?? t.accent;
    final Widget inner = Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: selected ? c.withValues(alpha: 0.14) : t.surface,
        border: Border.all(color: selected ? t.borderStrong : t.border),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 14, color: selected ? c : t.textDim),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: selected ? t.textHi : t.text,
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return inner;
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: inner,
      ),
    );
  }
}

class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.color, this.size = 9});
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: <BoxShadow>[
            BoxShadow(color: color.withValues(alpha: 0.3), blurRadius: 9),
          ],
        ),
      );
}

/// 骨架屏
class SkeletonBox extends StatefulWidget {
  const SkeletonBox({super.key, this.width, this.height = 16, this.radius = 10});
  final double? width;
  final double height;
  final double radius;

  @override
  State<SkeletonBox> createState() => _SkeletonBoxState();
}

class _SkeletonBoxState extends State<SkeletonBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.radius),
          gradient: LinearGradient(
            begin: Alignment(_c.value * 2 - 1, 0),
            end: Alignment(_c.value * 2, 0),
            colors: <Color>[
              t.surface,
              t.textDim.withValues(alpha: 0.18),
              t.surface,
            ],
          ),
        ),
      ),
    );
  }
}

class KpiTile extends StatelessWidget {
  const KpiTile({super.key, required this.value, required this.label, this.color});
  final String value;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return HubCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            value,
            style: TextStyle(
              fontSize: 28,
              height: 1,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
              color: color ?? t.textHi,
            ),
          ),
          const SizedBox(height: 7),
          Text(label, style: TextStyle(fontSize: 13, color: t.textDim)),
        ],
      ),
    );
  }
}

/// 分段控件
class HubSegmented<T> extends StatelessWidget {
  const HubSegmented({
    super.key,
    required this.items,
    required this.value,
    required this.onChanged,
    this.label,
  });

  final List<(T, String)> items;
  final T value;
  final ValueChanged<T> onChanged;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Semantics(
      label: label,
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: t.bg1,
          border: Border.all(color: t.border),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: items.map((it) {
            final selected = it.$1 == value;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: InkWell(
                borderRadius: BorderRadius.circular(9),
                onTap: () => onChanged(it.$1),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  constraints: const BoxConstraints(minHeight: 38),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: selected ? t.surfaceSolid : Colors.transparent,
                    borderRadius: BorderRadius.circular(9),
                    boxShadow: selected
                        ? <BoxShadow>[
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.25),
                              blurRadius: 8,
                            ),
                          ]
                        : null,
                  ),
                  child: Text(
                    it.$2,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: selected ? t.textHi : t.textDim,
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}

/// 轻量提示（保留输入不被清空）
void showHubToast(BuildContext context, String msg) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontWeight: FontWeight.w600)),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(milliseconds: 1800),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
}

/// 格式化容量
String fmtBytes(int? bytes) {
  if (bytes == null || bytes <= 0) return '未知';
  const units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${units[i]}';
}

/// 相对时间
String fmtTime(int? ms) {
  if (ms == null) return '未知';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final diff = DateTime.now().difference(d);
  if (diff.inDays > 365) return '${(diff.inDays / 365).floor()} 年前';
  if (diff.inDays > 0) return '${diff.inDays} 天前';
  if (diff.inHours > 0) return '${diff.inHours} 小时前';
  if (diff.inMinutes > 0) return '${diff.inMinutes} 分钟前';
  return '刚刚';
}
