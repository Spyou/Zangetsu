package com.spyou.watch_app;

import android.app.*;
import android.bluetooth.*;
import android.content.*;
import android.content.pm.ServiceInfo;
import android.os.*;
import java.io.*;

/** Owns the HID registration independently of any visible activity. */
public class BetaConnectionService extends Service {
 public static BetaConnectionService instance;
 public static boolean running;
 private boolean playbackAvailable, playbackPlaying;
 private BetaMediaSession media;
 public void playbackSnapshot(org.json.JSONObject state){if(media!=null)media.update(state);}
 public void playbackChanged(boolean available, boolean playing){if(playbackAvailable==available && playbackPlaying==playing)return;playbackAvailable=available;playbackPlaying=playing;if(!stopped)getSystemService(NotificationManager.class).notify(41285,notification());}
 public boolean isConnected(){return registered && target!=null;}
 public final class LocalBinder extends Binder { public BetaConnectionService getService(){return BetaConnectionService.this;} }
 private final Handler handler=new Handler(Looper.getMainLooper());
 private BluetoothAdapter adapter;
 private BluetoothHidDevice hid;
 public BluetoothDevice target;
 public boolean registered;
 public String detail="Starting Bluetooth…";
 public Runnable observer;
 private boolean registering, requesting, stopped;
 private int heldReport, generation, attempts;
 private BluetoothDevice connecting;
 private long connectingSince;
 private SharedPreferences prefs;
 private String lastNotificationAction="none";
 private int notificationActionCount;
 private int hardwareVolumeCount;
 private int lastHardwareUsage;
 private static final byte[] DESCRIPTOR=hex("05 01 09 06 A1 01 85 01 05 07 19 E0 29 E7 15 00 25 01 75 01 95 08 81 02 75 08 95 01 81 01 05 07 19 00 29 65 15 00 25 65 75 08 95 06 81 00 C0 05 0C 09 01 A1 01 85 02 15 00 26 FF 03 19 00 2A FF 03 75 10 95 01 81 00 C0");
 private static byte[] hex(String s){String[] p=s.split(" ");byte[] b=new byte[p.length];for(int i=0;i<b.length;i++)b[i]=(byte)Integer.parseInt(p[i],16);return b;}
 public String savedName(){return prefs.getString("hidName","No saved TV");}
 public String name(BluetoothDevice d){String n=d.getName();return n==null||n.isEmpty()?d.getAddress():n;}
 private void update(String s){detail=s;android.util.Log.i("ZangetsuRemote",s);if(!stopped)getSystemService(NotificationManager.class).notify(41285,notification());if(observer!=null)observer.run();}
 private Notification notification(){
  PendingIntent open=PendingIntent.getActivity(this,0,new Intent(this,MainActivity.class),PendingIntent.FLAG_UPDATE_CURRENT|PendingIntent.FLAG_IMMUTABLE);
  PendingIntent stop=PendingIntent.getService(this,1,new Intent(this,BetaConnectionService.class).setAction("STOP"),PendingIntent.FLAG_UPDATE_CURRENT|PendingIntent.FLAG_IMMUTABLE);
  int icon=android.R.drawable.ic_media_play;
  Notification.Builder builder=(Build.VERSION.SDK_INT>=26?new Notification.Builder(this,"beta_remote"):new Notification.Builder(this)).setSmallIcon(icon).setContentTitle(target!=null?name(target):"Zangetsu").setContentText(target!=null?"TV remote · Bluetooth connected":detail).setContentIntent(open).setOngoing(true).setOnlyAlertOnce(true).setShowWhen(false);
  if((target!=null && registered) || (BetaRemoteBridge.Companion.getShared()!=null && BetaRemoteBridge.Companion.getShared().isCompanionConnected())){
   builder.addAction(notificationAction("VOLUME_DOWN","Volume down",R.drawable.beta_volume_down,23));
   if(playbackAvailable){
    builder.addAction(notificationAction("REWIND","Back 10 seconds",android.R.drawable.ic_media_rew,20));
    builder.addAction(notificationAction("PLAY_PAUSE",playbackPlaying?"Pause":"Play",playbackPlaying?android.R.drawable.ic_media_pause:android.R.drawable.ic_media_play,21));
    builder.addAction(notificationAction("FORWARD","Forward 10 seconds",android.R.drawable.ic_media_ff,22));
   }
   builder.addAction(notificationAction("VOLUME_UP","Volume up",R.drawable.beta_volume_up,24));
   builder.setStyle(new Notification.MediaStyle().setMediaSession(media.token()).setShowActionsInCompactView(playbackAvailable?new int[]{0,2,4}:new int[]{0,1}));
  }
  return builder.build();
 }
 private Notification.Action notificationAction(String action,String title,int icon,int request){
  PendingIntent pending=PendingIntent.getService(this,request,new Intent(this,BetaConnectionService.class).setAction(action),PendingIntent.FLAG_UPDATE_CURRENT|PendingIntent.FLAG_IMMUTABLE);
  return new Notification.Action.Builder(icon,title,pending).build();
 }
 @Override public void onCreate(){super.onCreate();media=new BetaMediaSession(this);instance=this;running=true;prefs=getSharedPreferences("beta_pairing",0);adapter=getSystemService(BluetoothManager.class).getAdapter();if(Build.VERSION.SDK_INT>=26)getSystemService(NotificationManager.class).createNotificationChannel(new NotificationChannel("beta_remote","TV remote",NotificationManager.IMPORTANCE_LOW));IntentFilter f=new IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED);if(Build.VERSION.SDK_INT>=33)registerReceiver(receiver,f,Context.RECEIVER_EXPORTED);else registerReceiver(receiver,f);}
 @Override public int onStartCommand(Intent intent,int flags,int id){
  if(intent!=null && "STOP".equals(intent.getAction())){if(BetaRemoteBridge.Companion.getShared()!=null)BetaRemoteBridge.Companion.getShared().disconnectAll();stopRemote();return START_NOT_STICKY;}
  stopped=false;
  if(Build.VERSION.SDK_INT>=29)startForeground(41285,notification(),ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE);else startForeground(41285,notification());
  String action=intent==null?null:intent.getAction();
  if("REWIND".equals(action)||"PLAY_PAUSE".equals(action)||"FORWARD".equals(action)||"VOLUME_DOWN".equals(action)||"VOLUME_UP".equals(action)){
   if(BetaRemoteBridge.Companion.getShared()!=null){BetaRemoteBridge.Companion.getShared().notificationControl(action);lastNotificationAction=action;notificationActionCount++;}
   else android.widget.Toast.makeText(this,"Open Zangetsu to reconnect your TV.",android.widget.Toast.LENGTH_SHORT).show();
  }
  ensure();return START_NOT_STICKY;
 }
 @Override public IBinder onBind(Intent intent){return new LocalBinder();}
 private final BroadcastReceiver receiver=new BroadcastReceiver(){public void onReceive(Context c,Intent i){int state=i.getIntExtra(BluetoothAdapter.EXTRA_STATE,-1);if(state==BluetoothAdapter.STATE_ON)ensure();if(state==BluetoothAdapter.STATE_OFF){target=null;registered=false;registering=false;connecting=null;heldReport=0;update("Bluetooth is off. Reconnects when Bluetooth is turned on.");}}};
 private final BluetoothProfile.ServiceListener listener=new BluetoothProfile.ServiceListener(){
  public void onServiceConnected(int p,BluetoothProfile proxy){requesting=false;hid=(BluetoothHidDevice)proxy;if(!stopped)ensure();}
  public void onServiceDisconnected(int p){hid=null;registered=false;registering=false;requesting=false;target=null;connecting=null;heldReport=0;if(!stopped){update("Bluetooth service unavailable. Retrying…");retry();}}
 };
 public void ensure(){
  if(stopped)return;
  if(Build.VERSION.SDK_INT<28){update("Bluetooth remote mode requires Android 9 or newer.");return;}
  if(Build.VERSION.SDK_INT>=31 && checkSelfPermission(android.Manifest.permission.BLUETOOTH_CONNECT)!=android.content.pm.PackageManager.PERMISSION_GRANTED){update("Allow Nearby devices to add Bluetooth remote controls.");return;}
  if(!prefs.getBoolean("hidEnabled",false)){update("Wi-Fi companion connected · link Bluetooth in Manage");return;}
  if(adapter==null || !adapter.isEnabled()){update("Turn on Bluetooth to connect your TV.");return;}
  if(hid==null){if(!requesting){requesting=adapter.getProfileProxy(this,listener,BluetoothProfile.HID_DEVICE);update(requesting?"Starting Bluetooth remote…":"Bluetooth keyboard mode unavailable.");}return;}
  if(registered){reconnect();return;}
  if(registering)return;registering=true;
  boolean ok=hid.registerApp(new BluetoothHidDeviceAppSdpSettings("Zangetsu","TV remote","Zangetsu",BluetoothHidDevice.SUBCLASS1_KEYBOARD,DESCRIPTOR),null,null,getMainExecutor(),callback);
  if(!ok){registering=false;update("Could not enable remote mode. Close other Bluetooth remote apps.");retry();}
 }
 private final BluetoothHidDevice.Callback callback=new BluetoothHidDevice.Callback(){
  public void onAppStatusChanged(BluetoothDevice plugged,boolean ready){registered=ready;registering=false;if(stopped)return;if(ready){update("Ready to connect.");if(plugged!=null && plugged.getAddress().equals(prefs.getString("hidAddress","")))connect(plugged);else reconnect();}else{target=null;connecting=null;heldReport=0;update("Bluetooth remote unavailable. Disconnect Drift or another remote app, then retry.");retry();}}
  public void onConnectionStateChanged(BluetoothDevice device,int state){
   if(stopped)return;
   if(!device.getAddress().equals(prefs.getString("hidAddress",""))){if(hid!=null)hid.disconnect(device);return;}
   if(state==BluetoothProfile.STATE_CONNECTED){target=device;connecting=null;attempts=0;prefs.edit().putString("hidAddress",device.getAddress()).putString("hidName",name(device)).apply();handler.removeCallbacks(retryTask);update("Connected to "+name(device));}
   else if(state==BluetoothProfile.STATE_DISCONNECTED){if(target!=null && !target.equals(device))return;target=null;connecting=null;heldReport=0;release();update("Reconnecting to "+savedName()+"…");retry();}
   else if(state==BluetoothProfile.STATE_CONNECTING){connecting=device;connectingSince=SystemClock.elapsedRealtime();update("Connecting to "+name(device)+"…");}
  }
  public void onGetReport(BluetoothDevice d,byte type,byte id,int length){if(hid==null)return;if(type==BluetoothHidDevice.REPORT_TYPE_INPUT && (id==1||id==2))hid.replyReport(d,type,id,new byte[id==1?8:2]);else hid.reportError(d,BluetoothHidDevice.ERROR_RSP_UNSUPPORTED_REQ);}
  public void onVirtualCableUnplug(BluetoothDevice d){target=null;connecting=null;heldReport=0;prefs.edit().remove("hidAddress").remove("hidName").apply();handler.removeCallbacks(retryTask);update("TV removed the remote. Pair it again.");}
 };
 private final Runnable retryTask=()->{if(!stopped)ensure();};
 private void retry(){handler.removeCallbacks(retryTask);if(!stopped)handler.postDelayed(retryTask,attempts++<3?5000:30000);}
 private void reconnect(){if(target!=null||stopped)return;if(connecting!=null && SystemClock.elapsedRealtime()-connectingSince<20000){retry();return;}connecting=null;String address=prefs.getString("hidAddress","");if(address.isEmpty())return;for(BluetoothDevice d:adapter.getBondedDevices())if(d.getAddress().equals(address)){connect(d);return;}update("Saved TV is no longer paired. Pair it again.");}
 public void connect(BluetoothDevice d){if(hid==null||!registered)return;if(target!=null){if(target.equals(d))return;update("Disconnect the current TV before choosing another.");return;}connecting=d;connectingSince=SystemClock.elapsedRealtime();if(hid.connect(d)){update("Connecting to "+name(d)+"…");retry();}else{connecting=null;update("TV unavailable. Retrying saved connection…");retry();}}
 public void press(int report,int code){if(hid==null||!registered||target==null)return;if(heldReport!=0)release();++generation;byte[] data=new byte[report==1?8:2];if(report==1)data[2]=(byte)code;else{data[0]=(byte)code;data[1]=(byte)(code>>8);}boolean sent=hid.sendReport(target,report,data);if(sent)heldReport=report;else update("Could not send button. Check connection.");}
 public void release(){++generation;int report=heldReport;heldReport=0;if(report!=0 && hid!=null && target!=null && registered)hid.sendReport(target,report,new byte[report==1?8:2]);}
 public void tap(int report,int code){press(report,code);int g=generation;handler.postDelayed(()->{if(generation==g)release();},25);}
 public void hardwareVolume(int usage){if(target!=null && registered){tap(2,usage);hardwareVolumeCount++;lastHardwareUsage=usage;}}
 public void stopRemote(){stopped=true;prefs.edit().putBoolean("hidEnabled",false).apply();handler.removeCallbacksAndMessages(null);release();if(hid!=null){if(target!=null)hid.disconnect(target);if(registered)hid.unregisterApp();}target=null;registered=false;update("Disconnected. Tap Connect to resume.");stopForeground(STOP_FOREGROUND_REMOVE);stopSelf();}
 @Override public void onDestroy(){stopped=true;if(media!=null)media.close();handler.removeCallbacksAndMessages(null);try{release();if(hid!=null){hid.unregisterApp();adapter.closeProfileProxy(BluetoothProfile.HID_DEVICE,hid);}}catch(SecurityException ignored){}unregisterReceiver(receiver);observer=null;instance=null;running=false;super.onDestroy();}
 @Override protected void dump(FileDescriptor fd,PrintWriter w,String[] args){w.println("Zangetsu: registered="+registered+" connected="+(target!=null)+" stopped="+stopped+" heldReport="+heldReport);w.println("TV="+(target!=null?name(target):savedName()));w.println("Notification actions="+notificationActionCount+" last="+lastNotificationAction);w.println("Hardware volume events="+hardwareVolumeCount+" lastUsage="+lastHardwareUsage);w.println(detail);}
}
