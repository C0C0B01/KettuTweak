#import <Foundation/Foundation.h>
#import <jsi/jsi.h>

@interface RCTHost : NSObject

- (void)instance:(id)instance didInitializeRuntime:(facebook::jsi::Runtime &)runtime;

@end
