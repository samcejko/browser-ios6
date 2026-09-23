// Shared macros and constants. Everything here must be iOS 6.0 safe.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// Any API newer than the iOS 6.0 deployment target is a hard error in files that include this header.
#pragma clang diagnostic error "-Wunguarded-availability"

#define L(key) NSLocalizedString((key), nil)
#define BRIsPad() (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad)
#define BRLog(fmt, ...) NSLog((@"[Browser] " fmt), ##__VA_ARGS__)

extern NSString * const BRErrorDomain;

// NSError codes in BRErrorDomain
enum {
    BRErrorNetwork        = -1,
    BRErrorTLS            = -2,
    BRErrorCertificate    = -3,
    BRErrorTimeout        = -4,
    BRErrorCancelled      = -5,
    BRErrorBadResponse    = -6,
    BRErrorDNS            = -7,
    BRErrorConnect        = -8,
    BRErrorConnectionLost = -9,
};

NSError *BRMakeError(NSInteger code, NSString *message);

// Maps a BRErrorDomain error to the NSURLErrorDomain code WebKit understands; other domains pass through.
NSError *BRURLErrorFromError(NSError *error, NSURL *url);

// Escapes &, <, >, " and ' for inclusion in HTML.
NSString *BRHTMLEscape(NSString *string);

// Resident memory of this process in megabytes (for logging).
double BRResidentMemoryMB(void);
