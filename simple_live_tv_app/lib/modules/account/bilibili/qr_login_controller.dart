import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_tv_app/app/log.dart';
import 'package:simple_live_tv_app/requests/http_client.dart';
import 'package:simple_live_tv_app/services/bilibili_account_service.dart';

enum QRStatus {
  loading,
  unscanned,
  scanned,
  expired,
  failed,
}

class BiliBiliQRLoginController extends GetxController {
  @override
  void onInit() {
    loadQRCode();
    super.onInit();
  }

  Timer? timer;

  var qrcodeUrl = "".obs;
  var qrcodeKey = "";

  /// 二维码状态
  /// - [0] 加载中
  /// - [1] 未扫描
  /// - [2] 已扫描，待确认
  /// - [3] 二维码已经失效
  /// - [4] 登录失败
  Rx<QRStatus> qrStatus = QRStatus.loading.obs;

  // ── WBI 签名（静态缓存，全局共享） ──
  static String _imgKey = '';
  static String _subKey = '';

  static const List<int> _mixinKeyEncTab = [
    46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35,
    27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13,
    37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4,
    22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52
  ];

  static String _getMixinKey(String origin) {
    return _mixinKeyEncTab.fold("", (s, i) => s + origin[i]).substring(0, 32);
  }

  static Future<void> _ensureWbiKeys() async {
    if (_imgKey.isNotEmpty && _subKey.isNotEmpty) return;
    var resp = await HttpClient.instance.getJson(
      'https://api.bilibili.com/x/web-interface/nav',
    );
    var imgUrl = resp["data"]["wbi_img"]["img_url"].toString();
    var subUrl = resp["data"]["wbi_img"]["sub_url"].toString();
    _imgKey = imgUrl.substring(imgUrl.lastIndexOf('/') + 1).split('.').first;
    _subKey = subUrl.substring(subUrl.lastIndexOf('/') + 1).split('.').first;
  }

  static Future<Map<String, String>> _getWbiSign(String url) async {
    await _ensureWbiKeys();
    var mixinKey = _getMixinKey(_imgKey + _subKey);
    var currentTime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    var queryParams = Map<String, String>.from(Uri.parse(url).queryParameters);
    queryParams["wts"] = currentTime.toString();

    Map<String, String> map = {};
    var sortedKeys = queryParams.keys.toList()..sort();
    for (var key in sortedKeys) {
      var value = queryParams[key]!;
      map[key] = value.split('').where((c) => "!'()*".contains(c) == false).join('');
    }
    var query = map.keys.map((key) => "$key=${Uri.encodeQueryComponent(map[key]!)}").join("&");
    var wbiSign = md5.convert(utf8.encode("$query$mixinKey")).toString();
    queryParams["w_rid"] = wbiSign;
    return queryParams;
  }

  void loadQRCode() async {
    try {
      qrStatus.value = QRStatus.loading;

      var wbiSign = await _getWbiSign(
        "https://passport.bilibili.com/x/passport-login/web/qrcode/generate",
      );
      var result = await HttpClient.instance.getJson(
        "https://passport.bilibili.com/x/passport-login/web/qrcode/generate",
        queryParameters: wbiSign,
      );
      if (result["code"] != 0) {
        throw result["message"];
      }
      qrcodeKey = result["data"]["qrcode_key"];
      qrcodeUrl.value = result["data"]["url"];
      qrStatus.value = QRStatus.unscanned;
      startPoll();
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast(e.toString());
      qrStatus.value = QRStatus.failed;
    }
  }

  void startPoll() {
    timer = Timer.periodic(
      const Duration(seconds: 3),
      (timer) {
        pollQRStatus();
      },
    );
  }

  void pollQRStatus() async {
    try {
      var wbiSign = await _getWbiSign(
        "https://passport.bilibili.com/x/passport-login/web/qrcode/poll?qrcode_key=$qrcodeKey",
      );
      var response = await HttpClient.instance.get(
        "https://passport.bilibili.com/x/passport-login/web/qrcode/poll",
        queryParameters: wbiSign,
      );
      if (response.data["code"] != 0) {
        throw response.data["message"];
      }
      var data = response.data["data"];
      var code = data["code"];
      if (code == 0) {
        var cookies = <String>[];
        response.headers["set-cookie"]?.forEach((element) {
          var cookie = element.split(";")[0];
          cookies.add(cookie);
        });
        if (cookies.isNotEmpty) {
          var cookieStr = cookies.join(";");
          Log.i(cookieStr);
          BiliBiliAccountService.instance.setCookie(cookieStr);
          await BiliBiliAccountService.instance.loadUserInfo();
          Get.back();
        }
      } else if (code == 86038) {
        qrStatus.value = QRStatus.expired;
        qrcodeKey = "";
        timer?.cancel();
      } else if (code == 86090) {
        qrStatus.value = QRStatus.scanned;
      }
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast(e.toString());
    }
  }

  @override
  void onClose() {
    timer?.cancel();
    super.onClose();
  }
}