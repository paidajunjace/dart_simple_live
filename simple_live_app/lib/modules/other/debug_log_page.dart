import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/log.dart';

class DebugLogPage extends StatelessWidget {
  const DebugLogPage({Key? key}) : super(key: key);

  /// 导出 = 磁盘日志（最多 3 个最新文件）+ 内存日志，合并成一个文件后分享。
  /// 原实现只导出内存那 2000 条，appSupport/log 下的完整日志没进文件；
  /// 且没有 try/catch，写盘或分享失败时按钮点了没有任何反馈。
  Future<void> _exportLogs() async {
    try {
      final buffer = StringBuffer();
      buffer.writeln("==== 磁盘日志 ====");
      final supportDir = await getApplicationSupportDirectory();
      final logDir = Directory("${supportDir.path}/log");
      if (await logDir.exists()) {
        final files = logDir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith(".log"))
            .toList()
          ..sort(
              (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
        if (files.isEmpty) {
          buffer.writeln("（空：日志开关未开启，或本次冷启动后尚未写入）");
        } else {
          for (final f in files.take(3)) {
            buffer.writeln("---- ${p.basename(f.path)} ----");
            buffer.writeln(await f.readAsString());
          }
        }
      } else {
        buffer.writeln("（无 log 目录：设置里的日志开关未开启）");
      }

      buffer.writeln("");
      buffer.writeln("==== 内存日志（最近 ${Log.debugLogs.length} 条） ====");
      buffer.writeln(
          Log.debugLogs.map((x) => "${x.datetime}\r\n${x.content}").join("\r\n\r\n"));

      final dir = await getApplicationDocumentsDirectory();
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(":", "-")
          .replaceAll(".", "-");
      final out = File("${dir.path}/simple_live_log_${stamp}.log");
      await out.writeAsString(buffer.toString(), flush: true);
      final size = await out.length();

      SmartDialog.showToast("已生成 ${p.basename(out.path)}（${size ~/ 1024} KB）");
      await SharePlus.instance.share(
        ShareParams(files: [XFile(out.path)]),
      );
    } catch (e) {
      SmartDialog.showToast("导出失败：${e}");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Log"),
        actions: [
          IconButton(
            onPressed: _exportLogs,
            icon: const Icon(Icons.save),
          ),
          IconButton(
            onPressed: () {
              Log.debugLogs.clear();
            },
            icon: const Icon(Icons.clear_all),
          ),
        ],
      ),
      body: Obx(
        () => ListView.separated(
          itemCount: Log.debugLogs.length,
          separatorBuilder: (_, i) => const Divider(),
          padding: AppStyle.edgeInsetsA12,
          itemBuilder: (_, i) {
            var item = Log.debugLogs[i];
            return SelectableText(
              "${item.datetime.toString()}\r\n${item.content}",
              style: TextStyle(
                color: item.color,
                fontSize: 12,
              ),
            );
          },
        ),
      ),
    );
  }
}
