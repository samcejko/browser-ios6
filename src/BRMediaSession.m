#import "BRMediaSession.h"
#import "BRBrowserViewController.h"
#import "BRSettings.h"
#import "BRCommon.h"
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>

// The scripts run in the page's own document: media inside an <iframe> of another site is out of a script's reach,
// as for every script of the page. (That media still plays on in the background - the audio session is the app's -
// only the lock screen's buttons and title do not reach it.)

// The state of the page's media: "playing <seconds>" when an audio or video element plays (it is remembered as the
// one the lock screen's buttons mean), "paused <seconds>" for the remembered one, "" without media.
static NSString * const BRMediaStateScript =
    @"(function(){var ms=document.querySelectorAll('video,audio'),i,m,last=null;"
     "for(i=0;i<ms.length;i++){m=ms[i];if(!m.paused&&!m.ended){for(var j=0;j<ms.length;j++)ms[j].__brLastPlayed=false;m.__brLastPlayed=true;return 'playing '+(m.currentTime||0).toFixed(1);}if(m.__brLastPlayed)last=m;}"
     "return last?'paused '+(last.currentTime||0).toFixed(1):'';})()";

// Play, pause or toggle: %@ is 'play', 'pause' or 'toggle'. Playing pauses the element that plays; play starts the
// remembered element, else the first one with a source. The page shim refuses play() more than 5 s after the last
// tap or key (the activation modern browsers want): a button of the lock screen is the user's hand too, so a key
// event is dispatched first, which counts as that tap. Answers what was done ('paused', 'play') or ''.
static NSString * const BRMediaControlScript =
    @"(function(mode){var ms=document.querySelectorAll('video,audio'),i,m,playing=null,pick=null;"
     "for(i=0;i<ms.length;i++){m=ms[i];if(!m.paused&&!m.ended){playing=m;break;}}"
     "if(mode==='pause'||(mode==='toggle'&&playing)){if(playing)playing.pause();return playing?'paused':'';}"
     "for(i=0;i<ms.length;i++){m=ms[i];if(m.__brLastPlayed&&!m.ended){pick=m;break;}}"
     "if(!pick)for(i=0;i<ms.length;i++){m=ms[i];if((m.currentSrc||m.src)&&!m.ended){pick=m;break;}}"
     "if(!pick)return '';"
     "try{var ev=document.createEvent('Event');ev.initEvent('keydown',true,true);document.dispatchEvent(ev);}catch(e){}"
     "try{var p=pick.play();if(p&&p.then)p.then(null,function(){});}catch(e2){return '';}"
     "return 'play';})('%@')";

@interface BRMediaSession ()
@property (nonatomic, weak) BRBrowserViewController *browser;
@property (nonatomic) UIBackgroundTaskIdentifier task;
@property (nonatomic, strong) NSTimer *watch;
@property (nonatomic) BOOL inBackground;
@property (nonatomic) NSInteger watchTicks;
@end

@implementation BRMediaSession

+ (instancetype)shared
{
    static BRMediaSession *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[BRMediaSession alloc] init]; });
    return shared;
}

- (instancetype)init
{
    self = [super init];
    if (self) _task = UIBackgroundTaskInvalid;
    return self;
}

- (void)startWithBrowser:(BRBrowserViewController *)browser
{
    self.browser = browser;
    [self applyPreference];
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(didEnterBackground) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [nc addObserver:self selector:@selector(willEnterForeground) name:UIApplicationWillEnterForegroundNotification object:nil];
    // (the lock screen's and a headset's buttons; the app delegate hands them on)
    [[UIApplication sharedApplication] beginReceivingRemoteControlEvents];
}

- (void)applyPreference
{
    // Playback: the page's media goes on in the background and plays through the ring/silent switch, like a video
    // app's. SoloAmbient is what every app has without a choice: media stops when the app leaves the screen and
    // follows the switch. The category alone takes nothing from other apps' sound; the session becomes active when
    // the page's player starts, as it did before.
    NSString *category = [BRSettings backgroundAudio] ? AVAudioSessionCategoryPlayback : AVAudioSessionCategorySoloAmbient;
    NSError *error = nil;
    if (![[AVAudioSession sharedInstance] setCategory:category error:&error]) BRLog(@"Audio session category %@ refused: %@", category, error);
    else BRLog(@"Audio session category %@", category);
}

#pragma mark - Background

- (void)didEnterBackground
{
    self.inBackground = YES;
    if (![BRSettings backgroundAudio]) return;
    NSString *state = [self.browser evaluateJavaScript:BRMediaStateScript];
    BRLog(@"Background: media %@", state.length ? state : @"none");
    if (![state hasPrefix:@"playing"]) return;
    [self updateNowPlaying];
    // Time to go on while the player is between two parts of a stream (without sound iOS would suspend the app):
    // some minutes, which any app gets; from the first sound on, the audio background mode keeps the app running.
    [self endTask];
    self.task = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{ [self endTask]; }];
    // A look at the player a moment later: a video the system paused as the app left the screen is started again
    // (once, and only one that played at that moment - never one the user paused). On a developer's device the
    // state is logged now and then as well.
    [self.watch invalidate];
    self.watchTicks = 0;
    self.watch = [NSTimer scheduledTimerWithTimeInterval:2 target:self selector:@selector(watchTick) userInfo:nil repeats:YES];
}

- (void)watchTick
{
    if (!self.inBackground) { [self.watch invalidate]; self.watch = nil; return; }
    self.watchTicks++;
    NSString *state = [self.browser evaluateJavaScript:BRMediaStateScript];
    if (self.watchTicks == 1 && [state hasPrefix:@"paused"]) {
        NSString *done = [self.browser evaluateJavaScript:[NSString stringWithFormat:BRMediaControlScript, @"play"]];
        BRLog(@"Background: media paused on leaving the screen, play again: %@", done.length ? done : @"nothing to play");
    } else if (self.watchTicks <= 3 || self.watchTicks % 15 == 0) {
        BRLog(@"Background: media %@ after %ld s", state.length ? state : @"none", (long)self.watchTicks * 2);
    }
    if (self.watchTicks >= 3 && !BRDebugEnabled()) { [self.watch invalidate]; self.watch = nil; }
}

- (void)willEnterForeground
{
    self.inBackground = NO;
    [self.watch invalidate];
    self.watch = nil;
    [self endTask];
}

- (void)endTask
{
    if (self.task == UIBackgroundTaskInvalid) return;
    [[UIApplication sharedApplication] endBackgroundTask:self.task];
    self.task = UIBackgroundTaskInvalid;
}

#pragma mark - Lock screen

// What the lock screen shows next to its buttons: the page's title, its host as the "artist".
- (void)updateNowPlaying
{
    NSString *titleAndHost = [self.browser evaluateJavaScript:@"(document.title||'')+'\\n'+(location.host||'')"];
    NSArray *parts = [titleAndHost componentsSeparatedByString:@"\n"];
    NSString *title = parts.count ? [parts[0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : @"";
    NSString *host = parts.count > 1 ? parts[1] : @"";
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[MPMediaItemPropertyTitle] = title.length ? title : (host.length ? host : @"Surfari");
    if (title.length && host.length) info[MPMediaItemPropertyArtist] = host;
    info[MPNowPlayingInfoPropertyPlaybackRate] = @1.0;
    [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = info;
}

- (void)handleRemoteControlEvent:(UIEvent *)event
{
    if (event.type != UIEventTypeRemoteControl) return;
    NSString *mode;
    switch (event.subtype) {
        case UIEventSubtypeRemoteControlTogglePlayPause: mode = @"toggle"; break;
        case UIEventSubtypeRemoteControlPlay: mode = @"play"; break;
        case UIEventSubtypeRemoteControlPause:
        case UIEventSubtypeRemoteControlStop: mode = @"pause"; break;
        default: return;
    }
    NSString *done = [self.browser evaluateJavaScript:[NSString stringWithFormat:BRMediaControlScript, mode]];
    BRLog(@"Remote control %@: %@", mode, done.length ? done : @"no media");
    if ([done isEqualToString:@"play"]) [self updateNowPlaying];
}

@end
