import 'package:simple_live_core/src/douyu/douyu_play_parser.dart';
import 'package:test/test.dart';

void main() {
  group('DouyuPlayParser.parseUrl', () {
    test('rtmp 正常且有 HTML 转义', () {
      final body = <String, Object>{
        'error': 0,
        'data': <String, Object>{
          'rtmp_url': 'https://hwa.douyucdn2.cn/live',
          'rtmp_live': '11395024rFnjHwaO_4000.flv?wsAuth=a&amp;token=b',
        },
      };
      expect(
        DouyuPlayParser.parseUrl(body),
        'https://hwa.douyucdn2.cn/live/11395024rFnjHwaO_4000.flv?wsAuth=a&token=b',
      );
    });

    test('cdn 基础地址带尾斜杠时不产生双斜杠', () {
      final body = <String, Object>{
        'data': <String, Object>{
          'rtmp_url': 'https://a.douyucdn.cn/live/',
          'rtmp_live': 'x.flv',
        },
      };
      expect(DouyuPlayParser.parseUrl(body), 'https://a.douyucdn.cn/live/x.flv');
    });

    test('rtmp 缺失时回退 mixed 混合流', () {
      final body = <String, Object>{
        'data': <String, Object>{
          'rtmp_url': '',
          'rtmp_live': '',
          'mixed_url': 'https://mixed.douyucdn.cn/live',
          'mixed_live': 'room.m3u8',
        },
      };
      expect(DouyuPlayParser.parseUrl(body), 'https://mixed.douyucdn.cn/live/room.m3u8');
    });

    test('只有 av1_url 时直接返回', () {
      final body = <String, Object>{
        'data': <String, Object>{'av1_url': 'https://av1.douyucdn.cn/live/room.flv'},
      };
      expect(DouyuPlayParser.parseUrl(body), 'https://av1.douyucdn.cn/live/room.flv');
    });

    test('无任何可用地址返回 null', () {
      final body = <String, Object>{'data': <String, Object>{}};
      expect(DouyuPlayParser.parseUrl(body), isNull);
    });

    test('响应为空返回 null', () {
      expect(DouyuPlayParser.parseUrl(null), isNull);
    });
  });

  group('DouyuPlayParser.describeError', () {
    test('error=0 且 data 正常时无错误', () {
      final body = <String, Object>{
        'error': 0,
        'data': <String, Object>{'rtmp_url': 'https://x', 'rtmp_live': 'y.flv'},
      };
      expect(DouyuPlayParser.describeError(body), isNull);
    });

    test('error!=0 时带出 msg', () {
      final body = <String, Object>{'error': 1, 'msg': '房间不存在'};
      final desc = DouyuPlayParser.describeError(body);
      expect(desc, isNotNull);
      expect(desc, contains('房间不存在'));
      expect(DouyuPlayParser.parseUrl(body), isNull);
    });

    test('缺少 data 字段时报结构异常', () {
      final body = <String, Object>{'error': 0};
      expect(DouyuPlayParser.describeError(body), '响应缺少 data 字段');
    });

    test('空响应报错', () {
      expect(DouyuPlayParser.describeError(null), '响应为空');
    });
  });
}
