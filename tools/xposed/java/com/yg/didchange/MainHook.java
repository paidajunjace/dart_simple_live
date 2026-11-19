package com.yg.didchange;

import android.os.Build;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.zip.CRC32;

import de.robv.android.xposed.IXposedHookLoadPackage;
import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XC_MethodReplacement;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;
import de.robv.android.xposed.callbacks.XC_LoadPackage.LoadPackageParam;

public class MainHook implements IXposedHookLoadPackage {

    private static final String TAG = "DIDChanger";
    private static final String PKG_SIMPLE_LIVE = "com.xycz.simple_live";
    private static final String PKG_OPENWRITE = "com.openwrite.app";
    private static final String PKG_DOUYU = "com.duowan.kiwi";

    private static final SecureRandom RNG = new SecureRandom();

    // 每次进程启动生成一次的新ID（进程存续期内保持稳定）
    private static final String sAndroidId = randomHex(16);
    private static final String sImei = randomDigits(15);
    private static final String sMeid = randomDigits(14);
    private static final String sImsi = randomDigits(15);
    private static final String sSerial = randomHex(10).toUpperCase();
    private static final String sUuidV4 = randomUuidV4();

    @Override
    public void handleLoadPackage(LoadPackageParam lpp) {
        if (PKG_SIMPLE_LIVE.equals(lpp.packageName)) {
            log("loaded in " + lpp.packageName + " pid=" + android.os.Process.myPid());
            hookSystemDeviceIds();
            randomizeDouyuDid(lpp);
        } else if (PKG_OPENWRITE.equals(lpp.packageName)) {
            log("loaded in " + lpp.packageName + " pid=" + android.os.Process.myPid());
            hookSystemDeviceIds();
            hookOpenWriteDeviceId();
        } else if (PKG_DOUYU.equals(lpp.packageName)) {
            log("loaded in " + lpp.packageName + " pid=" + android.os.Process.myPid());
            DouyuCapture.hook(lpp);
        }
    }

    // ============ OpenWrite: flutter.device_id 随机化 ============
    // OpenWrite 的 device_id 是 shared_preferences 存的 UUID v4
    // (文件 shared_prefs/FlutterSharedPreferences.xml, 键 flutter.device_id)
    // 直接 hook SharedPreferencesImpl.getString，命中该键返回本进程新生成的 UUID。
    // app 每次心跳 POST device_id 都会重读 SP → 会话内稳定使用本进程的 UUID。

    private static final String OW_PREFS_NAME = "FlutterSharedPreferences";
    private static final String OW_DID_KEY = "flutter.device_id";

    private void hookOpenWriteDeviceId() {
        // SharedPreferencesImpl 是 @hide 类，android.jar stub 里没有，运行时反射取
        Class<?> spImpl;
        Class<?> editorImpl;
        try {
            spImpl = Class.forName("android.app.SharedPreferencesImpl");
            editorImpl = Class.forName("android.app.SharedPreferencesImpl$EditorImpl");
        } catch (Throwable t) {
            log("SharedPreferencesImpl not found: " + t);
            return;
        }

        try {
            XposedHelpers.findAndHookMethod(
                    spImpl,
                    "getString",
                    String.class, String.class,
                    new XC_MethodHook() {
                        @Override
                        protected void afterHookedMethod(MethodHookParam param) {
                            Object key = param.args[0];
                            if (OW_DID_KEY.equals(key)) {
                                if (!sUuidV4.equals(param.getResult())) {
                                    param.setResult(sUuidV4);
                                }
                            }
                        }
                    });
            log("hook SharedPreferencesImpl.getString ok, device_id -> " + sUuidV4);
        } catch (Throwable t) {
            log("hook getString failed: " + t);
        }

        // 兜底：app 写回 device_id 时统一成本进程 UUID，避免会话间读到历史值
        try {
            XposedHelpers.findAndHookMethod(
                    editorImpl,
                    "putString",
                    String.class, String.class,
                    new XC_MethodHook() {
                        @Override
                        protected void beforeHookedMethod(MethodHookParam param) {
                            Object key = param.args[0];
                            if (OW_DID_KEY.equals(key)) {
                                param.args[1] = sUuidV4;
                            }
                        }
                    });
        } catch (Throwable ignore) {
        }
    }

    // ============ 1) 系统层设备ID随机化 ============

    private void hookSystemDeviceIds() {
        // Settings.Secure.getString(resolver, ANDROID_ID)
        try {
            Class<?> cls = SettingsSecureClass.get();
            XposedHelpers.findAndHookMethod(cls, "getString",
                    android.content.ContentResolver.class, String.class,
                    new XC_MethodHook() {
                        @Override
                        protected void afterHookedMethod(MethodHookParam param) {
                            String name = (String) param.args[1];
                            if ("android_id".equals(name)) {
                                param.setResult(sAndroidId);
                            }
                        }
                    });
        } catch (Throwable t) {
            log("hook Settings.Secure failed: " + t);
        }

        // Build.getSerial() / Build.SERIAL
        try {
            if (Build.VERSION.SDK_INT >= 26) {
                XposedHelpers.findAndHookMethod(Build.class, "getSerial", new XC_MethodReplacement() {
                    @Override
                    protected Object replaceHookedMethod(MethodHookParam param) {
                        return sSerial;
                    }
                });
            }
            try {
                java.lang.reflect.Field f = Build.class.getField("SERIAL");
                f.setAccessible(true);
                f.set(null, sSerial);
            } catch (Throwable ignore) {
            }
        } catch (Throwable t) {
            log("hook Build.serial failed: " + t);
        }

        // TelephonyManager 设备标识
        hookTm("getDeviceId", sImei);
        hookTm("getImei", sImei);
        hookTm("getMeid", sMeid);
        hookTm("getSubscriberId", sImsi);
    }

    private void hookTm(String method, String value) {
        try {
            XposedHelpers.findAndHookMethod(android.telephony.TelephonyManager.class,
                    method, new XC_MethodReplacement() {
                        @Override
                        protected Object replaceHookedMethod(MethodHookParam param) {
                            return value;
                        }
                    });
        } catch (Throwable t) {
            // 无参重载不存在则跳过
        }
        try {
            XposedHelpers.findAndHookMethod(android.telephony.TelephonyManager.class,
                    method, int.class, new XC_MethodReplacement() {
                        @Override
                        protected Object replaceHookedMethod(MethodHookParam param) {
                            return value;
                        }
                    });
        } catch (Throwable ignore) {
        }
    }

    // ============ 2) Simple Live: 斗鱼 dy_did / acf_did 随机化 ============
    // Simple Live 的斗鱼 Cookie 持久化在 Hive box "LocalStorage"
    //  文件: /data/user/0/<pkg>/app_flutter/LocalStorage.hive
    //  Hive 2.x 帧格式（无加密）:
    //   [u32 frameLength][u8 keyType=1][u8 keyLen][key utf8]
    //   [u8 valueType=4][u32 strLen][str utf8][u32 crc32]
    //   crc32 覆盖从 frameLength 字段开始到 payload 末尾（不含 crc 自身），种子0
    //  Hive 是 append-only 日志，同名 key 的后帧覆盖前帧，故直接追加即可。

    private static final String HIVE_DIR = "app_flutter";
    private static final String HIVE_BOX = "LocalStorage";
    private static final String HIVE_KEY = "DouyuCookie";

    private void randomizeDouyuDid(LoadPackageParam lpp) {
        try {
            File dir = new File(lpp.appInfo.dataDir, HIVE_DIR);
            File hiveFile = new File(dir, HIVE_BOX + ".hive");
            if (!dir.exists()) dir.mkdirs();

            String oldCookie = null;
            if (hiveFile.exists() && hiveFile.length() > 0) {
                oldCookie = readLastValue(hiveFile, HIVE_KEY);
            }

            String newDid = randomHex(32);
            String newCookie = replaceDid(oldCookie, newDid);

            byte[] frame = buildFrame(HIVE_KEY, newCookie);
            appendToFile(hiveFile, frame);
            log("dy_did -> " + newDid + (oldCookie != null ? " (replaced)" : " (created)"));
        } catch (Throwable t) {
            log("randomizeDouyuDid failed: " + t);
        }
    }

    // 扫描整份 hive 日志，返回目标 key 最后一次写入的字符串值；无则 null
    private static String readLastValue(File f, String key) throws IOException {
        byte[] all = readFile(f);
        int pos = 0;
        String last = null;
        while (pos + 4 <= all.length) {
            long len = u32(all, pos);
            if (len < 8 || pos + len > all.length) break;
            byte[] frameBytes = new byte[(int) len];
            System.arraycopy(all, pos, frameBytes, 0, (int) len);
            Frame fr = parseFrame(frameBytes);
            if (fr != null && key.equals(fr.key)) {
                last = fr.value;
            }
            pos += (int) len;
        }
        return last;
    }

    private static final class Frame {
        String key;
        String value;
    }

    private static Frame parseFrame(byte[] b) {
        try {
            long declaredLen = u32(b, 0);
            CRC32 crc = new CRC32();
            crc.update(b, 0, (int) declaredLen - 4);
            long expect = u32(b, (int) declaredLen - 4);
            if (crc.getValue() != expect) return null;

            int p = 4;
            int keyType = b[p++] & 0xff;
            if (keyType != 1) return null;
            int keyLen = b[p++] & 0xff;
            String k = new String(b, p, keyLen, StandardCharsets.UTF_8);
            p += keyLen;

            Frame fr = new Frame();
            fr.key = k;
            if (p >= declaredLen - 4) return fr;
            int valType = b[p++] & 0xff;
            if (valType != 4) { fr.value = null; return fr; }
            long strLen = u32(b, p);
            p += 4;
            if (p + strLen > declaredLen - 4) return fr;
            fr.value = new String(b, p, (int) strLen, StandardCharsets.UTF_8);
            return fr;
        } catch (Throwable t) {
            return null;
        }
    }

    private static byte[] buildFrame(String key, String value) {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        try {
            out.write(new byte[4]);
            out.write(1);
            byte[] kb = key.getBytes(StandardCharsets.UTF_8);
            out.write(kb.length);
            out.write(kb);
            byte[] vb = value.getBytes(StandardCharsets.UTF_8);
            out.write(4);
            w32(out, vb.length);
            out.write(vb);
        } catch (IOException e) {
            throw new RuntimeException(e);
        }
        byte[] head = out.toByteArray();
        int frameLen = head.length + 4;
        head[0] = (byte) (frameLen >>> 24);
        head[1] = (byte) (frameLen >>> 16);
        head[2] = (byte) (frameLen >>> 8);
        head[3] = (byte) frameLen;

        CRC32 crc = new CRC32();
        crc.update(head, 0, head.length);
        int cv = (int) crc.getValue();
        byte[] tail = {(byte) (cv >>> 24), (byte) (cv >>> 16), (byte) (cv >>> 8), (byte) cv};

        byte[] all = new byte[frameLen];
        System.arraycopy(head, 0, all, 0, head.length);
        System.arraycopy(tail, 0, all, head.length, 4);
        return all;
    }

    private static String replaceDid(String cookie, String newDid) {
        if (cookie == null) cookie = "";
        StringBuilder kept = new StringBuilder();
        for (String pair : cookie.split(";")) {
            String seg = pair.trim();
            if (seg.isEmpty()) continue;
            String low = seg.toLowerCase();
            if (low.startsWith("dy_did=") || low.startsWith("acf_did=")) continue;
            if (kept.length() > 0) kept.append("; ");
            kept.append(seg);
        }
        if (kept.length() > 0) kept.append("; ");
        kept.append("dy_did=").append(newDid).append("; acf_did=").append(newDid);
        return kept.toString();
    }

    // ============ IO / 随机数工具 ============

    private static byte[] readFile(File f) throws IOException {
        FileInputStream in = new FileInputStream(f);
        try {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
            return out.toByteArray();
        } finally {
            in.close();
        }
    }

    private static void appendToFile(File f, byte[] data) throws IOException {
        FileOutputStream out = new FileOutputStream(f, true);
        try {
            out.write(data);
            out.flush();
        } finally {
            out.close();
        }
    }

    private static long u32(byte[] b, int off) {
        return ((b[off] & 0xffL) << 24) | ((b[off + 1] & 0xffL) << 16)
                | ((b[off + 2] & 0xffL) << 8) | (b[off + 3] & 0xffL);
    }

    private static void w32(OutputStream out, int v) throws IOException {
        out.write((v >>> 24) & 0xff);
        out.write((v >>> 16) & 0xff);
        out.write((v >>> 8) & 0xff);
        out.write(v & 0xff);
    }

    private static String randomHex(int len) {
        char[] chars = "0123456789abcdef".toCharArray();
        StringBuilder sb = new StringBuilder(len);
        for (int i = 0; i < len; i++) sb.append(chars[RNG.nextInt(16)]);
        return sb.toString();
    }

    private static String randomDigits(int len) {
        StringBuilder sb = new StringBuilder(len);
        for (int i = 0; i < len; i++) sb.append((char) ('0' + RNG.nextInt(10)));
        return sb.toString();
    }

    // 随机 UUID v4（与 OpenWrite 原生格式一致：8-4-4-4-12，version 4 + IETF variant）
    private static String randomUuidV4() {
        byte[] b = new byte[16];
        RNG.nextBytes(b);
        b[6] = (byte) ((b[6] & 0x0f) | 0x40);
        b[8] = (byte) ((b[8] & 0x3f) | 0x80);
        StringBuilder sb = new StringBuilder(36);
        for (int i = 0; i < 16; i++) {
            if (i == 4 || i == 6 || i == 8 || i == 10) sb.append('-');
            sb.append(String.format("%02x", b[i]));
        }
        return sb.toString();
    }

    private static void log(String msg) {
        XposedBridge.log("[" + TAG + "] " + msg);
    }
}

// Settings.Secure 类引用延迟解析（避免类验证期崩溃）
final class SettingsSecureClass {
    static Class<?> get() throws ClassNotFoundException {
        return Class.forName("android.provider.Settings$Secure");
    }
}
