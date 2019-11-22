#import "AppDelegate+FirebasePlugin.h"
#import "FirebasePlugin.h"
#import "Firebase.h"
#import <objc/runtime.h>

#if defined(__IPHONE_10_0) && __IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_10_0
@import UserNotifications;

// Implement UNUserNotificationCenterDelegate to receive display notification via APNS for devices
// running iOS 10 and above. Implement FIRMessagingDelegate to receive data message via FCM for
// devices running iOS 10 and above.
@interface AppDelegate () <UNUserNotificationCenterDelegate, FIRMessagingDelegate>
@end
#endif

#define kApplicationInBackgroundKey @"applicationInBackground"
#define kDelegateKey @"delegate"

@implementation AppDelegate (FirebasePlugin)

#if defined(__IPHONE_10_0) && __IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_10_0

- (void)setDelegate:(id)delegate {
    objc_setAssociatedObject(self, kDelegateKey, delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (id)delegate {
    return objc_getAssociatedObject(self, kDelegateKey);
}

#endif

+ (void)load {
    Method original = class_getInstanceMethod(self, @selector(application:didFinishLaunchingWithOptions:));
    Method swizzled = class_getInstanceMethod(self, @selector(application:swizzledDidFinishLaunchingWithOptions:));
    method_exchangeImplementations(original, swizzled);
}

- (void)setApplicationInBackground:(NSNumber *)applicationInBackground {
    objc_setAssociatedObject(self, kApplicationInBackgroundKey, applicationInBackground, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (NSNumber *)applicationInBackground {
    return objc_getAssociatedObject(self, kApplicationInBackgroundKey);
}

- (BOOL)application:(UIApplication *)application swizzledDidFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [self application:application swizzledDidFinishLaunchingWithOptions:launchOptions];

    // get GoogleService-Info.plist file path
    NSString *filePath = [[NSBundle mainBundle] pathForResource:@"GoogleService-Info" ofType:@"plist"];
    
    // if file is successfully found, use it
    if(filePath){
        NSLog(@"GoogleService-Info.plist found, setup: [FIRApp configureWithOptions]");
        // create firebase configure options passing .plist as content
        FIROptions *options = [[FIROptions alloc] initWithContentsOfFile:filePath];
        
        // configure FIRApp with options
        [FIRApp configureWithOptions:options];
    }
    
    // no .plist found, try default App
    if (![FIRApp defaultApp] && !filePath) {
        NSLog(@"GoogleService-Info.plist NOT FOUND, setup: [FIRApp defaultApp]");
        [FIRApp configure];
    }

    // [START set_messaging_delegate]
    [FIRMessaging messaging].delegate = self;
    // [END set_messaging_delegate]
#if defined(__IPHONE_10_0) && __IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_10_0
    self.delegate = [UNUserNotificationCenter currentNotificationCenter].delegate;
        [UNUserNotificationCenter currentNotificationCenter].delegate = self;
#endif

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(tokenRefreshNotification:)
                                                 name:kFIRInstanceIDTokenRefreshNotification object:nil];

    self.applicationInBackground = @(YES);

    return YES;
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    [self connectToFcm];
    self.applicationInBackground = @(NO);
    }

- (void)applicationDidEnterBackground:(UIApplication *)application {
    [[FIRMessaging messaging] disconnect];
    self.applicationInBackground = @(YES);
    NSLog(@"Disconnected from FCM");
}

# pragma mark - FIRMessagingDelegate
- (void)messaging:(FIRMessaging *)messaging didReceiveRegistrationToken:(NSString *)fcmToken {
    [FirebasePlugin.firebasePlugin sendToken:fcmToken];
}

- (void)tokenRefreshNotification:(NSNotification *)notification {
    // Note that this callback will be fired everytime a new token is generated, including the first
    // time. So if you need to retrieve the token as soon as it is available this is where that
    // should be done.
    NSString *refreshedToken = [[FIRInstanceID instanceID] token];
    NSLog(@"InstanceID token: %@", refreshedToken);

    // Connect to FCM since connection may have failed when attempted before having a token.
    [self connectToFcm];
    [FirebasePlugin.firebasePlugin sendToken:refreshedToken];
}

- (void)connectToFcm {
    [[FIRMessaging messaging] connectWithCompletion:^(NSError * _Nullable error) {
        if (error != nil) {
            NSLog(@"Unable to connect to FCM. %@", error);
        } else {
            NSLog(@"Connected to FCM.");
            NSString *refreshedToken = [[FIRInstanceID instanceID] token];
            NSLog(@"InstanceID token: %@", refreshedToken);
        }
    }];
}

- (void)application:(UIApplication *)application didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken {
    [FIRMessaging messaging].APNSToken = deviceToken;
    NSLog(@"deviceToken1 = %@", deviceToken);
}

//Tells the app that a remote notification arrived that indicates there is data to be fetched.
// Called when a message arrives in the foreground and remote notifications permission has been granted
- (void)application:(UIApplication *)application didReceiveRemoteNotification:(NSDictionary *)userInfo
    fetchCompletionHandler:(void (^)(UIBackgroundFetchResult))completionHandler {

    NSDictionary *mutableUserInfo = [userInfo mutableCopy];
    NSDictionary* aps = [mutableUserInfo objectForKey:@"aps"];
    if([aps objectForKey:@"alert"] != nil){
        [mutableUserInfo setValue:@"notification" forKey:@"messageType"];
    }else{
        [mutableUserInfo setValue:@"data" forKey:@"messageType"];
    }

    [mutableUserInfo setValue:self.applicationInBackground forKey:@"tap"];
    // Print full message.
    NSLog(@"%@", mutableUserInfo);
    completionHandler(UIBackgroundFetchResultNewData);
    [FirebasePlugin.firebasePlugin sendNotification:mutableUserInfo];
}

// [START ios_10_data_message]
// Receive data messages on iOS 10+ directly from FCM (bypassing APNs) when the app is in the foreground.
// To enable direct data messages, you can set [Messaging messaging].shouldEstablishDirectChannel to YES.
- (void)messaging:(FIRMessaging *)messaging didReceiveMessage:(FIRMessagingRemoteMessage *)remoteMessage {
    NSLog(@"Received data message: %@", remoteMessage.appData);

    // This will allow us to handle FCM data-only push messages even if the permission for push
    // notifications is yet missing. This will only work when the app is in the foreground.
    [FirebasePlugin.firebasePlugin sendNotification:remoteMessage.appData];
}

// Scans a message for keys which indicate a notification should be shown.
// If found, extracts relevant keys and uses then to display a local notification
-(void)processMessageForForegroundNotification:(NSDictionary*)messageData {
    bool showForegroundNotification = [messageData objectForKey:@"notification_foreground"];
    if(!showForegroundNotification){
        return;
    }
    
    NSString* title = nil;
    NSString* body = nil;
    NSString* sound = nil;
    NSString* badge = nil;
    
    // Extract APNS notification keys
    NSDictionary* aps = [messageData objectForKey:@"aps"];
    if([aps objectForKey:@"alert"] != nil){
        NSDictionary* alert = [aps objectForKey:@"alert"];
        if([alert objectForKey:@"title"] != nil){
            title = [alert objectForKey:@"title"];
        }
        if([alert objectForKey:@"body"] != nil){
            body = [alert objectForKey:@"body"];
        }
        if([aps objectForKey:@"sound"] != nil){
            sound = [aps objectForKey:@"sound"];
        }
        if([aps objectForKey:@"badge"] != nil){
            sound = [aps objectForKey:@"badge"];
        }
    }
    
    // Extract data notification keys
    if([messageData objectForKey:@"notification_title"] != nil){
        title = [messageData objectForKey:@"notification_title"];
    }
    if([messageData objectForKey:@"notification_body"] != nil){
        body = [messageData objectForKey:@"notification_body"];
    }
    if([messageData objectForKey:@"notification_ios_sound"] != nil){
        sound = [messageData objectForKey:@"notification_ios_sound"];
    }
    if([messageData objectForKey:@"notification_ios_badge"] != nil){
        badge = [messageData objectForKey:@"notification_ios_badge"];
    }
   
    if(title == nil || body == nil){
        return;
    }
    
    [[UNUserNotificationCenter currentNotificationCenter] getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings * _Nonnull settings) {
        if (settings.alertSetting == UNNotificationSettingEnabled) {
            UNMutableNotificationContent *objNotificationContent = [[UNMutableNotificationContent alloc] init];
            objNotificationContent.title = [NSString localizedUserNotificationStringForKey:title arguments:nil];
            objNotificationContent.body = [NSString localizedUserNotificationStringForKey:body arguments:nil];
            
            NSDictionary* alert = [[NSDictionary alloc] initWithObjectsAndKeys:
                                   title, @"title",
                                   body, @"body"
                                   , nil];
            NSMutableDictionary* aps = [[NSMutableDictionary alloc] initWithObjectsAndKeys:
                                 alert, @"alert",
                                 nil];
            
            if([sound isEqualToString:@"default"]){
                objNotificationContent.sound = [UNNotificationSound defaultSound];
                [aps setValue:sound forKey:@"sound"];
            }else if(sound != nil){
                objNotificationContent.sound = [UNNotificationSound soundNamed:sound];
                [aps setValue:sound forKey:@"sound"];
            }
            
            if(badge != nil){
                NSNumberFormatter* f = [[NSNumberFormatter alloc] init];
                f.numberStyle = NSNumberFormatterDecimalStyle;
                objNotificationContent.badge = [f numberFromString:badge];
                [aps setValue:badge forKey:@"badge"];
            }
            
            
            NSDictionary* userInfo = [[NSDictionary alloc] initWithObjectsAndKeys:
                                      @"true", @"notification_foreground",
                                      @"data", @"messageType",
                                      aps, @"aps"
                                      , nil];
            
            objNotificationContent.userInfo = userInfo;
            
            UNTimeIntervalNotificationTrigger *trigger =  [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:0.1f repeats:NO];
            UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:@"local_notification" content:objNotificationContent trigger:trigger];
            [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request withCompletionHandler:^(NSError * _Nullable error) {
                if (!error) {
                    NSLog(@"Local Notification succeeded");
                } else {
                    NSLog(@"Local Notification failed: %@", error);
                }
            }];
        }else{
            NSLog(@"processMessageForForegroundNotification: cannot show notification as permission denied");
        }
    }];
}

- (void)application:(UIApplication *)application didFailToRegisterForRemoteNotificationsWithError:(NSError *)error {
  NSLog(@"Unable to register for remote notifications: %@", error);
}

// [END ios_10_data_message]
#if defined(__IPHONE_10_0) && __IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_10_0
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {

    [self.delegate userNotificationCenter:center
              willPresentNotification:notification
                withCompletionHandler:completionHandler];

    if (![notification.request.trigger isKindOfClass:UNPushNotificationTrigger.class])
        return;

    NSDictionary* mutableUserInfo = [notification.request.content.userInfo mutableCopy];
    NSString* messageType = [mutableUserInfo objectForKey:@"messageType"];
    if(![messageType isEqualToString:@"data"]){
        [mutableUserInfo setValue:@"notification" forKey:@"messageType"];
    }

    [mutableUserInfo setValue:self.applicationInBackground forKey:@"tap"];

    // Print full message.
    NSLog(@"%@", mutableUserInfo);

    completionHandler(UNNotificationPresentationOptionAlert);
    [FirebasePlugin.firebasePlugin sendNotification:mutableUserInfo];
}

// Asks the delegate to process the user's response to a delivered notification.
// Called when user taps on system notification
- (void) userNotificationCenter:(UNUserNotificationCenter *)center
 didReceiveNotificationResponse:(UNNotificationResponse *)response
          withCompletionHandler:(void (^)(void))completionHandler
{
    [self.delegate userNotificationCenter:center
       didReceiveNotificationResponse:response
                withCompletionHandler:completionHandler];

    if (![response.notification.request.trigger isKindOfClass:UNPushNotificationTrigger.class] && ![response.notification.request.trigger isKindOfClass:UNTimeIntervalNotificationTrigger.class]){
        NSLog(@"didReceiveNotificationResponse: aborting as not a supported UNNotificationTrigger");
        return;
    }

    NSDictionary *mutableUserInfo = [response.notification.request.content.userInfo mutableCopy];
    
    NSString* tap;
    if([self.applicationInBackground isEqual:[NSNumber numberWithBool:YES]]){
        tap = @"background";
    }else{
        tap = @"foreground";
        
    }
    [mutableUserInfo setValue:tap forKey:@"tap"];
    if([mutableUserInfo objectForKey:@"messageType"] == nil){
        [mutableUserInfo setValue:@"notification" forKey:@"messageType"];
    }
    

    // Print full message.
    NSLog(@"Response %@", mutableUserInfo);

    [FirebasePlugin.firebasePlugin sendNotification:mutableUserInfo];

    completionHandler();
}

// Receive data message on iOS 10 devices.
- (void)applicationReceivedRemoteMessage:(FIRMessagingRemoteMessage *)remoteMessage {
    // Print full message
    NSLog(@"%@", [remoteMessage appData]);
}
#endif

@end
