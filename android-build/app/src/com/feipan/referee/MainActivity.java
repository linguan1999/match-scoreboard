package com.feipan.referee;

import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.PowerManager;
import android.provider.Settings;
import android.view.WindowManager;
import android.webkit.JavascriptInterface;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

public class MainActivity extends Activity {
    private WebView webView;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        webView = new WebView(this);
        WebSettings s = webView.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setDatabaseEnabled(true);
        s.setAllowFileAccess(true);
        webView.setWebViewClient(new WebViewClient());
        webView.addJavascriptInterface(new Bridge(this), "AndroidBridge");
        setContentView(webView);
        webView.loadUrl("file:///android_asset/referee.html");

        // 前台服务：后台保活 + 代发心跳，保证切后台/锁屏后数据持续一致
        Intent svc = new Intent(this, KeepAliveService.class);
        if (Build.VERSION.SDK_INT >= 26) startForegroundService(svc);
        else startService(svc);

        askIgnoreBatteryOptimizationsOnce();
    }

    @Override
    protected void onResume() {
        super.onResume();
        setForegroundFlag(true);
    }

    @Override
    protected void onPause() {
        super.onPause();
        setForegroundFlag(false);
    }

    private void setForegroundFlag(boolean fg) {
        getSharedPreferences(KeepAliveService.PREFS, MODE_PRIVATE)
                .edit().putBoolean(KeepAliveService.KEY_FOREGROUND, fg).apply();
    }

    /* 首次启动引导用户把 App 加入电池优化白名单，防止国产 ROM 杀后台服务 */
    private void askIgnoreBatteryOptimizationsOnce() {
        SharedPreferences p = getSharedPreferences(KeepAliveService.PREFS, MODE_PRIVATE);
        if (p.getBoolean("askedBattery", false)) return;
        PowerManager pm = (PowerManager) getSystemService(Context.POWER_SERVICE);
        if (pm != null && pm.isIgnoringBatteryOptimizations(getPackageName())) return;
        p.edit().putBoolean("askedBattery", true).apply();
        try {
            Intent i = new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS);
            i.setData(Uri.parse("package:" + getPackageName()));
            startActivity(i);
        } catch (ActivityNotFoundException e) { /* 部分 ROM 无此页面，忽略 */ }
    }

    @Override
    public void onBackPressed() {
        if (webView != null && webView.canGoBack()) {
            webView.goBack();
        } else {
            super.onBackPressed();
        }
    }

    /* JS 桥：页面把最新状态/设置写进 SharedPreferences，供后台心跳读取 */
    public static class Bridge {
        private final Context ctx;

        Bridge(Context c) { this.ctx = c.getApplicationContext(); }

        @JavascriptInterface
        public void onStateChanged(String json) {
            ctx.getSharedPreferences(KeepAliveService.PREFS, Context.MODE_PRIVATE)
                    .edit().putString(KeepAliveService.KEY_STATE, json).apply();
        }

        @JavascriptInterface
        public void onSettingsChanged(String json) {
            ctx.getSharedPreferences(KeepAliveService.PREFS, Context.MODE_PRIVATE)
                    .edit().putString(KeepAliveService.KEY_SETTINGS, json).apply();
        }
    }
}
