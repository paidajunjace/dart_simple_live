package com.yg.didchange;

import android.app.Application;
import android.content.Context;
import android.util.Log;

import java.io.File;
import java.io.FileOutputStream;
import java.io.OutputStreamWriter;
import java.io.Writer;
import java.lang.reflect.Method;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;
import java.util.concurrent.atomic.AtomicInteger;

import de.robv.android.xposed.AndroidAppHelper;
import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;
import de.robv.android.xposed.callbacks.XC_LoadPackage.LoadPackageParam;

/**
 * 斗鱼 App 取流取证。只读响应，不改请求。
 *
 * 日志位置按优先级找第一个可写的：
 *   1) <externalFilesDir>/DYCapture.log   (/sdcard/Android/data/com.duowan.kiwi/files/)
 *   2) <filesDir>/DYCapture.log
 *   3) /sdcard/DYCapture.log              (老系统/有存储权限时)
 * 三个都失败就只打 Logcat（tag: DYCapture）。
 */
final class DouyuCapture {

    private static final String TAG = "DYCapture";
    private static final String FILE_NAME = "DYCapture.log";
    private static final Object LOCK = new Object();
    private static final AtomicInteger SEEN = new AtomicInteger();
    private static final AtomicInteger DUMPED = new AtomicInteger();
    private static volatile File sLogFile;
    private static volatile boolean sPathResolved;

    private DouyuCapture() {}

    static void hook(LoadPackageParam lpp) {
        log("hook 开始, pkg=" + lpp.packageName + " loader=" + lpp.classLoader);
        resolveLogFile();
        String[] candidates = {
                "com.douyu.sdk.net.interceptor.RequestInterceptor",
                "com.douyu.sdk.net.RequestInterceptor",
        };
        boolean any = false;
        for (String cn : candidates) {
            any |= hookInterceptor(lpp, cn);
        }
        if (!any) {
            log("两个候选类都没 hook 上，把日志发给开发者定位");
        }
        log("日志文件路径 = " + (sLogFile == null ? "(不可写，仅 Logcat)" : sLogFile.getAbsolutePath()));
    }

    private static boolean hookInterceptor(LoadPackageParam lpp, String className) {
        try {
            Class<?> clazz = XposedHelpers.findClass(className, lpp.classLoader);
            log("找到类 " + className + " 方法数=" + clazz.getDeclaredMethods().length);
            int hooked = 0;
            for (Method m : clazz.getDeclaredMethods()) {
                if (!"intercept".equals(m.getName())) {
                    continue;
                }
                XposedBridge.hookMethod(m, new XC_MethodHook() {
                    @Override
                    protected void afterHookedMethod(MethodHookParam param) {
                        try {
                            Object response = param.getResult();
                            if (response == null) {
                                return;
                            }
                            Object request = XposedHelpers.callMethod(response, "request");
                            String url = String.valueOf(XposedHelpers.callMethod(request, "url"));
                            int n = SEEN.incrementAndGet();
                            if (n <= 300) {
                                write("REQ " + n + " " + url + "\n");
                            }
                            boolean wantBody = url.contains("appGetPlayer")
                                    || url.contains("getPlayer")
                                    || (url.contains("/live/") && url.contains("stream"));
                            if (wantBody && DUMPED.incrementAndGet() <= 40) {
                                Object peek = XposedHelpers.callMethod(response, "peekBody", 2097152L);
                                String body = String.valueOf(XposedHelpers.callMethod(peek, "string"));
                                write("HIT " + url + "\n" + body + "\n---\n");
                            }
                        } catch (Throwable t) {
                            log("读响应失败: " + t);
                        }
                    }
                });
                hooked++;
            }
            log("hook " + className + " 完成，命中 intercept 方法 " + hooked + " 个");
            return hooked > 0;
        } catch (Throwable t) {
            log("hook " + className + " 失败: " + t);
            return false;
        }
    }

    private static void resolveLogFile() {
        if (sPathResolved) {
            return;
        }
        sPathResolved = true;
        String[] dirs = new String[4];
        try {
            Application app = AndroidAppHelper.currentApplication();
            if (app != null) {
                // Android 11+ 里 Android/media/<pkg> 对其它进程/MTP 可见，
                // 抓包日志放这儿，主机侧不用 root 也能直接读
                File[] mediaDirs = app.getExternalMediaDirs();
                if (mediaDirs != null && mediaDirs.length > 0 && mediaDirs[0] != null) {
                    dirs[0] = mediaDirs[0].getAbsolutePath();
                }
                File ext = app.getExternalFilesDir(null);
                if (ext != null) {
                    dirs[1] = ext.getAbsolutePath();
                }
                dirs[2] = app.getFilesDir().getAbsolutePath();
            }
        } catch (Throwable t) {
            log("取 Context 失败: " + t);
        }
        dirs[3] = "/sdcard";
        for (String d : dirs) {
            if (d == null) {
                continue;
            }
            try {
                File f = new File(d, FILE_NAME);
                File parent = f.getParentFile();
                if (parent != null && !parent.exists()) {
                    parent.mkdirs();
                }
                Writer w = new OutputStreamWriter(new FileOutputStream(f, true), "UTF-8");
                w.write("[boot] log ready " + new SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(new Date()) + "\n");
                w.close();
                sLogFile = f;
                return;
            } catch (Throwable t) {
                log("路径不可写 " + d + " : " + t);
            }
        }
    }

    private static void write(String text) {
        if (sLogFile == null) {
            return;
        }
        synchronized (LOCK) {
            Writer w = null;
            try {
                w = new OutputStreamWriter(new FileOutputStream(sLogFile, true), "UTF-8");
                w.write("[" + new SimpleDateFormat("HH:mm:ss", Locale.US).format(new Date()) + "] " + text);
                w.flush();
            } catch (Throwable t) {
                log("写日志失败: " + t);
            } finally {
                if (w != null) {
                    try { w.close(); } catch (Throwable ignored) { }
                }
            }
        }
    }

    static void log(String msg) {
        Log.i(TAG, msg);
        XposedBridge.log(TAG + ": " + msg);
    }
}
