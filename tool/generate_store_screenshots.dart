import 'dart:async';
import 'dart:convert';
import 'dart:io';

const _targets = <String>[
  'phone-1',
  'phone-2',
  'phone-3',
  'phone-4',
  'seven-1',
  'seven-2',
  'ten-1',
  'ten-2',
];

Future<void> main(List<String> args) async {
  final selected = args.isEmpty ? _targets : args;
  final unknown = selected.where((target) => !_targets.contains(target));
  if (unknown.isNotEmpty) {
    stderr.writeln('Unknown screenshot target(s): ${unknown.join(', ')}');
    stderr.writeln('Known targets: ${_targets.join(', ')}');
    exitCode = 64;
    return;
  }

  final flutter = Platform.environment['FLUTTER_BIN'] ?? 'flutter';
  for (final target in selected) {
    final generated = await _runTarget(flutter, target);
    if (!generated) {
      exitCode = 1;
      return;
    }
  }

  stdout.writeln('Generated ${selected.length} screenshot target(s).');
}

Future<bool> _runTarget(String flutter, String target) async {
  stdout.writeln('Generating $target...');
  final process = await Process.start(
    flutter,
    [
      'test',
      '--reporter',
      'compact',
      '--timeout',
      '15s',
      'tool/generate_store_screenshots_test.dart',
    ],
    environment: {...Platform.environment, 'SCREENSHOT_TARGET': target},
    runInShell: Platform.isWindows,
  );

  final generated = Completer<void>();
  final output = StringBuffer();
  final stdoutDone = _watchOutput(process.stdout, stdout, output, generated);
  final stderrDone = _watchOutput(process.stderr, stderr, output, generated);

  final outcome = await Future.any<Object>([
    generated.future.then((_) => 'generated'),
    process.exitCode.then((code) => code),
    Future<void>.delayed(const Duration(seconds: 25)).then((_) => 'timeout'),
  ]);

  if (outcome == 'generated') {
    await _stopProcessTree(process);
    await Future.wait([stdoutDone, stderrDone]);
    return true;
  }

  if (outcome == 'timeout') {
    await _stopProcessTree(process);
    await Future.wait([stdoutDone, stderrDone]);
    final generatedBeforeDeadline = output.toString().contains('Generated ');
    if (!generatedBeforeDeadline) {
      stderr.writeln('Timed out generating $target');
    }
    return generatedBeforeDeadline;
  }

  await Future.wait([stdoutDone, stderrDone]);
  final code = outcome as int;
  if (code != 0) {
    stderr.writeln('Failed generating $target (exit $code)');
    return false;
  }

  final generatedAfterExit = output.toString().contains('Generated ');
  if (!generatedAfterExit) {
    stderr.writeln('Worker exited before generating $target');
  }
  return generatedAfterExit;
}

Future<void> _stopProcessTree(Process process) async {
  if (Platform.isWindows) {
    await Process.run('taskkill', ['/PID', '${process.pid}', '/T', '/F']);
  } else {
    process.kill(ProcessSignal.sigkill);
  }
  await process.exitCode.timeout(
    const Duration(seconds: 5),
    onTimeout: () => -1,
  );
}

Future<void> _watchOutput(
  Stream<List<int>> stream,
  IOSink sink,
  StringBuffer output,
  Completer<void> generated,
) {
  final completer = Completer<void>();
  String tail = '';
  stream
      .transform(utf8.decoder)
      .listen(
        (text) {
          sink.write(text);
          if (!generated.isCompleted) {
            // Check the current chunk plus a small tail from the previous one
            // to catch cases where 'Generated ' is split across chunks.
            if ((tail + text).contains('Generated ')) {
              generated.complete();
            }
            // Keep the last 20 characters for the next split-check.
            final combined = tail + text;
            tail = combined.length > 20
                ? combined.substring(combined.length - 20)
                : combined;
          }
          output.write(text);
        },
        onError: completer.completeError,
        onDone: completer.complete,
        cancelOnError: true,
      );
  return completer.future;
}
