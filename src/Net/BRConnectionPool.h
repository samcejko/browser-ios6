#import <Foundation/Foundation.h>

@class BRTLSSocket;

// Idle keep-alive connections, keyed by "scheme://host:port". Sockets are handed out most recently
// used first, checked for liveness, and dropped after an idle timeout.
@interface BRConnectionPool : NSObject

+ (instancetype)shared;

- (BRTLSSocket *)checkoutSocketForKey:(NSString *)key;      // nil when nothing usable is idle
- (void)checkinSocket:(BRTLSSocket *)socket forKey:(NSString *)key;
- (void)drain;                                              // closes every idle connection (memory warning, background)

@property (nonatomic, readonly) NSUInteger idleCount;
@property (nonatomic, readonly) NSUInteger reuseCount;      // statistics: sockets handed out since launch

@end
