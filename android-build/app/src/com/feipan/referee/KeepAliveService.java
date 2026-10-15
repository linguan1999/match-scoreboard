package com.feipan.referee;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.ServiceInfo;
import android.net.wifi.WifiManager;
import android.os.Build;
import android.os.IBinder;
import android.os.PowerManager;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

/**
 * 前台服务：App 切后台/锁屏后代替 WebView 里的 JS 发心跳。
 *
 * JS 每次保存状态时通过 AndroidBridge 把 {courts, sessionId, takeover, savedAt}
 * 和服务器设置写入 SharedPreferences；本服务每 10 秒检查一次：
 * App 在后台且状态新鲜（≤4 小时）时，按与 JS settle() 相同的逻辑结算
 * running 场地的计时，然后 POST /update（本地优先，失败转云端）。
 * 服务端 owner 会话因此不会过期，比分与时间保持连续。
 */
public class KeepAliveService extends Service {
    public static final String PREFS = "feipan-sync";
    public static final String KEY_STATE = "stateJson";
    public static final String KEY_SETTINGS = "settingsJson";
    public static final String KEY_FOREGROUND = "isForeground";

    private static final long HEARTBEAT_MS = 10_000;
    private static final long STALE_MS = 4 * 3600_000L;   // 状态超 4 小时未更新 → 僵尸状态，不再推

    private PowerManager.WakeLock wakeLock;
    private WifiManager.WifiLock wifiLock;
    private ScheduledExecutorService exec;

    @Override
    public void onCreate() {
        super.onCreate();
        startForegroundWithNotification();

        PowerManager pm = (PowerManager) getSystemService(POWER_SERVICE);
        if (pm != null) {
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "feipan:sync");
            wakeLock.setReferenceCounted(false);
            wakeLock.acquire();
        }

        WifiManager wm = (WifiManager) getApplicationContext().getSystemService(WIFI_SERVICE);
        if (wm != null) {
            int mode = Build.VERSION.SDK_INT >= 29
                    ? WifiManager.WIFI_MODE_FULL_LOW_LATENCY : WifiManager.WIFI_MODE_FULL;
            wifiLock = wm.createWifiLock(mode, "feipan:wifi");
            wifiLock.setReferenceCounted(false);
            wifiLock.acquire();
        }

        exec = Executors.newSingleThreadScheduledExecutor();
        exec.scheduleWithFixedDelay(new HeartbeatTask(this), HEARTBEAT_MS, HEARTBEAT_MS, TimeUnit.MILLISECONDS);
    }

    /* 包私有，供 HeartbeatTask 调用 */
    void heartbeatSafe() {
        try { heartbeat(); } catch (Throwable ignored) { }
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        return START_STICKY;   // 被系统回收后自动拉起，继续心跳
    }

    private void heartbeat() throws Exception {
        SharedPreferences p = getSharedPreferences(PREFS, MODE_PRIVATE);
        if (p.getBoolean(KEY_FOREGROUND, true)) return;   // 前台时 JS 自己推，避免重复

        String stateJson = p.getString(KEY_STATE, null);
        if (stateJson == null) return;
        JSONObject payload = new JSONObject(stateJson);
        long savedAt = payload.optLong("savedAt", 0);
        if (System.currentTimeMillis() - savedAt > STALE_MS) return;

        JSONObject settings = new JSONObject(p.getString(KEY_SETTINGS, "{}"));
        String secret = settings.optString("secret", "");
        String localBase = settings.optString("localBase", "");
        String cloudBase = settings.optString("cloudBase", "");

        // 与 JS settle() 同逻辑：running 场地把 lastTick 至今的时长结算进 elapsedMs。
        // 注意不改写 prefs：每次从同一 (elapsedMs, lastTick) 基准按当前时刻重算，结果幂等且连续。
        JSONArray courts = payload.optJSONArray("courts");
        if (courts != null) {
            long now = System.currentTimeMillis();
            for (int i = 0; i < courts.length(); i++) {
                JSONObject c = courts.optJSONObject(i);
                if (c != null && "running".equals(c.optString("status"))) {
                    c.put("elapsedMs", c.optLong("elapsedMs") + Math.max(0, now - c.optLong("lastTick")));
                    c.put("lastTick", now);
                }
            }
        }
        payload.put("pushEpoch", System.currentTimeMillis());
        byte[] body = payload.toString().getBytes(StandardCharsets.UTF_8);

        // 与 JS push 一致：本地优先，失败转云端；本次失败下轮心跳自动重试
        if (!localBase.isEmpty() && post(localBase, secret, body, 1500)) return;
        if (!cloudBase.isEmpty()) post(cloudBase, secret, body, 5000);
    }

    private boolean post(String base, String secret, byte[] body, int timeoutMs) {
        HttpURLConnection conn = null;
        try {
            URL url = new URL(base + "/update?key=" + URLEncoder.encode(secret, "UTF-8"));
            conn = (HttpURLConnection) url.openConnection();
            conn.setRequestMethod("POST");
            conn.setRequestProperty("Content-Type", "application/json");
            conn.setConnectTimeout(timeoutMs);
            conn.setReadTimeout(timeoutMs);
            conn.setDoOutput(true);
            OutputStream os = conn.getOutputStream();
            os.write(body);
            os.close();
            int code = conn.getResponseCode();
            return code >= 200 && code < 300;
        } catch (Exception e) {
            return false;
        } finally {
            if (conn != null) conn.disconnect();
        }
    }

    private void startForegroundWithNotification() {
        String channelId = "sync";
        NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        if (Build.VERSION.SDK_INT >= 26 && nm != null) {
            nm.createNotificationChannel(new NotificationChannel(
                    channelId, "比分同步", NotificationManager.IMPORTANCE_LOW));
        }
        PendingIntent pi = PendingIntent.getActivity(this, 0,
                new Intent(this, MainActivity.class),
                Build.VERSION.SDK_INT >= 23 ? PendingIntent.FLAG_IMMUTABLE : 0);
        Notification.Builder b = Build.VERSION.SDK_INT >= 26
                ? new Notification.Builder(this, channelId)
                : new Notification.Builder(this);
        Notification n = b.setContentTitle("裁判计分器")
                .setContentText("后台保持比分同步中")
                .setSmallIcon(R.drawable.ic_launcher)
                .setContentIntent(pi)
                .setOngoing(true)
                .build();
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC);
        } else {
            startForeground(1, n);
        }
    }

    @Override
    public void onDestroy() {
        if (exec != null) exec.shutdownNow();
        if (wakeLock != null && wakeLock.isHeld()) wakeLock.release();
        if (wifiLock != null && wifiLock.isHeld()) wifiLock.release();
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) { return null; }
}

/* 具名顶层类替代匿名内部类：build-tools 34.0.0 的 d8 处理 JDK21 编译的匿名类会 NPE */
class HeartbeatTask implements Runnable {
    private final KeepAliveService svc;

    HeartbeatTask(KeepAliveService s) { this.svc = s; }

    @Override
    public void run() { svc.heartbeatSafe(); }
}
