import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/services/douyu_account_service.dart';

class DouyuWebLoginController extends BaseController {
  InAppWebViewController? webViewController;
  final CookieManager cookieManager = CookieManager.instance();

  void onWebViewCreated(InAppWebViewController controller) {
    webViewController = controller;
    webViewController!.loadUrl(
      urlRequest: URLRequest(
        url: WebUri("https://passport.douyu.com/login?passport_type=1"),
      ),
    );
  }

  void onLoadStop(InAppWebViewController controller, Uri? uri) async {
    await tryCaptureLogin();
  }

  /// 检查 douyu.com 域下是否已有登录态 Cookie(dy_ptkey)，
  /// 有则抓取全量 Cookie 交给 DouyuAccountService 并返回
  Future<bool> tryCaptureLogin() async {
    try {
      var cookies =
          await cookieManager.getCookies(url: WebUri("https://www.douyu.com/"));
      if (cookies.isEmpty) {
        return false;
      }
      var hasLogin = cookies.any((e) => e.name == "dy_ptkey" && e.value.isNotEmpty);
      if (!hasLogin) {
        return false;
      }
      var cookieStr = cookies.map((e) => "${e.name}=${e.value}").join("; ");
      Log.i("斗鱼网页登录成功，Cookie 长度 ${cookieStr.length}");
      DouyuAccountService.instance.setCookie(cookieStr);
      SmartDialog.showToast("斗鱼账号登录成功");
      Get.back();
      return true;
    } catch (e) {
      Log.logPrint(e);
      return false;
    }
  }
}