import 'package:html_unescape/html_unescape.dart';

/// 斗鱼 getH5Play 响应的纯函数解析器。
///
/// 抽出来的目的：把「响应结构 -> 播放地址 / 错误描述」的判断从网络调用里剥离，
/// 使它可以离线单测，不需要真实请求斗鱼。
class DouyuPlayParser {
  /// 解析播放地址。
  ///
  /// 优先级：rtmp_url + rtmp_live -> mixed_url + mixed_live（混合流）-> av1_url。
  /// 无可用地址时返回 null。
  static String? parseUrl(Map<Object?, Object?>? body) {
    if (body == null) {
      return null;
    }
    final data = body['data'];
    if (data is! Map) {
      return null;
    }
    final pairs = <List<Object?>>[
      [data['rtmp_url'], data['rtmp_live']],
      [data['mixed_url'], data['mixed_live']],
    ];
    for (final pair in pairs) {
      final base = pair[0];
      final path = pair[1];
      if (base is String && base.isNotEmpty && path is String && path.isNotEmpty) {
        return _join(base, path);
      }
    }
    final av1 = data['av1_url'];
    if (av1 is String && av1.isNotEmpty) {
      return av1;
    }
    return null;
  }

  /// 业务错误描述；响应正常时返回 null。
  static String? describeError(Map<Object?, Object?>? body) {
    if (body == null) {
      return '响应为空';
    }
    final error = body['error'];
    if (error != null && error.toString() != '0') {
      return 'error=$error msg=${body['msg'] ?? ''}';
    }
    if (body['data'] is! Map) {
      return '响应缺少 data 字段';
    }
    return null;
  }

  static String _join(String base, String path) {
    final trimmed = base.endsWith('/')
        ? base.substring(0, base.length - 1)
        : base;
    return '$trimmed/${HtmlUnescape().convert(path)}';
  }
}
