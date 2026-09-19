package com.spyou.watch_app;

import android.Manifest;
import android.app.*;
import android.bluetooth.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.content.pm.ServiceInfo;
import android.os.*;
import java.util.Arrays;

/** Zangetsu foreground remote owner, implemented against Android's public HID API. */
public class BetaConnectionService extends Service {
    public static BetaConnectionService instance;
    public static boolean running;
    public BluetoothDevice target;
    public boolean registered;
    public String detail = "Remote starting";
    public Runnable observer;
    private enum Phase { IDLE, PROFILE, REGISTERING, READY, CONNECTING, CONNECTED, CLOSED }
    private Phase phase = Phase.IDLE;
    private final Handler queue = new Handler(Looper.getMainLooper());
    private BluetoothAdapter adapter;
    private BluetoothHidDevice profile;
    private SharedPreferences preferences;
    private BetaMediaSession media;
    private boolean playerVisible, playing, foreground;
    private int activeReport;
    private byte[] activePayload;
    private Runnable pendingRelease;
    private static final int NOTIFICATION = 41285;
    private static final String CHANNEL = "beta_remote";

    // HID short items: keyboard report 1 (modifier/reserved/six keys),
    // consumer report 2 (one unsigned 16-bit usage). Values are protocol fields.
    private static byte[] descriptor() {
        int[] items = {
            0x05,1, 0x09,6, 0xA1,1, 0x85,1,
            0x05,7, 0x15,0, 0x25,1, 0x19,0xE0, 0x29,0xE7,
            0x75,1, 0x95,8, 0x81,2,
            0x75,8, 0x95,1, 0x81,1,
            0x15,0, 0x26,0xFF,0, 0x19,0, 0x2A,0xFF,0,
            0x75,8, 0x95,6, 0x81,0, 0xC0,
            0x05,0x0C, 0x09,1, 0xA1,1, 0x85,2,
            0x15,0, 0x26,0xFF,3, 0x19,0, 0x2A,0xFF,3,
            0x75,16, 0x95,1, 0x81,0, 0xC0
        };
        byte[] bytes = new byte[items.length];
        for (int i = 0; i < items.length; i++) bytes[i] = (byte) items[i];
        return bytes;
    }

    private boolean permitted() {
        return Build.VERSION.SDK_INT < 31 || checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED;
    }
    public boolean isConnected() { return phase == Phase.CONNECTED && registered && target != null; }
    public String savedName() { return preferences.getString("hidName", "TV"); }
    public String name(BluetoothDevice device) {
        String label = permitted() ? device.getName() : null;
        return label == null || label.isEmpty() ? "TV" : label;
    }
    private void status(String text) {
        detail = text;
        if (foreground) getSystemService(NotificationManager.class).notify(NOTIFICATION, notification());
        if (observer != null) observer.run();
    }
    public void playbackSnapshot(org.json.JSONObject state) { if (media != null) media.update(state); }
    public void playbackChanged(boolean available, boolean isPlaying) {
        if (playerVisible == available && playing == isPlaying) return;
        playerVisible = available;
        playing = isPlaying;
        if (foreground) getSystemService(NotificationManager.class).notify(NOTIFICATION, notification());
    }
    private Notification.Action action(String command, String title, int icon, int id) {
        Intent intent = new Intent(this, BetaConnectionService.class).setAction(command);
        return new Notification.Action.Builder(icon, title, PendingIntent.getService(this, id, intent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE)).build();
    }
    private Notification notification() {
        Notification.Builder result = Build.VERSION.SDK_INT >= 26 ? new Notification.Builder(this, CHANNEL) : new Notification.Builder(this);
        result.setSmallIcon(android.R.drawable.ic_media_play).setContentTitle(isConnected() ? name(target) : "Zangetsu")
            .setContentText(detail).setOngoing(true).setOnlyAlertOnce(true).setShowWhen(false)
            .setContentIntent(PendingIntent.getActivity(this, 0, new Intent(this, MainActivity.class), PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE));
        BetaRemoteBridge bridge = BetaRemoteBridge.Companion.getShared();
        if (isConnected() || (bridge != null && bridge.isCompanionConnected())) {
            result.addAction(action("VOLUME_DOWN", "Volume down", R.drawable.beta_volume_down, 23));
            if (playerVisible) {
                result.addAction(action("REWIND", "Back 10 seconds", android.R.drawable.ic_media_rew, 20));
                result.addAction(action("PLAY_PAUSE", playing ? "Pause" : "Play", playing ? android.R.drawable.ic_media_pause : android.R.drawable.ic_media_play, 21));
                result.addAction(action("FORWARD", "Forward 10 seconds", android.R.drawable.ic_media_ff, 22));
            }
            result.addAction(action("VOLUME_UP", "Volume up", R.drawable.beta_volume_up, 24));
            result.setStyle(new Notification.MediaStyle().setMediaSession(media.token())
                .setShowActionsInCompactView(playerVisible ? new int[]{0,2,4} : new int[]{0,1}));
        }
        return result.build();
    }
    @Override public void onCreate() {
        super.onCreate();
        instance = this; running = true;
        preferences = getSharedPreferences("beta_pairing", MODE_PRIVATE);
        media = new BetaMediaSession(this);
        BluetoothManager manager = getSystemService(BluetoothManager.class);
        adapter = manager == null ? null : manager.getAdapter();
        if (Build.VERSION.SDK_INT >= 26) getSystemService(NotificationManager.class).createNotificationChannel(new NotificationChannel(CHANNEL, "TV remote", NotificationManager.IMPORTANCE_LOW));
        IntentFilter filter = new IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED);
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(radio, filter, RECEIVER_EXPORTED); else registerReceiver(radio, filter);
    }
    @Override public IBinder onBind(Intent intent) { return null; }
    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        String command = intent == null ? "" : intent.getAction();
        if ("STOP".equals(command)) {
            BetaRemoteBridge bridge = BetaRemoteBridge.Companion.getShared();
            if (bridge != null) bridge.disconnectAll();
            stopRemote(); return START_NOT_STICKY;
        }
        if (Build.VERSION.SDK_INT >= 29) startForeground(NOTIFICATION, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE);
        else startForeground(NOTIFICATION, notification());
        foreground = true;
        if (Arrays.asList("REWIND", "PLAY_PAUSE", "FORWARD", "VOLUME_DOWN", "VOLUME_UP").contains(command)) {
            BetaRemoteBridge bridge = BetaRemoteBridge.Companion.getShared();
            if (bridge != null) bridge.notificationControl(command);
            else status("Open Zangetsu to reconnect");
        }
        ensure();
        return START_NOT_STICKY;
    }
    private final Runnable reconcile = () -> ensure();
    private void schedule(long delay) { queue.removeCallbacks(reconcile); if (phase != Phase.CLOSED) queue.postDelayed(reconcile, delay); }
    public void ensure() {
        if (phase == Phase.CLOSED) return;
        if (Build.VERSION.SDK_INT < 28) { status("Bluetooth remote requires Android 9 or newer"); return; }
        if (!preferences.getBoolean("hidEnabled", false)) { status("Use Manage to enable Bluetooth controls"); return; }
        if (!permitted()) { status("Allow Nearby devices to use Bluetooth controls"); return; }
        if (adapter == null || !adapter.isEnabled()) { status("Bluetooth is off"); return; }
        try {
            if (profile == null) {
                if (phase == Phase.PROFILE) return;
                phase = Phase.PROFILE;
                if (!adapter.getProfileProxy(this, profileEvents, BluetoothProfile.HID_DEVICE)) { phase = Phase.IDLE; status("Bluetooth remote profile unavailable"); schedule(5000); }
                return;
            }
            if (!registered) {
                if (phase == Phase.REGISTERING) return;
                phase = Phase.REGISTERING;
                boolean accepted = profile.registerApp(new BluetoothHidDeviceAppSdpSettings("Zangetsu", "TV controls", "Zangetsu", BluetoothHidDevice.SUBCLASS1_KEYBOARD, descriptor()), null, null, queue::post, events);
                if (!accepted) { phase = Phase.IDLE; status("Close another Bluetooth remote app, then retry"); schedule(5000); }
                return;
            }
            if (isConnected() || phase == Phase.CONNECTING) return;
            String wanted = preferences.getString("hidAddress", "");
            for (BluetoothDevice device : adapter.getBondedDevices()) if (device.getAddress().equals(wanted)) { connect(device); return; }
            status(wanted.isEmpty() ? "Choose a paired TV in Manage" : "Pair the saved TV in Bluetooth settings");
        } catch (SecurityException denied) { status("Bluetooth permission is unavailable"); }
    }
    private final BluetoothProfile.ServiceListener profileEvents = new BluetoothProfile.ServiceListener() {
        @Override public void onServiceConnected(int id, BluetoothProfile service) {
            if (phase == Phase.CLOSED) { if (adapter != null) adapter.closeProfileProxy(id, service); return; }
            profile = (BluetoothHidDevice) service; phase = Phase.IDLE; ensure();
        }
        @Override public void onServiceDisconnected(int id) {
            profile = null; registered = false; target = null; activeReport = 0;
            if (phase != Phase.CLOSED) { phase = Phase.IDLE; status("Bluetooth service reconnecting"); schedule(5000); }
        }
    };
    private final BluetoothHidDevice.Callback events = new BluetoothHidDevice.Callback() {
        @Override public void onAppStatusChanged(BluetoothDevice host, boolean ready) {
            if (phase == Phase.CLOSED) return;
            registered = ready; phase = ready ? Phase.READY : Phase.IDLE;
            if (!ready) { target = null; activeReport = 0; status("Bluetooth registration unavailable; close other remote apps"); schedule(5000); }
            else ensure();
        }
        @Override public void onConnectionStateChanged(BluetoothDevice host, int state) {
            if (phase == Phase.CLOSED || !permitted()) return;
            try {
                if (!host.getAddress().equals(preferences.getString("hidAddress", ""))) { if (profile != null) profile.disconnect(host); return; }
                if (state == BluetoothProfile.STATE_CONNECTED) {
                    queue.removeCallbacks(connectionTimeout); target = host; phase = Phase.CONNECTED;
                    preferences.edit().putString("hidName", name(host)).apply(); status("Connected to " + name(host));
                } else if (state == BluetoothProfile.STATE_DISCONNECTED) {
                    queue.removeCallbacks(connectionTimeout); target = null; activeReport = 0; phase = Phase.READY;
                    status("TV disconnected; reconnecting"); schedule(5000);
                }
            } catch (SecurityException denied) { status("Bluetooth permission is unavailable"); }
        }
        @Override public void onGetReport(BluetoothDevice host, byte type, byte id, int bufferSize) {
            if (!isConnected() || !host.equals(target) || !permitted() || profile == null) return;
            try {
                if (type != BluetoothHidDevice.REPORT_TYPE_INPUT || (id != 1 && id != 2)) { profile.reportError(host, BluetoothHidDevice.ERROR_RSP_UNSUPPORTED_REQ); return; }
                byte[] payload = activeReport == id && activePayload != null ? activePayload.clone() : new byte[id == 1 ? 8 : 2];
                if (bufferSize > 0 && bufferSize < payload.length) { profile.reportError(host, BluetoothHidDevice.ERROR_RSP_INVALID_PARAM); return; }
                profile.replyReport(host, type, id, payload);
            } catch (SecurityException denied) { status("Bluetooth permission is unavailable"); }
        }
        @Override public void onVirtualCableUnplug(BluetoothDevice host) {
            if (target != null && !target.equals(host)) return;
            target = null; activeReport = 0;
            preferences.edit().remove("hidAddress").remove("hidName").putBoolean("hidEnabled", false).apply();
            queue.removeCallbacks(connectionTimeout); queue.removeCallbacks(reconcile);
            if (phase != Phase.CLOSED) { phase = Phase.READY; status("TV removed pairing; choose the TV again"); }
        }
    };
    private final Runnable connectionTimeout = () -> {
        if (phase != Phase.CONNECTING) return;
        phase = Phase.READY; status("TV did not connect; retrying"); schedule(5000);
    };
    public void connect(BluetoothDevice device) {
        if (!registered || profile == null || !permitted() || phase == Phase.CLOSED) return;
        if (isConnected() || phase == Phase.CONNECTING) return;
        if (!device.getAddress().equals(preferences.getString("hidAddress", ""))) return;
        try {
            if (profile.connect(device)) {
                phase = Phase.CONNECTING; status("Connecting to " + name(device));
                queue.removeCallbacks(connectionTimeout); queue.postDelayed(connectionTimeout, 20000);
            } else { status("TV unavailable; retrying"); schedule(5000); }
        } catch (SecurityException denied) { status("Bluetooth permission is unavailable"); }
    }
    public void press(int report, int usage) {
        if ((report != 1 && report != 2) || usage < 0 || usage > (report == 1 ? 255 : 1023)) return;
        release();
        if (!isConnected() || !permitted()) return;
        byte[] payload = new byte[report == 1 ? 8 : 2];
        if (report == 1) payload[2] = (byte) usage;
        else { payload[0] = (byte) usage; payload[1] = (byte) (usage >>> 8); }
        try {
            if (profile.sendReport(target, report, payload)) { activeReport = report; activePayload = payload; }
            else status("TV did not accept the button");
        } catch (SecurityException denied) { status("Bluetooth permission is unavailable"); }
    }
    public void release() {
        if (pendingRelease != null) queue.removeCallbacks(pendingRelease);
        pendingRelease = null;
        int report = activeReport; activeReport = 0; activePayload = null;
        if (report == 0 || !isConnected() || !permitted()) return;
        try { profile.sendReport(target, report, new byte[report == 1 ? 8 : 2]); }
        catch (SecurityException denied) { status("Bluetooth permission is unavailable"); }
    }
    public void tap(int report, int usage) { press(report, usage); pendingRelease = this::release; queue.postDelayed(pendingRelease, 25); }
    public void hardwareVolume(int usage) { tap(2, usage); }
    private final BroadcastReceiver radio = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) {
            if (phase == Phase.CLOSED) return;
            int state = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, -1);
            if (state == BluetoothAdapter.STATE_OFF) { target = null; registered = false; activeReport = 0; phase = Phase.IDLE; status("Bluetooth is off"); }
            else if (state == BluetoothAdapter.STATE_ON) ensure();
        }
    };
    private void closeProfile() {
        release(); phase = Phase.CLOSED; queue.removeCallbacksAndMessages(null);
        if (profile != null && permitted()) {
            try { if (target != null) profile.disconnect(target); profile.unregisterApp(); }
            catch (SecurityException ignored) { }
        }
        if (adapter != null && profile != null) adapter.closeProfileProxy(BluetoothProfile.HID_DEVICE, profile);
        profile = null; target = null; registered = false;
    }
    public void stopRemote() {
        preferences.edit().putBoolean("hidEnabled", false).apply(); closeProfile();
        foreground = false; stopForeground(STOP_FOREGROUND_REMOVE); stopSelf();
    }
    @Override public void onDestroy() {
        foreground = false; closeProfile(); unregisterReceiver(radio); media.close(); observer = null;
        if (instance == this) instance = null;
        running = false; super.onDestroy();
    }
}
