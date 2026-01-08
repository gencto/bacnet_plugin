import 'package:flutter/material.dart';

class LogConsole extends StatelessWidget {
  final List<String> logs;

  const LogConsole({super.key, required this.logs});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 150,
      color: Colors.black87,
      child: ListView.builder(
        itemCount: logs.length,
        reverse: true, // Show newest at bottom (or top if reversed list)
        itemBuilder: (context, index) {
          // logs[0] is oldest? Let's assume logs is append-only, so reverse index
          final entry = logs[logs.length - 1 - index];
          return Padding(
            padding: const EdgeInsets.all(4.0),
            child: Text(
              entry,
              style: const TextStyle(
                color: Colors.greenAccent,
                fontFamily: 'monospace',
                fontSize: 12,
              ),
            ),
          );
        },
      ),
    );
  }
}
