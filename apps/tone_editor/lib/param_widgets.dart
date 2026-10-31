import 'package:flutter/material.dart';

import 'params.dart';

/// パラメータ 1 つ（スライダー、または選択肢）
class ParamControl extends StatelessWidget {
  final ParamDef def;
  final int value;
  final ValueChanged<int> onChanged;
  const ParamControl({super.key, required this.def, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final label = Row(children: [
      Flexible(child: Text(def.label, style: text.bodyMedium, overflow: TextOverflow.ellipsis)),
      if (def.help != null)
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Tooltip(message: def.help!, child: const Icon(Icons.help_outline, size: 16)),
        ),
    ]);
    if (def.choices != null) {
      final items = def.choices!.entries.where((e) => e.key >= def.min && e.key <= def.max).toList();
      final v = def.choices!.containsKey(value) ? value : items.first.key;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          SizedBox(width: 220, child: label),
          Expanded(
            child: DropdownButton<int>(
              isExpanded: true,
              value: v,
              items: [for (final e in items) DropdownMenuItem(value: e.key, child: Text(e.value))],
              onChanged: (x) { if (x != null) onChanged(x); },
            ),
          ),
        ]),
      );
    }
    final v = def.clamp(value);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 0),
      child: Row(children: [
        SizedBox(width: 220, child: label),
        Expanded(
          child: Slider(
            value: v.toDouble(),
            min: def.min.toDouble(),
            max: def.max.toDouble(),
            divisions: def.max - def.min,
            label: def.format?.call(v) ?? '$v',
            onChanged: (x) => onChanged(x.round()),
          ),
        ),
        SizedBox(
          width: 76,
          child: Text(def.format?.call(v) ?? '$v', textAlign: TextAlign.right, style: text.bodyMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
        ),
      ]),
    );
  }
}
