//
//  MRPlayerSettingsViewController.m
//  IJKMediaMacDemo
//
//  Created by Reach Matt on 2024/1/24.
//  Copyright © 2024 IJK Mac. All rights reserved.
//

#import "MRPlayerSettingsViewController.h"
#import <IJKMediaPlayerKit/IJKFFMoviePlayerController.h>

@interface MRPlayerSettingsViewController ()

@property (nonatomic, weak) IBOutlet NSPopUpButton *subtitlePopUpBtn;
@property (nonatomic, weak) IBOutlet NSPopUpButton *audioPopUpBtn;
@property (nonatomic, weak) IBOutlet NSPopUpButton *videoPopUpBtn;

@property (nonatomic, assign) BOOL use_openGL;
@property (nonatomic, copy) NSString *fcc;
@property (nonatomic, assign) int snapshot;
@property (nonatomic, assign) BOOL accurateSeek;
//for cocoa binding end

@end

@implementation MRPlayerSettingsViewController

+ (float)viewWidth
{
    return 300;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do view setup here.
}

- (IBAction)onResetColorAdjust:(NSButton *)sender {
    int tag = (int)sender.tag;
    if (tag == 1) {
        
    } else if (tag == 2){
        
    } else if (tag == 3){
        
    }
}


- (void)exchangeToNextSubtitle
{
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

- (void)updateTracks:(NSDictionary *)mediaMeta
{
    int audioIdx = [mediaMeta[k_IJKM_VAL_TYPE__AUDIO] intValue];
    NSLog(@"当前音频：%d",audioIdx);
    int videoIdx = [mediaMeta[k_IJKM_VAL_TYPE__VIDEO] intValue];
    NSLog(@"当前视频：%d",videoIdx);
    int subtitleIdx = [mediaMeta[k_IJKM_VAL_TYPE__SUBTITLE] intValue];
    NSLog(@"当前字幕：%d",subtitleIdx);
    
    [self.subtitlePopUpBtn removeAllItems];
    NSString *currentTitle = @"选择字幕";
    [self.subtitlePopUpBtn addItemWithTitle:currentTitle];
    
    [self.audioPopUpBtn removeAllItems];
    NSString *currentAudio = @"选择音轨";
    [self.audioPopUpBtn addItemWithTitle:currentAudio];
    
    [self.videoPopUpBtn removeAllItems];
    NSString *currentVideo = @"选择视轨";
    [self.videoPopUpBtn addItemWithTitle:currentVideo];
    
    for (NSDictionary *stream in mediaMeta[kk_IJKM_KEY_STREAMS]) {
        NSString *type = stream[k_IJKM_KEY_TYPE];
        int streamIdx = [stream[k_IJKM_KEY_STREAM_IDX] intValue];
        if ([type isEqualToString:k_IJKM_VAL_TYPE__SUBTITLE]) {
            NSLog(@"subtile meta:%@",stream);
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
            if ([mediaMeta[k_IJKM_VAL_TYPE__SUBTITLE] intValue] == streamIdx) {
                currentTitle = title;
            }
            [self.subtitlePopUpBtn addItemWithTitle:title];
        } else if ([type isEqualToString:k_IJKM_VAL_TYPE__AUDIO]) {
            NSLog(@"audio meta:%@",stream);
            NSString *title = stream[k_IJKM_KEY_TITLE];
            if (title.length == 0) {
                title = stream[k_IJKM_KEY_LANGUAGE];
            }
            if (title.length == 0) {
                title = @"未知";
            }
            title = [NSString stringWithFormat:@"%@-%d",title,streamIdx];
            if ([mediaMeta[k_IJKM_VAL_TYPE__AUDIO] intValue] == streamIdx) {
                currentAudio = title;
            }
            [self.audioPopUpBtn addItemWithTitle:title];
        } else if ([type isEqualToString:k_IJKM_VAL_TYPE__VIDEO]) {
            NSLog(@"video meta:%@",stream);
            NSString *title = stream[k_IJKM_KEY_TITLE];
            if (title.length == 0) {
                title = stream[k_IJKM_KEY_LANGUAGE];
            }
            if (title.length == 0) {
                title = @"未知";
            }
            title = [NSString stringWithFormat:@"%@-%d",title,streamIdx];
            if ([mediaMeta[k_IJKM_VAL_TYPE__VIDEO] intValue] == streamIdx) {
                currentVideo = title;
            }
            [self.videoPopUpBtn addItemWithTitle:title];
        }
    }
    [self.subtitlePopUpBtn selectItemWithTitle:currentTitle];
    [self.audioPopUpBtn selectItemWithTitle:currentAudio];
    [self.videoPopUpBtn selectItemWithTitle:currentVideo];
}

@end
