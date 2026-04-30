import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';
import '../theme/app_theme.dart';
import '../widgets/frequency_atoms.dart';

/// 3-page swipeable explainer: what is this / Bluetooth-only / no internet.
/// Can be shown standalone (from Discovery empty state) or embedded in
/// onboarding flow.
class FrequencyExplainerScreen extends StatefulWidget {
  final VoidCallback onDone;

  /// If true, renders without Scaffold/SafeArea/Chrome (for embedding).
  final bool embedded;

  const FrequencyExplainerScreen({
    super.key,
    required this.onDone,
    this.embedded = false,
  });

  @override
  State<FrequencyExplainerScreen> createState() =>
      _FrequencyExplainerScreenState();
}

class _FrequencyExplainerScreenState extends State<FrequencyExplainerScreen> {
  final PageController _controller = PageController();
  int _currentPage = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final content = _buildContent(context);
    if (widget.embedded) {
      return content;
    }
    final c = FrequencyTheme.of(context).colors;
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: content,
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    final l10n = AppLocalizations.of(context);
    return Column(
      children: [
        if (!widget.embedded)
          FreqChrome(
            left: const FrequencyWordmark(),
            right: [
              if (_currentPage < 2)
                TextButton(
                  onPressed: widget.onDone,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    l10n.explainerSkip,
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 13,
                      color: c.ink2,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
            ],
          ),
        Expanded(
          child: PageView(
            controller: _controller,
            onPageChanged: (page) => setState(() => _currentPage = page),
            children: [
              _ExplainerPage(
                icon: Icons.podcasts_outlined,
                headline: l10n.explainerPage1Headline,
                body: l10n.explainerPage1Body,
              ),
              _ExplainerPage(
                icon: Icons.bluetooth,
                headline: l10n.explainerPage2Headline,
                body: l10n.explainerPage2Body,
              ),
              _ExplainerPage(
                icon: Icons.cloud_off_outlined,
                headline: l10n.explainerPage3Headline,
                body: l10n.explainerPage3Body,
              ),
            ],
          ),
        ),
        _buildBottomBar(context),
      ],
    );
  }

  Widget _buildBottomBar(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
      child: Column(
        children: [
          _PageIndicator(
            currentPage: _currentPage,
            pageCount: 3,
          ),
          const SizedBox(height: 20),
          if (_currentPage == 2)
            PrimaryButton(
              label: l10n.explainerGetStarted,
              block: true,
              padding: const EdgeInsets.symmetric(vertical: 14),
              fontSize: 15,
              onPressed: widget.onDone,
            )
          else
            Row(
              children: [
                Expanded(
                  child: FreqButton(
                    label: l10n.explainerBack,
                    block: true,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    fontSize: 15,
                    onPressed: _currentPage > 0
                        ? () => _controller.previousPage(
                              duration: const Duration(milliseconds: 280),
                              curve: Curves.easeInOut,
                            )
                        : null,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: PrimaryButton(
                    label: l10n.explainerNext,
                    block: true,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    fontSize: 15,
                    onPressed: () => _controller.nextPage(
                      duration: const Duration(milliseconds: 280),
                      curve: Curves.easeInOut,
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _ExplainerPage extends StatelessWidget {
  final IconData icon;
  final String headline;
  final String body;

  const _ExplainerPage({
    required this.icon,
    required this.headline,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 40, 32, 20),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              color: c.accentSoft,
              borderRadius: BorderRadius.circular(30),
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 56, color: c.accentInk),
          ),
          const SizedBox(height: 40),
          Text(
            headline,
            style: Theme.of(context).textTheme.displayMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          Text(
            body,
            style: Theme.of(context)
                .textTheme
                .bodyLarge
                ?.copyWith(color: c.ink2, height: 1.5),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _PageIndicator extends StatelessWidget {
  final int currentPage;
  final int pageCount;

  const _PageIndicator({
    required this.currentPage,
    required this.pageCount,
  });

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(
        pageCount,
        (index) => Container(
          margin: const EdgeInsets.symmetric(horizontal: 4),
          width: index == currentPage ? 24 : 8,
          height: 8,
          decoration: BoxDecoration(
            color: index == currentPage ? c.accent : c.line,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
      ),
    );
  }
}
