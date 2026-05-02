import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';
import '../theme/app_theme.dart';
import '../widgets/frequency_atoms.dart';

/// In-app Privacy & Security FAQ.
///
/// Sets honest expectations about Bluetooth LE security, the absence of
/// app-level E2EE in v1, and what data (if any) leaves the device.
/// Addresses the security-FAQ sub-item of issue #133.
class SecurityFaqScreen extends StatelessWidget {
  const SecurityFaqScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Column(
          children: [
            FreqChrome(
              left: Text(
                l10n.securityFaqTitle,
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: c.ink,
                ),
              ),
              right: [
                _CloseButton(
                  semanticLabel: l10n.securityFaqCloseIcon,
                  onTap: () => Navigator.of(context).maybePop(),
                ),
              ],
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: c.accentSoft,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        alignment: Alignment.center,
                        child: Icon(
                          Icons.lock_outline,
                          size: 20,
                          color: c.accentInk,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          l10n.securityFaqIntro,
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 13,
                            color: c.ink2,
                            height: 1.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  _FaqItem(
                    question: l10n.securityFaqQ1,
                    answer: l10n.securityFaqA1,
                  ),
                  _FaqItem(
                    question: l10n.securityFaqQ2,
                    answer: l10n.securityFaqA2,
                  ),
                  _FaqItem(
                    question: l10n.securityFaqQ3,
                    answer: l10n.securityFaqA3,
                  ),
                  _FaqItem(
                    question: l10n.securityFaqQ4,
                    answer: l10n.securityFaqA4,
                  ),
                  _FaqItem(
                    question: l10n.securityFaqQ5,
                    answer: l10n.securityFaqA5,
                  ),
                  const SizedBox(height: 8),
                  PrimaryButton(
                    label: l10n.securityFaqClose,
                    block: true,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    fontSize: 15,
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FaqItem extends StatefulWidget {
  final String question;
  final String answer;

  const _FaqItem({required this.question, required this.answer});

  @override
  State<_FaqItem> createState() => _FaqItemState();
}

class _FaqItemState extends State<_FaqItem> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: FreqCard(
        padding: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: Semantics(
          expanded: _expanded,
          child: InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.question,
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: c.ink,
                          ),
                        ),
                      ),
                      Icon(
                        _expanded
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
                        size: 18,
                        color: c.ink2,
                      ),
                    ],
                  ),
                  if (_expanded) ...[
                    const SizedBox(height: 10),
                    Text(
                      widget.answer,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 13,
                        color: c.ink2,
                        height: 1.55,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CloseButton extends StatelessWidget {
  final VoidCallback onTap;
  final String semanticLabel;
  const _CloseButton({required this.onTap, required this.semanticLabel});

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 48,
          height: 48,
          child: Center(
            child: Semantics(
              button: true,
              label: semanticLabel,
              child: Icon(Icons.close, size: 20, color: c.ink2),
            ),
          ),
        ),
      ),
    );
  }
}
