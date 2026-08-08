import 'package:flutter/material.dart';

/// An [IndexedStack] that only builds a tab the first time it is opened, then
/// keeps it alive for the rest of the session.
///
/// The two obvious approaches both misbehave for these dashboards:
///  * `children[index]` rebuilds the tab on every tap, so each switch refires
///    the screen's network calls and throws away scroll position and any
///    half-filled form.
///  * A plain [IndexedStack] fixes that but builds *every* tab up front, so
///    opening a dashboard would fire all of its screens' requests at once.
///
/// This keeps unvisited tabs as empty placeholders until they are selected.
class LazyTabView extends StatefulWidget {
  final int currentIndex;

  /// Built lazily - one builder per tab, in bottom-nav order.
  final List<WidgetBuilder> builders;

  const LazyTabView({
    super.key,
    required this.currentIndex,
    required this.builders,
  });

  @override
  State<LazyTabView> createState() => _LazyTabViewState();
}

class _LazyTabViewState extends State<LazyTabView> {
  final Set<int> _visited = {};

  @override
  void initState() {
    super.initState();
    _visited.add(widget.currentIndex);
  }

  @override
  void didUpdateWidget(covariant LazyTabView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _visited.add(widget.currentIndex);
  }

  @override
  Widget build(BuildContext context) {
    return IndexedStack(
      index: widget.currentIndex,
      children: List.generate(
        widget.builders.length,
        (i) => _visited.contains(i)
            ? widget.builders[i](context)
            : const SizedBox.shrink(),
      ),
    );
  }
}
