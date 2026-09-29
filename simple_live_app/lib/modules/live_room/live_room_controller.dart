import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:share_plus/share_plus.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/modules/live_room/player/player_controller.dart';
import 'package:simple_live_app/modules/settings/danmu_settings_page.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/widgets/desktop_refresh_button.dart';
import 'package:simple_live_app/widgets/follow_user_item.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class LiveRoomController extends PlayerController with WidgetsBindingObserver {
  final Site pSite;
  final String pRoomId;
  late LiveDanmaku liveDanmaku;
  LiveRoomController({
    required this.pSite,
    required this.pRoomId,
  }) {
    rxSite = pSite.obs;
    rxRoomId = pRoomId.obs;
    liveDanmaku = site.liveSite.getDanmaku();
    // 抖音应该默认是竖屏的
    if (site.id == "douyin") {
      isVertical.value = true;
    }
  }

  late Rx<Site> rxSite;
  Site get site => rxSite.value;
  late Rx<String> rxRoomId;
  String get roomId => rxRoomId.value;

  Rx<LiveRoomDetail?> detail = Rx<LiveRoomDetail?>(null);
  var online = 0.obs;
  var followed = false.obs;
  var liveStatus = false.obs;
  RxList<LiveSuperChatMessage> superChats = RxList<LiveSuperChatMessage>();

  /// 滚动控制
  final ScrollController scrollController = ScrollController();

  /// 聊天信息
  RxList<LiveMessage> messages = RxList<LiveMessage>();

  /// 清晰度数据
  RxList<LivePlayQuality> qualites = RxList<LivePlayQuality>();

  /// 当前清晰度
  var currentQuality = -1;
  var currentQualityInfo = "".obs;

  /// 线路数据
  RxList<String> playUrls = RxList<String>();

  Map<String, String>? playHeaders;

  /// 当前线路
  var currentLineIndex = -1;
  var currentLineInfo = "".obs;

  /// 退出倒计时
  var countdown = 60.obs;

  Timer? autoExitTimer;

  /// 设置的自动关闭时间（分钟）
  var autoExitMinutes = 60.obs;

  ///是否延迟自动关闭
  var delayAutoExit = false.obs;

  /// 是否启用自动关闭
  var autoExitEnable = false.obs;

  /// 是否禁用自动滚动聊天栏
  /// - 当用户向上滚动聊天栏时，不再自动滚动
  var disableAutoScroll = false.obs;

  /// 是否处于后台
  var isBackground = false;

  /// 直播间加载失败
  var loadError = false.obs;
  Error? error;

  // 开播时长状态变量
  var liveDuration = "00:00:00".obs;
  Timer? _liveDurationTimer;

  @override
  void onInit() {
    WidgetsBinding.instance.addObserver(this);
    if (FollowService.instance.followList.isEmpty) {
      FollowService.instance.loadData();
    }
    initAutoExit();
    showDanmakuState.value = AppSettingsController.instance.danmuEnable.value;
    followed.value = DBService.instance.getFollowExist("${site.id}_$roomId");
    loadData();

    scrollController.addListener(scrollListener);

    super.onInit();
  }

  void scrollListener() {
    if (scrollController.position.userScrollDirection ==
        ScrollDirection.forward) {
      disableAutoScroll.value = true;
    }
  }

  /// 初始化自动关闭倒计时
  void initAutoExit() {
    if (AppSettingsController.instance.autoExitEnable.value) {
      autoExitEnable.value = true;
      autoExitMinutes.value =
          AppSettingsController.instance.autoExitDuration.value;
      setAutoExit();
    } else {
      autoExitMinutes.value =
          AppSettingsController.instance.roomAutoExitDuration.value;
    }
  }

  void setAutoExit() {
    if (!autoExitEnable.value) {
      autoExitTimer?.cancel();
      return;
    }
    autoExitTimer?.cancel();
    countdown.value = autoExitMinutes.value * 60;
    autoExitTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      countdown.value -= 1;
      if (countdown.value <= 0) {
        autoExitTimer?.cancel();
        var delay = await Utils.showAlertDialog("定时关闭已到时,是否延迟关闭?",
            title: "延迟关闭", confirm: "延迟", cancel: "关闭", selectable: true);
        if (delay) {
          timer.cancel();
          delayAutoExit.value = true;
          showAutoExitSheet();
          setAutoExit();
        } else {
          delayAutoExit.value = false;
          await WakelockPlus.disable();
          exit(0);
        }
      }
    });
  }
  // 弹窗逻辑

  void refreshRoom() {
    //messages.clear();
    superChats.clear();
    liveDanmaku.stop();

    loadData();
  }

  /// 聊天栏始终滚动到底部
  void chatScrollToBottom() {
    if (scrollController.hasClients) {
      // 如果手动上拉过，就不自动滚动到底部
      if (disableAutoScroll.value) {
        return;
      }
      scrollController.jumpTo(scrollController.position.maxScrollExtent);
    }
  }

  /// 初始化弹幕接收事件
  void initDanmau() {
    liveDanmaku.onMessage = onWSMessage;
    liveDanmaku.onClose = onWSClose;
    liveDanmaku.onReady = onWSReady;
  }

  /// 接收到WebSocket信息
  void onWSMessage(LiveMessage msg) {
    if (msg.type == LiveMessageType.chat) {
      if (messages.length > 200 && !disableAutoScroll.value) {
        messages.removeAt(0);
      } else if (disableAutoScroll.value && messages.length > 2000) {
        // 查看历史时不打断阅读，但给个上限防止无限堆积
        messages.removeRange(0, messages.length - 2000);
      }

      // 关键词屏蔽检查
      for (var keyword in AppSettingsController.instance.shieldList) {
        Pattern? pattern;
        if (Utils.isRegexFormat(keyword)) {
          String removedSlash = Utils.removeRegexFormat(keyword);
          try {
            pattern = RegExp(removedSlash);
          } catch (e) {
            // should avoid this during add keyword
            Log.d("关键词：$keyword 正则格式错误");
          }
        } else {
          pattern = keyword;
        }
        if (pattern != null && msg.message.contains(pattern)) {
          Log.d("关键词：$keyword\n已屏蔽消息内容：${msg.message}");
          return;
        }
      }

      messages.add(msg);

      WidgetsBinding.instance.addPostFrameCallback(
        (_) => chatScrollToBottom(),
      );
      if (!liveStatus.value || isBackground) {
        return;
      }

      addDanmaku([
        DanmakuContentItem(
          msg.message,
          color: Color.fromARGB(
            255,
            msg.color.r,
            msg.color.g,
            msg.color.b,
          ),
        ),
      ]);
    } else if (msg.type == LiveMessageType.online) {
      online.value = msg.data;
    } else if (msg.type == LiveMessageType.superChat) {
      superChats.add(msg.data);
    }
  }

  /// 添加一条系统消息
  void addSysMsg(String msg) {
    messages.add(
      LiveMessage(
        type: LiveMessageType.chat,
        userName: "LiveSysMessage",
        message: msg,
        color: LiveMessageColor.white,
      ),
    );
  }

  /// 接收到WebSocket关闭信息
  void onWSClose(String msg) {
    addSysMsg(msg);
  }

  /// WebSocket准备就绪
  void onWSReady() {
    addSysMsg("弹幕服务器连接正常");
  }

  /// 加载直播间信息
  void loadData() async {
    try {
      SmartDialog.showLoading(msg: "");
      loadError.value = false;
      error = null;
      update();
      addSysMsg("正在读取直播间信息");
      detail.value = await site.liveSite.getRoomDetail(roomId: roomId);

      if (site.id == Constant.kDouyin) {
        // 1.6.0之前收藏的WebRid
        // 1.6.0收藏的RoomID
        // 1.6.0之后改回WebRid
        if (detail.value!.roomId != roomId) {
          var oldId = roomId;
          rxRoomId.value = detail.value!.roomId;
          if (followed.value) {
            // 更新关注列表
            DBService.instance.deleteFollow("${site.id}_$oldId");
            DBService.instance.addFollow(
              FollowUser(
                id: "${site.id}_$roomId",
                roomId: roomId,
                siteId: site.id,
                userName: detail.value!.userName,
                face: detail.value!.userAvatar,
                addTime: DateTime.now(),
              ),
            );
          } else {
            followed.value =
                DBService.instance.getFollowExist("${site.id}_$roomId");
          }
        }
      }

      getSuperChatMessage();

      addHistory();
      // 确认房间关注状态
      followed.value = DBService.instance.getFollowExist("${site.id}_$roomId");
      online.value = detail.value!.online;
      liveStatus.value = detail.value!.status || detail.value!.isRecord;
      if (liveStatus.value) {
        getPlayQualites();
      }
      if (detail.value!.isRecord) {
        addSysMsg("当前主播未开播，正在轮播录像");
      }
      addSysMsg("开始连接弹幕服务器");
      initDanmau();
      liveDanmaku.start(detail.value?.danmakuData);
      startLiveDurationTimer(); // 启动开播时长定时器
    } catch (e) {
      Log.logPrint(e);
      //SmartDialog.showToast(e.toString());
      loadError.value = true;
      // 网络层的异常多是 Exception 而非 Error，直接 as Error 会二次抛 TypeError
      error = e is Error ? e : StateError(e.toString());
    } finally {
      SmartDialog.dismiss(status: SmartStatus.loading);
    }
  }

  /// 初始化播放器
  void getPlayQualites() async {
    qualites.clear();
    currentQuality = -1;

    try {
      var playQualites =
          await site.liveSite.getPlayQualites(detail: detail.value!);

      if (playQualites.isEmpty) {
        SmartDialog.showToast("无法读取播放清晰度");
        return;
      }
      qualites.value = playQualites;
      var qualityLevel = await getQualityLevel();
      if (qualityLevel == 2) {
        //最高
        currentQuality = 0;
      } else if (qualityLevel == 0) {
        //最低
        currentQuality = playQualites.length - 1;
      } else {
        //中间值
        int middle = (playQualites.length / 2).floor();
        currentQuality = middle;
      }

      final opened = await getPlayUrl();
      if (!opened) {
        // 首播也没切过去：交给恢复链（换线/重签/退避重试）
        recoverPlayback("openfail");
      }
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("无法读取播放清晰度");
    }
  }

  Future<int> getQualityLevel() async {
    var qualityLevel = AppSettingsController.instance.qualityLevel.value;
    try {
      var connectivityResult = await (Connectivity().checkConnectivity());
      if (connectivityResult.first == ConnectivityResult.mobile) {
        qualityLevel =
            AppSettingsController.instance.qualityLevelCellular.value;
      }
    } catch (e) {
      Log.logPrint(e);
    }
    return qualityLevel;
  }

  Future<bool> getPlayUrl() async {
    try {
      if (site.id == Constant.kDouyu) {
        // 斗鱼对登录态取流有单会话连接配额：旧连接被 CDN 掐成半开后仍占着
        // 会话名额，新签名请求会被静默吞掉。重签前彻底关播放器释放连接。
        try {
          await player.stop().timeout(const Duration(seconds: 2));
        } catch (e) {
          // 超时也继续：拿不到干净释放也要试新地址
          Log.d("stop 未完成(忽略): $e");
        }
      }
      playUrls.clear();
      currentQualityInfo.value = qualites[currentQuality].quality;
      currentLineInfo.value = "";
      currentLineIndex = -1;
      var playUrl = await site.liveSite.getPlayUrls(
          detail: detail.value!, quality: qualites[currentQuality]);
      if (playUrl.urls.isEmpty) {
        SmartDialog.showToast("无法读取播放地址");
        return false;
      }
      playUrls.value = playUrl.urls;
      playHeaders = playUrl.headers;
      currentLineIndex = 0;
      currentLineInfo.value = "线路${currentLineIndex + 1}";
      //重置错误次数
      mediaErrorRetryCount = 0;
      liveStatus.value = true;
      startStallWatchdog();
      var opened = await initPlaylist();
      if (!opened) {
        Log.d("首次 open 未生效，重试一次");
        opened = await initPlaylist();
      }
      if (!opened) {
        return false;
      }
      scheduleProactiveRefresh();
      return true;
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("获取播放地址失败");
      return false;
    }
  }

  void changePlayLine(int index) {
    currentLineIndex = index;
    //重置错误次数
    mediaErrorRetryCount = 0;
    setPlayer();
  }

  Future<bool> initPlaylist() async {
    currentLineInfo.value = "线路${currentLineIndex + 1}";
    errorMsg.value = "";

    var finalUrl = playUrls[currentLineIndex];
    if (AppSettingsController.instance.playerForceHttps.value) {
      finalUrl = finalUrl.replaceAll("http://", "https://");
    }

    // 播放器按平台分支取参数：斗鱼激进续流参数，其他平台原版参数
    douyuLive = site.id == Constant.kDouyu;

    // 初始化播放器并设置 ao 参数
    await initializePlayer();

    try {
      if (douyuLive) {
        // 斗鱼：只 open 单条媒体。Playlist 自动前进会与恢复链竞争，
        // 产生多条并发连接互相挤掉（斗鱼限制同房间并发连接数）
        await player.open(Media(finalUrl, httpHeaders: playHeaders));
      } else {
        // 其他平台：恢复原版 Playlist 行为，mpv 自动前进兜底
        final mediaList = playUrls.map((url) {
          var u = url;
          if (AppSettingsController.instance.playerForceHttps.value) {
            u = u.replaceAll("http://", "https://");
          }
          return Media(u, httpHeaders: playHeaders);
        }).toList();
        await player.open(Playlist(mediaList));
        return true;
      }
    } catch (e) {
      Log.logPrint(e);
      return false;
    }
    // open 返回≠切换生效：新签地址可能被 CDN 直接 404/403，
    // mpv 之后静默无 error/completed（05:47 事故），主动校验 8 秒
    for (var i = 0; i < 16; i++) {
      if (_closed) {
        return false;
      }
      await Future.delayed(const Duration(milliseconds: 500));
      // PlayerState 无 error 字段；playing=true 或探测到视频宽高即生效
      if (player.state.playing || (player.state.width ?? 0) > 0) {
        return true;
      }
    }
    Log.d("播放切换校验超时(8s)，判定本次取流未生效");
    return false;
  }

  Future<void> setPlayer() async {
    currentLineInfo.value = "线路${currentLineIndex + 1}";
    errorMsg.value = "";
    if (site.id != Constant.kDouyu) {
      // 原版：Playlist 内 jump（重放/换线都走这个）
      await player.jump(currentLineIndex);
      return;
    }
    final ok = await initPlaylist();
    if (!ok) {
      // 换线后也没真正切过去：继续走恢复链，而不是停在这里
      recoverPlayback("linefail");
    }
  }

  /// 断流恢复：同一线路快速重放两次 → 换线路 → 重新签名取新地址。
  /// 直播流地址只在取回那一刻新鲜，反复 jump 旧地址只会循环失败，
  /// 表现为画面反复刷新后停住；重签等价于网页播放器定时刷新取流。
  bool _recovering = false;
  DateTime _lastRecoverAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _recoverRetryTimer;
  Timer? _proactiveRefreshTimer;
  bool _closed = false;
  int _retryWaves = 0;

  Future<void> recoverPlayback(String from) async {
    if (_closed || !Get.isRegistered<LiveRoomController>()) {
      // 房间已销毁，拒绝僵尸恢复（退出房间后还在重签的 bug）
      return;
    }
    if (!liveStatus.value) {
      return;
    }
    final now = DateTime.now();
    if (_recovering ||
        now.difference(_lastRecoverAt) < const Duration(seconds: 2)) {
      Log.d("恢复进行中，忽略重复触发($from)");
      return;
    }
    _recovering = true;
    _lastRecoverAt = now;
    _recoverRetryTimer?.cancel();
    _recoverRetryTimer = null;
    try {
      if (site.id != Constant.kDouyu) {
        // 其他平台完全按原版节奏：同线路重放两次 → 换线 → 收口；
        // 不做激进的 stop/重签，正常抖动不会被误判成断流频繁重连
        if (mediaErrorRetryCount < 2) {
          Log.d("播放中断($from)，第${mediaErrorRetryCount + 1}次重放当前线路");
          if (mediaErrorRetryCount == 1) {
            await Future.delayed(const Duration(seconds: 1));
          }
          mediaErrorRetryCount += 1;
          setPlayer();
          return;
        }
        if (currentLineIndex + 1 < playUrls.length) {
          Log.d("播放中断($from)，切换下一条线路");
          mediaErrorRetryCount = 0;
          changePlayLine(currentLineIndex + 1);
          return;
        }
        if (from == "end") {
          liveStatus.value = false;
        } else {
          errorMsg.value = "播放失败";
          SmartDialog.showToast("播放失败");
        }
        return;
      }
      // 断过的地址重开只会活几秒（CDN 必掐），重放无效；优先换线
      if (currentLineIndex + 1 < playUrls.length) {
        Log.d("播放中断($from)，切换下一条线路");
        mediaErrorRetryCount = 0;
        changePlayLine(currentLineIndex + 1);
        return;
      }
      if (mediaRefreshCount < 4) {
        mediaRefreshCount += 1;
        Log.d("播放中断($from)，重新签名获取播放地址，第${mediaRefreshCount}次");
        final ok = await getPlayUrl();
        if (!ok) {
          // 取地址失败（限频/网络抖动）：5 秒后重试，别让恢复链断头
          _scheduleRecoveryRetry();
        }
        return;
      }
      Log.d("播放中断($from)，恢复手段已用尽，复核真实开播状态");
      await confirmLiveStatus();
    } catch (e) {
      Log.logPrint(e);
    } finally {
      _recovering = false;
    }
  }

  int mediaErrorRetryCount = 0;
  int mediaRefreshCount = 0;

  /// 播放位置看门狗：CDN 静默断流时 mpv 不报 error/completed，
  /// 画面直接冻结且恢复链没有入口。每 5 秒采样一次位置，
  /// playing 状态下连续两拍无进展即判定卡死，主动走恢复链。
  Timer? _stallWatchdog;
  int _lastWatchPosMs = -1;
  int _stallBeats = 0;

  void startStallWatchdog() {
    _stallWatchdog?.cancel();
    if (site.id != Constant.kDouyu) {
      // 原版平台不设位置看门狗：mpv 自身缓冲足以扛小抖动
      _stallWatchdog = null;
      return;
    }
    _lastWatchPosMs = -1;
    _stallBeats = 0;
    _stallWatchdog = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (!liveStatus.value) {
        _stallBeats = 0;
        return;
      }
      if (!player.state.playing) {
        // 用户主动暂停时不误判
        _stallBeats = 0;
        _lastWatchPosMs = -1;
        return;
      }
      final pos = player.state.position.inMilliseconds;
      if (pos == _lastWatchPosMs) {
        _stallBeats += 1;
        if (_stallBeats >= 2) {
          Log.d("看门狗：播放位置 10 秒无进展(pos=$pos)，触发断流恢复");
          _stallBeats = 0;
          _lastWatchPosMs = -1;
          recoverPlayback("stall");
        }
      } else {
        _stallBeats = 0;
        _lastWatchPosMs = pos;
      }
    });
  }

  void stopStallWatchdog() {
    _stallWatchdog?.cancel();
    _stallWatchdog = null;
  }

  /// 重签仍失败时向房间接口复核：仍在播就冷却后重试，真下播才置为暂停，
  /// 避免把 CDN 断流误判成"直播结束"
  Future<void> confirmLiveStatus() async {
    try {
      var living = await site.liveSite.getLiveStatus(roomId: roomId);
      if (living) {
        Log.d("复核：主播仍在直播，按取流失败处理，冷却后重取地址");
        errorMsg.value = "";
        mediaErrorRetryCount = 0;
        await Future.delayed(const Duration(seconds: 5));
        mediaRefreshCount = 0;
        final ok = await getPlayUrl();
        if (!ok) {
          _scheduleRecoveryRetry();
        }
      } else {
        liveStatus.value = false;
      }
    } catch (e) {
      // 复核请求失败不等于下播（可能只是限频/网络抖动），冷却后重试
      Log.logPrint(e);
      _scheduleRecoveryRetry();
    }
  }

  @override
  void mediaEnd() async {
    super.mediaEnd();
    Log.d("播放结束");
    await recoverPlayback("end");
  }

  @override
  void mediaError(String error) async {
    // 原实现误调 super.mediaEnd()，每次报错都会关掉屏幕常亮
    super.mediaError(error);
    Log.d("播放器错误：$error");
    await recoverPlayback("error");
  }

  @override
  void onPlaybackResumed() {
    // 真正播起来才算恢复，重置断流恢复计数与看门狗节拍
    mediaRefreshCount = 0;
    _stallBeats = 0;
    _retryWaves = 0;
    _recoverRetryTimer?.cancel();
    _recoverRetryTimer = null;
  }

  /// 断流恢复重试：mpv 进入 idle 或取地址失败后不再产生事件，
  /// 不补一个定时入口的话恢复链会停在原地（表现为直接暂停）
  void _scheduleRecoveryRetry() {
    _recoverRetryTimer?.cancel();
    _retryWaves += 1;
    final base = _retryWaves - 1;
    final pow = base > 4 ? 16 : (1 << base);
    var secs = 5 * pow;
    if (secs > 60) secs = 60;
    Log.d("恢复将在 ${secs}s 后重试（第$_retryWaves轮）");
    _recoverRetryTimer = Timer(Duration(seconds: secs), () {
      if (_closed || !Get.isRegistered<LiveRoomController>()) {
        return;
      }
      recoverPlayback("retry");
    });
  }

  /// 斗鱼 CDN 会掐断整 5 分钟的 FLV 连接（实测两次恰好 300s），
  /// 断开后旧地址重开只能活几秒。在 4 分 30 秒主动重签换新地址，
  /// 把被动死亡变成一次 1~2 秒的主动小重连
  void scheduleProactiveRefresh() {
    _proactiveRefreshTimer?.cancel();
    // 主动续流只针对斗鱼：它对 FLV 连接整 300 秒必掐，不提前重签必黑屏。
    // 其他平台（B站/虎牙/抖音）按各自取流节奏走，不做定时打断
    if (site.id != Constant.kDouyu) {
      return;
    }
    _proactiveRefreshTimer = Timer(const Duration(seconds: 270), () {
      if (_closed || !Get.isRegistered<LiveRoomController>()) {
        return;
      }
      if (!liveStatus.value) {
        return;
      }
      Log.d("主动重签：CDN 5 分钟掐断窗口前刷新取流地址");
      if (_recovering) {
        return;
      }
      // 纳入恢复锁：getPlayUrl 里的 player.stop 会引发 completed 事件，
      // 不加锁会再拉起一条并行的恢复链
      _recovering = true;
      _lastRecoverAt = DateTime.now();
      getPlayUrl().then((ok) {
        _recovering = false;
        if (!ok) {
          // 主动重签被频控挡下时旧流必在 300s 被掐（06:47 事故），
          // 立即进恢复链，而不是等播放结束后才开始挣扎
          Log.d("主动重签未生效，转入恢复链");
          recoverPlayback("proactivefail");
        }
      });
    });
  }

  void cancelProactiveRefresh() {
    _proactiveRefreshTimer?.cancel();
    _proactiveRefreshTimer = null;
  }

  /// 读取SC
  void getSuperChatMessage() async {
    try {
      var sc =
          await site.liveSite.getSuperChatMessage(roomId: detail.value!.roomId);
      superChats.addAll(sc);
    } catch (e) {
      Log.logPrint(e);
      addSysMsg("SC读取失败");
    }
  }

  /// 移除掉已到期的SC
  void removeSuperChats() async {
    var now = DateTime.now().millisecondsSinceEpoch;
    superChats.value = superChats
        .where((x) => x.endTime.millisecondsSinceEpoch > now)
        .toList();
  }

  /// 添加历史记录
  void addHistory() {
    if (detail.value == null) {
      return;
    }
    var id = "${site.id}_$roomId";
    var history = DBService.instance.getHistory(id);
    if (history != null) {
      history.updateTime = DateTime.now();
    }
    history ??= History(
      id: id,
      roomId: roomId,
      siteId: site.id,
      userName: detail.value?.userName ?? "",
      face: detail.value?.userAvatar ?? "",
      updateTime: DateTime.now(),
    );

    DBService.instance.addOrUpdateHistory(history);
  }

  /// 关注用户
  void followUser() {
    if (detail.value == null) {
      return;
    }
    var id = "${site.id}_$roomId";
    DBService.instance.addFollow(
      FollowUser(
        id: id,
        roomId: roomId,
        siteId: site.id,
        userName: detail.value?.userName ?? "",
        face: detail.value?.userAvatar ?? "",
        addTime: DateTime.now(),
      ),
    );
    followed.value = true;
    EventBus.instance.emit(Constant.kUpdateFollow, id);
  }

  /// 取消关注用户
  void removeFollowUser() async {
    if (detail.value == null) {
      return;
    }
    if (!await Utils.showAlertDialog("确定要取消关注该用户吗？", title: "取消关注")) {
      return;
    }

    var id = "${site.id}_$roomId";
    DBService.instance.deleteFollow(id);
    followed.value = false;
    EventBus.instance.emit(Constant.kUpdateFollow, id);
  }

  void share() {
    if (detail.value == null) {
      return;
    }
    SharePlus.instance.share(ShareParams(uri: Uri.parse(detail.value!.url)));
  }

  void copyUrl() {
    if (detail.value == null) {
      return;
    }
    Utils.copyToClipboard(detail.value!.url);
    SmartDialog.showToast("已复制直播间链接");
  }

  /// 复制新生成的直播流
  void copyPlayUrl() async {
    // 未开播不复制
    if (!liveStatus.value) {
      return;
    }
    var playUrl = await site.liveSite
        .getPlayUrls(detail: detail.value!, quality: qualites[currentQuality]);
    if (playUrl.urls.isEmpty) {
      SmartDialog.showToast("无法读取播放地址");
      return;
    }
    Utils.copyToClipboard(playUrl.urls.first);
    SmartDialog.showToast("已复制播放直链");
  }

  /// 底部打开播放器设置
  void showDanmuSettingsSheet() {
    Utils.showBottomSheet(
      title: "弹幕设置",
      child: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          DanmuSettingsView(
            danmakuController: danmakuController,
            onTapDanmuShield: () {
              Get.back();
              showDanmuShield();
            },
          ),
        ],
      ),
    );
  }

  void showVolumeSlider(BuildContext targetContext) {
    SmartDialog.showAttach(
      targetContext: targetContext,
      alignment: Alignment.topCenter,
      displayTime: const Duration(seconds: 3),
      maskColor: const Color(0x00000000),
      builder: (context) {
        return Container(
          decoration: BoxDecoration(
            borderRadius: AppStyle.radius12,
            color: Theme.of(context).cardColor,
          ),
          padding: AppStyle.edgeInsetsA4,
          child: Obx(
            () => SizedBox(
              width: 200,
              child: Slider(
                min: 0,
                max: 100,
                value: AppSettingsController.instance.playerVolume.value,
                onChanged: (newValue) {
                  player.setVolume(newValue);
                  AppSettingsController.instance.setPlayerVolume(newValue);
                },
              ),
            ),
          ),
        );
      },
    );
  }

  void showQualitySheet() {
    Utils.showBottomSheet(
      title: "切换清晰度",
      child: RadioGroup(
        groupValue: currentQuality,
        onChanged: (e) {
          Get.back();
          currentQuality = e ?? 0;
          getPlayUrl();
        },
        child: ListView.builder(
          itemCount: qualites.length,
          itemBuilder: (_, i) {
            var item = qualites[i];
            return RadioListTile(
              value: i,
              title: Text(item.quality),
            );
          },
        ),
      ),
    );
  }

  void showPlayUrlsSheet() {
    Utils.showBottomSheet(
      title: "切换线路",
      child: RadioGroup(
        groupValue: currentLineIndex,
        onChanged: (e) {
          Get.back();
          //currentLineIndex = i;
          //setPlayer();
          changePlayLine(e ?? 0);
        },
        child: ListView.builder(
          itemCount: playUrls.length,
          itemBuilder: (_, i) {
            return RadioListTile(
              value: i,
              title: Text("线路${i + 1}"),
              secondary: Text(
                playUrls[i].contains(".flv") ? "FLV" : "HLS",
              ),
            );
          },
        ),
      ),
    );
  }

  void showPlayerSettingsSheet() {
    Utils.showBottomSheet(
      title: "画面尺寸",
      child: Obx(
        () => RadioGroup(
          groupValue: AppSettingsController.instance.scaleMode.value,
          onChanged: (e) {
            AppSettingsController.instance.setScaleMode(e ?? 0);
            updateScaleMode();
          },
          child: ListView(
            padding: AppStyle.edgeInsetsV12,
            children: const [
              RadioListTile(
                value: 0,
                title: Text("适应"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 1,
                title: Text("拉伸"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 2,
                title: Text("铺满"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 3,
                title: Text("16:9"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 4,
                title: Text("4:3"),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void showDanmuShield() {
    TextEditingController keywordController = TextEditingController();

    void addKeyword() {
      if (keywordController.text.isEmpty) {
        SmartDialog.showToast("请输入关键词");
        return;
      }

      AppSettingsController.instance
          .addShieldList(keywordController.text.trim());
      keywordController.text = "";
    }

    Utils.showBottomSheet(
      title: "关键词屏蔽",
      child: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          TextField(
            controller: keywordController,
            decoration: InputDecoration(
              contentPadding: AppStyle.edgeInsetsH12,
              border: const OutlineInputBorder(),
              hintText: "请输入关键词",
              suffixIcon: TextButton.icon(
                onPressed: addKeyword,
                icon: const Icon(Icons.add),
                label: const Text("添加"),
              ),
            ),
            onSubmitted: (e) {
              addKeyword();
            },
          ),
          AppStyle.vGap12,
          Obx(
            () => Text(
              "已添加${AppSettingsController.instance.shieldList.length}个关键词（点击移除）",
              style: Get.textTheme.titleSmall,
            ),
          ),
          AppStyle.vGap12,
          Obx(
            () => Wrap(
              runSpacing: 12,
              spacing: 12,
              children: AppSettingsController.instance.shieldList
                  .map(
                    (item) => InkWell(
                      borderRadius: AppStyle.radius24,
                      onTap: () {
                        AppSettingsController.instance.removeShieldList(item);
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey),
                          borderRadius: AppStyle.radius24,
                        ),
                        padding: AppStyle.edgeInsetsH12.copyWith(
                          top: 4,
                          bottom: 4,
                        ),
                        child: Text(
                          item,
                          style: Get.textTheme.bodyMedium,
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }

  void showFollowUserSheet() {
    Utils.showBottomSheet(
      title: "关注列表",
      child: Obx(
        () => Stack(
          children: [
            RefreshIndicator(
              onRefresh: FollowService.instance.loadData,
              child: ListView.builder(
                itemCount: FollowService.instance.liveList.length,
                itemBuilder: (_, i) {
                  var item = FollowService.instance.liveList[i];
                  return Obx(
                    () => FollowUserItem(
                      item: item,
                      playing: rxSite.value.id == item.siteId &&
                          rxRoomId.value == item.roomId,
                      onTap: () {
                        Get.back();
                        resetRoom(
                          Sites.allSites[item.siteId]!,
                          item.roomId,
                        );
                      },
                    ),
                  );
                },
              ),
            ),
            if (Platform.isLinux || Platform.isWindows || Platform.isMacOS)
              Positioned(
                right: 12,
                bottom: 12,
                child: Obx(
                  () => DesktopRefreshButton(
                    refreshing: FollowService.instance.updating.value,
                    onPressed: FollowService.instance.loadData,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void showAutoExitSheet() {
    if (AppSettingsController.instance.autoExitEnable.value &&
        !delayAutoExit.value) {
      SmartDialog.showToast("已设置了全局定时关闭");
      return;
    }
    Utils.showBottomSheet(
      title: "定时关闭",
      child: ListView(
        children: [
          Obx(
            () => SwitchListTile(
              title: Text(
                "启用定时关闭",
                style: Get.textTheme.titleMedium,
              ),
              value: autoExitEnable.value,
              onChanged: (e) {
                autoExitEnable.value = e;

                setAutoExit();
                //controller.setAutoExitEnable(e);
              },
            ),
          ),
          Obx(
            () => ListTile(
              enabled: autoExitEnable.value,
              title: Text(
                "自动关闭时间：${autoExitMinutes.value ~/ 60}小时${autoExitMinutes.value % 60}分钟",
                style: Get.textTheme.titleMedium,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                var value = await showTimePicker(
                  context: Get.context!,
                  initialTime: TimeOfDay(
                    hour: autoExitMinutes.value ~/ 60,
                    minute: autoExitMinutes.value % 60,
                  ),
                  initialEntryMode: TimePickerEntryMode.inputOnly,
                  builder: (_, child) {
                    return MediaQuery(
                      data: Get.mediaQuery.copyWith(
                        alwaysUse24HourFormat: true,
                      ),
                      child: child!,
                    );
                  },
                );
                if (value == null || (value.hour == 0 && value.minute == 0)) {
                  return;
                }
                var duration =
                    Duration(hours: value.hour, minutes: value.minute);
                autoExitMinutes.value = duration.inMinutes;
                AppSettingsController.instance
                    .setRoomAutoExitDuration(autoExitMinutes.value);
                //setAutoExitDuration(duration.inMinutes);
                setAutoExit();
              },
            ),
          ),
        ],
      ),
    );
  }

  void openNaviteAPP() async {
    var naviteUrl = "";
    var webUrl = "";
    if (site.id == Constant.kBiliBili) {
      naviteUrl = "bilibili://live/${detail.value?.roomId}";
      webUrl = "https://live.bilibili.com/${detail.value?.roomId}";
    } else if (site.id == Constant.kDouyin) {
      var args = detail.value?.danmakuData as DouyinDanmakuArgs;
      naviteUrl = "snssdk1128://webcast_room?room_id=${args.roomId}";
      webUrl = "https://live.douyin.com/${args.webRid}";
    } else if (site.id == Constant.kHuya) {
      var args = detail.value?.danmakuData as HuyaDanmakuArgs;
      naviteUrl =
          "yykiwi://homepage/index.html?banneraction=https%3A%2F%2Fdiy-front.cdn.huya.com%2Fzt%2Ffrontpage%2Fcc%2Fupdate.html%3Fhyaction%3Dlive%26channelid%3D${args.subSid}%26subid%3D${args.subSid}%26liveuid%3D${args.subSid}%26screentype%3D1%26sourcetype%3D0%26fromapp%3Dhuya_wap%252Fclick%252Fopen_app_guide%26&fromapp=huya_wap/click/open_app_guide";
      webUrl = "https://www.huya.com/${detail.value?.roomId}";
    } else if (site.id == Constant.kDouyu) {
      naviteUrl =
          "douyulink://?type=90001&schemeUrl=douyuapp%3A%2F%2Froom%3FliveType%3D0%26rid%3D${detail.value?.roomId}";
      webUrl = "https://www.douyu.com/${detail.value?.roomId}";
    }
    try {
      await launchUrlString(naviteUrl, mode: LaunchMode.externalApplication);
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("无法打开APP，将使用浏览器打开");
      await launchUrlString(webUrl, mode: LaunchMode.externalApplication);
    }
  }

  void resetRoom(Site site, String roomId) async {
    if (this.site == site && this.roomId == roomId) {
      return;
    }

    rxSite.value = site;
    rxRoomId.value = roomId;

    // 清除全部消息
    liveDanmaku.stop();
    messages.clear();
    superChats.clear();
    danmakuController?.clear();

    // 重新设置LiveDanmaku
    liveDanmaku = site.liveSite.getDanmaku();

    // 停止播放
    await player.stop();

    // 刷新信息
    loadData();
  }

  void copyErrorDetail() {
    Utils.copyToClipboard('''直播平台：${rxSite.value.name}
房间号：${rxRoomId.value}
错误信息：
${error?.toString()}
----------------
${error?.stackTrace}''');
    SmartDialog.showToast("已复制错误信息");
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.paused) {
      Log.d("进入后台");
      //进入后台，关闭弹幕
      danmakuController?.clear();
      isBackground = true;
    } else
    //返回前台
    if (state == AppLifecycleState.resumed) {
      Log.d("返回前台");
      isBackground = false;
    }
  }

  // 用于启动开播时长计算和更新的函数
  void startLiveDurationTimer() {
    // 如果不是直播状态或者 showTime 为空，则不启动定时器
    if (!(detail.value?.status ?? false) || detail.value?.showTime == null) {
      liveDuration.value = "00:00:00"; // 未开播时显示 00:00:00
      _liveDurationTimer?.cancel();
      return;
    }

    try {
      int startTimeStamp = int.parse(detail.value!.showTime!);
      // 取消之前的定时器
      _liveDurationTimer?.cancel();
      // 创建新的定时器，每秒更新一次
      _liveDurationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        int currentTimeStamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        int durationInSeconds = currentTimeStamp - startTimeStamp;

        int hours = durationInSeconds ~/ 3600;
        int minutes = (durationInSeconds % 3600) ~/ 60;
        int seconds = durationInSeconds % 60;

        String formattedDuration =
            '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
        liveDuration.value = formattedDuration;
      });
    } catch (e) {
      liveDuration.value = "--:--:--"; // 错误时显示 --:--:--
    }
  }

  @override
  void onClose() {
    _closed = true;
    WidgetsBinding.instance.removeObserver(this);
    scrollController.removeListener(scrollListener);
    autoExitTimer?.cancel();

    liveDanmaku.stop();
    danmakuController = null;
    _liveDurationTimer?.cancel(); // 页面关闭时取消定时器
    stopStallWatchdog();
    _recoverRetryTimer?.cancel();
    cancelProactiveRefresh();
    super.onClose();
  }
}
