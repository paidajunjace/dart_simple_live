import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/services/douyu_cookie_secret.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class DouyuAccountService extends GetxService {
  static DouyuAccountService get instance =>
      Get.find<DouyuAccountService>();

  var cookie = "";
  var hasCookie = false.obs;

  @override
  void onInit() {
    final bool cleared = LocalStorageService.instance
        .getValue(LocalStorageService.kDouyuCookieCleared, false);
    cookie = LocalStorageService.instance
        .getValue(LocalStorageService.kDouyuCookie, "");
    // 首次安装未手动设置且未主动清除时，使用本地预置的私人登录 Cookie，使安装即可用
    if (!cleared && cookie.isEmpty) cookie = kPrefilledDouyuCookie;
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
