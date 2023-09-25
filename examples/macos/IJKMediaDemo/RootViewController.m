//
//  RootViewController.m
//  IJKMediaMacDemo
//
//  Created by Matt Reach on 2021/11/1.
//  Copyright © 2021 IJK Mac. All rights reserved.
//

#import "RootViewController.h"
#import "MRDragView.h"
#import "MRUtil+SystemPanel.h"
#import <IJKMediaPlayerKit/IJKMediaPlayerKit.h>
#import <Carbon/Carbon.h>
#import "NSFileManager+Sandbox.h"
#import "SHBaseView.h"
#import <Quartz/Quartz.h>
#import "MRGlobalNotification.h"
#import "AppDelegate.h"
#import "MRProgressIndicator.h"
#import "MRBaseView.h"
#import <IOKit/pwr_mgt/IOPMLib.h>
#import "MultiRenderSample.h"
#import "NSString+Ex.h"

static NSString* lastPlayedKey = @"__lastPlayedKey";
static BOOL hdrAnimationShown = 0;

@interface RootViewController ()<MRDragViewDelegate,SHBaseViewDelegate,NSMenuDelegate>
{
    FILE *my_stderr;
    FILE *my_stdout;
}

@property (nonatomic, weak) IBOutlet NSStackView *advancedView;
@property (nonatomic, weak) IBOutlet MRBaseView *playerCtrlPanel;
@property (nonatomic, weak) IBOutlet NSTextField *playedTimeLb;
@property (nonatomic, weak) IBOutlet NSTextField *durationTimeLb;
@property (nonatomic, weak) IBOutlet NSButton *playCtrlBtn;
@property (nonatomic, weak) IBOutlet MRProgressIndicator *playerSlider;

@property (nonatomic, weak) IBOutlet NSPopUpButton *subtitlePopUpBtn;
@property (nonatomic, weak) IBOutlet NSPopUpButton *audioPopUpBtn;
@property (nonatomic, weak) IBOutlet NSPopUpButton *videoPopUpBtn;
@property (nonatomic, weak) IBOutlet NSTextField *seekCostLb;
@property (nonatomic, weak) NSTrackingArea *trackingArea;

//for cocoa binding begin
@property (nonatomic, assign) float volume;
@property (nonatomic, assign) float subtitleDelay;
@property (nonatomic, assign) float subtitleMargin;

@property (nonatomic, assign) float brightness;
@property (nonatomic, assign) float saturation;
@property (nonatomic, assign) float contrast;
@property (nonatomic, assign) BOOL use_openGL;
@property (nonatomic, copy) NSString *fcc;
@property (nonatomic, assign) int snapshot;
@property (nonatomic, assign) BOOL shouldShowHudView;
@property (nonatomic, assign) BOOL accurateSeek;
@property (nonatomic, assign) BOOL loop;
//for cocoa binding end

@property (nonatomic, assign) BOOL seeking;
@property (nonatomic, weak) id eventMonitor;

@property (nonatomic, assign) BOOL autoTest;
//
@property (nonatomic, assign) BOOL autoSeeked;
@property (nonatomic, assign) BOOL snapshot2;
@property (nonatomic, assign) int tickCount;

//player
@property (nonatomic, strong) IJKFFMoviePlayerController * player;
@property (nonatomic, strong) IJKKVOController * kvoCtrl;

@property (nonatomic, strong) NSMutableArray *playList;
@property (nonatomic, strong) NSMutableArray *subtitles;
@property (nonatomic, copy) NSURL *playingUrl;
@property (nonatomic, weak) NSTimer *tickTimer;

@end

@implementation RootViewController

- (void)dealloc
{
    if (self.tickTimer) {
        [self.tickTimer invalidate];
        self.tickTimer = nil;
        self.tickCount = 0;
    }
    
    [NSEvent removeMonitor:self.eventMonitor];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do view setup here.
    
    //for debug
    //[self.view setWantsLayer:YES];
    //self.view.layer.backgroundColor = [[NSColor redColor] CGColor];
    
    [IJKFFMoviePlayerController setLogHandler:^(IJKLogLevel level, NSString *tag, NSString *msg) {
        NSLog(@"[%@] [%d] %@",tag,level,msg);
//        printf("[%s] %s\n",[tag UTF8String],[msg UTF8String]);
    }];

    self.subtitleMargin = 0.7;
    self.fcc = @"fcc-_es2";
    self.snapshot = 3;
    self.volume = 0.4;
    [self onReset:nil];
    [self reSetLoglevel:@"info"];
    self.seekCostLb.stringValue = @"";
    self.accurateSeek = 1;
    self.loop = 0;
//http://bitmovin-a.akamaihd.net/content/dataset/multi-codec/hevc/stream_ts.m3u8
//http://bitmovin-a.akamaihd.net/content/dataset/multi-codec/hevc/stream.mpd
//http://bitmovin-a.akamaihd.net/content/dataset/multi-codec/hevc/stream_fmp4.m3u8
//https://events-delivery.apple.com/2807skttevpekgjkgcyolyxgkexyahqp/m3u8/vod_index-bHTtMFcgdqmJGoHoDBPadNWwGwrNevrj.m3u8
//@"http://localhost/test-videos/av1-m3u8/res.m3u8"
//    @"http://10.18.17.49/samba/video/BDMV%E7%9A%84%E5%BA%93/%E4%BB%A5%E5%AF%A1%E6%95%8C%E4%BC%97%5B%E7%AE%80%E7%B9%81%E8%8B%B1%E5%AD%97%E5%B9%95%5D.Widows.2018.BluRay.2160p.x265.10bit.HDR.2Audio-MiniHD/Widows.2018.BluRay.2160p.x265.10bit.HDR.2Audio-MiniHD.mkv"
//    @"http://10.18.17.49/samba/video-library/movies/Fast.X.2023.1080p.WEB-DL.DDP5.1.Atmos.H264-AQLJ.m2ts"
//    @"https://pan.baidu.com/rest/2.0/xpan/file?method=streaming&access_token=123.be0be15bf745faf4d16855c1690d6912.YBC2KjymwuTVhNLBrpv7f1LpYasEMPrFAl0eVUD.Uukf5A&adToken=&path=%2F%E5%85%84D%E8%BF%9E%EF%BC%88%E5%9B%BD%E9%85%8D%EF%BC%89%2FEP04%28%E6%96%B0%E5%85%B5%E6%94%AF%E6%8F%B4%29.2001.BluRay.1080p.x264.AAC.2Audios.Chs%26Eng.%E7%89%B9%E6%95%88%E4%B8%AD%E5%AD%97-DiaosMan.mp4&type=M3U8_AUTO_720"
    NSArray *onlineArr = @[
        @"http://10.18.17.49/samba/video/0-%E6%B5%8B%E8%AF%95%E8%B6%85%E9%95%BF%E6%96%87%E4%BB%B6%E8%B7%AF%E5%BE%84%E5%90%8D/1-%E6%B5%8B%E8%AF%95%E8%B6%85%E9%95%BF%E6%96%87%E4%BB%B6%E8%B7%AF%E5%BE%84%E5%90%8DAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABBBBBBBBBBBBBBBBBBBBBBBBBBBCCCCCCCCCCCCCCCCCCCCCCCCCCCCC/2-%E6%B5%8B%E8%AF%95%E8%B6%85%E9%95%BF%E6%96%87%E4%BB%B6%E8%B7%AF%E5%BE%84%E5%90%8DAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABBBBBBBBBBBBBBBBBBBBBBBBBBBCCCCCCCCCCCCCCCCCCCCCCCCCCCCC/3-%E6%B5%8B%E8%AF%95%E8%B6%85%E9%95%BF%E6%96%87%E4%BB%B6%E8%B7%AF%E5%BE%84%E5%90%8DAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABBBBBBBBBBBBBBBBBBBBBBBBBBBCCCCCCCCCCCCCCCCCCCCCCCCCCCCC/%E4%B8%AD%E6%96%87%E8%B7%AF%E5%BE%84%E5%90%8D%E5%A4%A7%E6%B3%95%E4%B9%A6%E7%B1%8D%E5%B0%91%E5%B9%B4%E7%8A%AFiasninifsdjifjsdljfsldajf%E5%8F%91%E7%94%9F%E7%9A%84%E5%8F%91%E8%BE%BE%E7%9C%81%E4%BB%BD%E7%9A%84%E5%8D%81%E5%88%86%E5%A4%A7%E6%96%B9%E7%9A%84%E8%BE%85%E5%AF%BC%E6%96%B9%E6%B3%95%E7%9A%84%E6%B5%AE%E5%8A%A8%E5%B9%85%E5%BA%A6ijlj%E6%9D%A5%E7%9C%8B%E7%9C%8B%E4%BA%86%E7%A6%BB%E5%BC%80%E4%BA%86%E7%9C%8B%E7%9C%8B%E6%9D%A5%E7%9C%8B%E6%9D%A5%E7%9C%8B%E4%BA%86%E7%9C%8B%E4%BA%86%E7%9C%8B.mp4",
        @"http://10.18.17.49/samba/audio/%E5%88%80%E9%83%8E/12%20%E7%88%B1%E6%98%AF%E4%BD%A0%E6%88%91--%E5%88%80%E9%83%8E%20%E4%BA%91%E6%9C%B5.wav",
  @"https://data.vod.itc.cn/?new=/28/239/P2Z8sTDwIBxWRuh2jD5xxA.mp4&vid=376988099&plat=14&mkey=Wgy6JxP7PToFhTW12v9ypDGjtQdLtriy&ch=null&user=api&qd=8001&cv=6.11&uid=4216341A-7133-4718-A5FE-C46318838B7B&ca=2&pg=5&pt=1&prod=ifox&playType=p2p",
        @"https://data.vod.itc.cn/?new=/73/15/oFed4wzSTZe8HPqHZ8aF7J.mp4&vid=77972299&plat=14&mkey=XhSpuZUl_JtNVIuSKCB05MuFBiqUP7rB&ch=null&user=api&qd=8001&cv=3.13&uid=F45C89AE5BC3&ca=2&pg=5&pt=1&prod=ifox",
        @"https://cdn10.vipbf-video.com/20221205/17013_50618fea/index.m3u8"
    ];

    for (NSString *url in onlineArr) {
        [self.playList addObject:[NSURL URLWithString:url]];
    }
   
    NSArray *bundleNameArr = @[@"996747-5277368-31.m3u8",
                               @"ipad8225552_4897622324404_1436873-no-dis.m3u8",
                               @"ipad8225552_4897622324404_1436873.m3u8",
                               @"5003509-693880-3.m3u8"];
    
    for (NSString *fileName in bundleNameArr) {
        NSString *localM3u8 = [[NSBundle mainBundle] pathForResource:[fileName stringByDeletingPathExtension] ofType:[fileName pathExtension]];
        [self.playList addObject:[NSURL fileURLWithPath:localM3u8]];
    }
        
    if ([self.view isKindOfClass:[SHBaseView class]]) {
        SHBaseView *baseView = (SHBaseView *)self.view;
        baseView.delegate = self;
        baseView.needTracking = YES;
    }

    __weakSelf__
    self.eventMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent * _Nullable(NSEvent * _Nonnull theEvent) {
        __strongSelf__
        if (theEvent.window == self.view.window && [theEvent keyCode] == kVK_ANSI_Period && theEvent.modifierFlags & NSEventModifierFlagCommand){
            [self onStop];
        }
        return theEvent;
    }];
    
    OBSERVER_NOTIFICATION(self, _playExplorerMovies:,kPlayExplorerMovieNotificationName_G, nil);
    OBSERVER_NOTIFICATION(self, _playNetMovies:,kPlayNetMovieNotificationName_G, nil);
    [self prepareRightMenu];
    
    [self.playerSlider onDraggedIndicator:^(double progress, MRProgressIndicator * _Nonnull indicator, BOOL isEndDrag) {
        __strongSelf__
        if (self.autoTest) {
            self.autoSeeked = 1;
        }
        if (isEndDrag) {
            [self seekTo:progress * indicator.maxValue];
            if (!self.tickTimer) {
                self.tickTimer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(onTick:) userInfo:nil repeats:YES];
            }
        } else {
            if (self.tickTimer) {
                [self.tickTimer invalidate];
                self.tickTimer = nil;
                self.tickCount = 0;
            }
            int interval = progress * indicator.maxValue;
            self.playedTimeLb.stringValue = [NSString stringWithFormat:@"%02d:%02d",(int)(interval/60),(int)(interval%60)];
        }
    }];
    
    self.playedTimeLb.stringValue = @"--:--";
    self.durationTimeLb.stringValue = @"--:--";
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self toggleAdvancedViewShow];
    });

}

- (void)prepareRightMenu
{
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Root"];
    menu.delegate = self;
    self.view.menu = menu;
}

- (void)menuWillOpen:(NSMenu *)menu
{
    if (menu == self.view.menu) {
        
        [menu removeAllItems];
        
        [menu addItemWithTitle:@"打开文件" action:@selector(openFile:)keyEquivalent:@""];
        
        if (self.playingUrl) {
            if ([self.player isPlaying]) {
                [menu addItemWithTitle:@"暂停" action:@selector(pauseOrPlay:)keyEquivalent:@""];
            } else {
                [menu addItemWithTitle:@"播放" action:@selector(pauseOrPlay:)keyEquivalent:@""];
            }
            [menu addItemWithTitle:@"停止" action:@selector(doStopPlay) keyEquivalent:@"."];
            [menu addItemWithTitle:@"下一集" action:@selector(playNext:)keyEquivalent:@""];
            [menu addItemWithTitle:@"上一集" action:@selector(playPrevious:)keyEquivalent:@""];
            
            [menu addItemWithTitle:@"前进10s" action:@selector(fastForward:)keyEquivalent:@""];
            [menu addItemWithTitle:@"后退10s" action:@selector(fastRewind:)keyEquivalent:@""];
            
            NSMenuItem *speedItem = [menu addItemWithTitle:@"倍速" action:nil keyEquivalent:@""];
            
            [menu setSubmenu:({
                NSMenu *menu = [[NSMenu alloc] initWithTitle:@"倍速"];
                menu.delegate = self;
                ;menu;
            }) forItem:speedItem];
        } else {
            if ([self.playList count] > 0) {
                [menu addItemWithTitle:@"下一集" action:@selector(playNext:)keyEquivalent:@""];
                [menu addItemWithTitle:@"上一集" action:@selector(playPrevious:)keyEquivalent:@""];
            }
        }
    } else if ([menu.title isEqualToString:@"倍速"]) {
        [menu removeAllItems];
        [menu addItemWithTitle:@"0.01x" action:@selector(updateSpeed:) keyEquivalent:@""].tag = 1;
        [menu addItemWithTitle:@"0.8x" action:@selector(updateSpeed:) keyEquivalent:@""].tag = 80;
        [menu addItemWithTitle:@"1.0x" action:@selector(updateSpeed:) keyEquivalent:@""].tag = 100;
        [menu addItemWithTitle:@"1.25x" action:@selector(updateSpeed:) keyEquivalent:@""].tag = 125;
        [menu addItemWithTitle:@"1.5x" action:@selector(updateSpeed:) keyEquivalent:@""].tag = 150;
        [menu addItemWithTitle:@"2.0x" action:@selector(updateSpeed:) keyEquivalent:@""].tag = 200;
        [menu addItemWithTitle:@"3.0x" action:@selector(updateSpeed:) keyEquivalent:@""].tag = 300;
        [menu addItemWithTitle:@"4.0x" action:@selector(updateSpeed:) keyEquivalent:@""].tag = 400;
        [menu addItemWithTitle:@"5.0x" action:@selector(updateSpeed:) keyEquivalent:@""].tag = 500;
        [menu addItemWithTitle:@"20x" action:@selector(updateSpeed:) keyEquivalent:@""].tag = 2000;
    }
}

- (void)openFile:(NSMenuItem *)sender
{
    AppDelegate *delegate = NSApp.delegate;
    [delegate openDocument:sender];
}

- (void)_playExplorerMovies:(NSNotification *)notifi
{
    if (!self.view.window.isKeyWindow) {
        return;
    }
    NSDictionary *info = notifi.userInfo;
    NSArray *movies = info[@"obj"];
    
    if ([movies count] > 0) {
        [self.playList removeAllObjects];
        [self doStopPlay];
        // 开始播放
        [self appendToPlayList:movies];
    }
}

- (void)_playNetMovies:(NSNotification *)notifi
{
    NSDictionary *info = notifi.userInfo;
    NSArray *links = info[@"links"];
    NSMutableArray *videos = [NSMutableArray array];
    
    for (NSString *link in links) {
        NSURL *url = [NSURL URLWithString:link];
        [videos addObject:url];
    }
    
    if ([videos count] > 0) {
        // 开始播放
        [self.playList removeAllObjects];
        [self.playList addObjectsFromArray:videos];
        [self doStopPlay];
        [self playFirstIfNeed];
    }
}

- (void)toggleAdvancedViewShow
{
    __weakSelf__
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext * _Nonnull context) {
        context.duration = 0.35;
        context.allowsImplicitAnimation = YES;
        context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        __strongSelf__
        self.advancedView.animator.hidden = !self.advancedView.isHidden;
    }];
}

- (void)toggleTitleBar:(BOOL)show
{
    if (!show && !self.playingUrl) {
        return;
    }
    
    if (show == self.view.window.titlebarAppearsTransparent) {
        self.view.window.titlebarAppearsTransparent = !show;
        self.view.window.titleVisibility = show ? NSWindowTitleVisible : NSWindowTitleHidden;
        [[self.view.window standardWindowButton:NSWindowCloseButton] setHidden:!show];
        [[self.view.window standardWindowButton:NSWindowMiniaturizeButton] setHidden:!show];
        [[self.view.window standardWindowButton:NSWindowZoomButton] setHidden:!show];
        
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext * _Nonnull context) {
            context.duration = 0.45;
            self.playerCtrlPanel.animator.alphaValue = show ? 1.0 : 0.0;
        }];
    }
}

- (void)baseView:(SHBaseView *)baseView mouseEntered:(NSEvent *)event
{
    if ([event locationInWindow].y > self.view.bounds.size.height - 35) {
        return;
    }
    [self toggleTitleBar:YES];
}

- (void)baseView:(SHBaseView *)baseView mouseMoved:(NSEvent *)event
{
    if ([event locationInWindow].y > self.view.bounds.size.height - 35) {
        return;
    }
    [self toggleTitleBar:YES];
}

- (void)baseView:(SHBaseView *)baseView mouseExited:(NSEvent *)event
{
    [self toggleTitleBar:NO];
}

- (void)keyDown:(NSEvent *)event
{
    if (event.window != self.view.window) {
        return;
    }
    
    if (event.modifierFlags & NSEventModifierFlagCommand) {
        switch ([event keyCode]) {
            case kVK_LeftArrow:
            {
                [self playPrevious:nil];
            }
                break;
            case kVK_RightArrow:
            {
                [self playNext:nil];
            }
                break;
            case kVK_ANSI_B:
            {
                [self toggleAdvancedViewShow];
            }
                break;
            case kVK_ANSI_R:
            {
                IJKSDLRotatePreference preference = self.player.view.rotatePreference;
                
                if (preference.type == IJKSDLRotateNone) {
                    preference.type = IJKSDLRotateZ;
                }
                
                if (event.modifierFlags & NSEventModifierFlagOption) {
                    
                    preference.type --;
                    
                    if (preference.type <= IJKSDLRotateNone) {
                        preference.type = IJKSDLRotateZ;
                    }
                }
                
                if (event.modifierFlags & NSEventModifierFlagShift) {
                    preference.degrees --;
                } else {
                    preference.degrees ++;
                }
                
                if (preference.degrees >= 360) {
                    preference.degrees = 0;
                }
                self.player.view.rotatePreference = preference;
                if (!self.player.isPlaying) {
                    [self.player.view setNeedsRefreshCurrentPic];
                }
                NSLog(@"rotate:%@ %d",@[@"X",@"Y",@"Z"][preference.type-1],(int)preference.degrees);
            }
                break;
            case kVK_ANSI_S:
            {
                [self onCaptureShot:nil];
            }
                break;
            case kVK_ANSI_Period:
            {
                [self doStopPlay];
            }
                break;
            case kVK_ANSI_H:
            {
                if (event.modifierFlags & NSEventModifierFlagShift) {
                    [self toggleHUD:nil];
                }
            }
                break;
            case kVK_ANSI_0:
            {
                self.autoTest = NO;
            }
                break;
            default:
            {
                NSLog(@"0x%X",[event keyCode]);
            }
                break;
        }
    } else if (event.modifierFlags & NSEventModifierFlagControl) {
        switch ([event keyCode]) {
            case kVK_ANSI_H:
            {
                
            }
                break;
        }
    } else if (event.modifierFlags & NSEventModifierFlagOption) {
        switch ([event keyCode]) {
            case kVK_ANSI_S:
            {
                //loop exchange subtitles
                NSInteger idx = [self.subtitlePopUpBtn indexOfSelectedItem];
                idx ++;
                if (idx >= [self.subtitlePopUpBtn numberOfItems]) {
                    idx = 0;
                }
                NSMenuItem *item = [self.subtitlePopUpBtn itemAtIndex:idx];
                if (item) {
                    [self.subtitlePopUpBtn selectItem:item];
                    [self.subtitlePopUpBtn.target performSelector:self.subtitlePopUpBtn.action withObject:self.subtitlePopUpBtn];
                }
            }
                break;
        }
    }  else {
        switch ([event keyCode]) {
            case kVK_RightArrow:
            {
                [self fastForward:nil];
            }
                break;
            case kVK_LeftArrow:
            {
                [self fastRewind:nil];
            }
                break;
            case kVK_DownArrow:
            {
                float volume = self.volume;
                volume -= 0.1;
                if (volume < 0) {
                    volume = .0f;
                }
                self.volume = volume;
                [self onVolumeChange:nil];
            }
                break;
            case kVK_UpArrow:
            {
                float volume = self.volume;
                volume += 0.1;
                if (volume > 1) {
                    volume = 1.0f;
                }
                self.volume = volume;
                [self onVolumeChange:nil];
            }
                break;
            case kVK_Space:
            {
                [self pauseOrPlay:nil];
            }
                break;
            case kVK_ANSI_Minus:
            {
                if (self.player) {
                    float delay = [self.player currentSubtitleExtraDelay];
                    delay -= 2;
                    self.subtitleDelay = delay;
                    [self.player updateSubtitleExtraDelay:delay];
                }
            }
                break;
            case kVK_ANSI_Equal:
            {
                if (self.player) {
                    float delay = [self.player currentSubtitleExtraDelay];
                    delay += 2;
                    self.subtitleDelay = delay;
                    [self.player updateSubtitleExtraDelay:delay];
                }
            }
                break;
            case kVK_Escape:
            {
                if (self.view.window.styleMask & NSWindowStyleMaskFullScreen) {
                    [self.view.window toggleFullScreen:nil];
                }
            }
                break;
            case kVK_Return:
            {
                if (!(self.view.window.styleMask & NSWindowStyleMaskFullScreen)) {
                    [self.view.window toggleFullScreen:nil];
                }
            }
                break;
            default:
            {
                NSLog(@"keyCode:0x%X",[event keyCode]);
            }
                break;
        }
    }
}

- (void)loadNASPlayList:(NSURL*)url
{
    NSString *nas_text = [[NSString alloc] initWithContentsOfFile:[url path] encoding:NSUTF8StringEncoding error:nil];
    nas_text = [nas_text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSArray *lines = [nas_text componentsSeparatedByString:@"\n"];
    NSString *host = [lines firstObject];
    [self.playList removeAllObjects];
    NSString *lastVideo = [[NSUserDefaults standardUserDefaults] objectForKey:lastPlayedKey];
    NSURL *lastUrl = nil;
    for (int i = 1; i < lines.count; i++) {
        NSString *path = lines[i];
        if (!path || [path length] == 0 || [path hasPrefix:@"#"]) {
            continue;
        }
        
        NSString *urlStr = [host stringByAppendingString:path];
        NSURL *url = [NSURL URLWithString:urlStr];
        [self.playList addObject:url];
        
        if (lastVideo && !lastUrl && [path containsString:lastVideo]) {
            lastUrl = url;
        }
    }
    if (lastUrl) {
        [self doStopPlay];
        BOOL hwaccel = [self preferHW];
        [self playURL:lastUrl hwaccel:hwaccel];
    } else {
        [self playFirstIfNeed];
    }
}

- (NSMutableArray *)playList
{
    if (!_playList) {
        _playList = [NSMutableArray array];
    }
    return _playList;
}

- (NSMutableArray *)subtitles
{
    if (!_subtitles) {
        _subtitles = [NSMutableArray array];
    }
    return _subtitles;
}

- (void)perpareIJKPlayer:(NSURL *)url hwaccel:(BOOL)hwaccel
{
    if (self.playingUrl) {
        [self doStopPlay];
    }
    
    self.playingUrl = url;
    
    if (my_stdout) {
        fflush(my_stdout);
        fclose(my_stdout);
        my_stdout = NULL;
    }
    if (my_stderr) {
        fflush(my_stderr);
        fclose(my_stderr);
        my_stderr = NULL;
    }
    
    self.seeking = NO;
    
    if (self.autoTest) {
        
        [IJKFFMoviePlayerController setLogLevel:k_IJK_LOG_INFO];
        
        NSString *dir = [self dirForCurrentPlayingUrl];
        NSString *movieName = [[url absoluteString] lastPathComponent];
        NSString *fileName = [NSString stringWithFormat:@"%@.txt",movieName];
        NSString *filePath = [dir stringByAppendingPathComponent:fileName];
        
        my_stdout = freopen([filePath cStringUsingEncoding:NSASCIIStringEncoding], "a+", stdout);
        my_stderr = freopen([filePath cStringUsingEncoding:NSASCIIStringEncoding], "a+", stderr);
        
        self.autoSeeked = NO;
        self.snapshot2 = NO;
    }
    
    IJKFFOptions *options = [IJKFFOptions optionsByDefault];
    //视频帧处理不过来的时候丢弃一些帧达到同步的效果
    [options setPlayerOptionIntValue:1 forKey:@"framedrop"];
    [options setPlayerOptionIntValue:6      forKey:@"video-pictq-size"];
    //    [options setPlayerOptionIntValue:50000      forKey:@"min-frames"];
    [options setPlayerOptionIntValue:119     forKey:@"max-fps"];
    [options setPlayerOptionIntValue:self.loop?0:1      forKey:@"loop"];
    [options setCodecOptionIntValue:IJK_AVDISCARD_DEFAULT forKey:@"skip_loop_filter"];
    //for mgeg-ts seek
    [options setFormatOptionIntValue:1 forKey:@"seek_flag_keyframe"];
//    default is 5000000,but some high bit rate video probe faild cause no audio.
    [options setFormatOptionValue:@"10000000" forKey:@"probesize"];
//    [options setFormatOptionValue:@"1" forKey:@"flush_packets"];
//    [options setPlayerOptionIntValue:0      forKey:@"packet-buffering"];
//    [options setPlayerOptionIntValue:1      forKey:@"render-wait-start"];
//    [options setCodecOptionIntValue:1 forKey:@"allow_software"];
//    test video decoder performance.
//    [options setPlayerOptionIntValue:1 forKey:@"an"];
//    [options setPlayerOptionIntValue:1 forKey:@"nodisp"];
    
    [options setPlayerOptionIntValue:[MRUtil boolForKey:@"values.copy_hw_frame"] forKey:@"copy_hw_frame"];
    if ([url isFileURL]) {
        //图片不使用 cvpixelbufferpool
        NSString *ext = [[[url path] pathExtension] lowercaseString];
        if ([[MRUtil pictureType] containsObject:ext]) {
            [options setPlayerOptionIntValue:0      forKey:@"enable-cvpixelbufferpool"];
            if ([@"gif" isEqualToString:ext]) {
                [options setPlayerOptionIntValue:-1      forKey:@"loop"];
            }
        }
    }
    
//    [options setFormatOptionIntValue:0 forKey:@"http_persistent"];
    //请求m3u8文件里的ts出错后是否继续请求下一个ts，默认是1000
    [options setFormatOptionIntValue:1 forKey:@"max_reload"];
    
    BOOL isLive = NO;
    //isLive表示是直播还是点播
    if (isLive) {
        // Param for living
        [options setPlayerOptionIntValue:1 forKey:@"infbuf"];
        [options setPlayerOptionIntValue:0 forKey:@"packet-buffering"];
    } else {
        // Param for playback
        [options setPlayerOptionIntValue:0 forKey:@"infbuf"];
        [options setPlayerOptionIntValue:1 forKey:@"packet-buffering"];
    }
    
//    [options setPlayerOptionValue:@"fcc-bgra"        forKey:@"overlay-format"];
//    [options setPlayerOptionValue:@"fcc-bgr0"        forKey:@"overlay-format"];
//    [options setPlayerOptionValue:@"fcc-argb"        forKey:@"overlay-format"];
//    [options setPlayerOptionValue:@"fcc-0rgb"        forKey:@"overlay-format"];
//    [options setPlayerOptionValue:@"fcc-uyvy"        forKey:@"overlay-format"];
//    [options setPlayerOptionValue:@"fcc-i420"        forKey:@"overlay-format"];
//    [options setPlayerOptionValue:@"fcc-nv12"        forKey:@"overlay-format"];
    
    [options setPlayerOptionValue:self.fcc forKey:@"overlay-format"];
    [options setPlayerOptionIntValue:hwaccel forKey:@"videotoolbox_hwaccel"];
    [options setPlayerOptionIntValue:self.accurateSeek forKey:@"enable-accurate-seek"];
    [options setPlayerOptionIntValue:1500 forKey:@"accurate-seek-timeout"];
    
    options.metalRenderer = !self.use_openGL;
    options.showHudView = self.shouldShowHudView;
    
    NSMutableArray *dus = [NSMutableArray array];
    if ([url.scheme isEqualToString:@"file"] && [url.absoluteString.pathExtension isEqualToString:@"m3u8"]) {
        NSString *str = [[NSString alloc] initWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
        NSArray *lines = [str componentsSeparatedByString:@"\n"];
        double sum = 0;
        for (NSString *line in lines) {
            if ([line hasPrefix:@"#EXTINF"]) {
                NSArray *items = [line componentsSeparatedByString:@":"];
                NSString *du = [[[items lastObject] componentsSeparatedByString:@","] firstObject];
                if (du) {
                    sum += [du doubleValue];
                    [dus addObject:@(sum)];
                }
            } else {
                continue;
            }
        }
    }
    self.playerSlider.tags = dus;
    
    [NSDocumentController.sharedDocumentController noteNewRecentDocumentURL:url];
    self.player = [[IJKFFMoviePlayerController alloc] initWithContentURL:url withOptions:options];
    
    NSView <IJKVideoRenderingProtocol>*playerView = self.player.view;
    CGRect rect = self.view.frame;
    rect.origin = CGPointZero;
    playerView.frame = rect;
    playerView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.view addSubview:playerView positioned:NSWindowBelow relativeTo:nil];
    
    playerView.showHdrAnimation = !hdrAnimationShown;
    //playerView.preventDisplay = YES;
    //test
    [playerView setBackgroundColor:0 g:0 b:0];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ijkPlayerFirstVideoFrameRendered:) name:IJKMPMoviePlayerFirstVideoFrameRenderedNotification object:self.player];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ijkPlayerPreparedToPlay:) name:IJKMPMediaPlaybackIsPreparedToPlayDidChangeNotification object:self.player];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ijkPlayerPreparedToPlay:) name:IJKMPMoviePlayerSelectedStreamDidChangeNotification object:self.player];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ijkPlayerDidFinish:) name:IJKMPMoviePlayerPlaybackDidFinishNotification object:self.player];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ijkPlayerCouldNotFindCodec:) name:IJKMPMovieNoCodecFoundNotification object:self.player];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ijkPlayerNaturalSizeAvailable:) name:IJKMPMovieNaturalSizeAvailableNotification object:self.player];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ijkPlayerAfterSeekFirstVideoFrameDisplay:) name:IJKMPMoviePlayerAfterSeekFirstVideoFrameDisplayNotification object:self.player];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ijkPlayerVideoDecoderFatal:) name:IJKMPMoviePlayerVideoDecoderFatalNotification object:self.player];
    
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ijkPlayerRecvWarning:) name:IJKMPMoviePlayerPlaybackRecvWarningNotification object:self.player];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ijkPlayerHdrAnimationStateChanged:) name:IJKMoviePlayerHDRAnimationStateChanged object:self.player.view];
    
    
    self.kvoCtrl = [[IJKKVOController alloc] initWithTarget:self.player.monitor];
    [self.kvoCtrl safelyAddObserver:self forKeyPath:@"vdecoder" options:NSKeyValueObservingOptionNew context:nil];
    self.player.shouldAutoplay = YES;
    [self onVolumeChange:nil];
}

#pragma mark - ijkplayer

- (void)ijkPlayerRecvWarning:(NSNotification *)notifi
{
    if (self.player == notifi.object) {
        int reason = [notifi.userInfo[IJKMPMoviePlayerPlaybackWarningReasonUserInfoKey] intValue];
        if (reason == 1000) {
            NSLog(@"recv warning:%d",reason);
            //会收到很多次，所以立马取消掉监听
            [[NSNotificationCenter defaultCenter] removeObserver:self name:IJKMPMoviePlayerPlaybackRecvWarningNotification object:notifi.object];
            [self retry];
        }
    }
}

- (void)ijkPlayerHdrAnimationStateChanged:(NSNotification *)notifi
{
    if (self.player.view == notifi.object) {
        int state = [notifi.userInfo[@"state"] intValue];
        if (state == 1) {
            NSLog(@"hdr animation is begin.");
        } else if (state == 2) {
            NSLog(@"hdr animation is end.");
            hdrAnimationShown = 1;
        }
    }
}

- (void)ijkPlayerFirstVideoFrameRendered:(NSNotification *)notifi
{
    if (self.player == notifi.object) {
        NSLog(@"first frame cost:%lldms",self.player.monitor.firstVideoFrameLatency);
        self.seekCostLb.stringValue = [NSString stringWithFormat:@"%lldms",self.player.monitor.firstVideoFrameLatency];
    }
}

- (void)ijkPlayerVideoDecoderFatal:(NSNotification *)notifi
{
    if (self.player == notifi.object) {
        if (self.player.isUsingHardwareAccelerae) {
            NSLog(@"decoder fatal:%@;close videotoolbox hwaccel.",notifi.userInfo);
            NSURL *playingUrl = self.playingUrl;
            [self doStopPlay];
            [self playURL:playingUrl hwaccel:NO];
            return;
        }
    }
    NSLog(@"decoder fatal:%@",notifi.userInfo);
}

- (void)ijkPlayerAfterSeekFirstVideoFrameDisplay:(NSNotification *)notifi
{
    NSLog(@"seek cost time:%@ms",notifi.userInfo[@"du"]);
//    self.seeking = NO;
    self.seekCostLb.stringValue = [NSString stringWithFormat:@"%@ms",notifi.userInfo[@"du"]];
//    //seek 完毕后仍旧是播放状态就开始播放
//    if (self.playCtrlBtn.state == NSControlStateValueOn) {
//        [self.player play];
//    }
}

- (void)ijkPlayerCouldNotFindCodec:(NSNotification *)notifi
{
    NSLog(@"找不到解码器，联系开发小帅锅：%@",notifi.userInfo);
}

- (void)ijkPlayerNaturalSizeAvailable:(NSNotification *)notifi
{
//    if (self.player == notifi.object) {
//        CGSize const videoSize = NSSizeFromString(notifi.userInfo[@"size"]);
//        if (!CGSizeEqualToSize(self.view.window.aspectRatio, videoSize)) {
//
////            [self.view.window setAspectRatio:videoSize];
//            CGRect rect = self.view.window.frame;
//
//            CGPoint center = CGPointMake(rect.origin.x + rect.size.width/2.0, rect.origin.y + rect.size.height/2.0);
//            static float kMaxRatio = 1.0;
//            if (videoSize.width < videoSize.height) {
//                rect.size.width = rect.size.height / videoSize.height * videoSize.width;
//                if (rect.size.width > [[NSScreen mainScreen]frame].size.width * kMaxRatio) {
//                    float ratio = [[NSScreen mainScreen]frame].size.width * kMaxRatio / rect.size.width;
//                    rect.size.width *= ratio;
//                    rect.size.height *= ratio;
//                }
//            } else {
//                rect.size.height = rect.size.width / videoSize.width * videoSize.height;
//                if (rect.size.height > [[NSScreen mainScreen]frame].size.height * kMaxRatio) {
//                    float ratio = [[NSScreen mainScreen]frame].size.height * kMaxRatio / rect.size.height;
//                    rect.size.width *= ratio;
//                    rect.size.height *= ratio;
//                }
//            }
//            //keep center.
//            rect.origin = CGPointMake(center.x - rect.size.width/2.0, center.y - rect.size.height/2.0);
//            rect.size = CGSizeMake((int)rect.size.width, (int)rect.size.height);
//            NSLog(@"窗口位置:%@;视频尺寸：%@",NSStringFromRect(rect),NSStringFromSize(videoSize));
//            [NSAnimationContext runAnimationGroup:^(NSAnimationContext * _Nonnull context) {
//                [self.view.window.animator setFrame:rect display:YES];
//                [self.view.window.animator center];
//            }];
//
//        }
//    }
}

- (void)ijkPlayerDidFinish:(NSNotification *)notifi
{
    if (self.player == notifi.object) {
        int reason = [notifi.userInfo[IJKMPMoviePlayerPlaybackDidFinishReasonUserInfoKey] intValue];
        if (IJKMPMovieFinishReasonPlaybackError == reason) {
            int errCode = [notifi.userInfo[@"code"] intValue];
            NSLog(@"播放出错:%d",errCode);
            if (self.autoTest) {
                NSString *dir = [self saveDir:nil];
                NSString *fileName = [NSString stringWithFormat:@"a错误汇总.txt"];
                NSString *filePath = [dir stringByAppendingPathComponent:fileName];
                FILE *pf = fopen([filePath UTF8String], "a+");
                fprintf(pf, "%d:%s\n",errCode,[[self.playingUrl absoluteString]UTF8String]);
                fflush(pf);
                fclose(pf);
                
                //-5 网络错误
                if (errCode != -5) {
                    [self playNext:nil];
                }
            } else {
                NSAlert *alert = [[NSAlert alloc] init];
                NSString *urlString = [self.player.contentURL isFileURL] ? [self.player.contentURL path] : [self.player.contentURL absoluteString];
                alert.informativeText = urlString;
                alert.messageText = [NSString stringWithFormat:@"%@",notifi.userInfo[@"msg"]];
                
                if ([self.playList count] > 1) {
                    [alert addButtonWithTitle:@"Next"];
                }
                [alert addButtonWithTitle:@"Retry"];
                [alert addButtonWithTitle:@"OK"];
                [alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse returnCode) {
                    if ([[alert buttons] count] == 3) {
                        if (returnCode == NSAlertFirstButtonReturn) {
                            [self playNext:nil];
                        } else if (returnCode == NSAlertSecondButtonReturn) {
                            //retry
                            [self retry];
                        } else {
                            //
                        }
                    } else if ([[alert buttons] count] == 2) {
                        if (returnCode == NSAlertFirstButtonReturn) {
                            //retry
                            [self retry];
                        } else if (returnCode == NSAlertSecondButtonReturn) {
                            //
                        }
                    }
                }];
            }
        } else if (IJKMPMovieFinishReasonPlaybackEnded == reason) {
            NSLog(@"播放结束");
            if ([[MRUtil pictureType] containsObject:[[self.playingUrl lastPathComponent] pathExtension]]) {
//                [self stopPlay];
            } else {
                NSString *key = [[self.playingUrl absoluteString] md5Hash];
                [[NSUserDefaults standardUserDefaults] removeObjectForKey:key];
                self.playingUrl = nil;
                [self playNext:nil];
            }
        }
    }
}

- (void)saveCurrentPlayRecord
{
    if (self.playingUrl && self.player) {
        NSString *key = [[self.playingUrl absoluteString] md5Hash];
        
        if (self.player.duration > 0 &&
            self.player.duration - self.player.currentPlaybackTime < 10 &&
            self.player.currentPlaybackTime / self.player.duration > 0.9) {
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:key];
        } else {
            [[NSUserDefaults standardUserDefaults] setDouble:self.player.currentPlaybackTime forKey:key];
        }
    }
}

- (NSTimeInterval)readCurrentPlayRecord
{
    if (self.playingUrl) {
        NSString *key = [[self.playingUrl absoluteString] md5Hash];
        return [[NSUserDefaults standardUserDefaults] doubleForKey:key];
    }
    return 0.0;
}

- (void)ijkPlayerPreparedToPlay:(NSNotification *)notifi
{
    if (self.player.isPreparedToPlay) {
        
        NSDictionary *dic = self.player.monitor.mediaMeta;
        
        [self.subtitlePopUpBtn removeAllItems];
        NSString *currentTitle = @"选择字幕";
        [self.subtitlePopUpBtn addItemWithTitle:currentTitle];
        
        [self.audioPopUpBtn removeAllItems];
        NSString *currentAudio = @"选择音轨";
        [self.audioPopUpBtn addItemWithTitle:currentAudio];
        
        [self.videoPopUpBtn removeAllItems];
        NSString *currentVideo = @"选择视轨";
        [self.videoPopUpBtn addItemWithTitle:currentVideo];
        
        for (NSDictionary *stream in dic[kk_IJKM_KEY_STREAMS]) {
            NSString *type = stream[k_IJKM_KEY_TYPE];
            int streamIdx = [stream[k_IJKM_KEY_STREAM_IDX] intValue];
            if ([type isEqualToString:k_IJKM_VAL_TYPE__SUBTITLE]) {
                NSLog(@"subtile all meta:%@",stream);
                NSString *url = stream[k_IJKM_KEY_EX_SUBTITLE_URL];
                NSString *title = nil;
                if (url) {
                    title = [[url lastPathComponent] stringByRemovingPercentEncoding];
                } else {
                    title = stream[k_IJKM_KEY_TITLE];
                    if (title.length == 0) {
                        title = stream[k_IJKM_KEY_LANGUAGE];
                    }
                    if (title.length == 0) {
                        title = @"未知";
                    }
                }
                title = [NSString stringWithFormat:@"%@-%d",title,streamIdx];
                if ([dic[k_IJKM_VAL_TYPE__SUBTITLE] intValue] == streamIdx) {
                    currentTitle = title;
                }
                [self.subtitlePopUpBtn addItemWithTitle:title];
            } else if ([type isEqualToString:k_IJKM_VAL_TYPE__AUDIO]) {
                NSLog(@"audio all meta:%@",stream);
                NSString *title = stream[k_IJKM_KEY_TITLE];
                if (title.length == 0) {
                    title = stream[k_IJKM_KEY_LANGUAGE];
                }
                if (title.length == 0) {
                    title = @"未知";
                }
                title = [NSString stringWithFormat:@"%@-%d",title,streamIdx];
                if ([dic[k_IJKM_VAL_TYPE__AUDIO] intValue] == streamIdx) {
                    currentAudio = title;
                }
                [self.audioPopUpBtn addItemWithTitle:title];
            } else if ([type isEqualToString:k_IJKM_VAL_TYPE__VIDEO]) {
                NSLog(@"video all meta:%@",stream);
                NSString *title = stream[k_IJKM_KEY_TITLE];
                if (title.length == 0) {
                    title = stream[k_IJKM_KEY_LANGUAGE];
                }
                if (title.length == 0) {
                    title = @"未知";
                }
                title = [NSString stringWithFormat:@"%@-%d",title,streamIdx];
                if ([dic[k_IJKM_VAL_TYPE__VIDEO] intValue] == streamIdx) {
                    currentVideo = title;
                }
                [self.videoPopUpBtn addItemWithTitle:title];
            }
        }
        [self.subtitlePopUpBtn selectItemWithTitle:currentTitle];
        [self.audioPopUpBtn selectItemWithTitle:currentAudio];
        [self.videoPopUpBtn selectItemWithTitle:currentVideo];
        
        if (!self.tickTimer) {
            self.tickTimer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(onTick:) userInfo:nil repeats:YES];
        }
    }
}

- (void)playURL:(NSURL *)url hwaccel:(BOOL)hwaccel
{
    if (!url) {
        return;
    }
    [self destroyPlayer];
    [self perpareIJKPlayer:url hwaccel:hwaccel];
    NSString *videoName = [url isFileURL] ? [url path] : [[url resourceSpecifier] lastPathComponent];
    
    NSInteger idx = [self.playList indexOfObject:self.playingUrl] + 1;
    
    [[NSUserDefaults standardUserDefaults] setObject:videoName forKey:lastPlayedKey];
    
    NSString *title = [NSString stringWithFormat:@"(%ld/%ld)%@",(long)idx,[[self playList] count],videoName];
    [self.view.window setTitle:title];
    
    [self onReset:nil];
    self.playCtrlBtn.state = NSControlStateValueOn;
    
    IJKSDLSubtitlePreference p = self.player.view.subtitlePreference;
    p.bottomMargin = self.subtitleMargin;
    NSNumber *number = [[NSUserDefaultsController sharedUserDefaultsController] valueForKeyPath:@"values.subtitleFontRatio"];
    p.ratio = [number floatValue];
    self.player.view.subtitlePreference = p;
    
    int startTime = (int)([self readCurrentPlayRecord] * 1000);
//    [options setPlayerOptionIntValue:startTime forKey:@"seek-at-start"];
    [self.player setPlayerOptionIntValue:startTime forKey:@"seek-at-start"];
    [self.player prepareToPlay];
    
    if ([self.subtitles count] > 0) {
        NSURL *firstUrl = [self.subtitles firstObject];
        [self.player loadThenActiveSubtitle:firstUrl];
        [self.player loadSubtitlesOnly:[self.subtitles subarrayWithRange:NSMakeRange(1, self.subtitles.count - 1)]];
    }
    
    [self onTick:nil];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context
{
    if (object == self.player.monitor) {
        if ([keyPath isEqualToString:@"vdecoder"]) {
            NSLog(@"current video decoder:%@",change[NSKeyValueChangeNewKey]);
        }
    }
}

static IOPMAssertionID g_displaySleepAssertionID;

- (void)enableComputerSleep:(BOOL)enable
{
    if (!g_displaySleepAssertionID && !enable)
    {
        NSLog(@"enableComputerSleep:NO");
        IOPMAssertionCreateWithName(kIOPMAssertionTypeNoDisplaySleep, kIOPMAssertionLevelOn,
                                    (__bridge CFStringRef)[[NSBundle mainBundle] bundleIdentifier],&g_displaySleepAssertionID);
    }
    else if (g_displaySleepAssertionID && enable)
    {
        NSLog(@"enableComputerSleep:YES");
        IOPMAssertionRelease(g_displaySleepAssertionID);
        g_displaySleepAssertionID = 0;
    }
}

- (void)onTick:(NSTimer *)sender
{
    long interval = (long)self.player.currentPlaybackTime;
    long duration = self.player.monitor.duration / 1000;
    self.playedTimeLb.stringValue = [NSString stringWithFormat:@"%02d:%02d",(int)(interval/60),(int)(interval%60)];
    self.durationTimeLb.stringValue = [NSString stringWithFormat:@"%02d:%02d",(int)(duration/60),(int)(duration%60)];
    self.playerSlider.playedValue = interval;
    self.playerSlider.minValue = 0;
    self.playerSlider.maxValue = duration;
    self.playerSlider.preloadValue = self.player.playableDuration;
    
    if ([self.player isPlaying]) {
        self.tickCount ++;
        if (self.tickCount % 60 == 0) {
            [self saveCurrentPlayRecord];
        }
        if (self.autoTest) {
            //auto seek
            if (duration > 0) {
                if (interval >= 10) {
                    if (!self.autoSeeked) {
                        NSLog(@"\n-----------\n%@\n-----------\n",[self.player allHudItem]);
                        [self onCaptureShot:nil];
                        [self seekTo:duration - 10];
                        self.autoSeeked = YES;
                    }
                    
                    if (interval > duration - 5) {
                        if (!self.snapshot2) {
                            NSLog(@"\n-----------\n%@\n-----------\n",[self.player allHudItem]);
                            [self onCaptureShot:nil];
                            self.snapshot2 = YES;
                        }
                    }
                }
            }
            
            if (self.tickCount >= 60) {
                NSLog(@"\nwtf? why played %ds\n",self.tickCount);
                NSLog(@"\n-----------\n%@\n-----------\n",[self.player allHudItem]);
                [self onCaptureShot:nil];
                [self playNext:nil];
            }
        }
        [self enableComputerSleep:NO];
    }
}

- (NSURL *)existTaskForUrl:(NSURL *)url
{
    NSURL *t = nil;
    for (NSURL *item in [self.playList copy]) {
        if ([[item absoluteString] isEqualToString:[url absoluteString]]) {
            t = item;
            break;
        }
    }
    return t;
}

- (void)appendToPlayList:(NSArray *)bookmarkArr
{
    NSMutableArray *videos = [NSMutableArray array];
    NSMutableArray *subtitles = [NSMutableArray array];
    
    if (bookmarkArr.count == 1) {
        NSDictionary *dic = bookmarkArr[0];
        NSURL *url = dic[@"url"];
        if ([[[url pathExtension] lowercaseString] isEqualToString:@"xlist"]) {
            self.autoTest = YES;
            [self loadNASPlayList:url];
            return;
        }
    }
    
    for (NSDictionary *dic in bookmarkArr) {
        NSURL *url = dic[@"url"];
        
        if ([self existTaskForUrl:url]) {
            continue;
        }
        if ([dic[@"type"] intValue] == 0) {
            [videos addObject:url];
        } else if ([dic[@"type"] intValue] == 1) {
            [subtitles addObject:url];
        } else {
            NSAssert(NO, @"没有处理的文件:%@",url);
        }
    }
    
    if ([videos count] > 0) {
        [self.playList addObjectsFromArray:videos];
        [self playFirstIfNeed];
    }
    
    if ([subtitles count] > 0) {
        [self.subtitles addObjectsFromArray:subtitles];
        
        NSURL *firstUrl = [subtitles firstObject];
        [subtitles removeObjectAtIndex:0];
        [self.player loadThenActiveSubtitle:firstUrl];
        [self.player loadSubtitlesOnly:subtitles];
    }
}

#pragma mark - 拖拽

- (void)handleDragFileList:(nonnull NSArray<NSURL *> *)fileUrls
{
    BOOL needPlay = YES;
    NSMutableArray *bookmarkArr = [NSMutableArray array];
    for (NSURL *url in fileUrls) {
        //先判断是不是文件夹
        BOOL isDirectory = NO;
        BOOL isExist = [[NSFileManager defaultManager] fileExistsAtPath:[url path] isDirectory:&isDirectory];
        if (isExist) {
            if (isDirectory) {
                //扫描文件夹
                NSString *dir = [url path];
                NSArray *dicArr = [MRUtil scanFolderWithPath:dir filter:[MRUtil acceptMediaType]];
                if ([dicArr count] > 0) {
                    [bookmarkArr addObjectsFromArray:dicArr];
                }
            } else {
                NSString *pathExtension = [[url pathExtension] lowercaseString];
                if ([[MRUtil acceptMediaType] containsObject:pathExtension]) {
                    if ([[MRUtil subtitleType] containsObject:pathExtension]) {
                        needPlay = NO;
                    }
                    NSDictionary *dic = [MRUtil makeBookmarkWithURL:url];
                    [bookmarkArr addObject:dic];
                }
            }
        }
    }
    
    if (needPlay) {
        //拖拽播放时清空原先的列表
        [self.playList removeAllObjects];
        [self doStopPlay];
    }
    
    [self appendToPlayList:bookmarkArr];
}

- (NSDragOperation)acceptDragOperation:(NSArray<NSURL *> *)list
{
    for (NSURL *url in list) {
        if (url) {
            //先判断是不是文件夹
            BOOL isDirectory = NO;
            BOOL isExist = [[NSFileManager defaultManager] fileExistsAtPath:[url path] isDirectory:&isDirectory];
            if (isExist) {
                if (isDirectory) {
                   //扫描文件夹
                   NSString *dir = [url path];
                   NSArray *dicArr = [MRUtil scanFolderWithPath:dir filter:[MRUtil acceptMediaType]];
                    if ([dicArr count] > 0) {
                        return NSDragOperationCopy;
                    }
                } else {
                    NSString *pathExtension = [[url pathExtension] lowercaseString];
                    if ([[MRUtil acceptMediaType] containsObject:pathExtension]) {
                        return NSDragOperationCopy;
                    }
                }
            }
        }
    }
    return NSDragOperationNone;
}

- (void)playFirstIfNeed
{
    if (!self.playingUrl) {
        [self pauseOrPlay:nil];
    }
}

#pragma mark - 点击事件

- (IBAction)pauseOrPlay:(NSButton *)sender
{
    if (!sender) {
        if (self.playCtrlBtn.state == NSControlStateValueOff) {
            self.playCtrlBtn.state = NSControlStateValueOn;
        } else {
            self.playCtrlBtn.state = NSControlStateValueOff;
        }
    }
    
    if (self.playingUrl) {
        if (self.playCtrlBtn.state == NSControlStateValueOff) {
            [self enableComputerSleep:YES];
            [self.player pause];
            [self toggleTitleBar:YES];
        } else {
            [self.player play];
        }
    } else {
        [self playNext:nil];
    }
}

- (IBAction)toggleHUD:(id)sender
{
    self.shouldShowHudView = !self.shouldShowHudView;
    self.player.shouldShowHudView = self.shouldShowHudView;
}

- (IBAction)onMoreFunc:(id)sender
{
    [self toggleAdvancedViewShow];
}

- (BOOL)preferHW
{
    return [MRUtil boolForKey:@"values.hw"];
}

- (void)retry
{
    NSURL *url = self.playingUrl;
    [self doStopPlay];
    BOOL hwaccel = [self preferHW];
    [self playURL:url hwaccel:hwaccel];
}

- (void)onStop
{
    [self saveCurrentPlayRecord];
    [self doStopPlay];
}

- (void)destroyPlayer
{
    if (self.player) {
        [self.kvoCtrl safelyRemoveAllObservers];
        [[NSNotificationCenter defaultCenter] removeObserver:self name:nil object:self.player];
        [self.player.view removeFromSuperview];
        [self.player pause];
        [self.player shutdown];
        self.player = nil;
    }
}

- (void)doStopPlay
{
    NSLog(@"stop play");
    [self destroyPlayer];
    
    if (self.tickTimer) {
        [self.tickTimer invalidate];
        self.tickTimer = nil;
        self.tickCount = 0;
    }
    
    if (self.playingUrl) {
        self.playingUrl = nil;
    }
    
    [self.view.window setTitle:@""];
    self.playedTimeLb.stringValue = @"--:--";
    self.durationTimeLb.stringValue = @"--:--";
    [self enableComputerSleep:YES];
    self.playCtrlBtn.state = NSControlStateValueOff;
}

- (IBAction)playPrevious:(NSButton *)sender
{
    if ([self.playList count] == 0) {
        return;
    }
    
    [self saveCurrentPlayRecord];
    
    NSUInteger idx = [self.playList indexOfObject:self.playingUrl];
    if (idx == NSNotFound) {
        idx = 0;
    } else if (idx <= 0) {
        idx = [self.playList count] - 1;
    } else {
        idx --;
    }
    
    NSURL *url = self.playList[idx];
    BOOL hwaccel = [self preferHW];
    [self playURL:url hwaccel:hwaccel];
}

- (IBAction)playNext:(NSButton *)sender
{
    [self saveCurrentPlayRecord];
    if ([self.playList count] == 0) {
        [self doStopPlay];
        return;
    }

    NSUInteger idx = [self.playList indexOfObject:self.playingUrl];
    //when autotest not loop
    if (self.autoTest && idx == self.playList.count - 1) {
        [self doStopPlay];
        self.autoTest = NO;
        [self.playList removeAllObjects];
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:lastPlayedKey];
        return;
    }
    
    if (idx == NSNotFound) {
        idx = 0;
    } else if (idx >= [self.playList count] - 1) {
        idx = 0;
    } else {
        idx ++;
    }
    
    NSURL *url = self.playList[idx];
    BOOL hwaccel = [self preferHW];
    [self playURL:url hwaccel:hwaccel];
}

- (void)seekTo:(float)cp
{
    NSLog(@"seek to:%g",cp);
//    if (self.seeking) {
//        NSLog(@"xql ignore seek.");
//        return;
//    }
//    self.seeking = YES;
    if (cp < 0) {
        cp = 0;
    }
//    [self.player pause];
    self.seekCostLb.stringValue = @"";
    if (self.player.monitor.duration > 0) {
        if (cp >= self.player.monitor.duration) {
            cp = self.player.monitor.duration - 5;
        }
        self.player.currentPlaybackTime = cp;
        
        long interval = (long)cp;
        self.playedTimeLb.stringValue = [NSString stringWithFormat:@"%02d:%02d",(int)(interval/60),(int)(interval%60)];
        self.playerSlider.playedValue = interval;
    }
}

- (IBAction)fastRewind:(NSButton *)sender
{
    float cp = self.player.currentPlaybackTime;
    cp -= 10;
    [self seekTo:cp];
}

- (IBAction)fastForward:(NSButton *)sender
{    
    if (self.player.playbackState == IJKMPMoviePlaybackStatePaused) {
        [self.player stepToNextFrame];
    } else {
        float cp = self.player.currentPlaybackTime;
        cp += 10;
        [self seekTo:cp];
    }
}

- (IBAction)onVolumeChange:(NSSlider *)sender
{
    self.player.playbackVolume = self.volume;
}

#pragma mark 倍速设置

- (void)updateSpeed:(NSButton *)sender
{
    NSInteger tag = sender.tag;
    float speed = tag / 100.0;
    self.player.playbackRate = speed;
}

#pragma mark 字幕设置

- (IBAction)onChangeSubtitleColor:(NSPopUpButton *)sender
{
    NSMenuItem *item = [sender selectedItem];
    int bgrValue = (int)item.tag;
    IJKSDLSubtitlePreference p = self.player.view.subtitlePreference;
    p.color = bgrValue;
    self.player.view.subtitlePreference = p;
    if (!self.player.isPlaying) {
        [self.player.view setNeedsRefreshCurrentPic];
    }
}

- (IBAction)onChangeSubtitleSize:(NSStepper *)sender
{
    IJKSDLSubtitlePreference p = self.player.view.subtitlePreference;
    p.ratio = sender.floatValue;
    self.player.view.subtitlePreference = p;
    if (!self.player.isPlaying) {
        [self.player.view setNeedsRefreshCurrentPic];
    }
}

- (IBAction)onSelectSubtitle:(NSPopUpButton*)sender
{
    if (sender.indexOfSelectedItem == 0) {
        [self.player closeCurrentStream:k_IJKM_VAL_TYPE__SUBTITLE];
    } else {
        NSString *title = sender.selectedItem.title;
        NSArray *items = [title componentsSeparatedByString:@"-"];
        int idx = [[items lastObject] intValue];
        NSLog(@"SelectSubtitleTrack:%d",idx);
        [self.player exchangeSelectedStream:idx];
    }
}

- (IBAction)onChangeSubtitleDelay:(NSStepper *)sender
{
    float delay = sender.floatValue;
    [self.player updateSubtitleExtraDelay:delay];
}

- (IBAction)onChangeSubtitleBottomMargin:(NSSlider *)sender
{
    IJKSDLSubtitlePreference p = self.player.view.subtitlePreference;
    p.bottomMargin = sender.floatValue;
    self.player.view.subtitlePreference = p;
    if (!self.player.isPlaying) {
        [self.player.view setNeedsRefreshCurrentPic];
    }
}

#pragma mark 画面设置

- (IBAction)onChangeRenderType:(NSPopUpButton *)sender
{
    [self retry];
}

- (IBAction)onChangeScaleMode:(NSPopUpButton *)sender
{
    NSMenuItem *item = [sender selectedItem];
    if (item.tag == 1) {
        //scale to fill
        [self.player setScalingMode:IJKMPMovieScalingModeFill];
    } else if (item.tag == 2) {
        //aspect fill
        [self.player setScalingMode:IJKMPMovieScalingModeAspectFill];
    } else if (item.tag == 3) {
        //aspect fit
        [self.player setScalingMode:IJKMPMovieScalingModeAspectFit];
    }
    
    if (!self.player.isPlaying) {
        [self.player.view setNeedsRefreshCurrentPic];
    }
}

- (IBAction)onRotate:(NSPopUpButton *)sender
{
    NSMenuItem *item = [sender selectedItem];
    
    IJKSDLRotatePreference preference = self.player.view.rotatePreference;
    
    if (item.tag == 0) {
        preference.type = IJKSDLRotateNone;
        preference.degrees = 0;
    } else if (item.tag == 1) {
        preference.type = IJKSDLRotateZ;
        preference.degrees = -90;
    } else if (item.tag == 2) {
        preference.type = IJKSDLRotateZ;
        preference.degrees = -180;
    } else if (item.tag == 3) {
        preference.type = IJKSDLRotateZ;
        preference.degrees = -270;
    } else if (item.tag == 4) {
        preference.type = IJKSDLRotateY;
        preference.degrees = 180;
    } else if (item.tag == 5) {
        preference.type = IJKSDLRotateX;
        preference.degrees = 180;
    }
    
    self.player.view.rotatePreference = preference;
    if (!self.player.isPlaying) {
        [self.player.view setNeedsRefreshCurrentPic];
    }
    NSLog(@"rotate:%@ %d",@[@"None",@"X",@"Y",@"Z"][preference.type],(int)preference.degrees);
}

- (NSString *)saveDir:(NSString *)subDir
{
    NSArray *subDirs = nil;
    if (self.autoTest) {
        subDirs = subDir ? @[@"auto-test",subDir] : @[@"auto-test"];
    } else {
        subDirs = subDir ? @[@"ijkPro",subDir] : @[@"ijkPro"];
    }
    NSString * path = [NSFileManager mr_DirWithType:NSPicturesDirectory WithPathComponents:subDirs];
    return path;
}

- (NSString *)dirForCurrentPlayingUrl
{
    if ([self.playingUrl isFileURL]) {
        if (![[MRUtil pictureType] containsObject:[[self.playingUrl lastPathComponent] pathExtension]]) {
            return [self saveDir:[[self.playingUrl path] lastPathComponent]];
        } else {
            return [self saveDir:nil];
        }
    }
    return [self saveDir:[[self.playingUrl path] stringByDeletingLastPathComponent]];
}

- (IBAction)onCaptureShot:(id)sender
{
    CGImageRef img = [self.player.view snapshot:self.snapshot];
    if (img) {
        NSString * dir = [self dirForCurrentPlayingUrl];
        NSString *movieName = [self.playingUrl lastPathComponent];
        NSString *fileName = [NSString stringWithFormat:@"%@-%ld.jpg",movieName,(long)(CFAbsoluteTimeGetCurrent() * 1000)];
        NSString *filePath = [dir stringByAppendingPathComponent:fileName];
        NSLog(@"截屏:%@",filePath);
        [MRUtil saveImageToFile:img path:filePath];
    }
}

- (IBAction)onChangeBSC:(NSSlider *)sender
{
    if (sender.tag == 1) {
        self.brightness = sender.floatValue;
    } else if (sender.tag == 2) {
        self.saturation = sender.floatValue;
    } else if (sender.tag == 3) {
        self.contrast = sender.floatValue;
    }
    
    IJKSDLColorConversionPreference colorPreference = self.player.view.colorPreference;
    colorPreference.brightness = self.brightness;//B
    colorPreference.saturation = self.saturation;//S
    colorPreference.contrast = self.contrast;//C
    self.player.view.colorPreference = colorPreference;
    if (!self.player.isPlaying) {
        [self.player.view setNeedsRefreshCurrentPic];
    }
}

- (IBAction)onChangeDAR:(NSPopUpButton *)sender
{
    int dar_num = 0;
    int dar_den = 1;
    if (![sender.titleOfSelectedItem isEqual:@"还原"]) {
        const char* str = sender.titleOfSelectedItem.UTF8String;
        sscanf(str, "%d:%d", &dar_num, &dar_den);
    }
    self.player.view.darPreference = (IJKSDLDARPreference){1.0 * dar_num/dar_den};
    if (!self.player.isPlaying) {
        [self.player.view setNeedsRefreshCurrentPic];
    }
}

- (IBAction)onReset:(NSButton *)sender
{
    if (sender.tag == 1) {
        self.brightness = 1.0;
    } else if (sender.tag == 2) {
        self.saturation = 1.0;
    } else if (sender.tag == 3) {
        self.contrast = 1.0;
    } else {
        self.brightness = 1.0;
        self.saturation = 1.0;
        self.contrast = 1.0;
    }
    
    [self onChangeBSC:nil];
}

#pragma mark 音轨设置

- (IBAction)onSelectAudioTrack:(NSPopUpButton*)sender
{
    if (sender.indexOfSelectedItem == 0) {
        [self.player closeCurrentStream:k_IJKM_VAL_TYPE__AUDIO];
    } else {
        NSString *title = sender.selectedItem.title;
        NSArray *items = [title componentsSeparatedByString:@"-"];
        int idx = [[items lastObject] intValue];
        NSLog(@"SelectAudioTrack:%d",idx);
        [self.player exchangeSelectedStream:idx];
    }
}

- (IBAction)onSelectVideoTrack:(NSPopUpButton*)sender
{
    if (sender.indexOfSelectedItem == 0) {
        [self.player closeCurrentStream:k_IJKM_VAL_TYPE__VIDEO];
    } else {
        NSString *title = sender.selectedItem.title;
        NSArray *items = [title componentsSeparatedByString:@"-"];
        int idx = [[items lastObject] intValue];
        NSLog(@"SelectVideoTrack:%d",idx);
        [self.player exchangeSelectedStream:idx];
    }
}

#pragma mark 解码设置

- (IBAction)onChangedHWaccel:(NSButton *)sender
{
    [self retry];
}

- (IBAction)onChangedAccurateSeek:(NSButton *)sender
{
    [self.player enableAccurateSeek:self.accurateSeek];
}

- (IBAction)onSelectFCC:(NSPopUpButton*)sender
{
    [self retry];
}

#pragma mark 日志级别

- (int)levelWithString:(NSString *)str
{
    str = [str lowercaseString];
    if ([str isEqualToString:@"default"]) {
        return k_IJK_LOG_DEFAULT;
    } else if ([str isEqualToString:@"verbose"]) {
        return k_IJK_LOG_VERBOSE;
    } else if ([str isEqualToString:@"debug"]) {
        return k_IJK_LOG_DEBUG;
    } else if ([str isEqualToString:@"info"]) {
        return k_IJK_LOG_INFO;
    } else if ([str isEqualToString:@"warn"]) {
        return k_IJK_LOG_WARN;
    } else if ([str isEqualToString:@"error"]) {
        return k_IJK_LOG_ERROR;
    } else if ([str isEqualToString:@"fatal"]) {
        return k_IJK_LOG_FATAL;
    } else if ([str isEqualToString:@"silent"]) {
        return k_IJK_LOG_SILENT;
    } else {
        return k_IJK_LOG_UNKNOWN;
    }
}

- (void)reSetLoglevel:(NSString *)loglevel
{
    int level = [self levelWithString:loglevel];
    [IJKFFMoviePlayerController setLogLevel:level];
}

- (IBAction)onChangeLogLevel:(NSPopUpButton*)sender
{
    NSString *title = sender.selectedItem.title;
    [self reSetLoglevel:title];
}

- (IBAction)testMultiRenderSample:(NSButton *)sender
{
    NSURL *playingUrl = self.playingUrl;
    [self doStopPlay];
    
    MultiRenderSample *multiRenderVC = [[MultiRenderSample alloc] initWithNibName:@"MultiRenderSample" bundle:nil];
    
    NSWindowStyleMask mask = NSWindowStyleMaskBorderless | NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView;
    
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 600) styleMask:mask backing:NSBackingStoreBuffered defer:YES];
    window.contentViewController = multiRenderVC;
    window.movableByWindowBackground = YES;
    [window makeKeyAndOrderFront:nil];
    window.releasedWhenClosed = NO;
    [multiRenderVC playURL:playingUrl];
}

- (IBAction)onToggleLoopMode:(id)sender
{
    [self retry];
}

- (IBAction)openNewInstance:(id)sender
{
    NSWindowStyleMask mask = NSWindowStyleMaskBorderless | NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView;
    
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 600) styleMask:mask backing:NSBackingStoreBuffered defer:YES];
    window.contentViewController = [[RootViewController alloc] init];
    window.movableByWindowBackground = YES;
    [window makeKeyAndOrderFront:nil];
    window.releasedWhenClosed = NO;
}

@end
