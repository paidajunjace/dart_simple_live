import 'package:fvp/fvp.dart' as fvp;
import 'package:video_player/video_player.dart' as vp;

/// fvp（mdk-sdk）引擎自检：用第二个引擎打开同一条直播地址，量首帧耗时。
/// 只做对比与取数，不参与正常播放链路。
class EngineProbe {
  /// 返回一行可复制的结论。异常也返回文本，不抛。
  static Future<String> run(
    String url, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final sw = Stopwatch()..start();
    vp.VideoPlayerController? c;
    try {
      // 幂等：重复调用只会覆盖同一个平台实现
      fvp.registerWith();
      c = vp.VideoPlayerController.networkUrl(
        Uri.parse(url),
        httpHeaders: headers ?? const {},
      );
      await c.initialize().timeout(timeout);
      sw.stop();
      final w = c.value.size.width;
      final h = c.value.size.height;
      final d = c.value.duration;
      return "fvp 首帧 ${sw.elapsedMilliseconds}ms · ${w.toInt()}x${h.toInt()} · duration=$d";
    } catch (e) {
      sw.stop();
      return "fvp 失败(${sw.elapsedMilliseconds}ms): ${e.toString()}";
    } finally {
      try {
        await c?.dispose();
      } catch (_) {}
    }
  }
}
