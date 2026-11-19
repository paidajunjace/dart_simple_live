package com.yg.didchange;

import android.util.Log;

import java.io.FileOutputStream;
import java.io.OutputStreamWriter;
import java.io.Writer;
import java.lang.reflect.Method;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;

import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;
import de.robv.android.xposed.callbacks.XC_LoadPackage.LoadPackageParam;

/**
 * 斗鱼 App 取流取证：把 appGetPlayer 的响应体落盘。
 * 只读，不改请求/响应，不触碰登录态。
 *
 * 目标类来自 jadx 反编译 classes12.dex：
 *   com.douyu.sdk.net.interceptor.RequestInterceptor#intercept(okhttp3.Interceptor.Chain)
 *   com.douyu.sdk.playerframework.business.live.liveuser.rtmp.net.PlayerApi
 */
final class DouyuCapture {

    private static final String TAG = "DYCapture";
    private static final String LOG_PATH = "/sdcard/DYCapture.log";
    private static final String FILTER = "appGetPlayer";
    private static final Object LOCK = new Object();

    private DouyuCapture() {}

    static void hook(LoadPackageParam lpp) {
        hookInterceptor(lpp, "com.douyu.sdk.net.interceptor.RequestInterceptor");
        // 兜底：老版本可能放在这个包下
        hookInterceptor(lpp, "com.douyu.sdk.net.RequestInterceptor");
    }

    private static void hookInterceptor(LoadPackageParam lpp, String className) {
        try {
            Class<?> clazz = XposedHelpers.findClass(className, lpp.classLoader);
            Method target = null;
            for (Method m : clazz.getDeclaredMethods()) {
                if (!"intercept".equals(m.getName())) {
                    continue;
                }
                if (m.getParameterTypes().length == 1) {
                    target = m;
                    break;
                }
            }
            if (target == null) {
                log("未找到 intercept: " + className);
                return;
            }
            XposedBridge.hookMethod(target, new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    try {
                        Object response = param.getResult();
                        if (response == null) {
                            return;
                        }
                        Object request = XposedHelpers.callMethod(response, "request");
                        String url = String.valueOf(XposedHelpers.callMethod(request, "url"));
                        if (url == null || !url.contains(FILTER)) {
                            return;
                        }
                        Object peek = XposedHelpers.callMethod(response, "peekBody", 2 * 1024 * 1024L);
                        String body = String.valueOf(XposedHelpers.callMethod(peek, "string"));
                        dump(url + "\n" + body + "\n---\n");
                    } catch (Throwable t) {
                        log("读取响应失败: " + t);
                    }
                }
            });
            log("已 hook " + className);
        } catch (Throwable t) {
            log("hook " + className + " 失败: " + t);
        }
    }

    private static void dump(String text) {
        synchronized (LOCK) {
            Writer w = null;
            try {
                w = new OutputStreamWriter(new FileOutputStream(LOG_PATH, true), "UTF-8");
                w.write("[" + new SimpleDateFormat("HH:mm:ss", Locale.US).format(new Date()) + "] " + text);
                w.flush();
            } catch (Throwable t) {
                log("写日志失败: " + t);
            } finally {
                if (w != null) {
                    try {
                        w.close();
                    } catch (Throwable ignored) {
                    }
                }
            }
        }
    }

    static void log(String msg) {
        Log.i(TAG, msg);
        XposedBridge.log(TAG + ": " + msg);
    }
}
