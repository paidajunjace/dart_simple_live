import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/modules/mine/account/douyu/douyu_web_login_controller.dart';

class DouyuWebLoginPage extends GetView<DouyuWebLoginController> {
  const DouyuWebLoginPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("斗鱼账号登录"),
        actions: [
          TextButton.icon(
            onPressed: () => controller.tryCaptureLogin(),
            icon: const Icon(Icons.check_circle_outline),
            label: const Text("我已登录"),
          ),
        ],
      ),
      body: Column(
        children: [
          const Material(
            color: Colors.transparent,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Text(
                "在页面中登录你的斗鱼账号，登录成功后会自动返回并保存登录状态，之后将使用网页同款取流方式观看。",
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
          ),
          Expanded(
            child: InAppWebView(
              onWebViewCreated: controller.onWebViewCreated,
              onLoadStop: controller.onLoadStop,
              initialSettings: InAppWebViewSettings(
                userAgent:
                    "Mozilla/5.0 (Linux; Android 11; Pad) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36",
                useShouldOverrideUrlLoading: true,
              ),
              shouldOverrideUrlLoading: (webController, navigationAction) async {
                return NavigationActionPolicy.ALLOW;
              },
            ),
          ),
        ],
      ),
    );
  }
}