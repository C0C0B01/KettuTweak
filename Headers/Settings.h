#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface BunnySettingsViewController
    : UIViewController <UITableViewDelegate, UITableViewDataSource>
- (instancetype)initWithVersion:(NSString *)version;
@end

FOUNDATION_EXTERN void showSettingsSheet(void);