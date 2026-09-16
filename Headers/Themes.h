#import <Foundation/Foundation.h>
#import <objc/message.h>

#import "Logger.h"
#import "Utils.h"

FOUNDATION_EXTERN void initializeThemeColors(NSDictionary *semanticColors, NSDictionary *rawColors);

#define CURRENT_THEME [NSString stringWithFormat:@"%@/%@", NSHomeDirectory(), @"Documents/pyoncord/current-theme.json"]
