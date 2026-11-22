import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class DouyuAccountService extends GetxService {
  static DouyuAccountService get instance =>
      Get.find<DouyuAccountService>();

  var cookie = "";
  var hasCookie = false.obs;

  @override
  void onInit() {
    // 不随包预置任何登录态：默认匿名观看，Cookie 只能由用户自己导入。
    // （旧实现由 CI 从 Secret 注入一份真实登录 Cookie，等于让所有装包的人共用一个账号）
    cookie = LocalStorageService.instance
        .getValue(LocalStorageService.kDouyuCookie, "");
    hasCookie.value = cookie.isNotEmpty;
    setSite();
    super.onInit();
  }

  void setSite() {
    var site = (Sites.allSites[Constant.kDouyu]!.liveSite as DouyuSite);
    site.cookie = cookie;
  }

  void setCookie(String cookie) {
    this.cookie = cookie;
    LocalStorageService.instance
        .setValue(LocalStorageService.kDouyuCookie, cookie);
    LocalStorageService.instance
        .setValue(LocalStorageService.kDouyuCookieCleared, false);
    hasCookie.value = cookie.isNotEmpty;
    setSite();
  }

  void clearCookie() {
    cookie = "";
    LocalStorageService.instance
        .setValue(LocalStorageService.kDouyuCookie, "");
    // 标记用户主动清除，避免下次启动又回退到预置 Cookie
    LocalStorageService.instance
        .setValue(LocalStorageService.kDouyuCookieCleared, true);
    hasCookie.value = false;
    setSite();
  }
}
