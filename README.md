# Getting Started                         {#mainpage}

![WePay logo](https://www.wepay.com/img/redesign/logos/wepay-color.png "WePay")

## Introduction
The WePay iOS SDK enables collection of payments via various payment methods(described below).

It is meant for consumption by [WePay](http://www.wepay.com) partners who are developing their own iOS apps aimed at merchants and/or consumers.

Regardless of the payment method used, the SDK will ultimately return a Payment Token, which must be redeemed via a server-to-server [API](http://www.wepay.com/developer) call to complete the transaction.

## Payment methods
There are two types of payment methods:
+ Consumer payment methods - to be used in apps where consumers directly pay and/or make donations
+ Merchant payment methods - to be used in apps where merchants collect payments from their customers
 
The WePay iOS SDK supports the following payment methods
 - Card Swiper (Merchant)
    Using a Card Swiper, a merchant can accept in-person payments by swiping a consumer's traditional magnetic strip card.
 - Card Dipper (Merchant)
    Using an Card Dipper, a merchant can accept in-person payments by prosessing a consumer's EMV-enabled chip card.
 - Manual Entry (Consumer/Merchant)
    The Manual Entry payment method lets consumer and merchant apps accept payments by allowing the user to manually enter card info.

## Installation

Note: Card reader functionality is not available in this SDK by default. If you want to use this SDK with WePay card readers, send an email to mobile@wepay.com.

#### Using [cocoapods](https://cocoapods.org/) (recommended)
+ Add `pod "WePay"` to your podfile
+ Run `pod install`
+ Done!

The [SwiftExample app](https://github.com/wepay/wepay-ios/tree/master/SwiftExample) also utilizes `cocoapods`.

#### Using library binaries
+ Download the latest zip file from our [releases page](https://github.com/wepay/wepay-ios/releases/latest)
+ Unzip the file and copy the contents anywhere inside your project directory
+ In Xcode, go to your app's target settings. On the `Build Phases` tab, expand the `Link Binary With Libraries` section.
+ Include the following iOS frameworks:
    - AudioToolbox.framework
    - AVFoundation.framework
    - CoreBluetooth.framework
    - CoreLocation.framework
    - CoreTelephony.framework
    - MediaPlayer.framework
    - SystemConfiguration.framework
    - UIKit.framework
    - libstdc++.6.0.9.dylib
+ Also include the framework files you copied:
    - TrustDefenderMobile.framework
    - WePay.framework
+ Done!

## Documentation
HTML documentation is hosted on our [Github Pages Site](http://wepay.github.io/wepay-ios/).

Pdf documentation is available on the [releases page](https://github.com/wepay/wepay-ios/releases/latest) or as a direct [download](https://github.com/wepay/wepay-ios/raw/master/documentation/wepay-ios.pdf).

## SDK Organization

### WePay.h
`WePay.h` is the starting point for consuming the SDK, and contains the primary class you will interact with.
It exposes all the methods you can call to accept payments via the supported payment methods.
Detailed reference documentation is available on the reference page for the `WePay` class.

### Delegate protocols
The SDK uses delegate protocols to respond to API calls. You must adopt the relevant protocols to receive responses to the API calls you make.
Detailed reference documentation is available on the reference page for each protocol:
- `WPAuthorizationDelegate`
- `WPCardReaderDelegate`
- `WPCheckoutDelegate`
- `WPTokenizationDelegate`


### Data Models
All other classes in the SDK are data models that are used to exchange data between your app and the SDK. 
Detailed reference documentation is available on the reference page for each class.

## Next Steps
Head over to the [documentation](http://wepay.github.io/wepay-ios/) to see all the API methods available.
When you are ready, look at the samples below to learn how to interact with the SDK.


## Error Handling
`WPError.h` serves as documentation for all errors surfaced by the WePay iOS SDK.

## Samples

 See the [WePayExample app](https://github.com/wepay/wepay-ios/tree/master/WePayExample) for a working implementation of all API methods.

 See the [SwiftExample app](https://github.com/wepay/wepay-ios/tree/master/SwiftExample) for a working implementation of all API methods in a Swift 2 application.
 Note: make sure to open the project using `SwiftApp.xcworkspace` and not `SwiftApp.xcodeproj`.

### Initializing a Bridging Header (for Swift apps)

+ For using Objective-C modules in a Swift application, you will need to create a bridging header.
+ Make sure you are working in `{app_name}.xcworkspace` file.
+ Under your target application folder, create a header file: `{app_name}-Bridging-Header.h`
+ In the Header file, import the modules you need:
~~~{.m}
#import <WePay/WePay.h>
~~~
+ Click on the main application project to get to `Build Settings`.
+ Search for `bridging header` in your target application to find a setting called `Swift Compiler - Code Generation`.
+ Double click in the column next to `Objective-C Bridging Header` and add your Header file: `{app_name}/{app_name}-Bridging-Header.h`
+ There's no need to import the module in your code; you can use the module by calling it directly in your Swift application.

### Initializing the SDK

+ Complete the installation steps (above).
+ Include WePay.h
~~~{.m}
#import <WePay/WePay.h>
~~~
+ Define a property to store the WePay object
~~~{.m}
\@property (nonatomic, strong) WePay *wepay;
~~~
+ Create a WPConfig object
~~~{.m}
WPConfig *config = [[WPConfig alloc] initWithClientId:@"your_client_id" environment:kWPEnvironmentStage];
~~~
+ Initialize the WePay object and assign it to the property
~~~{.m}
self.wepay = [[WePay alloc] initWithConfig:config];
~~~

#####(optional) Providing permission to use location services for fraud detection

+ In Xcode, go to your projects settings. On the Build Phases tab, expand the Link Binary With Libraries section and include the CoreLocation.framework iOS framework.

+ Open your app's Info.plist file and add entries for NSLocationUsageDescription and NSLocationWhenInUseUsageDescription.
~~~{.xml}
<key>NSLocationUsageDescription</key>
<string>Location information is used for fraud prevention</string>
<key>NSLocationWhenInUseUsageDescription</key>
<string>Location information is used for fraud prevention</string>
~~~
+ Set the option on the config object, before initializing the WePay object
~~~{.m}
config.useLocation = YES;
~~~

### Integrating the Swipe payment method

+ Adopt the WPCardReaderDelegate and WPTokenizationDelegate protocols
~~~{.m}
\@interface MyWePayDelegate : NSObject <WPCardReaderDelegate, WPTokenizationDelegate>
~~~
+ Implement the WPCardReaderDelegate protocol methods
~~~{.m}
- (void) cardReaderDidChangeStatus:(id) status
{
    if (status == kWPCardReaderStatusNotConnected) {
        // show UI that prompts the user to connect the Card Reader
        self.statusLabel.text = @"Connect Card Reader";
    } else if (status == kWPCardReaderStatusWaitingForSwipe) {
        // show UI that prompts the user to swipe
        self.statusLabel.text = @"Swipe Card";
    } else if (status == kWPCardReaderStatusSwipeDetected) {
        // provide feedback to the user that a swipe was detected
        self.statusLabel.text = @"Swipe Detected...";
    } else if (status == kWPCardReaderStatusTokenizing) {
        // provide feedback to the user that the card info is being tokenized/verified
        self.statusLabel.text = @"Tokenizing...";
    }  else if (status == kWPCardReaderStatusStopped) {
        // provide feedback to the user that the swiper has stopped
        self.statusLabel.text = @"Card Reader Stopped";
    } else {
        // handle any other status messages
        self.statusLabel.text = [status description];
    } 
}  

- (void) didReadPaymentInfo:(WPPaymentInfo *)paymentInfo 
{
    // use the payment info (for display/recordkeeping)
    // wait for tokenization response
}

- (void) didFailToReadPaymentInfoWithError:(NSError *)error   
{
    // Handle the error
}

- (void) shouldResetCardReaderWithCompletion:(void (^)(BOOL))completion
{
    // Change this to YES if you want to reset the card reader
    completion(NO);
}
~~~
+ Implement the WPTokenizationDelegate protocol methods
~~~{.m}
- (void) paymentInfo:(WPPaymentInfo *)paymentInfo didTokenize:(WPPaymentToken *)paymentToken
{
    // Send the tokenId (paymentToken.tokenId) to your server
    // Your server would use the tokenId to make a /checkout/create call to complete the transaction
}

- (void) paymentInfo:(WPPaymentInfo *)paymentInfo didFailTokenization:(NSError *)error
{
	// Handle the error
}
~~~
+ Make the WePay API call, passing in the instance(s) of the class(es) that implemented the delegate protocols
~~~{.m}
[self.wepay startCardReaderForTokenizingWithCardReaderDelegate:self tokenizationDelegate:self authorizationDelegate:nil];
// Show UI asking the user to insert the card reader and wait for it to be ready
~~~
+ That's it! The following sequence of events will occur:
    1. The user inserts the card reader (or it is already inserted)
    2. The SDK tries to detect the card reader and initialize it.
        - If the card reader is not detected, the `cardReaderDidChangeStatus:` method will be called with `status = kWPCardReaderStatusNotConnected`
        - If the card reader is successfully detected, then the `cardReaderDidChangeStatus:` method will be called with `status = kWPCardReaderStatusConnected`.
        - Next, if the card reader is successfully initialized, then the `cardReaderDidChangeStatus:` method will be called with `status = kWPCardReaderStatusWaitingForSwipe`
        - Otherwise, `didFailToReadPaymentInfoWithError:` will be called with the appropriate error, and processing will stop (the `cardReaderDidChangeStatus:` method will be called with `status = kWPCardReaderStatusStopped`)
    3. If the card reader successfully initialized, it will wait for the user to swipe a card
    4. If a recoverable error occurs during swiping, the `didFailToReadPaymentInfoWithError:` method will be called. After a few seconds, the `cardReaderDidChangeStatus:` method will be called with `status = kWPCardReaderStatusWaitingForSwipe` and the card reader will again wait for the user to swipe a card
    5. If an unrecoverable error occurs during swiping, or the user does not swipe, the `didFailToReadPaymentInfoWithError:` method will be called, and processing will stop
    6. Otherwise, the user swiped successfully, and the `cardReaderDidChangeStatus:` method will be called with `status = kWPCardReaderStatusSwipeDetected` followed by the `didReadPaymentInfo:` method
    7. Next, the SDK will automatically send the obtained card info to WePay's servers for tokenization (the `cardReaderDidChangeStatus:` method will be called with `status = kWPCardReaderStatusTokenizing`)
    8. If the tokenization succeeds, the `paymentInfo:didTokenize:` method will be called
    9. Otherwise, if the tokenization fails, the `paymentInfo:didFailTokenization:` method will be called with the appropriate error

### Integrating the Dip payment method

+ Adopt the WPAuthorizationDelegate, WPCardReaderDelegate and WPTokenizationDelegate protocols
~~~{.m}
\@interface MyWePayDelegate : NSObject <WPAuthorizationDelegate, WPCardReaderDelegate, WPTokenizationDelegate>
~~~
+ Implement the WPCardReaderDelegate and WPTokenizationDelegate protocol methods (as shown above)
+ Implement the WPAuthorizationDelegate protocol methods
~~~{.m}
- (void) authorizeAmountWithCompletion:(void (^)(double amount, NSString *currencyCode, long accountId))completion
{
    // obtain transaction info
    double amount = 10.00;
    NSString *currencyCode = @"USD";
    long accountId = 12345678;

    // execute the completion
    completion(amount, currencyCode, accountId);
}

- (void) selectEMVApplication:(NSArray *)applications
                   completion:(void (^)(NSInteger selectedIndex))completion
{
    // In production apps, the payer must choose the app id they want to use.
    // Here, we always select the first application in the array
    int selectedIndex = 0;
    completion(selectedIndex);
}

- (void) insertPayerEmailWithCompletion:(void (^)(NSString *email))completion
{
    // obtain email
    NSString *email = @"emv@example.com";
    
    // execute the completion
    completion(email);
}

- (void) paymentInfo:(WPPaymentInfo *)paymentInfo
        didAuthorize:(WPAuthorizationInfo *)authorizationInfo
{
    // Send the token Id (authorizationInfo.tokenId) and transaction token (authorizationInfo.transactionToken) to your server
    // Your server must use the tokenId and transactionToken to make a /checkout/create call to complete the transaction
}

- (void) paymentInfo:(WPPaymentInfo *)paymentInfo
didFailAuthorization:(NSError *)error
{
    // Handle the error
}
~~~
+ Make the WePay API call, passing in the instance(s) of the class(es) that implemented the delegate protocols
~~~{.m}
[self.wepay startCardReaderForTokenizingWithCardReaderDelegate:self tokenizationDelegate:self authorizationDelegate:self];
// Show UI asking the user to insert the card reader and wait for it to be ready
~~~
+ That's it! The following sequence of events will occur:
    1. The user inserts the card reader (or it is already inserted)
    2. The SDK tries to detect the card reader and initialize it.
        - If the card reader is not detected, the `cardReaderDidChangeStatus:` method will be called with `status = kWPCardReaderStatusNotConnected`
        - If the card reader is successfully detected, then the `cardReaderDidChangeStatus:` method will be called with `status = kWPCardReaderStatusConnected`.
    3. Next, the SDK checks if the card reader is correctly configured (the `cardReaderDidChangeStatus:` method will be called with `status = kWPCardReaderStatusCheckingReader`).
        - If the card reader is already configured, the App is given a chance to force configuration. The SDK calls the `shouldResetCardReaderWithCompletion:` method, and the app must execute the completion method, telling the SDK whether or not the reader should be reset.
        - If the reader was not configured, or the app requested a reset, the card reader is configured (the `cardReaderDidChangeStatus:` method will be called with `status = kWPCardReaderStatusConfiguringReader`)
    4. Next, if the card reader is successfully initialized, the SDK asks the app for transaction information by calling the `authorizeAmountWithCompletion:` method. The app must execute the completion method, telling the SDK what the amount, currency code and merchant account id is.
    5. Next, the `cardReaderDidChangeStatus:` method will be called with `status = kWPCardReaderStatusWaitingForCard` 
    6. If the user inserts a card successfully, the `cardReaderDidChangeStatus:` method will be called with `status = kWPCardReaderStatusCardDipped`
    7. If the card has multiple applications on it, the payer must choose one:
        - The SDK calls the `selectEMVApplication:completion:` method with a list of Applications on the card.
        - The app must display these Applications to the payer and allow them to choose which application they want to use.
        - Once the payer has decided, the app must inform the SDK of the choice by executing the completion method and passing in the index of the chosen application.
    8. Next, the SDK extracts card data from the card.
        - If the SDK is unable to obtain data from the card, the `didFailToReadPaymentInfoWithError:` method will be called with the appropriate error, and processing will stop (the `cardReaderDidChangeStatus:` method will be called with `status = kWPCardReaderStatusStopped`)
        - Otherwise, the SDK attempts to ask the App for the payer’s email by calling the `insertPayerEmailWithCompletion:` method
    9. If the app implements this optional delegate method, it must execute the completion method and pass in the payer’s email address.
    10. Next, the `didReadPaymentInfo:` method is called with the obtained payment info.
    11. Next, the SDK will automatically send the obtained EMV card info to WePay's servers for authorization (the `cardReaderDidChangeStatus:` method will be called with `status = kWPCardReaderStatusAuthorizing`)
    12. If authorization fails, the `paymentInfo:didFailAuthorization:` method will be called and processing will stop.
    13. If authorization succeeds, the `paymentInfo:didAuthorize:` method will be called.
    14. Done!

Note: After the card is inserted into the reader, it must not be removed until a successful auth response (or an error) is returned.

### Integrating the Manual payment method

+ Adopt the WPTokenizationDelegate protocol
~~~{.h}
\@interface MyWePayDelegate : NSObject <WPTokenizationDelegate>
~~~
+ Implement the WPTokenizationDelegate protocol methods
~~~{.m}
- (void) paymentInfo:(WPPaymentInfo *)paymentInfo didTokenize:(WPPaymentToken *)paymentToken
{
    // Send the tokenId (paymentToken.tokenId) to your server
    // Your server can use the tokenId to make a /checkout/create call to complete the transaction
}

- (void) paymentInfo:(WPPaymentInfo *)paymentInfo didFailTokenization:(NSError *)error
{
    // Handle error
}
~~~
+ Instantiate a WPPaymentInfo object using the user's credit card and address data
~~~{.m}
WPPaymentInfo *paymentInfo = [[WPPaymentInfo alloc] initWithFirstName:@"WPiOS"
                                                                 lastName:@"Example"
                                                                    email:@"wp.ios.example@wepay.com"
                                                           billingAddress:[[WPAddress alloc] initWithZip:@"94306"]
                                                          shippingAddress:nil
                                                               cardNumber:@"5496198584584769"
                                                                      cvv:@"123"
                                                                 expMonth:@"04"
                                                                  expYear:@"2020"
                                                          virtualTerminal:YES];
// Note: the virtualTerminal parameter above should be set to YES if a merchant is collecting payments manually using your app. It should be set to NO if a payer is making a manual payment using your app.
~~~
+ Make the WePay API call, passing in the instance of the class that implemented the WPTokenizationDelegate protocol
~~~{.m}
[self.wepay tokenizeManualPaymentInfo:paymentInfo tokenizationDelegate:self];
~~~
+ That's it! The following sequence of events will occur:
    1. The SDK will send the obtained payment info to WePay's servers for tokenization
    2. If the tokenization succeeds, the `paymentInfo:didTokenize:` method will be called
    3. Otherwise, if the tokenization fails, the `paymentInfo:didFailTokenization:` method will be called with the appropriate error


### Integrating the Store Signature API

+ Adopt the WPCheckoutDelegate protocol
~~~{.h}
\@interface MyWePayDelegate : NSObject <WPCheckoutDelegate>
~~~
+ Implement the WPCheckoutDelegate protocol methods
~~~{.m}
- (void) didStoreSignature:(NSString *)signatureUrl
             forCheckoutId:(NSString *)checkoutId
{
    // success! nothing to do here
}

- (void) didFailToStoreSignatureImage:(UIImage *)image
                        forCheckoutId:(NSString *)checkoutId
                            withError:(NSError *)error
{
    // handle the error
}

~~~
+ Obtain the checkout_id associated with this signature from your server
~~~{.m}
NSString *checkoutId = [self obtainCheckoutId];
~~~
+ Instantiate a UIImage containing the user's signature
~~~{.m}
UIImage *signature = [UIImage imageNamed:@"dd_signature.png"];
~~~
+ Make the WePay API call, passing in the instance of the class that implemented the WPCheckoutDelegate protocol
~~~{.m}
[self.wepay storeSignatureImage:signature 
                  forCheckoutId:checkoutId
               checkoutDelegate:self];
~~~
+ That's it! The following sequence of events will occur:
    1. The SDK will send the obtained signature to WePay's servers
    2. If the operation succeeds, the `didStoreSignature:forCheckoutId:` method will be called
    3. Otherwise, if the operation fails, the `didFailToStoreSignatureImage:forCheckoutId:withError:` method will be called with the appropriate error
