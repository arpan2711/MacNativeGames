/* Native macOS window and VI service adapter. No guest frame is synthesized. */
#import <Cocoa/Cocoa.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import <CoreVideo/CoreVideo.h>
#include <stdatomic.h>
#include <math.h>
#include "runtime.h"
#include "game_version.h"
#include "totk_ui_lang.h"
#include "../third_party/d2r_gfx/gfx/nvn/totk_mfx_mode.h"
int mfxup_output_enabled(void);
static NSWindow *window;
uint64_t dm_nvn_frame_count(void);   /* gfx/nvn/hle_nvn.c: game frames presented so far */
static CAMetalLayer *metalLayer;
static NSView *bootOverlay;
static NSTextField *bootStage,*bootDetail;
static NSProgressIndicator *bootProgress;
static NSView *shortcutHelp;
int taa_enabled(void);   /* third_party/d2r_gfx/gfx/nvn/totk_taa.m: key 5 */
static uint64_t bootStartNS;
static _Atomic uint64_t presentedFrames;
static _Atomic int warmPending;
static CVDisplayLinkRef displayLink;
static _Atomic int focused;
static pthread_mutex_t vsyncLock=PTHREAD_MUTEX_INITIALIZER;
static void *vsyncEvents[16];
static unsigned vsyncCount;
void hle_bind_system_event(void *,int);
void hle_signal_system_event(void *);
void *front_metal_layer(void){return (__bridge void *)metalLayer;}
void front_frame_presented(void){
 if(atomic_fetch_add_explicit(&presentedFrames,1,memory_order_relaxed)==0){
  fprintf(stderr,"[totk-boot] %.3f first presented frame\n",(runtime_now_ns()-bootStartNS)/1e9);
  dispatch_async(dispatch_get_main_queue(), ^{if(!atomic_load(&warmPending))bootOverlay.hidden=YES;});
 }
}
void runtime_boot_progress(const char *stage,uint64_t done,uint64_t total){
 static const char *last;
 if(stage!=last){fprintf(stderr,"[totk-boot] %.3f %s\n",bootStartNS?(runtime_now_ns()-bootStartNS)/1e9:0,stage?stage:"startup");last=stage;}
 NSString *s=[NSString stringWithUTF8String:stage?stage:TOTK_UI("正在启动","Starting")];
 dispatch_async(dispatch_get_main_queue(), ^{
  if(!bootOverlay||bootOverlay.hidden)return;
  bootStage.stringValue=s;
  if(total){bootDetail.stringValue=[NSString stringWithFormat:@"%.1f / %.1f GB",done/1e9,total/1e9];
   bootProgress.indeterminate=NO;bootProgress.doubleValue=(double)done/(double)total*100.0;}
  else {bootDetail.stringValue=@(TOTK_UI("正在处理，请稍候","Working, please wait"));bootProgress.indeterminate=YES;[bootProgress startAnimation:nil];}
 });
}
void runtime_boot_count(const char *stage,uint64_t done,uint64_t total){
 /* Steps counted in items, not bytes (the shader import: tens of thousands of files, minutes on a phone). */
 static const char *last;
 if(stage!=last){fprintf(stderr,"[totk-boot] %.3f %s\n",bootStartNS?(runtime_now_ns()-bootStartNS)/1e9:0,stage?stage:"startup");last=stage;}
 NSString *s=[NSString stringWithUTF8String:stage?stage:TOTK_UI("正在启动","Starting")];
 dispatch_async(dispatch_get_main_queue(), ^{
  if(!bootOverlay||bootOverlay.hidden)return;
  bootStage.stringValue=s;bootDetail.stringValue=[NSString stringWithFormat:@"%llu / %llu",(unsigned long long)done,(unsigned long long)total];
  if(total){bootProgress.indeterminate=NO;bootProgress.doubleValue=(double)done/(double)total*100.0;}
 });
}
void runtime_boot_status(const char *stage,const char *detail){
 if(bootStartNS)fprintf(stderr,"[totk-boot] %.3f %s — %s\n",(runtime_now_ns()-bootStartNS)/1e9,stage?stage:"startup",detail?detail:"");
 NSString *s=[NSString stringWithUTF8String:stage?stage:TOTK_UI("正在启动","Starting")];
 NSString *d=[NSString stringWithUTF8String:detail?detail:TOTK_UI("正在处理，请稍候","Working, please wait")];
 dispatch_async(dispatch_get_main_queue(), ^{
  if(!bootOverlay||bootOverlay.hidden)return;
  bootStage.stringValue=s;bootDetail.stringValue=d;
  bootProgress.indeterminate=YES;[bootProgress startAnimation:nil];
 });
}
void runtime_warm_progress(uint64_t done,uint64_t total,uint64_t shaders,uint64_t shader_total,uint64_t pipelines,uint64_t pipeline_total){
 atomic_store(&warmPending,1);
 dispatch_async(dispatch_get_main_queue(), ^{
  if(!bootOverlay||bootOverlay.hidden)return;
  double percent=total ? fmin(100.0,(double)done/(double)total*100.0) : 100.0;
  bootStage.stringValue=[NSString stringWithFormat:@(TOTK_UI("预热着色器与管线 %.0f%%","Warming shaders and pipelines %.0f%%")),floor(percent)];
  bootDetail.stringValue=[NSString stringWithFormat:@(TOTK_UI("已处理 %llu/%llu 项 · 着色器 %llu/%llu · 管线 %llu/%llu","%llu/%llu items · shaders %llu/%llu · pipelines %llu/%llu")),
      (unsigned long long)done,(unsigned long long)total,(unsigned long long)shaders,(unsigned long long)shader_total,
      (unsigned long long)pipelines,(unsigned long long)pipeline_total];
  bootProgress.indeterminate=NO;
  bootProgress.doubleValue=percent;
 });
}
void runtime_warm_done(void){
 atomic_store(&warmPending,0);
 dispatch_async(dispatch_get_main_queue(), ^{if(atomic_load(&presentedFrames))bootOverlay.hidden=YES;});
}
uint64_t front_game_res(int docked){(void)docked;return (720ULL<<32)|1280;}
/* TOTK_ASSUME_FOCUS=1: unattended test runs. macOS refuses to activate an app launched from the background while the user is working in
   another one; the window then never becomes key, GetCurrentFocusState stays 0 and the game waits before its first frame. In this mode the
   game is told it is focused, and the window is shown without taking the keyboard from the user (scripted input does not need it). */
static int assume_focus(void){static int v=-1;if(v<0){const char *e=getenv("TOTK_ASSUME_FOCUS");v=e&&atoi(e);}return v;}
/* Keep the guest active when the macOS window loses key status. Native input is still cleared
   in windowDidResignKey so a held key cannot remain stuck while another app has focus. */
int runtime_front_focus(void){return 1;}
static CVReturn vsync_callback(CVDisplayLinkRef link,const CVTimeStamp *now,const CVTimeStamp *output,CVOptionFlags flags,CVOptionFlags *out,void *ctx){
 (void)link;(void)now;(void)output;(void)flags;(void)out;(void)ctx;
 pthread_mutex_lock(&vsyncLock);for(unsigned i=0;i<vsyncCount;i++)hle_signal_system_event(vsyncEvents[i]);pthread_mutex_unlock(&vsyncLock);return kCVReturnSuccess;
}
@interface TOTKInputView:NSView
@end
@implementation TOTKInputView
-(BOOL)acceptsFirstResponder{return YES;}
-(void)keyDown:(NSEvent *)e{runtime_input_key(e.keyCode,1);}
-(void)keyUp:(NSEvent *)e{runtime_input_key(e.keyCode,0);}
-(void)flagsChanged:(NSEvent *)e{if(e.keyCode==56)runtime_input_key(56,!!(e.modifierFlags&NSEventModifierFlagShift));if(e.keyCode==58)runtime_input_key(58,!!(e.modifierFlags&NSEventModifierFlagOption));}
@end
@interface TOTKShortcutHelp:NSView
@property(strong) NSTextField *label;
@property(strong) NSTimer *timer;
@property NSSize textSize;
-(void)position;
-(void)refresh;
@end
/* Compact HUD (default): one small box in the window's top-right corner with the FPS, shader and load lines (published by
   gfx/nvn/fps_overlay.c, refreshed twice a second) above the shortcuts. TOTK_HUD=corners: the lines stay in the picture's
   corners and this is the larger centred shortcut box. */
@implementation TOTKShortcutHelp
static NSString *shortcut_text(void){
 const char *interp;
 switch(mfx_enabled()){
  case MFX_30:interp="30+30";break;
  case MFX_HALF:interp=TOTK_UI("刷新率一半","half refresh rate");break;
  case MFX_MAX:interp=TOTK_UI("不限帧","unlimited");break;
  default:interp=TOTK_UI("关闭","off");break;
 }
 uint64_t size=runtime_output_size_current();unsigned w=(uint32_t)size,h=(uint32_t)(size>>32);
 NSString *picture;
 if(mfxup_output_enabled())picture=@"MetalFX 2K";
 else if(w==2560&&h==1440)picture=@(TOTK_UI("原生 2K","native 2K"));
 else if(w!=1920||h!=1080)picture=[NSString stringWithFormat:@(TOTK_UI("原生 %u×%u","native %u×%u")),w,h];
 else picture=@(TOTK_UI("关闭","off"));
 return [NSString stringWithFormat:@(TOTK_UI("快捷键说明\n1  提示：全部 → 只显示 FPS → 隐藏\n2  补帧：当前 %@（按键切换）\n3  画质：当前 %@（按键切换）\n4  21:9 宽屏：开 / 关\n5  边缘平滑（MetalFX 时间性）：%@","Shortcuts\n1  Overlays: all → FPS only → off\n2  Interpolation: %@ (current; press to cycle)\n3  Picture: %@ (current; press to cycle)\n4  Ultrawide 21:9: on / off\n5  Edge smoothing (MetalFX Temporal): %@")),[NSString stringWithUTF8String:interp],picture,
  taa_enabled()?@(TOTK_UI("开","on")):@(TOTK_UI("关","off"))];
}
-(instancetype)initWithFrame:(NSRect)frame{if((self=[super initWithFrame:frame])){int compact=hud_compact();self.wantsLayer=YES;self.layer.backgroundColor=[NSColor colorWithCalibratedWhite:0.04 alpha:compact?0.72:0.86].CGColor;self.layer.cornerRadius=compact?7:14;self.layer.borderWidth=1;self.layer.borderColor=[NSColor colorWithCalibratedWhite:1 alpha:compact?0.14:0.2].CGColor;
 self.label=[NSTextField labelWithString:shortcut_text()];self.label.font=[NSFont systemFontOfSize:17 weight:NSFontWeightMedium];self.label.textColor=NSColor.whiteColor;self.label.alignment=NSTextAlignmentCenter;self.label.maximumNumberOfLines=0;self.label.lineBreakMode=NSLineBreakByWordWrapping;self.label.frame=NSInsetRect(self.bounds,20,18);self.label.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;[self addSubview:self.label];
 if(compact){self.label.alignment=NSTextAlignmentLeft;self.label.lineBreakMode=NSLineBreakByClipping;}
 [self refresh];__weak TOTKShortcutHelp *weak=self;self.timer=[NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t){(void)t;[weak refresh];}];}return self;}
-(void)refresh{
 if(!hud_compact()){self.label.stringValue=shortcut_text();return;}
 NSFont *mono=[NSFont monospacedSystemFontOfSize:10.5 weight:NSFontWeightMedium],*small=[NSFont systemFontOfSize:10];
 NSColor *green=[NSColor colorWithCalibratedRed:80/255.0 green:1 blue:120/255.0 alpha:1],*yellow=[NSColor colorWithCalibratedRed:1 green:230/255.0 blue:40/255.0 alpha:1];
 NSMutableAttributedString *a=[NSMutableAttributedString new];
 int full=fps_overlay_full_hud();   // key 1 minimal: the FPS line (line 0) only; the others keep their last text, so skip them
 for(int i=0;i<3;i++){char t[128];int hl=0;if((!full&&i!=0)||!hud_snapshot(i,t,sizeof t,&hl))continue;
  [a appendAttributedString:[[NSAttributedString alloc] initWithString:[([NSString stringWithUTF8String:t] ?: @"") stringByAppendingString:@"\n"] attributes:@{NSFontAttributeName:mono,NSForegroundColorAttributeName:hl?yellow:green}]];}
 if(!full){if(a.length)[a deleteCharactersInRange:NSMakeRange(a.length-1,1)];   // no empty line under the single FPS line
  else [a appendAttributedString:[[NSAttributedString alloc] initWithString:@"FPS --" attributes:@{NSFontAttributeName:mono,NSForegroundColorAttributeName:green}]];}
 else if(a.length){NSMutableParagraphStyle *gap=[NSMutableParagraphStyle new];gap.paragraphSpacingBefore=4;
  [a appendAttributedString:[[NSAttributedString alloc] initWithString:shortcut_text() attributes:@{NSFontAttributeName:small,NSForegroundColorAttributeName:[NSColor colorWithCalibratedWhite:0.75 alpha:1],NSParagraphStyleAttributeName:gap}]];}
 else [a appendAttributedString:[[NSAttributedString alloc] initWithString:shortcut_text() attributes:@{NSFontAttributeName:small,NSForegroundColorAttributeName:[NSColor colorWithCalibratedWhite:0.75 alpha:1]}]];
 if([a isEqualToAttributedString:self.label.attributedStringValue])return;
 self.label.attributedStringValue=a;NSSize z=[self.label sizeThatFits:NSMakeSize(CGFLOAT_MAX,CGFLOAT_MAX)];self.textSize=NSMakeSize(ceil(z.width),ceil(z.height));[self position];}
-(NSView *)hitTest:(NSPoint)p{(void)p;return nil;}
-(void)viewDidMoveToSuperview{[super viewDidMoveToSuperview];[self position];}
-(void)layout{[super layout];[self position];}
-(void)position{if(!self.superview)return;NSRect f,in;
 if(hud_compact()){CGFloat w=self.textSize.width+16,h=self.textSize.height+10,m=10;f=NSMakeRect(floor(self.superview.bounds.size.width-w-m),floor(self.superview.bounds.size.height-h-m),w,h);in=NSMakeRect(8,5,self.textSize.width,self.textSize.height);}
 else{CGFloat w=MIN(560,MAX(280,self.superview.bounds.size.width-40)),h=192;f=NSMakeRect(floor((self.superview.bounds.size.width-w)/2),floor((self.superview.bounds.size.height-h)/2),w,h);in=NSInsetRect(NSMakeRect(0,0,w,h),20,18);}
 if(!NSEqualRects(self.frame,f))self.frame=f;self.label.frame=in;}
@end
/* The live FPS in the menu bar: a menu of the game's own, after its app menu on the left, whose title is the frame rate
   ("60 FPS", "50+50 FPS" while frame interpolation shows generated frames), refreshed twice a second with the value the
   overlay uses. Part of the app's own menu bar, so macOS shows it whenever the game is in front (a status item next to
   the clock can be hidden by System Settings > Menu Bar). Independent of key 1; hidden in full screen with the menu bar.
   TOTK_MENUBAR_FPS=0 leaves the menu bar alone. */
extern int dm_gfx_fps_now(int *generated) __attribute__((weak_import));   // gfx/nvn/nvn_mtl.m (absent in tests)
static NSMenu *fpsMenu;static NSMenuItem *fpsMenuItem;static NSTimer *fpsTimer;
static int menubar_fps_enabled(void){const char *e=getenv("TOTK_MENUBAR_FPS");return !(e&&!strcmp(e,"0"));}
static void front_menubar_fps_add(NSMenu *bar){   // from front_install_menu
 if(!menubar_fps_enabled())return;
 fpsMenu=[[NSMenu alloc] initWithTitle:@"FPS --"];
 NSMenuItem *about=[[NSMenuItem alloc] initWithTitle:@(TOTK_UI("实时帧率（TOTK_MENUBAR_FPS=0 可隐藏）","Live frame rate (TOTK_MENUBAR_FPS=0 hides it)")) action:nil keyEquivalent:@""];
 about.enabled=NO;[fpsMenu addItem:about];fpsMenu.autoenablesItems=NO;
 fpsMenuItem=[[NSMenuItem alloc] initWithTitle:@"FPS --" action:nil keyEquivalent:@""];fpsMenuItem.submenu=fpsMenu;[bar addItem:fpsMenuItem];
}
/* TOTK_TITLE_FPS=1: the window title also ends in the frame rate ("Tears of the Kingdom  Mac — Ver. 1.4.3 — 60 FPS"),
   kept after whatever title the game set. Off by default: the menu bar already shows it. */
static int title_fps_enabled(void){const char *e=getenv("TOTK_TITLE_FPS");return e&&!strcmp(e,"1");}
static NSString *titleBase,*titleShown;
static void front_title_fps(NSString *fps){
 if(!title_fps_enabled()||!window)return;
 NSString *now=window.title;
 if(!titleShown||![now isEqualToString:titleShown])titleBase=now;   // the game changed its title: keep that one as the base
 titleShown=[NSString stringWithFormat:@"%@ — %@",titleBase,fps];
 if(![now isEqualToString:titleShown])window.title=titleShown;
}
static void front_menubar_fps(void){   // starts the refresh once the window exists
 if((!fpsMenu&&!title_fps_enabled())||fpsTimer)return;
 fpsTimer=[NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t){(void)t;
  int gen=0,fps=dm_gfx_fps_now?dm_gfx_fps_now(&gen):-1;
  NSString *title=fps<0?@"FPS --":gen>0?[NSString stringWithFormat:@"%d+%d FPS",fps,gen]:[NSString stringWithFormat:@"%d FPS",fps];
  if(fpsMenu&&![fpsMenu.title isEqualToString:title]){fpsMenu.title=title;fpsMenuItem.title=title;}
  front_title_fps(title);}];
}
/* Button guide (key 6; TOTK_PAD_GUIDE=0 starts it hidden): a controller drawing in the top-right corner, under the HUD box,
   with each button's printed label (Xbox / 8BitDo letters, PlayStation symbols or Nintendo letters, as connected) and what
   it does in the game with the current layout (runtime_gamepad_target follows controls.txt). Shown while a controller is
   connected; drawn by AppKit, so it costs the game's GPU nothing. */
@interface TOTKPadGuide:NSView
@property(strong) NSTimer *timer;
@property int style;
@property(copy) NSArray<NSString *> *actions;
-(void)position;
@end
static NSView *padGuide;static _Atomic int padGuideOn=-1;
enum{PG_SOUTH,PG_EAST,PG_WEST,PG_NORTH,PG_L3,PG_R3,PG_L1,PG_R1,PG_L2,PG_R2,PG_MENU,PG_VIEW,PG_LEFT,PG_UP,PG_RIGHT,PG_DOWN,PG_BUTTONS};
static const CGFloat PG_W=346,PG_H=222,PG_SCALE=1.1;
static NSString *pg_action(int physical){
 static const char *const what[16]={"Action","Dash / Back","Jump","Attack","Crouch","Scope","Abilities","Throw","Lock on","Bow","Menu","Map","Shields","Items","Weapons","Whistle"};
 uint16_t m=runtime_gamepad_target(physical);if(!m)return @"—";
 NSMutableArray *parts=[NSMutableArray array];for(int i=0;i<16&&parts.count<2;i++)if(m&(1u<<i))[parts addObject:@(what[i])];
 return [parts componentsJoinedByString:@" + "];
}
static NSString *pg_label(int style,int physical){
 static const char *const letters[PG_BUTTONS]={"A","B","X","Y","L3","R3","LB","RB","LT","RT","Start","Select"};
 static const char *const playstation[PG_BUTTONS]={"✕","○","□","△","L3","R3","L1","R1","L2","R2","Options","Create"};
 static const char *const nintendo[PG_BUTTONS]={"B","A","Y","X","L3","R3","L","R","ZL","ZR","+","−"};
 const char *const *t=style==RUNTIME_PAD_PLAYSTATION?playstation:style==RUNTIME_PAD_NINTENDO?nintendo:letters;
 return physical<PG_LEFT&&t[physical]?@(t[physical]):@"";
}
static NSColor *pg_face_color(int style,int physical){
 CGFloat c[4][3]={{0.36,0.78,0.30},{0.90,0.27,0.24},{0.24,0.50,0.95},{0.98,0.80,0.18}};   // Xbox: A green, B red, X blue, Y yellow
 if(style==RUNTIME_PAD_PLAYSTATION){CGFloat p[4][3]={{0.45,0.62,0.98},{0.95,0.36,0.40},{0.92,0.50,0.80},{0.30,0.82,0.65}};memcpy(c,p,sizeof c);}
 if(style==RUNTIME_PAD_NINTENDO)return [NSColor colorWithCalibratedWhite:0.82 alpha:1];
 return [NSColor colorWithCalibratedRed:c[physical][0] green:c[physical][1] blue:c[physical][2] alpha:1];
}
@implementation TOTKPadGuide
-(BOOL)isFlipped{return YES;}
-(NSView *)hitTest:(NSPoint)p{(void)p;return nil;}
-(instancetype)initWithFrame:(NSRect)frame{if((self=[super initWithFrame:frame])){self.wantsLayer=YES;self.layer.backgroundColor=[NSColor colorWithCalibratedWhite:0.04 alpha:0.72].CGColor;self.layer.cornerRadius=9;self.layer.borderWidth=1;self.layer.borderColor=[NSColor colorWithCalibratedWhite:1 alpha:0.14].CGColor;
 __weak TOTKPadGuide *weak=self;self.timer=[NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t){(void)t;[weak refresh];}];[self refresh];}return self;}
-(void)refresh{
 if(padGuideOn<0){const char *e=getenv("TOTK_PAD_GUIDE");padGuideOn=!(e&&!strcmp(e,"0"));}
 int style=runtime_gamepad_style();NSMutableArray *a=[NSMutableArray array];for(int i=0;i<PG_BUTTONS;i++)[a addObject:pg_action(i)];
 BOOL hide=!padGuideOn||style==RUNTIME_PAD_NONE||(bootOverlay&&!bootOverlay.hidden);
 if(self.hidden!=hide)self.hidden=hide;
 if(style!=self.style||![a isEqualToArray:self.actions]){self.style=style;self.actions=a;self.needsDisplay=YES;}
 [self position];}
-(void)position{if(!self.superview)return;NSRect b=self.superview.bounds;CGFloat w=ceil(PG_W*PG_SCALE),h=ceil(PG_H*PG_SCALE),m=10,top=b.size.height-m;
 if(shortcutHelp&&!shortcutHelp.hidden&&shortcutHelp.frame.size.height>0)top=NSMinY(shortcutHelp.frame)-8;   // under the HUD box
 NSRect f=NSMakeRect(floor(b.size.width-w-m),floor(top-h),w,h);if(!NSEqualRects(f,self.frame))self.frame=f;}
static void pg_text(NSString *s,CGFloat x,CGFloat y,int align,CGFloat size,NSColor *color,BOOL bold){   // align -1 right edge at x, 0 centred, 1 left edge at x
 NSDictionary *at=@{NSFontAttributeName:[NSFont systemFontOfSize:size weight:bold?NSFontWeightBold:NSFontWeightMedium],NSForegroundColorAttributeName:color};
 NSSize z=[s sizeWithAttributes:at];CGFloat ox=align<0?x-z.width:align==0?x-z.width/2:x;[s drawAtPoint:NSMakePoint(ox,y-z.height/2) withAttributes:at];}
static void pg_tag(NSString *label,NSString *action,CGFloat x,CGFloat y,CGFloat w,int right){   // a shoulder button: [label] action
 NSColor *dim=[NSColor colorWithCalibratedWhite:1 alpha:0.10],*line=[NSColor colorWithCalibratedWhite:1 alpha:0.28];
 NSBezierPath *p=[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x,y-9,w,18) xRadius:9 yRadius:9];[dim setFill];[p fill];[line setStroke];[p stroke];
 CGFloat lx=right?x+w-22:x+22;NSBezierPath *t=[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(lx-17,y-7,34,14) xRadius:7 yRadius:7];[[NSColor colorWithCalibratedWhite:1 alpha:0.85] setFill];[t fill];
 pg_text(label,lx,y,0,9,[NSColor colorWithCalibratedWhite:0.08 alpha:1],YES);
 pg_text(action,right?x+w-44:x+44,y,right?-1:1,10,NSColor.whiteColor,NO);}
-(void)drawRect:(NSRect)dirty{(void)dirty;
 NSAffineTransform *s=[NSAffineTransform transform];[s scaleBy:PG_SCALE];[s concat];
 NSArray<NSString *> *A=self.actions;int st=self.style;if(A.count<PG_BUTTONS)return;
 NSColor *white=NSColor.whiteColor,*grey=[NSColor colorWithCalibratedWhite:0.72 alpha:1],*body=[NSColor colorWithCalibratedWhite:1 alpha:0.09],*edge=[NSColor colorWithCalibratedWhite:1 alpha:0.30];
 pg_text(@"Controls  ·  key 6 hides",12,12,1,9.5,grey,NO);
 pg_tag(pg_label(st,PG_L2),A[PG_L2],12,34,150,0);pg_tag(pg_label(st,PG_L1),A[PG_L1],12,56,150,0);
 pg_tag(pg_label(st,PG_R2),A[PG_R2],184,34,150,1);pg_tag(pg_label(st,PG_R1),A[PG_R1],184,56,150,1);
 // the body and its two grips
 NSBezierPath *bp=[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(18,76,294,112) xRadius:46 yRadius:46];
 [bp appendBezierPathWithOvalInRect:NSMakeRect(28,138,88,78)];[bp appendBezierPathWithOvalInRect:NSMakeRect(214,138,88,78)];
 [body setFill];[bp fill];   // one silhouette: no outline, so the grips do not draw lines across the body
 // left stick (move, click: L3)
 NSBezierPath *ls=[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(54,92,34,34)];[[NSColor colorWithCalibratedWhite:1 alpha:0.16] setFill];[ls fill];[edge setStroke];[ls stroke];
 pg_text(@"Move",71,109,0,9,white,YES);pg_text([NSString stringWithFormat:@"%@: %@",pg_label(st,PG_L3),A[PG_L3]],71,136,0,9.5,grey,NO);
 // d-pad
 CGFloat dx=120,dy=172;NSBezierPath *dp=[NSBezierPath bezierPath];[dp appendBezierPathWithRect:NSMakeRect(dx-5,dy-15,10,30)];[dp appendBezierPathWithRect:NSMakeRect(dx-15,dy-5,30,10)];
 [[NSColor colorWithCalibratedWhite:1 alpha:0.75] setFill];[dp fill];
 pg_text(A[PG_UP],dx,dy-23,0,9.5,white,NO);pg_text(A[PG_DOWN],dx,dy+23,0,9.5,white,NO);pg_text(A[PG_LEFT],dx-19,dy,-1,9.5,white,NO);pg_text(A[PG_RIGHT],dx+19,dy,1,9.5,white,NO);
 // right stick (camera, click: R3)
 NSBezierPath *rs=[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(196,156,32,32)];[[NSColor colorWithCalibratedWhite:1 alpha:0.16] setFill];[rs fill];[edge setStroke];[rs stroke];
 pg_text(@"Camera",212,172,0,8.5,white,YES);pg_text([NSString stringWithFormat:@"%@: %@",pg_label(st,PG_R3),A[PG_R3]],212,199,0,9.5,grey,NO);
 // the two middle buttons
 struct{int b;CGFloat x;}mid[2]={{PG_VIEW,146},{PG_MENU,184}};
 for(int i=0;i<2;i++){NSBezierPath *p=[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(mid[i].x-17,99,34,13) xRadius:6.5 yRadius:6.5];[[NSColor colorWithCalibratedWhite:1 alpha:0.80] setFill];[p fill];
  pg_text(pg_label(st,mid[i].b),mid[i].x,105.5,0,7.5,[NSColor colorWithCalibratedWhite:0.08 alpha:1],YES);pg_text(A[mid[i].b],mid[i].x,121,0,9.5,white,NO);}
 // face buttons: north, west, east, south around (264,116)
 struct{int b;CGFloat x,y,tx,ty;int align;}face[4]={{PG_NORTH,264,96,264,82,0},{PG_WEST,244,116,233,116,-1},{PG_EAST,284,116,295,116,1},{PG_SOUTH,264,136,264,151,0}};
 for(int i=0;i<4;i++){NSBezierPath *c=[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(face[i].x-9,face[i].y-9,18,18)];[pg_face_color(st,face[i].b) setFill];[c fill];
  pg_text(pg_label(st,face[i].b),face[i].x,face[i].y,0,9.5,[NSColor colorWithCalibratedWhite:0.06 alpha:1],YES);
  pg_text(A[face[i].b],face[i].tx,face[i].ty,face[i].align,10,white,NO);}
}
@end
void runtime_pad_guide_toggle(void){dispatch_async(dispatch_get_main_queue(),^{if(padGuideOn<0){const char *e=getenv("TOTK_PAD_GUIDE");padGuideOn=!(e&&!strcmp(e,"0"));}
 padGuideOn=!padGuideOn;fprintf(stderr,"[totk] key 6: button guide %s\n",padGuideOn?"on":"off");[(TOTKPadGuide *)padGuide refresh];});}
void runtime_shortcut_help_toggle(void){int mode=fps_overlay_toggle_hints();dispatch_async(dispatch_get_main_queue(), ^{   // key 1: all -> minimal (FPS only) -> off
 shortcutHelp.hidden=mode==0||(mode==2&&!hud_compact());[(TOTKShortcutHelp *)shortcutHelp refresh];});}   // mode 0 off, 2 minimal (fps_overlay.h HUD_MODE_*)
/* The drawable follows the window's pixel size; the present pass scales the game picture (1920x1080 docked) into it and
   keeps 16:9 (black bars on other shapes), so a larger window or full screen shows the game at its own resolution instead
   of a fixed small drawable that the compositor stretches. */
/* TOTK_DRAWABLE_SCALE=<f> (test scripts only): the drawable is that many times the window's pixels and the window server
   scales it down for the screen. It lets a test exercise the 2K output path (a 2560x1440 picture) on a screen smaller than
   that (2026-10-17: the Mac reported a 1920x1080 display); the desktop launcher never sets it. */
static CGFloat drawable_scale(void){static CGFloat f=-1;if(f<0){const char *e=getenv("TOTK_DRAWABLE_SCALE");f=e?atof(e):1;if(f<0.25||f>4)f=1;}return f;}
static void front_sync_drawable(void){
 NSView *v=window.contentView;if(!v||!metalLayer)return;
 CGFloat s=window.backingScaleFactor>0?window.backingScaleFactor:1,ts=drawable_scale();CGSize px=CGSizeMake(round(v.bounds.size.width*s*ts),round(v.bounds.size.height*s*ts));
 if(px.width<1||px.height<1||CGSizeEqualToSize(metalLayer.drawableSize,px))return;
 metalLayer.contentsScale=s;metalLayer.drawableSize=px;fprintf(stderr,"[totk] window drawable %.0fx%.0f (scale %.0f)\n",px.width,px.height,s);
}
@interface TOTKWindowDelegate:NSObject<NSWindowDelegate>
@end
@implementation TOTKWindowDelegate
-(void)windowDidBecomeKey:(NSNotification *)n{(void)n;atomic_store(&focused,1);runtime_oe_push_message(15);fprintf(stderr,"[totk] window gained focus\n");}
-(void)windowDidResignKey:(NSNotification *)n{(void)n;atomic_store(&focused,0);runtime_input_clear();runtime_oe_push_message(15);fprintf(stderr,"[totk] window lost focus\n");}
/* The process ends with the window. Save writes go straight to the files (runtime/fs_host.c), so a close in the middle of a
   save waits (up to 15 s, the window already gone) until the game has written and committed it (runtime_fs_save_busy). */
-(void)windowWillClose:(NSNotification *)n{(void)n;
 if(!runtime_fs_save_busy()){fprintf(stderr,"[totk] window closed; graceful guest shutdown pending\n");_exit(0);}
 fprintf(stderr,"[totk] window closed while the game is saving: quitting when the save is done\n");
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
  uint64_t t0=runtime_now_ns();while(runtime_fs_save_busy()&&runtime_now_ns()-t0<15000000000ull)usleep(20000);
  fprintf(stderr,"[totk] save %s after %.2f s; quitting\n",runtime_fs_save_busy()?"still in progress (gave up)":"done",(runtime_now_ns()-t0)/1e9);_exit(0);});
}
-(void)windowDidResize:(NSNotification *)n{(void)n;front_sync_drawable();}
/* Whether any part of the window can be seen (TOTK, 2026-10-16 night): macOS stops the display link's callbacks for a
   fully covered window, so presents stop and per-picture measurements of that stretch are void; a test session's log
   says when (the user working in other apps covered the test windows of the frame interpolation tests). */
static _Atomic int windowVisible=-1;   /* -1 not known yet; read by the present path's stall lines (runtime_front_window_visible) */
static void note_occlusion(const char *when){int v=(window.occlusionState&NSWindowOcclusionStateVisible)!=0;atomic_store(&windowVisible,v);
 fprintf(stderr,"[totk] window %s%s (frame %llu)\n",v?"visible":"covered (or on another Space): no presents until it is visible again",when,(unsigned long long)dm_nvn_frame_count());}
-(void)windowDidChangeOcclusionState:(NSNotification *)n{(void)n;note_occlusion("");}
-(void)windowDidChangeBackingProperties:(NSNotification *)n{(void)n;front_sync_drawable();}
@end
static TOTKWindowDelegate *windowDelegate;
int runtime_front_window_visible(void){return atomic_load(&windowVisible);}
void runtime_front_request_close(void){dispatch_async(dispatch_get_main_queue(), ^{[window performClose:nil];});}
/* Use the window-close path, not terminate:, so Command-Q also waits for active saves. */
static void front_install_menu(void){
 NSMenu *menu=[NSMenu new],*appMenu=[NSMenu new];
 NSMenuItem *appItem=[NSMenuItem new];appItem.submenu=appMenu;[menu addItem:appItem];
 NSMenuItem *quit=[[NSMenuItem alloc] initWithTitle:@(TOTK_UI("退出 " GAME_NAME,"Quit " GAME_NAME)) action:@selector(performClose:) keyEquivalent:@"q"];
 quit.keyEquivalentModifierMask=NSEventModifierFlagCommand;quit.target=window;
 [appMenu addItem:quit];front_menubar_fps_add(menu);NSApp.mainMenu=menu;
}
static void *guest_main(void *callback){@autoreleasepool{((void(*)(void))callback)();}return NULL;}
void runtime_front_run(void(*callback)(void)){
 @autoreleasepool{
  bootStartNS=runtime_now_ns();
  [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
  runtime_gamepad_start();
  /* Default window: the docked output size, 1920x1080, scaled down (16:9 kept) when the screen's visible area is smaller. */
  /* TOTK_WINDOW_SIZE=<w>x<h> (test scripts only, e.g. the 2K output test; the desktop launcher never sets it): another starting size. */
  NSRect vis=NSScreen.mainScreen?NSScreen.mainScreen.visibleFrame:NSMakeRect(0,0,1920,1080+28);CGFloat ww=1920,wh=1080;
  {const char *e=getenv("TOTK_WINDOW_SIZE");int w=0,h=0;if(e&&sscanf(e,"%dx%d",&w,&h)==2&&w>=320&&h>=180&&w<=8192&&h<=8192){ww=w;wh=h;}}
  CGFloat k=fmin(1,fmin(vis.size.width/ww,(vis.size.height-28)/wh));ww=floor(ww*k);wh=floor(wh*k);
  window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,ww,wh) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
  window.releasedWhenClosed=NO;   /* a close that waits for a save (windowWillClose) must not free the window the static pointer still holds */
  /* An agent's test game (TOTK_SLOT_OWNER other than user) says so in its title: it plays a save copy and its script closes it. */
  const char *owner=getenv("TOTK_SLOT_OWNER"),*purpose=getenv("TOTK_SLOT_PURPOSE");
  window.title=owner&&*owner&&strcmp(owner,"user")?[NSString stringWithFormat:@(TOTK_UI("测试局（%s）Ver. %s：%s — 存档副本，进度不会存进你的存档，脚本会自己关闭","Test session (%s) Ver. %s: %s — save copy, progress is not saved to your save, the script closes it")),owner,TOTK_GAME_VERSION,purpose&&*purpose?purpose:TOTK_UI("代理测试","agent test")]:[NSString stringWithFormat:@GAME_NAME "  Mac — Ver. %s",TOTK_GAME_VERSION];
  windowDelegate=[TOTKWindowDelegate new];window.delegate=windowDelegate;
  front_install_menu();
  window.collectionBehavior|=NSWindowCollectionBehaviorFullScreenPrimary;
  window.contentView=[[TOTKInputView alloc] initWithFrame:NSMakeRect(0,0,ww,wh)];
  metalLayer=[CAMetalLayer layer];metalLayer.device=MTLCreateSystemDefaultDevice();metalLayer.pixelFormat=MTLPixelFormatBGRA8Unorm;metalLayer.drawableSize=CGSizeMake(ww,wh);
  metalLayer.framebufferOnly=NO;window.contentView.wantsLayer=YES;window.contentView.layer=metalLayer;
  bootOverlay=[[NSView alloc] initWithFrame:window.contentView.bounds];bootOverlay.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
  bootOverlay.wantsLayer=YES;bootOverlay.layer.backgroundColor=[NSColor colorWithCalibratedRed:0.035 green:0.075 blue:0.09 alpha:1].CGColor;
  bootStage=[NSTextField labelWithString:@(TOTK_UI("正在启动海拉鲁","Starting Hyrule"))];
  bootStage.font=[NSFont systemFontOfSize:25 weight:NSFontWeightSemibold];bootStage.textColor=NSColor.whiteColor;
  bootStage.alignment=NSTextAlignmentCenter;bootStage.frame=NSMakeRect(0,wh/2+20,ww,40);bootStage.autoresizingMask=NSViewWidthSizable|NSViewMinYMargin|NSViewMaxYMargin;
  bootDetail=[NSTextField labelWithString:@(TOTK_UI("正在准备游戏环境","Preparing the game environment"))];
  bootDetail.font=[NSFont systemFontOfSize:14];bootDetail.textColor=[NSColor colorWithCalibratedWhite:0.72 alpha:1];
  bootDetail.alignment=NSTextAlignmentCenter;bootDetail.frame=NSMakeRect(0,wh/2-20,ww,28);bootDetail.autoresizingMask=NSViewWidthSizable|NSViewMinYMargin|NSViewMaxYMargin;
  bootProgress=[[NSProgressIndicator alloc] initWithFrame:NSMakeRect(ww/2-140,wh/2-55,280,10)];
  bootProgress.minValue=0;bootProgress.maxValue=100;bootProgress.indeterminate=YES;bootProgress.autoresizingMask=NSViewMinXMargin|NSViewMaxXMargin|NSViewMinYMargin|NSViewMaxYMargin;
  [bootOverlay addSubview:bootStage];[bootOverlay addSubview:bootDetail];[bootOverlay addSubview:bootProgress];
  [window.contentView addSubview:bootOverlay];[bootProgress startAnimation:nil];
  front_menubar_fps();
  shortcutHelp=[[TOTKShortcutHelp alloc] initWithFrame:NSZeroRect];shortcutHelp.autoresizingMask=hud_compact()?NSViewMinXMargin|NSViewMinYMargin:NSViewMinXMargin|NSViewMaxXMargin|NSViewMinYMargin|NSViewMaxYMargin;
  /* Keep discovery/warm-up visible; the help appears after the opaque boot
     overlay is hidden. Key 1 still controls its requested visibility. */
  [window.contentView addSubview:shortcutHelp positioned:NSWindowBelow relativeTo:bootOverlay];
  [(TOTKShortcutHelp *)shortcutHelp position];
  padGuide=[[TOTKPadGuide alloc] initWithFrame:NSZeroRect];padGuide.autoresizingMask=NSViewMinXMargin|NSViewMinYMargin;
  [window.contentView addSubview:padGuide positioned:NSWindowBelow relativeTo:bootOverlay];[(TOTKPadGuide *)padGuide position];
  /* The FPS, shader and load lines: in the corner panel above (compact HUD), or with TOTK_HUD=corners drawn into the game picture's corners by the present encoder (gfx/nvn/fps_overlay.c). */
  [window makeFirstResponder:window.contentView];[window center];front_sync_drawable();
  if(assume_focus()){[window orderFrontRegardless];}else{[window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];}   /* in front of other apps' windows, keyboard left alone */
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC),dispatch_get_main_queue(),^{note_occlusion(" 3 s after opening");});
  atomic_store(&focused,1);
  if(CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)||CVDisplayLinkSetOutputCallback(displayLink,vsync_callback,NULL)||CVDisplayLinkStart(displayLink))runtime_fail("native display link initialization");
  pthread_t guest;pthread_attr_t attr;pthread_attr_init(&attr);pthread_attr_setstacksize(&attr,8*1024*1024);int err=pthread_create(&guest,&attr,guest_main,(void *)callback);pthread_attr_destroy(&attr);if(err)runtime_fail("native game thread creation");
  [NSApp run];runtime_fail("native event loop returned unexpectedly");
 }
}
/* Text entry for the game (nn::swkbd::ShowKeyboard, runtime/swkbd_host.c; on the Switch a keyboard applet takes the screen).
   User, 2026-10-17: no on-screen keyboard, just the Mac keyboard. A bar at the bottom of the game window shows the game's
   prompt and one text field (input methods work); Return confirms, Escape cancels. Characters the game disallows and text
   beyond its length limit are removed as they are typed (the caller checks again). The calling guest thread waits on a
   semaphore; the game's keys are cleared while the bar has the keyboard. */
@interface TOTKTextBar:NSView<NSTextFieldDelegate>
@property(strong) NSTextField *field;
@property int maxUnits,minUnits,digitsOnly;
@property uint32_t disabled;
@property(copy) void(^done)(NSString *text);   /* nil: cancelled */
-(void)refilter;
@end
@implementation TOTKTextBar
-(BOOL)allowed:(unichar)c{
 BOOL digit=c>='0'&&c<='9';uint32_t d=self.disabled;
 if(self.digitsOnly&&!digit)return NO;
 if(c<0x20||c==0x7f)return NO;
 if((d&1u<<1&&c==' ')||(d&1u<<2&&c=='@')||(d&1u<<3&&c=='%')||(d&1u<<4&&c=='/')||(d&1u<<5&&c=='\\')||(d&1u<<6&&digit))return NO;
 return YES;
}
-(void)controlTextDidChange:(NSNotification *)n{(void)n;[self refilter];}
-(void)refilter{
 NSText *ed=self.field.currentEditor;if([ed isKindOfClass:NSTextView.class]&&((NSTextView *)ed).hasMarkedText)return;   /* still composing */
 NSString *s=self.field.stringValue;NSMutableString *t=[NSMutableString string];
 [s enumerateSubstringsInRange:NSMakeRange(0,s.length) options:NSStringEnumerationByComposedCharacterSequences usingBlock:^(NSString *sub,NSRange r,NSRange er,BOOL *stop){
  (void)r;(void)er;
  if(sub.length==1&&![self allowed:[sub characterAtIndex:0]])return;
  if(self.maxUnits>0&&t.length+sub.length>(NSUInteger)self.maxUnits){*stop=YES;return;}
  [t appendString:sub];}];
 if(![t isEqualToString:s]){self.field.stringValue=t;NSBeep();}
}
-(void)finish:(NSString *)text{void(^d)(NSString *)=self.done;self.done=nil;if(d)d(text);}
-(BOOL)control:(NSControl *)c textView:(NSTextView *)tv doCommandBySelector:(SEL)sel{
 (void)c;(void)tv;
 if(sel==@selector(insertNewline:)){[self refilter];NSString *s=self.field.stringValue;
  if((NSInteger)s.length<self.minUnits||!s.length){NSBeep();return YES;}[self finish:s];return YES;}
 if(sel==@selector(cancelOperation:)){[self finish:nil];return YES;}
 return NO;
}
@end
static __weak TOTKTextBar *openBar;   /* main thread only */
void runtime_front_text_test(const char *op,const char *text){
 NSString *o=[NSString stringWithUTF8String:op],*t=[NSString stringWithUTF8String:text?text:""]?:@"";
 dispatch_async(dispatch_get_main_queue(), ^{
  TOTKTextBar *bar=openBar;if(!bar){fprintf(stderr,"[totk] keyboard test: no text entry bar is open\n");return;}
  if([o isEqualToString:@"type"]){bar.field.stringValue=[bar.field.stringValue stringByAppendingString:t];[bar refilter];}
  else if([o isEqualToString:@"enter"])[bar control:bar.field textView:(NSTextView *)bar.field.currentEditor doCommandBySelector:@selector(insertNewline:)];
  else if([o isEqualToString:@"shot"]){   /* the bar as drawn (window screenshots of the game picture do not include AppKit views) */
   NSBitmapImageRep *rep=[bar bitmapImageRepForCachingDisplayInRect:bar.bounds];[bar cacheDisplayInRect:bar.bounds toBitmapImageRep:rep];
   NSData *png=[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];BOOL ok=[png writeToFile:t atomically:YES];
   fprintf(stderr,"[totk] keyboard test: bar picture %s %s\n",t.UTF8String,ok?"written":"FAILED");return;}
  else if([o isEqualToString:@"esc"])[bar control:bar.field textView:(NSTextView *)bar.field.currentEditor doCommandBySelector:@selector(cancelOperation:)];
  fprintf(stderr,"[totk] keyboard test: %s -> field \"%s\"\n",o.UTF8String,bar.field.stringValue.UTF8String);
 });
}
int runtime_front_text_input(const RuntimeTextRequest *req,char *out,size_t out_size){
 if(!window||!req||!out||!out_size){fprintf(stderr,"[totk] keyboard: no game window for text entry; cancelled\n");return 0;}
 NSString *prompt=[NSString stringWithUTF8String:req->prompt?req->prompt:""]?:@"",*initial=[NSString stringWithUTF8String:req->initial?req->initial:""]?:@"";
 int maxU=req->max_units,minU=req->min_units,digits=req->digits_only,secure=req->secure;uint32_t dis=req->disabled;
 __block NSString *result=nil;dispatch_semaphore_t sem=dispatch_semaphore_create(0);
 dispatch_async(dispatch_get_main_queue(), ^{
  NSView *cv=window.contentView;CGFloat w=fmin(720,cv.bounds.size.width-40),h=104;
  TOTKTextBar *bar=[[TOTKTextBar alloc] initWithFrame:NSMakeRect(floor((cv.bounds.size.width-w)/2),48,w,h)];
  bar.autoresizingMask=NSViewMinXMargin|NSViewMaxXMargin|NSViewMaxYMargin;bar.wantsLayer=YES;bar.layer.cornerRadius=12;
  bar.layer.backgroundColor=[NSColor colorWithCalibratedRed:0.035 green:0.075 blue:0.09 alpha:0.92].CGColor;
  bar.maxUnits=maxU;bar.minUnits=minU;bar.digitsOnly=digits;bar.disabled=dis;
  NSTextField *label=[NSTextField labelWithString:prompt];label.font=[NSFont systemFontOfSize:16 weight:NSFontWeightSemibold];
  label.textColor=NSColor.whiteColor;label.frame=NSMakeRect(18,h-36,w-36,22);label.lineBreakMode=NSLineBreakByTruncatingTail;
  NSString *limit=maxU>0?[NSString stringWithFormat:@(TOTK_UI("最多 %d 个字 · ","Up to %d characters · ")),maxU]:@"";
  NSTextField *hint=[NSTextField labelWithString:[NSString stringWithFormat:@(TOTK_UI("%@用键盘输入，回车确定，Esc 取消","%@Type with the keyboard, Return to confirm, Esc to cancel")),limit]];
  hint.font=[NSFont systemFontOfSize:12];hint.textColor=[NSColor colorWithCalibratedWhite:0.72 alpha:1];hint.alignment=NSTextAlignmentRight;
  hint.frame=NSMakeRect(18,h-36,w-36,20);hint.autoresizingMask=NSViewWidthSizable;
  NSTextField *field=secure?[[NSSecureTextField alloc] initWithFrame:NSMakeRect(18,16,w-36,34)]:[[NSTextField alloc] initWithFrame:NSMakeRect(18,16,w-36,34)];
  field.font=[NSFont systemFontOfSize:20];field.stringValue=initial;field.delegate=bar;field.bezelStyle=NSTextFieldRoundedBezel;bar.field=field;
  __weak TOTKTextBar *weakBar=bar;
  bar.done=^(NSString *text){result=[text copy];[weakBar removeFromSuperview];[window makeFirstResponder:window.contentView];dispatch_semaphore_signal(sem);};
  [bar addSubview:label];[bar addSubview:hint];[bar addSubview:field];[cv addSubview:bar];openBar=bar;
  runtime_input_clear();
  if(window.miniaturized)[window deminiaturize:nil];
  if(!assume_focus()){[NSApp activateIgnoringOtherApps:YES];[window makeKeyAndOrderFront:nil];}   /* test windows never take the keyboard */
  [window makeFirstResponder:field];
  fprintf(stderr,"[totk] keyboard: text entry bar shown (%s)\n",prompt.UTF8String);
 });
 dispatch_semaphore_wait(sem,DISPATCH_TIME_FOREVER);
 if(!result)return 0;
 snprintf(out,out_size,"%s",result.UTF8String?result.UTF8String:"");
 return 1;
}
static int viReady;
static unsigned displayIdentity,layerIdentity;
static void vi_initialize(void){if(!metalLayer)runtime_fail("VI requires native macOS window");viReady=1;fprintf(stderr,"[totk] native VI display initialized\n");}
static uint32_t vi_open(void **out){if(!viReady||!out)return 0xf601;*out=&displayIdentity;return 0;}
static uint32_t vi_layer(void **out,void *display){if(!out||display!=&displayIdentity)return 0xf601;*out=&layerIdentity;return 0;}
static uint32_t vi_window(void **out,void *layer){if(!out||layer!=&layerIdentity)return 0xf601;*out=front_metal_layer();return 0;}
static uint32_t vi_vsync(void *ev,void *display){
 if(!ev||display!=&displayIdentity)return 0xf601;hle_bind_system_event(ev,1);
 pthread_mutex_lock(&vsyncLock);if(vsyncCount>=16)runtime_fail("VI display event limit");vsyncEvents[vsyncCount++]=ev;pthread_mutex_unlock(&vsyncLock);return 0;
}
#ifdef GAME_BOTW
static uint32_t vi_scaling_mode(void *layer,int mode){(void)layer;(void)mode;return 0;}
#endif
void *runtime_front_override(const char *name){
 static const struct{const char *name;void *fn;} entries[]={
 {"_ZN2nn2vi10InitializeEv",vi_initialize},{"_ZN2nn2vi18OpenDefaultDisplayEPPNS0_7DisplayE",vi_open},
 {"_ZN2nn2vi11CreateLayerEPPNS0_5LayerEPNS0_7DisplayE",vi_layer},{"_ZN2nn2vi15GetNativeWindowEPPvPNS0_5LayerE",vi_window},
 {"_ZN2nn2vi20GetDisplayVsyncEventEPNS_2os15SystemEventTypeEPNS0_7DisplayE",vi_vsync}
#ifdef GAME_BOTW
 ,{"_ZN2nn2vi19SetLayerScalingModeEPNS0_5LayerENS0_11ScalingModeE",vi_scaling_mode}   /* SDK 7: the window scales itself */
#endif
 };
 for(unsigned i=0;i<sizeof(entries)/sizeof(*entries);i++)if(!strcmp(name,entries[i].name))return entries[i].fn;return NULL;
}
