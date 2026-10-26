package com.androiddeck.demo;

import android.app.Activity;
import android.os.Bundle;
import android.view.View;
import android.view.MotionEvent;
import android.view.KeyEvent;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Typeface;
import android.util.Log;
import java.io.File;
import java.io.FileWriter;
import java.util.LinkedHashMap;

public class TouchLab extends Activity {
  @Override public void onCreate(Bundle bundle) {
    super.onCreate(bundle);
    getWindow().getDecorView().setSystemUiVisibility(5894);
    setContentView(new Pad());
  }
  class Pad extends View {
    final Paint p = new Paint(3);
    final LinkedHashMap<Integer, float[]> points = new LinkedHashMap<>();
    int presses = 0, maxPointers = 0, keyCount = 0;
    long started = 0, longest = 0, lastHold = 0;
    String lastAction = "READY";
    final File file = new File(getExternalFilesDir(null), "touch-events.jsonl");
    Pad() { super(TouchLab.this); setFocusableInTouchMode(true); requestFocus(); file.delete(); }
    void text(Canvas c, String value, float x, float y, float size, int color, boolean bold) {
      p.setColor(color); p.setTextSize(size); p.setTypeface(bold ? Typeface.create("sans-serif", Typeface.BOLD) : Typeface.create("sans-serif", Typeface.NORMAL));
      c.drawText(value, x, y, p);
    }
    void rect(Canvas c, float x, float y, float w, float h, int color) { p.setColor(color); c.drawRoundRect(x, y, x+w, y+h, 22, 22, p); }
    @Override protected void onDraw(Canvas c) {
      float w=getWidth(), h=getHeight(), scale=w/720f;
      c.drawColor(Color.rgb(16,23,34));
      p.setColor(Color.rgb(27,37,51)); p.setStrokeWidth(1);
      for(int x=0;x<w;x+=40*scale)c.drawLine(x,0,x,h,p);
      for(int y=0;y<h;y+=40*scale)c.drawLine(0,y,w,y,p);
      c.save(); c.scale(scale,scale);
      text(c,"ANDROIDDECK / TOUCH LAB",40,65,18,0xffa7ec81,true);
      text(c,"真实 Android 触控试验场",40,125,33,0xffeef3fb,true);
      text(c,"点击 · 长按 · 多点触控 · 键盘映射",40,167,18,0xff8194b0,false);
      rect(c,40,205,640,195,0xff1c293b);
      text(c,"累计触摸",65,247,18,0xff91a4bf,false); text(c,String.valueOf(presses),65,309,49,0xffa7ec81,true);
      text(c,"当前触点",273,247,18,0xff91a4bf,false); text(c,String.valueOf(points.size()),273,309,49,0xffeef3fb,true);
      text(c,"最多同时",474,247,18,0xff91a4bf,false); text(c,String.valueOf(maxPointers),474,309,49,0xffa7ec81,true);
      long hold=points.isEmpty()?lastHold:android.os.SystemClock.uptimeMillis()-started;
      text(c,"持续触摸  "+hold+" ms       最长  "+longest+" ms",65,365,17,0xff91a4bf,false);
      text(c,"INPUT STATE",40,454,16,0xff596e8b,true);
      text(c,lastAction,40,493,25,0xffe4ebf8,true);
      text(c,"Android 正在接收真实 MotionEvent",40,535,16,0xff8194b0,false);
      c.restore();
      float r=Math.min(w,h)*.09f;
      p.setColor(0xff26392a);c.drawCircle(w*.22f,h*.73f,r*1.45f,p);
      p.setColor(0xff40553b);p.setStyle(Paint.Style.STROKE);p.setStrokeWidth(2);c.drawCircle(w*.22f,h*.73f,r,p);p.setStyle(Paint.Style.FILL);
      text(c,"W A S D",w*.22f-r*.8f,h*.73f+6*scale,17*scale,0xffa7ec81,true);
      p.setColor(0xff27392b);c.drawCircle(w*.8f,h*.73f,r*1.1f,p);
      text(c,"SPACE",w*.8f-r*.7f,h*.73f+6*scale,17*scale,0xffa7ec81,true);
      text(c,"方向摇杆",w*.22f-r*.7f,h*.73f+r*2,16*scale,0xff8194b0,false);
      text(c,"按住动作",w*.8f-r*.7f,h*.73f+r*2,16*scale,0xff8194b0,false);
      p.setColor(0xff223246);c.drawCircle(w*.72f,h*.5f,r*.7f,p);
      text(c,"F",w*.72f-7*scale,h*.5f+8*scale,23*scale,0xffadbfda,true);
      for (java.util.Map.Entry<Integer,float[]> entry:points.entrySet()) {
        float[] v=entry.getValue();p.setColor(0xbbadea89);c.drawCircle(v[0],v[1],r*.38f,p);
        text(c,"#"+entry.getKey(),v[0]+20*scale,v[1]-20*scale,18*scale,0xffd4ffc0,true);
      }
      float pulse=(float)(Math.sin(System.nanoTime()/250000000.0)*.5+.5);
      p.setColor(Color.argb(140+(int)(pulse*100),167,236,129));c.drawCircle(43*scale,h-73*scale,5*scale,p);
      text(c,"APK RUNNING  /  Android "+android.os.Build.VERSION.RELEASE,60*scale,h-66*scale,15*scale,0xff8fa5bf,false);
      text(c,"同时按 W + Space，检查双指触控",40*scale,h-30*scale,14*scale,0xff5e7693,false);
      postInvalidateDelayed(16);
    }
    @Override public boolean onTouchEvent(MotionEvent e) {
      int action=e.getActionMasked(), index=e.getActionIndex();
      String[] names={"DOWN","UP","MOVE","CANCEL","OUTSIDE","POINTER_DOWN","POINTER_UP"};
      lastAction=action<names.length?names[action]:String.valueOf(action);
      for(int i=0;i<e.getPointerCount();i++) points.put(e.getPointerId(i),new float[]{e.getX(i),e.getY(i)});
      if(action==0){started=e.getEventTime(); presses++;}
      if(action==5)presses++;
      maxPointers=Math.max(maxPointers,points.size());
      if(action==1||action==3){lastHold=e.getEventTime()-started;longest=Math.max(longest,lastHold);points.clear();}
      else if(action==6) points.remove(e.getPointerId(index));
      StringBuilder data=new StringBuilder("{\"action\":\"").append(lastAction).append("\",\"time\":").append(e.getEventTime())
        .append(",\"count\":").append(e.getPointerCount()).append(",\"active\":").append(points.size()).append(",\"pointers\":[");
      for(int i=0;i<e.getPointerCount();i++) {if(i>0)data.append(','); data.append("{\"id\":").append(e.getPointerId(i)).append(",\"x\":").append(Math.round(e.getX(i))).append(",\"y\":").append(Math.round(e.getY(i))).append('}');}
      data.append("]}");Log.i("DeckTouch",data.toString());
      try(FileWriter out=new FileWriter(file,true)){out.write(data.toString()+"\n");}catch(Exception err){Log.e("DeckTouch",err.toString());}
      invalidate();return true;
    }
    @Override public boolean onKeyDown(int code,KeyEvent e){keyCount++;Log.i("DeckKey","DOWN "+code);invalidate();return super.onKeyDown(code,e);}
  }
}
