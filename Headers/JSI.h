#pragma once

#import <Foundation/Foundation.h>
#import <functional>
#import <jsi/jsi.h>
#import <exception>
#import <memory>
#import <string>

@interface JSI : NSObject

+ (facebook::jsi::Value)fromObjC:(id)value runtime:(facebook::jsi::Runtime &)runtime;
+ (NSString *)toNSString:(const facebook::jsi::Value &)value
                 runtime:(facebook::jsi::Runtime &)runtime;
+ (BOOL)toBool:(const facebook::jsi::Value &)value
       runtime:(facebook::jsi::Runtime &)runtime
      fallback:(BOOL)fallback;
+ (double)toNumber:(const facebook::jsi::Value &)value fallback:(double)fallback;
+ (id)toObjC:(const facebook::jsi::Value &)value runtime:(facebook::jsi::Runtime &)runtime;

+ (facebook::jsi::Value)makeFunction:(const char *)name
                            argCount:(unsigned int)argCount
                             runtime:(facebook::jsi::Runtime &)runtime
                             handler:(const facebook::jsi::HostFunctionType &)handler;

+ (void)evaluate:(NSData *)scriptData tag:(NSString *)tag runtime:(facebook::jsi::Runtime &)runtime;

@end
