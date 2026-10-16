#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class BRBrowserViewController;

// Playing on in the background. A page's audio and video play in the system's player inside the web view; with the
// "audio" background mode (Info.plist) and a playback audio session, iOS lets that go on when the app leaves the screen
// or the device locks, and the buttons of the lock screen and of a headset reach the app as remote control events,
// which are passed to the page's media here. Settings > Pages > Play in the background switches it off (the session
// is then the plain one every app has: media stops with the app and follows the ring/silent switch).
@interface BRMediaSession : NSObject

+ (instancetype)shared;

// At launch, once the browser view exists: the audio session per the setting, the lock screen's events, the
// background observers.
- (void)startWithBrowser:(BRBrowserViewController *)browser;

// After the setting changed.
- (void)applyPreference;

// A remote control event (UIEventTypeRemoteControl) from the app delegate: play, pause or toggle the page's media.
- (void)handleRemoteControlEvent:(UIEvent *)event;

@end
