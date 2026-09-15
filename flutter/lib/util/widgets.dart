import 'package:flutter/material.dart';

import '../theme.dart';

IconData fileIcon(String? mime) {
  if (mime == null) return Icons.insert_drive_file_outlined;
  if (mime.startsWith('image/')) return Icons.image_outlined;
  if (mime.startsWith('video/')) return Icons.movie_outlined;
  if (mime == 'application/pdf') return Icons.picture_as_pdf_outlined;
  if (mime == 'application/zip') return Icons.inventory_2_outlined;
  return Icons.insert_drive_file_outlined;
}

class MetaRow extends StatelessWidget {
  final String label;
  final String value;
  final bool mono;

  const MetaRow(this.label, this.value, {this.mono = false, super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(label, style: const TextStyle(color: C.fg2, fontSize: 13)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: C.fg,
                fontSize: 13,
                fontFamily: mono ? 'monospace' : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Простой заголовок-панель, как остров в вебе.
class Panel extends StatelessWidget {
  final Widget child;
  const Panel({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: C.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: C.brd),
      ),
      child: child,
    );
  }
}

Future<bool> confirmDialog(
  BuildContext context,
  String title,
  String message, {
  bool danger = false,
}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Отмена'),
        ),
        FilledButton(
          style: danger
              ? FilledButton.styleFrom(backgroundColor: C.danger)
              : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(danger ? 'Удалить' : 'ОК'),
        ),
      ],
    ),
  );
  return r ?? false;
}

Future<String?> promptDialog(
  BuildContext context,
  String title, {
  String? initial,
}) async {
  final ctrl = TextEditingController(text: initial ?? '');
  final r = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(controller: ctrl, autofocus: true),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, ctrl.text),
          child: const Text('ОК'),
        ),
      ],
    ),
  );
  ctrl.dispose();
  return r;
}

void snack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(message)));
}
