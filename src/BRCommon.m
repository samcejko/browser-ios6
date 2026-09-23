#import "BRCommon.h"

#include <mach/mach.h>

NSString * const BRErrorDomain = @"BrowserErrorDomain";

double BRResidentMemoryMB(void)
{
    struct task_basic_info info;
    mach_msg_type_number_t count = TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_BASIC_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
    return (double)info.resident_size / (1024.0 * 1024.0);
}

NSError *BRMakeError(NSInteger code, NSString *message)
{
    if (!message) message = @"Unknown error";
    return [NSError errorWithDomain:BRErrorDomain code:code userInfo:@{ NSLocalizedDescriptionKey: message }];
}

NSError *BRURLErrorFromError(NSError *error, NSURL *url)
{
    if (!error) return nil;
    if (![error.domain isEqualToString:BRErrorDomain]) return error;
    NSInteger code;
    switch (error.code) {
        case BRErrorDNS:            code = NSURLErrorCannotFindHost; break;
        case BRErrorConnect:        code = NSURLErrorCannotConnectToHost; break;
        case BRErrorTimeout:        code = NSURLErrorTimedOut; break;
        case BRErrorTLS:            code = NSURLErrorSecureConnectionFailed; break;
        case BRErrorCertificate:    code = NSURLErrorServerCertificateUntrusted; break;
        case BRErrorCancelled:      code = NSURLErrorCancelled; break;
        case BRErrorBadResponse:    code = NSURLErrorBadServerResponse; break;
        case BRErrorConnectionLost: code = NSURLErrorNetworkConnectionLost; break;
        default:                    code = NSURLErrorUnknown; break;
    }
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[NSLocalizedDescriptionKey] = error.localizedDescription ?: @"";
    if (url) {
        info[NSURLErrorFailingURLErrorKey] = url;
        info[NSURLErrorFailingURLStringErrorKey] = url.absoluteString ?: @"";
    }
    info[NSUnderlyingErrorKey] = error;
    return [NSError errorWithDomain:NSURLErrorDomain code:code userInfo:info];
}

NSString *BRHTMLEscape(NSString *string)
{
    if (!string) return @"";
    NSMutableString *s = [string mutableCopy];
    [s replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, s.length)];
    [s replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, s.length)];
    [s replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, s.length)];
    [s replaceOccurrencesOfString:@"\"" withString:@"&quot;" options:0 range:NSMakeRange(0, s.length)];
    [s replaceOccurrencesOfString:@"'" withString:@"&#39;" options:0 range:NSMakeRange(0, s.length)];
    return s;
}
