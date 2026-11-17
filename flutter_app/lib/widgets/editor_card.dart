import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'frosted_dialog.dart';

enum UnsavedEditorAction { save, discard }

Future<UnsavedEditorAction?> confirmUnsavedEditorChanges(
  BuildContext context,
) => showFrostedDialog<UnsavedEditorAction>(
  context: context,
  barrierDismissible: false,
  builder: (dialogContext) => Padding(
    padding: const EdgeInsets.all(16),
    child: FrostedCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Unsaved changes',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 12),
          const Text('Save your changes before closing?'),
          const SizedBox(height: 16),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Keep editing'),
              ),
              TextButton(
                onPressed: () =>
                    Navigator.pop(dialogContext, UnsavedEditorAction.discard),
                child: const Text('Discard'),
              ),
              TextButton(
                onPressed: () =>
                    Navigator.pop(dialogContext, UnsavedEditorAction.save),
                child: const Text('Save'),
              ),
            ],
          ),
        ],
      ),
    ),
  ),
);

class EditorCard extends StatelessWidget {
  const EditorCard({
    super.key,
    required this.title,
    required this.child,
    required this.onClose,
    required this.onSave,
    this.saving = false,
  });

  final String title;
  final Widget child;
  final VoidCallback? onClose;
  final VoidCallback? onSave;
  final bool saving;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final maxHeight = math.max(
      0.0,
      math.min(
        media.size.height * 0.85,
        media.size.height -
            media.padding.vertical -
            media.viewInsets.bottom -
            32,
      ),
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, media.viewInsets.bottom + 16),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: FrostedCard(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.edit_outlined,
                    size: 18,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Flexible(child: child),
              const SizedBox(height: 8),
              const Divider(height: 1),
              SizedBox(
                height: 48,
                child: Row(
                  children: [
                    TextButton(
                      onPressed: saving ? null : onSave,
                      child: Text(saving ? 'Saving...' : 'Save'),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: saving ? null : onClose,
                      child: const Text('Close'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
