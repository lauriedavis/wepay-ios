//
//  WPExternalCardReaderHelper.h
//  WePay
//
//  Created by Chaitanya Bagaria on 11/17/15.
//  Copyright © 2015 WePay. All rights reserved.
//

#if defined(__has_include)
#if __has_include("RPx/MPOSCommunicationManager/RDeviceInfo.h") && __has_include("RUA/RUA.h") && __has_include("G4XSwiper/SwiperController.h")

#import <Foundation/Foundation.h>
#import "WePay_CardReader.h"
#import "WePay.h"
#import "WPConfig.h"

@interface WPExternalCardReaderHelper : NSObject <WPExternalCardReaderDelegate>

@property (nonatomic, weak) id<WPCardReaderDelegate> externalCardReaderDelegate;
@property (nonatomic, weak) id<WPTokenizationDelegate> externalTokenizationDelegate;
@property (nonatomic, weak) id<WPAuthorizationDelegate> externalAuthorizationDelegate;
@property (nonatomic, strong) WPConfig *config;

- (instancetype) initWithConfig:(WPConfig *)config;

@end

#endif
#endif
