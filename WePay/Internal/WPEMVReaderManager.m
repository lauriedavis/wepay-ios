//
//  WPEMVReaderManager.m
//  WePay
//
//  Created by Chaitanya Bagaria on 8/4/15.
//  Copyright (c) 2015 WePay. All rights reserved.
//

#if defined(__has_include)
#if __has_include("RPx/MPOSCommunicationManager/RDeviceInfo.h") && __has_include("RUA/RUA.h") && __has_include("G4XSwiper/SwiperController.h")

#import <CommonCrypto/CommonDigest.h>
#import "WPEMVReaderManager.h"
#import "WePay.h"
#import "WPConfig.h"
#import "WPError+internal.h"
#import "WPRoamHelper.h"

@interface WPEMVReaderManager () {
    int _currentPublicKeyIndex;

    NSArray *_aidsList;
    NSArray *_publicKeyList;
    NSDictionary *_tacList;
    NSString *_configHash;

    NSArray *_amountDOL;
    NSArray *_onlineDOL;
    NSArray *_responseDOL;

    __block WPEMVReaderManager *processor;
}

@property (nonatomic, strong) id<RUADeviceManager> roamDeviceManager;

@property (nonatomic, assign) BOOL swiperShouldWaitForSwipe;
@property (nonatomic, assign) BOOL swiperIsWaitingForSwipe;
@property (nonatomic, assign) BOOL swiperIsConnected;
@property (nonatomic, assign) BOOL shouldReportSwipedEMVCard;
@property (nonatomic, assign) BOOL readerSetupCompleted;
@property (nonatomic, assign) BOOL shouldIssueReversal;
@property (nonatomic, assign) BOOL isFallbackSwipe;

@property (nonatomic, assign) double amount;
@property (nonatomic, assign) long accountId;
@property (nonatomic, strong) NSString *currencyCode;

@property (nonatomic, strong) NSString *selectedAID;
@property (nonatomic, strong) NSString *applicationCryptogram;
@property (nonatomic, strong) NSString *issuerAuthenticationData;
@property (nonatomic, strong) NSString *authResponseCode;
@property (nonatomic, strong) NSString *authCode;
@property (nonatomic, strong) NSString *issuerScriptTemplate1;
@property (nonatomic, strong) NSString *issuerScriptTemplate2;

@property (nonatomic, strong) NSString *deviceSerialNumber;
@property (nonatomic, strong) NSString *creditCardId;
@property (nonatomic, strong) WPPaymentInfo *paymentInfo;

@property (nonatomic, assign) BOOL useTestEMVCards;
@property (nonatomic, assign) BOOL restartCardReaderAfterSuccess;
@property (nonatomic, assign) BOOL restartCardReaderAfterGeneralError;
@property (nonatomic, assign) BOOL restartCardReaderAfterOtherErrors;
@property (nonatomic, strong) NSString *wepayEnvironment;

@end

@implementation WPEMVReaderManager

#define RP350X_CONNECTION_TIME_SEC 5
#define WEPAY_CONFIG_HASH_KEY @"wepay.config.hashes"

#define CRYPTOGRAM_INFORMATION_DATA_00 @"00" // AAC (decline)
#define CRYPTOGRAM_INFORMATION_DATA_40 @"40" // TC  (approve)
#define CRYPTOGRAM_INFORMATION_DATA_80 @"80" // ARQC (online)

#define AUTH_RESPONSE_CODE_ONLINE_APPROVE @"00" // any other code is decline

#define AID_MCRD @"A000000004"
#define AID_VISA @"A000000003"
#define AID_DISC @"A000000152"
#define AID_AMEX @"A000000025"

#define TAC_DENIAL_KEY @"denial"
#define TAC_ONLINE_KEY @"online"
#define TAC_DEFAULT_KEY @"default"


- (instancetype) initWithConfig:(WPConfig *)config
{
    if (self = [super init]) {
        // set the swiper restart options
        self.restartCardReaderAfterSuccess = config.restartCardReaderAfterSuccess;
        self.restartCardReaderAfterGeneralError = config.restartCardReaderAfterGeneralError;
        self.restartCardReaderAfterOtherErrors = config.restartCardReaderAfterOtherErrors;

        self.useTestEMVCards = config.useTestEMVCards;
        self.wepayEnvironment = config.environment;
    }

    // store a weak instance for using inside blocks
    processor = self;

    if (self.useTestEMVCards) {
        [processor setupKeysValuesForTesting];
        [self setupTACsForTesting];
    } else {
        [processor setupKeysValuesForProduction];
        [self setupTACsForProduction];
    }

    return processor;
}

- (void) processCard
{
    NSLog(@"processCard");

    self.authCode = nil;
    self.issuerAuthenticationData = nil;
    self.authResponseCode = nil;
    self.selectedAID = nil;
    self.applicationCryptogram = nil;
    self.issuerScriptTemplate1 = nil;
    self.issuerScriptTemplate2 = nil;
    self.shouldIssueReversal = NO;
    self.isFallbackSwipe = NO;

    // clear any pending actions
    [self stopWaitingForCard];

    if (self.roamDeviceManager == nil) {
        // TODO: check return value and return error
        [self startDevice];
    }

    // set options
    self.swiperShouldWaitForSwipe = YES;

    // start card reader and wait for card
    [self checkAndWaitForEMVCard];
}

- (BOOL) startDevice
{
    NSLog(@"startDevice: RUADeviceTypeRP350x");
    self.roamDeviceManager = [RUA getDeviceManager:RUADeviceTypeRP350x];

    BOOL init = [self.roamDeviceManager initializeDevice:self];
    if (init) {
        [[self.roamDeviceManager getConfigurationManager] setCommandTimeout:TIMEOUT_WORKAROUND_SEC];
    } else {
        self.roamDeviceManager = nil;
    }

    self.readerSetupCompleted = NO;

    return init;
}

- (void) stopDevice
{
    self.swiperShouldWaitForSwipe = NO;

    // stop waiting for card and cancel all pending notifications
    [self stopWaitingForCard];

    // release and delete the device manager
    [self.roamDeviceManager releaseDevice];
    self.roamDeviceManager = nil;

    // inform delegate
    [self.delegate informExternalCardReader:kWPCardReaderStatusStopped];
}

#pragma mark - (private)

- (void) checkAndWaitForEMVCard
{
    NSLog(@"checkAndWaitForEMVCard");
    // TODO: rename swiper to card reader where appropriate
    if (self.swiperIsConnected) {

        if (self.deviceSerialNumber != nil) {
            if ([self compareStoredConfigHash:_configHash forKey:self.deviceSerialNumber]) {
                [processor storeConfigHash:nil forKey:self.deviceSerialNumber];
                [processor setupAIDSandPublicKeys];
            } else {
                // call delegate method for device reset
                [self.delegate informExternalCardReaderResetCompletion:^(BOOL shouldReset) {
                    if (shouldReset) {
                        [processor storeConfigHash:nil forKey:self.deviceSerialNumber];
                        [processor setupAIDSandPublicKeys];
                    } else {
                        self.readerSetupCompleted = YES;
                        [self setupExpectedDOLs];
                    }
                }];
            }

        } else {
            // get device serial number again
        }

    } else {
        // Wait a few seconds for the swiper to be detected, otherwise announce not connected
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate performSelector:@selector(informExternalCardReader:)
                                withObject:kWPCardReaderStatusNotConnected
                                afterDelay:RP350X_CONNECTION_TIME_SEC];
        });
    }
}

- (void) fetchDeviceSerialNumber
{
    id <RUAConfigurationManager> cmgr = [self.roamDeviceManager getConfigurationManager];
    [cmgr getReaderCapabilities: ^(RUAProgressMessage messageType, NSString* additionalMessage) {
                            NSLog(@"RUAProgressMessage: %@",[WPRoamHelper RUAProgressMessage_toString:messageType]);
                        }
                       response: ^(RUAResponse *ruaResponse) {
                           NSLog(@"RUAResponse: %@", [WPRoamHelper RUAResponse_toDictionary:ruaResponse]);
                           self.deviceSerialNumber = [[ruaResponse responseData] objectForKey:@((int)RUAParameterInterfaceDeviceSerialNumber)];
                           self.swiperIsConnected = YES;

                           // If we should wait for card
                           if (self.swiperShouldWaitForSwipe) {
                               // Inform external delegate
                               [self.delegate informExternalCardReader:kWPCardReaderStatusConnected];

                               // Check and wait - the delay is to let the swiper get charged
                               [self performSelector:@selector(checkAndWaitForEMVCard) withObject:nil afterDelay:1.0];
                           }

                       }];
}


/**
 *  Stops waiting for card - cancels card timeout timer, cancels scheduled checkAndWaitForEMVCard, asks Roam to stop waiting for card
 *
 */
- (void) stopWaitingForCard
{
    // TODO: cancel waiting for swipe timeout timer
//    [self.swipeTimeoutTimer invalidate];

    self.swiperIsWaitingForSwipe = NO;

    // cancel any scheduled wait for swipe
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(checkAndWaitForEMVCard)
                                               object:nil];

    // cancel any scheduled notifications - kWPSwiperStatusNotConnected
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(informExternalCardReader:)
                                               object:kWPCardReaderStatusNotConnected];


    // stop transaction if running
    [self stopTransaction];
}

- (void) reportAuthorizationSuccess:(WPAuthorizationInfo *)authInfo orError:(NSError *)error forPaymentInfo:(WPPaymentInfo *)paymentInfo
{
    // For EMV Readers, we dont start waiting for card again
    self.swiperShouldWaitForSwipe = NO;
    [self stopWaitingForCard];

    if (authInfo != nil) {
        [self.delegate informExternalAuthorizationSuccess:authInfo forPaymentInfo:paymentInfo];
    } else if (error != nil) {
        if (paymentInfo != nil) {
            [self.delegate informExternalAuthorizationFailure:error forPaymentInfo:paymentInfo];
        } else {
            [self.delegate informExternalCardReaderFailure:error];
        }
    }
}


#pragma mark - TransactionStartCommand

- (NSDictionary *)getEMVStartTransactionParameters {
    NSMutableDictionary *transactionParameters = [[NSMutableDictionary alloc] init];
    NSLocale *enUSPOSIXLocale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];

    NSDateFormatter *dateFormat = [[NSDateFormatter alloc]init];
    [dateFormat setDateFormat:@"yyMMdd"];
    [dateFormat setLocale:enUSPOSIXLocale];

    NSDateFormatter *timeFormat = [[NSDateFormatter alloc]init];
    [timeFormat setDateFormat:@"HHmmss"];
    [timeFormat setLocale:enUSPOSIXLocale];

    NSString *dateStr = [dateFormat stringFromDate:[NSDate date]];

    // // // // // // //
    // Required params:
    // // // // // // //

    [transactionParameters setObject:[self convertToEMVCurrencyCode:self.currencyCode] forKey:[NSNumber numberWithInt:RUAParameterTransactionCurrencyCode]];

    [transactionParameters setObject:@"00" forKey:[NSNumber numberWithInt:RUAParameterTransactionType]];

    // TODO: RUAParameterTerminalConfiguration

    [transactionParameters setObject:dateStr forKey:[NSNumber numberWithInt:RUAParameterTransactionDate]];

    /*
     TerminalCapabilities, please consult the corresponding EMVL2 approval
     for the selected device for authorised values 
     E0F8C8  Offline PIN, Online PIN and Signature, attended.(RP750x)
     E0B8C8  Offline PIN and Signature, attended.(RP750x)
     E068C8  Online PIN, Signature, attended. (RP750x) 
     E040C8  Online PIN only, attended. (RP750x)
     E028C8  Signature Only, attended. (RP350x)
     */
    [transactionParameters setObject:@"E028C8" forKey:[NSNumber numberWithInt:RUAParameterTerminalCapabilities]]; // Probably NO CVM (6008C8) for RP350x

    /*
     ‘21’
     –  Online Only, Attended Merchant (POS)
     ‘24’
     –  Online Only, Unattended Merchant (POS)
     ‘14’
     –  Online Only, Unattended Financial Institution (ATM)
     */

    [transactionParameters setObject:@"22" forKey:[NSNumber numberWithInt:RUAParameterTerminalType]];

    /*
     AdditionalTerminalCapabilities
     please consult the corresponding EMVL2 approval for the selected device for authorised values
     "6000A0A001" //RP750x
     "6000008001" //RP350x
     */
    [transactionParameters setObject:@"6000008001" forKey:[NSNumber numberWithInt:RUAParameterAdditionalTerminalCapabilities]]; // May need to be 6000000001 - ask Roam

    [transactionParameters setObject:@"9F3704" forKey:[NSNumber numberWithInt:RUAParameterDefaultValueForDDOL]]; // Input for offline data authentication - this is the typical value

    [transactionParameters setObject:@"59315A3159325A3259335A333030303530313034" forKey:[NSNumber numberWithInt:RUAParameterAuthorizationResponseCodeList]]; // Ask Roam

    // // // // // // //
    // Optional Params:
    // // // // // // //

    [transactionParameters setObject:@"0840" forKey:[NSNumber numberWithInt:RUAParameterTerminalCountryCode]];

    [transactionParameters setObject:[self convertToEMVAmount:self.amount] forKey:[NSNumber numberWithInt:RUAParameterAmountAuthorizedNumeric]];
    [transactionParameters setObject:@"000000000000" forKey:[NSNumber numberWithInt:RUAParameterAmountOtherNumeric]];


    // // // // // // //
    // Included in sample app, but not in doc
    // // // // // // //

    //    [transactionParameters setObject:timeStr forKey:[NSNumber numberWithInt:RUAParameterTransactionTime]];
    //    [transactionParameters setObject:@"00" forKey:[NSNumber numberWithInt:RUAParameterPOSEntryMode]]; // Ask Roam
    //    [transactionParameters setObject:@"0000" forKey:[NSNumber numberWithInt:RUAParameterMerchantCategoryCode]]; // MCC code, likely not used - check
    //    [transactionParameters setObject:@"0000000000000000" forKey:[NSNumber numberWithInt:RUAParameterTerminalIdentification]]; // The merchant's terminal number (lane 1, lane 2 etc) can use KSN
    //    [transactionParameters setObject:@"00110321" forKey:[NSNumber numberWithInt:RUAParameterTransactionSequenceCounter]]; // Auto incrementing number that can reset every day




    NSLog(@"getEMVStartTransactionParameters:\n%@", transactionParameters);
    
    return transactionParameters;
}

/**
 *  Starts the transaction on the card reader
 */
- (void) performEMVTransactionStartCommand
{
    NSLog(@"performEMVTransactionStartCommand");

    self.swiperIsWaitingForSwipe = YES;
    self.shouldReportSwipedEMVCard = NO;

    id <RUATransactionManager> tmgr = [self.roamDeviceManager getTransactionManager];

    NSDictionary *params = [self getEMVStartTransactionParameters];

    [tmgr sendCommand:RUACommandEMVStartTransaction
       withParameters:params
             progress: ^(RUAProgressMessage messageType, NSString* additionalMessage) {
                 NSLog(@"RUAProgressMessage: %@",[WPRoamHelper RUAProgressMessage_toString:messageType]);
                 switch (messageType) {
                     case RUAProgressMessagePleaseInsertCard:
                         if (self.shouldReportSwipedEMVCard) {
                             // tell the app an emv card was swiped
                             [self.delegate informExternalCardReader:kWPCardReaderStatusShouldNotSwipeEMVCard];
                         } else {
                             // inform delegate we are waiting for card
                             [self.delegate informExternalCardReader:kWPCardReaderStatusWaitingForCard];

                             // next time we get this progress message, it is because user is swiping EMV card
                             self.shouldReportSwipedEMVCard = YES;
                         }
                         break;
                     case RUAProgressMessagePleaseRemoveCard:
                         // TODO: called when card is inserted wrong
                         break;
                     case RUAProgressMessageCardInserted:
                         [self.delegate informExternalCardReader:kWPCardReaderStatusCardDipped];
                         break;
                     case RUAProgressMessageSwipeDetected:
                         [self.delegate informExternalCardReader:kWPCardReaderStatusSwipeDetected];
                         break;
                     case RUAProgressMessageICCErrorSwipeCard:
                         [self.delegate informExternalCardReader:kWPCardReaderStatusChipErrorSwipeCard];
                         self.isFallbackSwipe = YES;
                     default:
                         // Do nothing on progress, react to the response when it comes
                         break;
                 }
             }
             response: ^(RUAResponse *ruaResponse) {
                 NSLog(@"RUAResponse: %@", [WPRoamHelper RUAResponse_toDictionary:ruaResponse]);
                 
                 if ([ruaResponse responseType] == RUAResponseTypeMagneticCardData) {
                     NSMutableDictionary *responseData = [[WPRoamHelper RUAResponse_toDictionary:ruaResponse] mutableCopy];
                     [responseData setObject:@"RP350x" forKey:@"Model"];
                     [responseData setObject:@(self.isFallbackSwipe) forKey:@"Fallback"];
                     //TODO: no magic strings
                     [responseData setObject:@(self.accountId) forKey:@"AccountId"];
                     [self.delegate handleSwipeResponse:responseData];

                     // stop waiting for transaction
                     self.swiperShouldWaitForSwipe = NO;
                     [self stopWaitingForCard];
                 } else if ([ruaResponse responseType] == RUAResponseTypeListOfApplicationIdentifiers) {
                     NSArray *appIds = [ruaResponse listOfApplicationIdentifiers];
                     NSMutableArray *appLabels = [@[] mutableCopy];

                     for (RUAApplicationIdentifier *appID in appIds) {
                         [appLabels addObject:appID.applicationLabel];

//                         NSLog(@"AppID: %@, applicationLabel: %@, rid: %@, pix: %@, terminalApplicationVersion: %@", appID.aid, appID.applicationLabel, appID.rid, appID.pix, appID.terminalApplicationVersion);
                         //                     AMEX T=0 Terminal Test Card
                         //                     AppIDs count: 2
                         //                     AppID: A000000025010801, applicationLabel: AMERICAN EXPRESS, rid: (null), pix: (null), terminalApplicationVersion: (null)
                         //                     AppID: A000000025010802, applicationLabel: AMEX 2, rid: (null), pix: (null), terminalApplicationVersion: (null)
                         //                     Mastercard 8.0.A Test Card
                         //                     AppID: A0000000042203D0561111, applicationLabel: US CHECKING, rid: (null), pix: (null), terminalApplicationVersion: (null)
                         //                     AppID: A0000000042203D0562222, applicationLabel: US SAVING, rid: (null), pix: (null), terminalApplicationVersion: (null)

                     }

                     // call delegate method for app selection
                     [self.delegate informExternalAuthorizationApplications:appLabels
                                                                 completion:^(NSInteger selectedIndex) {
                                                                     if (selectedIndex < 0 || selectedIndex >= [appLabels count]) {
                                                                         [self reportAuthorizationSuccess:nil orError:[WPError errorInvalidApplicationId] forPaymentInfo:self.paymentInfo];
                                                                     } else {
                                                                         RUAApplicationIdentifier *selectedAppId = [appIds objectAtIndex:selectedIndex];
                                                                         [self performSelectAppIdCommand:selectedAppId];
                                                                     }
                                                                 }];

                 } else {
                     [self handleEMVStartTransactionResponse:ruaResponse];
                 }
             }
     ];

    // WORKAROUND: Roam's SDK does not properly handle assigned timeouts. We're working around that by immediately restarting the swiper when it timesout on its own.
    // when Roam fixes their SDK, we should handle timeouts correctly - ie, timeout at the correct time as configured, or never timeout if configured as such.
    // TODO: Roam has fixed their issue. We only need to set the timeout time properly up front //self.restartCardReaderAfterOtherErrors ? TIMEOUT_INFINITE_SEC : TIMEOUT_DEFAULT_SEC

}

/**
 *  Handle EMV Start Transaction response from Roam
 *
 *  @param ruaResponse The response
 */
- (void) handleEMVStartTransactionResponse:(RUAResponse *) ruaResponse
{
    NSDictionary *responseData = [WPRoamHelper RUAResponse_toDictionary:ruaResponse];
    NSError *error = [self validateEMVResponse:responseData];

    if (error != nil) {
        [self reportAuthorizationSuccess:nil orError:error forPaymentInfo:self.paymentInfo];
    } else {
        // TODO: validate this
        self.selectedAID = [responseData objectForKey:[WPRoamHelper RUAParameter_toString:RUAParameterApplicationIdentifier]];
        [self performEMVTransactionDataCommand];
    }
}

#pragma mark - SelectAppIdCommand

- (void) performSelectAppIdCommand:(RUAApplicationIdentifier *)selectedAppId {

    id <RUATransactionManager> tmgr = [self.roamDeviceManager getTransactionManager];
    NSDictionary *params = @{[NSNumber numberWithInt:RUAParameterApplicationIdentifier]: selectedAppId.aid};

    NSLog(@"performSelectAppIdCommandParameters:\n%@", params);


    [tmgr  sendCommand:RUACommandEMVFinalApplicationSelection
        withParameters:params
              progress: ^(RUAProgressMessage messageType, NSString* additionalMessage) {
                  NSLog(@"RUAProgressMessage: %@",[WPRoamHelper RUAProgressMessage_toString:messageType]);
              }

              response: ^(RUAResponse *ruaResponse) {
                  NSLog(@"RUAResponse: %@", [WPRoamHelper RUAResponse_toDictionary:ruaResponse]);
                  [self handleEMVStartTransactionResponse:ruaResponse];
              }

     ];
}

#pragma mark - TransactionDataCommand

- (NSDictionary *)getEMVTransactionDataParameters {
    NSMutableDictionary *transactionParameters = [[NSMutableDictionary alloc] init];

    // // // // // // //
    // Required params:
    // // // // // // //

    [transactionParameters setObject:@"00000000" forKey:[NSNumber numberWithInt:RUAParameterThresholdvalue]]; // 0 for now, online only - affects the randomness curve
    [transactionParameters setObject:@"99" forKey:[NSNumber numberWithInt:RUAParameterTargetpercentage]]; // Random percentage for going online, set to 99  for always online
    [transactionParameters setObject:@"99" forKey:[NSNumber numberWithInt:RUAParameterMaximumtargetpercentage]];
    [transactionParameters setObject:@"00000000" forKey:[NSNumber numberWithInt:RUAParameterTerminalFloorLimit]]; // 0 for now, online only


    //TODO: remove this, test only
//    BOOL testOffline = NO;
//    if (testOffline) {
//        [transactionParameters setObject:@"00001000" forKey:[NSNumber numberWithInt:RUAParameterThresholdvalue]]; // affects the randomness curve
//        [transactionParameters setObject:@"00" forKey:[NSNumber numberWithInt:RUAParameterTargetpercentage]]; // Random percentage for going online, set to 99  for always online or 0 for always offline (under threshold value)
//        [transactionParameters setObject:@"00" forKey:[NSNumber numberWithInt:RUAParameterMaximumtargetpercentage]];
//        [transactionParameters setObject:@"00001000" forKey:[NSNumber numberWithInt:RUAParameterTerminalFloorLimit]]; // 10.00
//    }

    // select TACs based on selected AID
    NSString *tacDenial = @"0000000000";
    NSString *tacOnline = @"0000000000";
    NSString *tacDefault = @"0000000000";

    for (NSString *aid in _tacList.keyEnumerator) {
        if ([self.selectedAID hasPrefix:aid]) {
            tacDenial = _tacList[aid][TAC_DENIAL_KEY];
            tacOnline = _tacList[aid][TAC_ONLINE_KEY];
            tacDefault = _tacList[aid][TAC_DEFAULT_KEY];

            // TODO: remove this
            NSLog(@"[WePay] found TACs %@, %@, %@ for AID: %@", tacDenial, tacOnline, tacDefault, self.selectedAID);



            break;
        }
    }

    [transactionParameters setObject:tacDenial forKey:[NSNumber numberWithInt:RUAParameterTerminalActionCodeDenial]]; // can vary between AIDs
    [transactionParameters setObject:tacOnline forKey:[NSNumber numberWithInt:RUAParameterTerminalActionCodeOnline]]; // can vary between AIDs (Visa says this should be Terminal Action Code – Online byte 4, bit 8 set to 1 )
    [transactionParameters setObject:tacDefault forKey:[NSNumber numberWithInt:RUAParameterTerminalActionCodeDefault]]; // can vary between AIDs - I should know what AID has been selected from _amountDOL


    // TODO: http://usa.visa.com/merchants/grow-your-business/payment-technologies/credit-card-chip/docs/Visa_Minimum_US_Online_Only_Terminal_Configuration.pdf

    // // // // // // //
    // Optional params:
    // // // // // // //

    //[transactionParameters setObject:@"03" forKey:[NSNumber numberWithInt:RUAParameterOnlinePINBlockFormat]]; // RP750x to support Chip and PIN
    //[transactionParameters setObject:@"00010001" forKey:[NSNumber numberWithInt:RUAParameterOnlinePINBlockKeyLocator]]; // RP750x to support Chip and PIN

    NSLog(@"getEMVTransactionDataParameters:\n%@", transactionParameters);

    return transactionParameters;
}


- (void)performEMVTransactionDataCommand {
    NSLog(@"performEMVTransactionDataCommand");

    id <RUATransactionManager> tmgr = [self.roamDeviceManager getTransactionManager];
    NSDictionary *params = [self getEMVTransactionDataParameters];

    [tmgr sendCommand:RUACommandEMVTransactionData withParameters:params
             progress: ^(RUAProgressMessage messageType, NSString* additionalMessage) {
                 NSLog(@"RUAProgressMessage: %@ %@", [WPRoamHelper RUAProgressMessage_toString:messageType], additionalMessage);
             }

             response: ^(RUAResponse *ruaResponse) {
                 NSLog(@"RUAResponse: %@", [WPRoamHelper RUAResponse_toString:ruaResponse]);

                 [self handleEMVTransactionDataResponse:ruaResponse];
             }
     ];
}

/**
 *  Handle EMV Data Transaction response from Roam
 *
 *  @param ruaResponse The response
 */
- (void) handleEMVTransactionDataResponse:(RUAResponse *) ruaResponse
{
    NSMutableDictionary *responseData = [[WPRoamHelper RUAResponse_toDictionary:ruaResponse] mutableCopy];
    // TODO: No Magic Strings
    [responseData setObject:@"RP350x" forKey:@"Model"];
    [responseData setObject:@(self.accountId) forKey:@"AccountId"];

    NSError *error = [self validateEMVResponse:responseData];

    if (error != nil) {
        [self reportAuthorizationSuccess:nil orError:error forPaymentInfo:self.paymentInfo];
    } else {
        // handle success
        if ([ruaResponse responseType] == RUAResponseTypeContactEMVResponseDOL || [ruaResponse responseType] == RUAResponseTypeContactEMVOnlineDOL) {

            // TODO:
            // for RUAResponseTypeContactEMVOnlineDOL make sure we got back an ARQC - tag 9F27 is 80
            // handle network issues

            NSString *firstName = [WPRoamHelper firstNameFromRUAData:responseData];
            NSString *lastName = [WPRoamHelper lastNameFromRUAData:responseData];
            NSString *pan = [responseData objectForKey:@"PAN"];

            // save application cryptgram for later use
            self.applicationCryptogram = [responseData objectForKey:@"ApplicationCryptogram"];

            NSDictionary *info = @{@"firstName"         : firstName ? firstName : [NSNull null],
                                   @"lastName"          : lastName ? lastName : [NSNull null],
                                   @"paymentDescription": pan ? pan : [NSNull null],
                                   @"emvInfo"           : responseData
                                   };

            self.paymentInfo = [[WPPaymentInfo alloc] initWithEMVInfo:info];

            // return payment info to delegate
            // TODO: verify if email gets inserted into our copy of payment info
            [self.delegate handlePaymentInfo:self.paymentInfo
                              successHandler:^(NSDictionary *returnData) {

                                  // TODO: remove this
                                  NSLog(@"auth api response: %@", returnData);

                                  self.authCode = [returnData objectForKey:@"authorisation_code"]; // can be nil

                                  // TODO: will be nil for offline auth, handle it
                                  NSString *issuerAuthenticationData = [returnData objectForKey:@"issuer_authentication_data"];
                                  NSString *authResponseCode = [returnData objectForKey:@"authorisation_response_code"];
                                  NSString *creditCardId = [returnData objectForKey:@"credit_card_id"];

                                  NSString *issuerScriptTemplate1 = [returnData objectForKey:@"issuer_script_template1"];
                                  if (issuerScriptTemplate1 != nil && ![issuerScriptTemplate1 isEqual:[NSNull null]]) {
                                      self.issuerScriptTemplate1 = issuerScriptTemplate1;
                                  }

                                  NSString *issuerScriptTemplate2 = [returnData objectForKey:@"issuer_script_template2"];
                                  if (issuerScriptTemplate2 != nil && ![issuerScriptTemplate2 isEqual:[NSNull null]]) {
                                      self.issuerScriptTemplate2 = issuerScriptTemplate2;
                                  }


                                  [processor executeMagicNumbersForIssuerAuthenticationData:issuerAuthenticationData
                                                                           authResponseCode:authResponseCode
                                                                               creditCardId:creditCardId];

                                  // TODO: validate response values and take action

                                  // TODO: resolve end game, including offline approval
                                  if ([ruaResponse responseType] == RUAResponseTypeContactEMVOnlineDOL) {
                                      // call complete transaction
                                      [self performEMVCompleteTransactionCommand];
                                  } else {
                                      // just handle the response, without calling complete transaction
                                      [self handleEMVCompleteTransactionResponse:ruaResponse];
                                  }
                              }
                                errorHandler:^(NSError * error) {
                                    // Call error handler with error returned.
                                    // [self.delegate informExternalAuthorizationFailure:error forPaymentInfo:self.paymentInfo];

                                    NSLog(@"auth api error: %@", error);

                                    //TODO: remove this after cert
                                    [self.delegate informExternalCardReader:[error description]];

                                    [processor executeMagicNumbersForIssuerAuthenticationData:nil
                                                                             authResponseCode:nil
                                                                                 creditCardId:nil];

                                    // TODO: should we complete Tx instead?
                                    // [self sendCommand:RUACommandEMVTransactionStop];
                                    [self performEMVCompleteTransactionCommand];
                                }];

        } else {
            NSLog(@"[performEMVTransactionDataCommand] Stopping, unhandled response");
            [self reportAuthorizationSuccess:nil orError:[WPError errorInvalidCardData] forPaymentInfo:self.paymentInfo];
        }
    }
}

- (void) executeMagicNumbersForIssuerAuthenticationData:(NSString *)issuerAuthenticationData
                                       authResponseCode:(NSString *)authResponseCode
                                           creditCardId:(NSString *)creditCardId
{
    BOOL isMagicSuccessAmount = [@[@(21.61), @(121.61), @(22.61), @(122.61), @(24.61), @(124.61), @(25.61), @(125.61)] containsObject:@(self.amount)];

    if (issuerAuthenticationData != nil && ![issuerAuthenticationData isEqual:[NSNull null]]) {
        self.issuerAuthenticationData = issuerAuthenticationData;
    } else if (![kWPEnvironmentProduction isEqualToString:self.wepayEnvironment] && isMagicSuccessAmount) {
        // simulate successful auth when not in production environment.
        self.issuerAuthenticationData = self.applicationCryptogram;
    }

    if (authResponseCode == nil || [authResponseCode isEqual:[NSNull null]]) {
        if (![kWPEnvironmentProduction isEqualToString:self.wepayEnvironment] && isMagicSuccessAmount) {
            // simulate successful auth when not in production environment.
            self.authResponseCode = @"00";
        }
    } else {
        self.authResponseCode = authResponseCode;
    }

    if (creditCardId == nil || [creditCardId isEqual:[NSNull null]]) {
        if (![kWPEnvironmentProduction isEqualToString:self.wepayEnvironment] && isMagicSuccessAmount) {
            // simulate successful auth when not in production environment.
            self.creditCardId = @"1234567890";
        }
    } else {
        self.creditCardId = creditCardId;
    }
}

#pragma mark - CompleteTransactionCommand

- (NSDictionary *)getEMVCompleteTransactionParameters {

    NSMutableDictionary *transactionParameters = [[NSMutableDictionary alloc] init];

    if (self.issuerAuthenticationData == nil && self.authResponseCode == nil) {
        // TODO: handle all scenarios
        // did not go online
        [transactionParameters setObject:@"02" forKey:[NSNumber numberWithInt:RUAParameterResultofOnlineProcess]];
    } else {
        // went online

        // // // // // // //
        // Required params:
        // // // // // // //

        [transactionParameters setObject:@"01" forKey:[NSNumber numberWithInt:RUAParameterResultofOnlineProcess]];

        // this can this be absent in degraded mode?
        if (self.issuerAuthenticationData != nil) {
            [transactionParameters setObject:self.issuerAuthenticationData forKey:[NSNumber numberWithInt:RUAParameterIssuerAuthenticationData]];
        }

        [transactionParameters setObject:[self convertResponseCodeToHexString:self.authResponseCode] forKey:[NSNumber numberWithInt:RUAParameterAuthorizationResponseCode]];

        // // // // // // //
        // Optional params:
        // // // // // // //

        // TODO: RUAParameterIssuerScriptResults
        // TODO: RUAParameterIssuerScriptIdentifier
        // TODO: RUAParameterWrapperforIssuerScriptTagWithIncorrectLength

        if (self.issuerScriptTemplate1 != nil) {
            [transactionParameters setObject:self.issuerScriptTemplate1 forKey:[NSNumber numberWithInt:RUAParameterIssuerScript1]];
        }

        if (self.issuerScriptTemplate2 != nil) {
            [transactionParameters setObject:self.issuerScriptTemplate2 forKey:[NSNumber numberWithInt:RUAParameterIssuerScript2]];
        }

        if (self.authCode != nil) {
            [transactionParameters setObject:self.authCode forKey:[NSNumber numberWithInt:RUAParameterAuthorizationCode]];
        } else {
            // TODO: this dummy value should not be needed, asked Roam
            [transactionParameters setObject:@"110203040509" forKey:[NSNumber numberWithInt:RUAParameterAuthorizationCode]];

        }
    }

    NSLog(@"getEMVCompleteTransactionParameters:\n%@", transactionParameters);
    return transactionParameters;
}

/**
 *  Completes the transaction
 */
- (void) performEMVCompleteTransactionCommand
{
    NSLog(@"performEMVCompleteTransactionCommand");

    id <RUATransactionManager> tmgr = [self.roamDeviceManager getTransactionManager];
    NSDictionary *params = [processor getEMVCompleteTransactionParameters];

    [tmgr  sendCommand:RUACommandEMVCompleteTransaction
        withParameters:params
              progress: ^(RUAProgressMessage messageType, NSString* additionalMessage) {
                  NSLog(@"onCompleteTX RUAProgressMessage: %@ %@", [WPRoamHelper RUAProgressMessage_toString:messageType], additionalMessage);
              }
              response: ^(RUAResponse *ruaResponse) {
                  NSLog(@"onCompleteTX RUAResponse: %@", [WPRoamHelper RUAResponse_toString:ruaResponse]);

                  [self handleEMVCompleteTransactionResponse:ruaResponse];
              }
     ];
}



/**
 *  Handle EMV Complete Transaction response from Roam. This can also be called in case of offline auth to handle the EMV Transaction Data command response.
 *
 *  @param ruaResponse The response
 */
- (void) handleEMVCompleteTransactionResponse:(RUAResponse *) ruaResponse
{
    // get response data
    NSDictionary *responseData = [WPRoamHelper RUAResponse_toDictionary:ruaResponse];
    NSError *error = [self validateEMVResponse:responseData];

    if (error != nil) {
        if (self.shouldIssueReversal) {
            // this is set inside the validator
            [self.delegate issueReversalForCreditCardId:@([self.creditCardId longLongValue])
                                              accountId:@(self.accountId)
                                           roamResponse:responseData];
            
        }

        // we found an error, return it
        [self reportAuthorizationSuccess:nil orError:error forPaymentInfo:self.paymentInfo];
    } else {
        // handle success
        NSString *tc = [responseData objectForKey:@"ApplicationCryptogram"];

        WPAuthorizationInfo *authInfo =
        [[WPAuthorizationInfo alloc] initWithAmount:self.amount
                                       currencyCode:self.currencyCode
                             transactionCertificate:tc
                                            tokenId:self.creditCardId];

        // inform external success
        [self reportAuthorizationSuccess:authInfo orError:nil forPaymentInfo:self.paymentInfo];
    }
}

#pragma mark - EMV Helpers

- (NSError *) validateEMVResponse:(NSDictionary*) responseData
{
    NSError *error = nil;
    NSString *errorCode = [responseData objectForKey: @"ErrorCode"];

    // TODO: use [WPError errorWithCardReaderResponseData]
    if (errorCode != nil ) {
        if ([errorCode isEqualToString:[WPRoamHelper RUAErrorCode_toString:RUAErrorCodeRSAKeyNotFound]]) {
            error = [WPError errorCardNotSupported];
        } else if ([errorCode isEqualToString:[WPRoamHelper RUAErrorCode_toString:RUAErrorCodeNonEMVCardOrCardError]]) {
            // This is only known to happen when "Conditions of Use Not Satisfied" e.g. geographical restrictions.
            error = [WPError errorCardNotSupported];
        }  else if ([errorCode isEqualToString:[WPRoamHelper RUAErrorCode_toString:RUAErrorCodeApplicationBlocked]]) {
            error = [WPError errorCardBlocked];
        } else {
            // TODO: define more specific errors
            error = [WPError errorForEMVTransactionErrorWithMessage:errorCode];
        }
    } else {
        //no error, but response may still be invalid for us.

        // check cryptogram
        NSString *command = [responseData objectForKey:[WPRoamHelper RUAParameter_toString:RUAParameterCommand]];
        NSString *cryptogramInformationData = [responseData objectForKey:[WPRoamHelper RUAParameter_toString:RUAParameterCryptogramInformationData]];

        BOOL isCompleteTx = [command isEqualToString:[WPRoamHelper RUACommand_toString:RUACommandEMVCompleteTransaction]];
        BOOL isTxData = [command isEqualToString:[WPRoamHelper RUACommand_toString:RUACommandEMVTransactionData]];
        BOOL isCardDecline = [cryptogramInformationData isEqualToString:CRYPTOGRAM_INFORMATION_DATA_00];
        BOOL isIssuerReachable = (self.authResponseCode != nil);
        BOOL isIssuerDecline = (self.authResponseCode != nil) && ![self.authResponseCode isEqualToString:AUTH_RESPONSE_CODE_ONLINE_APPROVE]; // non-nil code that is NOT the approval code "00"

        if (isCompleteTx && isIssuerDecline && isCardDecline) {
            // online decline, card confirmed decline
            error = [WPError errorDeclinedByIssuer];
        } else if (isCompleteTx && isIssuerReachable && isCardDecline) {
            // online approved, declined by card
            error = [WPError errorDeclinedByCard];

            // must issue reversal here
            self.shouldIssueReversal = YES;
        } else if (isCompleteTx && !isIssuerReachable && isCardDecline) {
            // issuer unreachable, declined by card
            error = [WPError errorIssuerUnreachable];
        } else if (isTxData && isCardDecline) {
            // offline declined
            error = [WPError errorDeclinedByCard];
        }
    }

    return error;
}

- (NSString *) convertToEMVAmount:(double) amount
{
    int intAmount = (int) (amount*100);
    return [NSString stringWithFormat:@"%012d", intAmount];
}

- (NSString *) convertToEMVCurrencyCode:(NSString *) currencyCode
{
    // 0840 for Dollar, 0826 for Pound
    if ([@"USD" isEqualToString:currencyCode]) {
        return @"0840";
    } else if ([@"GBP" isEqualToString:currencyCode]) {
        return @"0826";
    }

    //default
    return nil;
}

- (NSString *) convertResponseCodeToHexString:(NSString *)responseCode
{
    NSString *result = @"";

    unsigned long len = [responseCode length];
    unichar buffer[len];

    [responseCode getCharacters:buffer range:NSMakeRange(0, len)];

    for(int i = 0; i < len; ++i) {
        char current = buffer[i];
        result = [result stringByAppendingString:[NSString stringWithFormat:@"%X", current]];
    }

    return result;
}

- (void) stopTransaction
{
    id <RUATransactionManager> tmgr = [self.roamDeviceManager getTransactionManager];

    [tmgr sendCommand:RUACommandEMVTransactionStop withParameters:nil
             progress: ^(RUAProgressMessage messageType, NSString* additionalMessage) {
                 NSLog(@"onStopTX RUAProgressMessage: %@",[WPRoamHelper RUAProgressMessage_toString:messageType]);
             }
             response: ^(RUAResponse *ruaResponse) {
                 NSLog(@"onStopTX RUAResponseMessage: %@",[WPRoamHelper RUAResponse_toDictionary:ruaResponse]);
             }
     ];
}

#pragma mark - EMV Reader Setup

- (void)setupExpectedDOLs
{
    [processor setupDOLValues];

    id <RUAConfigurationManager> cmgr = [self.roamDeviceManager getConfigurationManager];
    [cmgr setExpectedAmountDOL:_amountDOL];
    [cmgr setExpectedResponseDOL:_responseDOL];
    [cmgr setExpectedOnlineDOL:_onlineDOL];

    [self performSelector:@selector(fetchAuthInfoForTransaction) withObject:nil afterDelay:1.0];
}

- (void) fetchAuthInfoForTransaction
{
    // fetch Tx info from delegate
    [processor.delegate fetchAuthInfo:^(double amount, NSString *currencyCode, long merchantAccountId) {
        // save transaction info
        processor.amount = amount;
        processor.currencyCode = currencyCode;
        processor.accountId = merchantAccountId;

        // kick off transaction
        [processor performEMVTransactionStartCommand];
    }];
}



- (void)setupDOLValues{
    _currentPublicKeyIndex = 0;

    //Initialize the amount data object list (DOL) array
    _amountDOL = [[NSArray alloc] initWithObjects:
//                  [NSNumber numberWithInt:RUAParameterAmountAuthorizedNumeric],  // 9F02
                  //[NSNumber numberWithInt:RUAParameterApplicationCryptogram],    // 9F26
                  [NSNumber numberWithInt:RUAParameterApplicationEffectiveDate], // 5F25
                  [NSNumber numberWithInt:RUAParameterApplicationExpirationDate],// 5F24
//                  [NSNumber numberWithInt:RUAParameterApplicationIdentifier],	 // 4F
                  [NSNumber numberWithInt:RUAParameterApplicationLabel],		 // 50
//                  [NSNumber numberWithInt:RUAParameterApplicationPreferredName], // 9F12
//                  [NSNumber numberWithInt:RUAParameterApplicationPriorityIndicator], // 87
                  [NSNumber numberWithInt:RUAParameterApplicationTransactionCounter], // 9F36
                  [NSNumber numberWithInt:RUAParameterCardholderVerificationMethodResult], // 9F34
                  //[NSNumber numberWithInt:RUAParameterCryptogramInformationData], // 9F27
                  [NSNumber numberWithInt:RUAParameterPAN], // 5A
                  [NSNumber numberWithInt:RUAParameterPANSequenceNumber], // 5F34
                  [NSNumber numberWithInt:RUAParameterTransactionStatusInformation], // 9B
                  [NSNumber numberWithInt:RUAParameterTerminalVerificationResults], // 95
                  [NSNumber numberWithInt:RUAParameterUnpredictableNumber], // 9F37
                  nil];



    //Initialize the online data object list (DOL) array
    _onlineDOL = [[NSMutableArray alloc] initWithObjects:
                  [NSNumber numberWithInt:RUAParameterAmountAuthorizedNumeric],   // 9F02
                  [NSNumber numberWithInt:RUAParameterAmountOtherNumeric],        // 9F03
                  [NSNumber numberWithInt:RUAParameterApplicationCryptogram],     // 9F26
                  [NSNumber numberWithInt:RUAParameterApplicationEffectiveDate],  // 5F25
                  [NSNumber numberWithInt:RUAParameterApplicationExpirationDate], // 5F24
                  [NSNumber numberWithInt:RUAParameterApplicationIdentifier],	  // 4F
                  [NSNumber numberWithInt:RUAParameterApplicationInterchangeProfile], // 82
                  [NSNumber numberWithInt:RUAParameterApplicationLabel], // 50
                  [NSNumber numberWithInt:RUAParameterApplicationPreferredName], // 9F12
                  [NSNumber numberWithInt:RUAParameterApplicationTransactionCounter], // 9F36
                  [NSNumber numberWithInt:RUAParameterCardHolderName], // 5F20
                  [NSNumber numberWithInt:RUAParameterCardRiskManagementDataObjectList1], // 8C
                  [NSNumber numberWithInt:RUAParameterCryptogramInformationData], // 9F27
                  [NSNumber numberWithInt:RUAParameterIssuerApplicationData], // 9F10
                  [NSNumber numberWithInt:RUAParameterPAN], // 5A
                  [NSNumber numberWithInt:RUAParameterPANSequenceNumber], // 5F34
                  [NSNumber numberWithInt:RUAParameterTerminalCapabilities], // 9F33
                  [NSNumber numberWithInt:RUAParameterTerminalCountryCode], // 9F1A
                  [NSNumber numberWithInt:RUAParameterTerminalType], // 9F35
                  [NSNumber numberWithInt:RUAParameterTerminalVerificationResults], // 95
                  [NSNumber numberWithInt:RUAParameterTrack2EquivalentData], // 57
                  [NSNumber numberWithInt:RUAParameterTransactionCurrencyCode], // 5F2A
                  [NSNumber numberWithInt:RUAParameterTransactionCurrencyExponent], // 5F36
                  [NSNumber numberWithInt:RUAParameterTransactionDate], // 9A
                  [NSNumber numberWithInt:RUAParameterTransactionStatusInformation], // 9B
                  [NSNumber numberWithInt:RUAParameterTransactionType], // 9C
                  [NSNumber numberWithInt:RUAParameterUnpredictableNumber], // 9F37
                  //[NSNumber numberWithInt:RUAParameterOnlinePINBlock], // Required for ICC Chip and Pin Transaction
                  //[NSNumber numberWithInt:RUAParameterOnlinePINSMID],  // Required for ICC Chip and Pin Transaction
                  nil];

    //Initialize the response data object list (DOL) array
    _responseDOL = [[NSMutableArray alloc] initWithObjects:
                    [NSNumber numberWithInt:RUAParameterAmountAuthorizedNumeric],   // 9F02
                    [NSNumber numberWithInt:RUAParameterAmountOtherNumeric],        // 9F03
                    [NSNumber numberWithInt:RUAParameterApplicationCryptogram],     // 9F26
                    [NSNumber numberWithInt:RUAParameterApplicationEffectiveDate],  // 5F25
                    [NSNumber numberWithInt:RUAParameterApplicationExpirationDate], // 5F24
                    [NSNumber numberWithInt:RUAParameterApplicationIdentifier],	  // 4F
                    [NSNumber numberWithInt:RUAParameterApplicationInterchangeProfile], // 82
                    [NSNumber numberWithInt:RUAParameterApplicationLabel], // 50
                    [NSNumber numberWithInt:RUAParameterApplicationPreferredName], // 9F12
                    [NSNumber numberWithInt:RUAParameterApplicationTransactionCounter], // 9F36
                    [NSNumber numberWithInt:RUAParameterCardHolderName], // 5F20
                    [NSNumber numberWithInt:RUAParameterCardholderVerificationMethodResult], //8C
                    [NSNumber numberWithInt:RUAParameterCryptogramInformationData], // 9F27
                    [NSNumber numberWithInt:RUAParameterCVMOUTresult], //DF38
                    [NSNumber numberWithInt:RUAParameterDedicatedFileName], // 84
                    [NSNumber numberWithInt:RUAParameterInterfaceDeviceSerialNumber], // 9F1E
                    [NSNumber numberWithInt:RUAParameterIssuerApplicationData], // 9F10
                    [NSNumber numberWithInt:RUAParameterPAN], // 5A
                    [NSNumber numberWithInt:RUAParameterPANSequenceNumber], // 5F34
                    [NSNumber numberWithInt:RUAParameterTerminalCapabilities], // 9F33
                    [NSNumber numberWithInt:RUAParameterTerminalCountryCode], // 9F1A
                    [NSNumber numberWithInt:RUAParameterTerminalType], // 9F35
                    [NSNumber numberWithInt:RUAParameterTerminalVerificationResults], // 95
                    [NSNumber numberWithInt:RUAParameterTrack2EquivalentData], // 57
                    [NSNumber numberWithInt:RUAParameterTransactionCurrencyCode], // 5F2A
                    [NSNumber numberWithInt:RUAParameterTransactionCurrencyExponent], // 5F36
                    [NSNumber numberWithInt:RUAParameterTransactionDate], // 9A
                    [NSNumber numberWithInt:RUAParameterTransactionSequenceCounter], // 9F41
                    [NSNumber numberWithInt:RUAParameterTransactionStatusInformation], // 9B
                    [NSNumber numberWithInt:RUAParameterTransactionType], // 9C
                    [NSNumber numberWithInt:RUAParameterUnpredictableNumber], // 9F37
                    nil];
}

- (void)setupKeysValuesForTesting
{

    _publicKeyList = [[NSArray alloc] initWithObjects:
                      // Mastercard
                      [[RUAPublicKey alloc] initWithRID:AID_MCRD
                                   withCAPublicKeyIndex:@"EF" withPublicKey:@"A191CB87473F29349B5D60A88B3EAEE0973AA6F1A082F358D849FDDFF9C091F899EDA9792CAF09EF28F5D22404B88A2293EEBBC1949C43BEA4D60CFD879A1539544E09E0F09F60F065B2BF2A13ECC705F3D468B9D33AE77AD9D3F19CA40F23DCF5EB7C04DC8F69EBA565B1EBCB4686CD274785530FF6F6E9EE43AA43FDB02CE00DAEC15C7B8FD6A9B394BABA419D3F6DC85E16569BE8E76989688EFEA2DF22FF7D35C043338DEAA982A02B866DE5328519EBBCD6F03CDD686673847F84DB651AB86C28CF1462562C577B853564A290C8556D818531268D25CC98A4CC6A0BDFFFDA2DCCA3A94C998559E307FDDF915006D9A987B07DDAEB3B"
                                withExponentOfPublicKey:@"03"],
                      [[RUAPublicKey alloc] initWithRID:AID_MCRD
                                   withCAPublicKeyIndex:@"F3" withPublicKey:@"98F0C770F23864C2E766DF02D1E833DFF4FFE92D696E1642F0A88C5694C6479D16DB1537BFE29E4FDC6E6E8AFD1B0EB7EA0124723C333179BF19E93F10658B2F776E829E87DAEDA9C94A8B3382199A350C077977C97AFF08FD11310AC950A72C3CA5002EF513FCCC286E646E3C5387535D509514B3B326E1234F9CB48C36DDD44B416D23654034A66F403BA511C5EFA3"
                                withExponentOfPublicKey:@"03"],
                      [[RUAPublicKey alloc] initWithRID:AID_MCRD
                                   withCAPublicKeyIndex:@"FA" withPublicKey:@"A90FCD55AA2D5D9963E35ED0F440177699832F49C6BAB15CDAE5794BE93F934D4462D5D12762E48C38BA83D8445DEAA74195A301A102B2F114EADA0D180EE5E7A5C73E0C4E11F67A43DDAB5D55683B1474CC0627F44B8D3088A492FFAADAD4F42422D0E7013536C3C49AD3D0FAE96459B0F6B1B6056538A3D6D44640F94467B108867DEC40FAAECD740C00E2B7A8852D"
                                withExponentOfPublicKey:@"03"],
                      [[RUAPublicKey alloc] initWithRID:AID_MCRD
                                   withCAPublicKeyIndex:@"F8" withPublicKey:@"A1F5E1C9BD8650BD43AB6EE56B891EF7459C0A24FA84F9127D1A6C79D4930F6DB1852E2510F18B61CD354DB83A356BD190B88AB8DF04284D02A4204A7B6CB7C5551977A9B36379CA3DE1A08E69F301C95CC1C20506959275F41723DD5D2925290579E5A95B0DF6323FC8E9273D6F849198C4996209166D9BFC973C361CC826E1"
                                withExponentOfPublicKey:@"FF"],
                      [[RUAPublicKey alloc] initWithRID:AID_MCRD
                                   withCAPublicKeyIndex:@"FE" withPublicKey:@"A653EAC1C0F786C8724F737F172997D63D1C3251C44402049B865BAE877D0F398CBFBE8A6035E24AFA086BEFDE9351E54B95708EE672F0968BCD50DCE40F783322B2ABA04EF137EF18ABF03C7DBC5813AEAEF3AA7797BA15DF7D5BA1CBAF7FD520B5A482D8D3FEE105077871113E23A49AF3926554A70FE10ED728CF793B62A1"
                                withExponentOfPublicKey:@"03"],
                      [[RUAPublicKey alloc] initWithRID:AID_MCRD
                                   withCAPublicKeyIndex:@"F1" withPublicKey:@"A0DCF4BDE19C3546B4B6F0414D174DDE294AABBB828C5A834D73AAE27C99B0B053A90278007239B6459FF0BBCD7B4B9C6C50AC02CE91368DA1BD21AAEADBC65347337D89B68F5C99A09D05BE02DD1F8C5BA20E2F13FB2A27C41D3F85CAD5CF6668E75851EC66EDBF98851FD4E42C44C1D59F5984703B27D5B9F21B8FA0D93279FBBF69E090642909C9EA27F898959541AA6757F5F624104F6E1D3A9532F2A6E51515AEAD1B43B3D7835088A2FAFA7BE7"
                                withExponentOfPublicKey:@"03"],

                      // VISA
                      [[RUAPublicKey alloc] initWithRID:AID_VISA
                                   withCAPublicKeyIndex:@"AC" withPublicKey:@"EE4F40F63A8E67EA1AC449EF57E3DE60E13BB1E6D8CCC42D1749652476F7082A888471D4C5A2BA7356C2F40B2AA7753C1244CCA0A0DFF3B49EC7C57CC5BD40DDF18BAA0D6020790CC92360FB201E6AE8C92DA94E0E041561365990F4B6F380FB8EF5906A1FA7F7FA9923B7AA6DA7A8A7964B88DD80548501E7B6FDD97B3F89F3A941DEA1447F464A8D7BEF53F6E5820F"
                                withExponentOfPublicKey:@"03"],
                                            [[RUAPublicKey alloc] initWithRID:AID_VISA
                                   withCAPublicKeyIndex:@"95" withPublicKey:@"BE9E1FA5E9A803852999C4AB432DB28600DCD9DAB76DFAAA47355A0FE37B1508AC6BF38860D3C6C2E5B12A3CAAF2A7005A7241EBAA7771112C74CF9A0634652FBCA0E5980C54A64761EA101A114E0F0B5572ADD57D010B7C9C887E104CA4EE1272DA66D997B9A90B5A6D624AB6C57E73C8F919000EB5F684898EF8C3DBEFB330C62660BED88EA78E909AFF05F6DA627B"
                                withExponentOfPublicKey:@"03"],
                      [[RUAPublicKey alloc] initWithRID:AID_VISA
                                   withCAPublicKeyIndex:@"99" withPublicKey:@"AB79FCC9520896967E776E64444E5DCDD6E13611874F3985722520425295EEA4BD0C2781DE7F31CD3D041F565F747306EED62954B17EDABA3A6C5B85A1DE1BEB9A34141AF38FCF8279C9DEA0D5A6710D08DB4124F041945587E20359BAB47B7575AD94262D4B25F264AF33DEDCF28E09615E937DE32EDC03C54445FE7E382777"
                                withExponentOfPublicKey:@"03"],

                      [[RUAPublicKey alloc] initWithRID:AID_VISA
                                   withCAPublicKeyIndex:@"92" withPublicKey:@"996AF56F569187D09293C14810450ED8EE3357397B18A2458EFAA92DA3B6DF6514EC060195318FD43BE9B8F0CC669E3F844057CBDDF8BDA191BB64473BC8DC9A730DB8F6B4EDE3924186FFD9B8C7735789C23A36BA0B8AF65372EB57EA5D89E7D14E9C7B6B557460F10885DA16AC923F15AF3758F0F03EBD3C5C2C949CBA306DB44E6A2C076C5F67E281D7EF56785DC4D75945E491F01918800A9E2DC66F60080566CE0DAF8D17EAD46AD8E30A247C9F"
                                withExponentOfPublicKey:@"03"],
                      [[RUAPublicKey alloc] initWithRID:AID_VISA
                                   withCAPublicKeyIndex:@"94" withPublicKey:@"ACD2B12302EE644F3F835ABD1FC7A6F62CCE48FFEC622AA8EF062BEF6FB8BA8BC68BBF6AB5870EED579BC3973E121303D34841A796D6DCBC41DBF9E52C4609795C0CCF7EE86FA1D5CB041071ED2C51D2202F63F1156C58A92D38BC60BDF424E1776E2BC9648078A03B36FB554375FC53D57C73F5160EA59F3AFC5398EC7B67758D65C9BFF7828B6B82D4BE124A416AB7301914311EA462C19F771F31B3B57336000DFF732D3B83DE07052D730354D297BEC72871DCCF0E193F171ABA27EE464C6A97690943D59BDABB2A27EB71CEEBDAFA1176046478FD62FEC452D5CA393296530AA3F41927ADFE434A2DF2AE3054F8840657A26E0FC617"
                                withExponentOfPublicKey:@"03"],

                      // Discover
                      [[RUAPublicKey alloc] initWithRID:AID_DISC
                                   withCAPublicKeyIndex:@"5A" withPublicKey:@"EDD8252468A705614B4D07DE3211B30031AEDB6D33A4315F2CFF7C97DB918993C2DC02E79E2FF8A2683D5BBD0F614BC9AB360A448283EF8B9CF6731D71D6BE939B7C5D0B0452D660CF24C21C47CAC8E26948C8EED8E3D00C016828D642816E658DC2CFC61E7E7D7740633BEFE34107C1FB55DEA7FAAEA2B25E85BED948893D07"
                                withExponentOfPublicKey:@"03"],

                      [[RUAPublicKey alloc] initWithRID:AID_DISC
                                   withCAPublicKeyIndex:@"5B" withPublicKey:@"D3F45D065D4D900F68B2129AFA38F549AB9AE4619E5545814E468F382049A0B9776620DA60D62537F0705A2C926DBEAD4CA7CB43F0F0DD809584E9F7EFBDA3778747BC9E25C5606526FAB5E491646D4DD28278691C25956C8FED5E452F2442E25EDC6B0C1AA4B2E9EC4AD9B25A1B836295B823EDDC5EB6E1E0A3F41B28DB8C3B7E3E9B5979CD7E079EF024095A1D19DD"
                                withExponentOfPublicKey:@"03"],
                      [[RUAPublicKey alloc] initWithRID:AID_DISC
                                   withCAPublicKeyIndex:@"5C" withPublicKey:@"833F275FCF5CA4CB6F1BF880E54DCFEB721A316692CAFEB28B698CAECAFA2B2D2AD8517B1EFB59DDEFC39F9C3B33DDEE40E7A63C03E90A4DD261BC0F28B42EA6E7A1F307178E2D63FA1649155C3A5F926B4C7D7C258BCA98EF90C7F4117C205E8E32C45D10E3D494059D2F2933891B979CE4A831B301B0550CDAE9B67064B31D8B481B85A5B046BE8FFA7BDB58DC0D7032525297F26FF619AF7F15BCEC0C92BCDCBC4FB207D115AA65CD04C1CF982191"
                                withExponentOfPublicKey:@"03"],
                      [[RUAPublicKey alloc] initWithRID:AID_DISC
                                   withCAPublicKeyIndex:@"5D" withPublicKey:@"AD938EA9888E5155F8CD272749172B3A8C504C17460EFA0BED7CBC5FD32C4A80FD810312281B5A35562800CDC325358A9639C501A537B7AE43DF263E6D232B811ACDB6DDE979D55D6C911173483993A423A0A5B1E1A70237885A241B8EEBB5571E2D32B41F9CC5514DF83F0D69270E109AF1422F985A52CCE04F3DF269B795155A68AD2D6B660DDCD759F0A5DA7B64104D22C2771ECE7A5FFD40C774E441379D1132FAF04CDF55B9504C6DCE9F61776D81C7C45F19B9EFB3749AC7D486A5AD2E781FA9D082FB2677665B99FA5F1553135A1FD2A2A9FBF625CA84A7D736521431178F13100A2516F9A43CE095B032B886C7A6AB126E203BE7"
                                withExponentOfPublicKey:@"03"],

                      // AMEX
                      [[RUAPublicKey alloc] initWithRID:AID_AMEX
                                   withCAPublicKeyIndex:@"96" withPublicKey:@"BC9AA294B1FDD263176E3243D8F448BBFFCB6ABD02C31811289F5085A9262B8B1B7C6477EB58055D9EF32A83D1B72D4A1471ECA30CE76585C3FD05372B686F92B795B1640959201523230149118D52D2425BD11C863D9B2A7C4AD0A2BFDBCA67B2713B290F493CD5521E5DDF05EF1040FC238D0A851C8E3E3B2B1F0D5D9D4AED"
                                withExponentOfPublicKey:@"03"],

                      [[RUAPublicKey alloc] initWithRID:AID_AMEX
                                   withCAPublicKeyIndex:@"97" withPublicKey:@"E178FFE834B4B767AF3C9A511F973D8E8505C5FCB2D3768075AB7CC946A955789955879AAF737407151521996DFA43C58E6B130EB1D863B85DC9FFB4050947A2676AA6A061A4A7AE1EDB0E36A697E87E037517EB8923136875BA2CA1087CBA7EC7653E5E28A0C261A033AF27E3A67B64BBA26956307EC47E674E3F8B722B3AE0498DB16C7985310D9F3D117300D32B09"
                                withExponentOfPublicKey:@"03"],

                      [[RUAPublicKey alloc] initWithRID:AID_AMEX
                                   withCAPublicKeyIndex:@"98" withPublicKey:@"D31A7094FB221CBA6660FB975AAFEA80DB7BB7EAFD7351E748827AB62D4AEECCFC1787FD47A04699A02DB00D7C382E80E804B35C59434C602389D691B9CCD51ED06BE67A276119C4C10E2E40FC4EDDF9DF39B9B0BDEE8D076E2A012E8A292AF8EFE18553470639C1A032252E0E5748B25A3F9BA4CFCEE073038B061837F2AC1B04C279640F5BD110A9DC665ED2FA6828BD5D0FE810A892DEE6B0E74CE8863BDE08FD5FD61A0F11FA0D14978D8CED7DD3"
                                withExponentOfPublicKey:@"03"],

                      [[RUAPublicKey alloc] initWithRID:AID_AMEX
                                   withCAPublicKeyIndex:@"99" withPublicKey:@"E1740074229FA0D228A9623581D7A322903FB89BA7686712E601FA8AB24A9789186F15B70CCBBE7421B1CB110D45361688135FFD0DB15A3F516BB291D4A123EBF5A06FBF7E1EE6311B737DABB289570A7959D532B25F1DA6758C84DDCCADC049BC764C05391ABD2CADEFFA7E242D5DD06E56001F0E68151E3388074BD9330D6AFA57CBF33946F531E51E0D4902EE235C756A905FB733940E6EC897B4944A5EDC765705E2ACF76C78EAD78DD9B066DF0B2C88750B8AEE00C9B4D4091FA7338449DA92DBFC908FA0781C0128C492DB993C88BA8BB7CADFE238D477F2517E0E7E3D2B11796A0318CE2AD4DA1DB8E54AB0D94F109DB9CAEEFBEF"
                                withExponentOfPublicKey:@"03"],

                      [[RUAPublicKey alloc] initWithRID:AID_AMEX
                                   withCAPublicKeyIndex:@"C1" withPublicKey:@"E69E319C34D1B4FB43AED4BD8BBA6F7A8B763F2F6EE5DDF7C92579A984F89C4A9C15B27037764C58AC7E45EFBC34E138E56BA38F76E803129A8DDEB5E1CC8C6B30CF634A9C9C1224BF1F0A9A18D79ED41EBCF1BE78087AE8B7D2F896B1DE8B7E784161A138A0F2169AD33E146D1B16AB595F9D7D98BE671062D217F44EB68C68640C7D57465A063F6BAC776D3E2DAC61"
                                withExponentOfPublicKey:@"03"],

                      [[RUAPublicKey alloc] initWithRID:AID_AMEX
                                   withCAPublicKeyIndex:@"C2" withPublicKey:@"B875002F38BA26D61167C5D440367604AD38DF2E93D8EE8DA0E8D9C0CF4CC5788D11DEA689E5F41D23A3DA3E0B1FA5875AE25620F5A6BCCEE098C1B35C691889D7D0EF670EB8312E7123FCC5DC7D2F0719CC80E1A93017F944D097330EDF945762FEE62B7B0BA0348228DBF38D4216E5A67A7EF74F5D3111C44AA31320F623CB3C53E60966D6920067C9E082B746117E48E4F00E110950CA54DA3E38E5453BD5544E3A6760E3A6A42766AD2284E0C9AF"
                                withExponentOfPublicKey:@"03"],

                      [[RUAPublicKey alloc] initWithRID:AID_AMEX
                                   withCAPublicKeyIndex:@"C3" withPublicKey:@"B93182ABE343DFBF388C71C4D6747DCDEC60367FE63CFAA942D7D323E688D0832836548BF0EDFF1EDEEB882C75099FF81A93FA525C32425B36023EA02A8899B9BF7D7934E86F997891823006CEAA93091A73C1FDE18ABD4F87A22308640C064C8C027685F1B2DB7B741B67AB0DE05E870481C5F972508C17F57E4F833D63220F6EA2CFBB878728AA5887DE407D10C6B8F58D46779ECEC1E2155487D52C78A5C03897F2BB580E0A2BBDE8EA2E1C18F6AAF3EB3D04C3477DEAB88F150C8810FD1EF8EB0596866336FE2C1FBC6BEC22B4FE5D885647726DB59709A505F75C49E0D8D71BF51E4181212BE2142AB2A1E8C0D3B7136CD7B7708E4D"
                                withExponentOfPublicKey:@"03"],
                      nil];

    // TODO: figure out Terminal Application Version
    _aidsList = [[NSMutableArray alloc] initWithObjects:
                 // Mastercard
                 [[RUAApplicationIdentifier alloc]initWithRID:AID_MCRD withPIX:@"1010" withAID:nil withApplicationLabel:nil withTerminalApplicationVersion:@"3033" withLowestSupportedICCApplicationVersion:@"3031" withPriorityIndex:@"00" withApplicationSelectionFlags:@"01"],
                 [[RUAApplicationIdentifier alloc]initWithRID:AID_MCRD withPIX:@"2010" withAID:nil withApplicationLabel:nil withTerminalApplicationVersion:@"3033" withLowestSupportedICCApplicationVersion:@"3031" withPriorityIndex:@"00" withApplicationSelectionFlags:@"01"],
                 [[RUAApplicationIdentifier alloc]initWithRID:AID_MCRD withPIX:@"2203" withAID:nil withApplicationLabel:nil withTerminalApplicationVersion:@"3033" withLowestSupportedICCApplicationVersion:@"3031" withPriorityIndex:@"00" withApplicationSelectionFlags:@"01"],
                 [[RUAApplicationIdentifier alloc]initWithRID:AID_MCRD withPIX:@"3010" withAID:nil withApplicationLabel:nil withTerminalApplicationVersion:@"3033" withLowestSupportedICCApplicationVersion:@"3031" withPriorityIndex:@"00" withApplicationSelectionFlags:@"01"],
                 [[RUAApplicationIdentifier alloc]initWithRID:AID_MCRD withPIX:@"3060" withAID:nil withApplicationLabel:nil withTerminalApplicationVersion:@"3033" withLowestSupportedICCApplicationVersion:@"3031" withPriorityIndex:@"00" withApplicationSelectionFlags:@"01"],
                 [[RUAApplicationIdentifier alloc]initWithRID:AID_MCRD withPIX:@"4010" withAID:nil withApplicationLabel:nil withTerminalApplicationVersion:@"3033" withLowestSupportedICCApplicationVersion:@"3031" withPriorityIndex:@"00" withApplicationSelectionFlags:@"01"],
                 [[RUAApplicationIdentifier alloc]initWithRID:AID_MCRD withPIX:@"5010" withAID:nil withApplicationLabel:nil withTerminalApplicationVersion:@"3033" withLowestSupportedICCApplicationVersion:@"3031" withPriorityIndex:@"00" withApplicationSelectionFlags:@"01"],
                 [[RUAApplicationIdentifier alloc]initWithRID:AID_MCRD withPIX:@"6000" withAID:nil withApplicationLabel:nil withTerminalApplicationVersion:@"3033" withLowestSupportedICCApplicationVersion:@"3031" withPriorityIndex:@"00" withApplicationSelectionFlags:@"01"],
                 [[RUAApplicationIdentifier alloc]initWithRID:AID_MCRD withPIX:@"9999" withAID:nil withApplicationLabel:nil withTerminalApplicationVersion:@"3033" withLowestSupportedICCApplicationVersion:@"3031" withPriorityIndex:@"00" withApplicationSelectionFlags:@"01"],

                 // VISA
                 [[RUAApplicationIdentifier alloc]initWithRID:AID_VISA withPIX:@"1010" withAID:nil withApplicationLabel:nil withTerminalApplicationVersion:@"3033" withLowestSupportedICCApplicationVersion:@"3031" withPriorityIndex:@"00" withApplicationSelectionFlags:@"01"],
                 [[RUAApplicationIdentifier alloc]initWithRID:AID_VISA withPIX:@"2010" withAID:nil withApplicationLabel:nil withTerminalApplicationVersion:@"3033" withLowestSupportedICCApplicationVersion:@"3031" withPriorityIndex:@"00" withApplicationSelectionFlags:@"01"],
                 [[RUAApplicationIdentifier alloc]initWithRID:AID_VISA withPIX:@"2020" withAID:nil withApplicationLabel:nil withTerminalApplicationVersion:@"3033" withLowestSupportedICCApplicationVersion:@"3031" withPriorityIndex:@"00" withApplicationSelectionFlags:@"01"],
                 [[RUAApplicationIdentifier alloc]initWithRID:AID_VISA withPIX:@"8010" withAID:nil withApplicationLabel:nil withTerminalApplicationVersion:@"3033" withLowestSupportedICCApplicationVersion:@"3031" withPriorityIndex:@"00" withApplicationSelectionFlags:@"01"],

                 // Discover
                 [[RUAApplicationIdentifier alloc]initWithRID:AID_DISC withPIX:@"3010" withAID:nil withApplicationLabel:nil withTerminalApplicationVersion:@"3033" withLowestSupportedICCApplicationVersion:@"3031" withPriorityIndex:@"00" withApplicationSelectionFlags:@"01"],

                 // AMEX
                 [[RUAApplicationIdentifier alloc]initWithRID:AID_AMEX withPIX:@"01" withAID:nil withApplicationLabel:nil withTerminalApplicationVersion:@"0001" withLowestSupportedICCApplicationVersion:@"0001" withPriorityIndex:@"00" withApplicationSelectionFlags:@"01"],

                 nil];

    _configHash = [self constructConfigHashWithKeysList:_publicKeyList aidsList:_aidsList];\
}

- (void)setupKeysValuesForProduction {

    _publicKeyList = [[NSArray alloc] initWithObjects:
                      // Mastercard
                      [[RUAPublicKey alloc] initWithRID:AID_MCRD
                                   withCAPublicKeyIndex:@"04" withPublicKey:@"A6DA428387A502D7DDFB7A74D3F412BE762627197B25435B7A81716A700157DDD06F7CC99D6CA28C2470527E2C03616B9C59217357C2674F583B3BA5C7DCF2838692D023E3562420B4615C439CA97C44DC9A249CFCE7B3BFB22F68228C3AF13329AA4A613CF8DD853502373D62E49AB256D2BC17120E54AEDCED6D96A4287ACC5C04677D4A5A320DB8BEE2F775E5FEC5"
                                withExponentOfPublicKey:@"03"],
                      [[RUAPublicKey alloc] initWithRID:AID_MCRD
                                   withCAPublicKeyIndex:@"05" withPublicKey:@"B8048ABC30C90D976336543E3FD7091C8FE4800DF820ED55E7E94813ED00555B573FECA3D84AF6131A651D66CFF4284FB13B635EDD0EE40176D8BF04B7FD1C7BACF9AC7327DFAA8AA72D10DB3B8E70B2DDD811CB4196525EA386ACC33C0D9D4575916469C4E4F53E8E1C912CC618CB22DDE7C3568E90022E6BBA770202E4522A2DD623D180E215BD1D1507FE3DC90CA310D27B3EFCCD8F83DE3052CAD1E48938C68D095AAC91B5F37E28BB49EC7ED597"
                                withExponentOfPublicKey:@"03"],
                      [[RUAPublicKey alloc] initWithRID:AID_MCRD
                                   withCAPublicKeyIndex:@"06" withPublicKey:@"CB26FC830B43785B2BCE37C81ED334622F9622F4C89AAE641046B2353433883F307FB7C974162DA72F7A4EC75D9D657336865B8D3023D3D645667625C9A07A6B7A137CF0C64198AE38FC238006FB2603F41F4F3BB9DA1347270F2F5D8C606E420958C5F7D50A71DE30142F70DE468889B5E3A08695B938A50FC980393A9CBCE44AD2D64F630BB33AD3F5F5FD495D31F37818C1D94071342E07F1BEC2194F6035BA5DED3936500EB82DFDA6E8AFB655B1EF3D0D7EBF86B66DD9F29F6B1D324FE8B26CE38AB2013DD13F611E7A594D675C4432350EA244CC34F3873CBA06592987A1D7E852ADC22EF5A2EE28132031E48F74037E3B34AB747F"
                                withExponentOfPublicKey:@"03"],

                      // VISA
                      [[RUAPublicKey alloc] initWithRID:AID_VISA
                                   withCAPublicKeyIndex:@"07" withPublicKey:@"A89F25A56FA6DA258C8CA8B40427D927B4A1EB4D7EA326BBB12F97DED70AE5E4480FC9C5E8A972177110A1CC318D06D2F8F5C4844AC5FA79A4DC470BB11ED635699C17081B90F1B984F12E92C1C529276D8AF8EC7F28492097D8CD5BECEA16FE4088F6CFAB4A1B42328A1B996F9278B0B7E3311CA5EF856C2F888474B83612A82E4E00D0CD4069A6783140433D50725F"
                                withExponentOfPublicKey:@"03"],
                      [[RUAPublicKey alloc] initWithRID:AID_VISA
                                   withCAPublicKeyIndex:@"08" withPublicKey:@"D9FD6ED75D51D0E30664BD157023EAA1FFA871E4DA65672B863D255E81E137A51DE4F72BCC9E44ACE12127F87E263D3AF9DD9CF35CA4A7B01E907000BA85D24954C2FCA3074825DDD4C0C8F186CB020F683E02F2DEAD3969133F06F7845166ACEB57CA0FC2603445469811D293BFEFBAFAB57631B3DD91E796BF850A25012F1AE38F05AA5C4D6D03B1DC2E568612785938BBC9B3CD3A910C1DA55A5A9218ACE0F7A21287752682F15832A678D6E1ED0B"
                                withExponentOfPublicKey:@"03"],
                      [[RUAPublicKey alloc] initWithRID:AID_VISA
                                   withCAPublicKeyIndex:@"09" withPublicKey:@"9D912248DE0A4E39C1A7DDE3F6D2588992C1A4095AFBD1824D1BA74847F2BC4926D2EFD904B4B54954CD189A54C5D1179654F8F9B0D2AB5F0357EB642FEDA95D3912C6576945FAB897E7062CAA44A4AA06B8FE6E3DBA18AF6AE3738E30429EE9BE03427C9D64F695FA8CAB4BFE376853EA34AD1D76BFCAD15908C077FFE6DC5521ECEF5D278A96E26F57359FFAEDA19434B937F1AD999DC5C41EB11935B44C18100E857F431A4A5A6BB65114F174C2D7B59FDF237D6BB1DD0916E644D709DED56481477C75D95CDD68254615F7740EC07F330AC5D67BCD75BF23D28A140826C026DBDE971A37CD3EF9B8DF644AC385010501EFC6509D7A41"
                                withExponentOfPublicKey:@"03"],

                      // Discover
                      [[RUAPublicKey alloc] initWithRID:AID_DISC
                                   withCAPublicKeyIndex:@"01" withPublicKey:@"8D1727AB9DC852453193EA0810B110F2A3FD304BE258338AC2650FA2A040FA10301EA53DF18FD9F40F55C44FE0EE7C7223BC649B8F9328925707776CB86F3AC37D1B22300D0083B49350E09ABB4B62A96363B01E4180E158EADDD6878E85A6C9D56509BF68F0400AFFBC441DDCCDAF9163C4AACEB2C3E1EC13699D23CDA9D3AD"
                                withExponentOfPublicKey:@"03"],

                      [[RUAPublicKey alloc] initWithRID:AID_DISC
                                   withCAPublicKeyIndex:@"03" withPublicKey:@"BF321241BDBF3585FFF2ACB89772EBD18F2C872159EAA4BC179FB03A1B850A1A758FA2C6849F48D4C4FF47E02A575FC13E8EB77AC37135030C5600369B5567D3A7AAF02015115E987E6BE566B4B4CC03A4E2B16CD9051667C2CD0EEF4D76D27A6F745E8BBEB45498ED8C30E2616DB4DBDA4BAF8D71990CDC22A8A387ACB21DD88E2CC27962B31FBD786BBB55F9E0B041"
                                withExponentOfPublicKey:@"03"],
                      [[RUAPublicKey alloc] initWithRID:AID_DISC
                                   withCAPublicKeyIndex:@"04" withPublicKey:@"8EEEC0D6D3857FD558285E49B623B109E6774E06E9476FE1B2FB273685B5A235E955810ADDB5CDCC2CB6E1A97A07089D7FDE0A548BDC622145CA2DE3C73D6B14F284B3DC1FA056FC0FB2818BCD7C852F0C97963169F01483CE1A63F0BF899D412AB67C5BBDC8B4F6FB9ABB57E95125363DBD8F5EBAA9B74ADB93202050341833DEE8E38D28BD175C83A6EA720C262682BEABEA8E955FE67BD9C2EFF7CB9A9F45DD5BDA4A1EEFB148BC44FFF68D9329FD"
                                withExponentOfPublicKey:@"03"],

                      [[RUAPublicKey alloc] initWithRID:AID_DISC
                                   withCAPublicKeyIndex:@"05" withPublicKey:@"E1200E9F4428EB71A526D6BB44C957F18F27B20BACE978061CCEF23532DBEBFAF654A149701C14E6A2A7C2ECAC4C92135BE3E9258331DDB0967C3D1D375B996F25B77811CCCC06A153B4CE6990A51A0258EA8437EDBEB701CB1F335993E3F48458BC1194BAD29BF683D5F3ECB984E31B7B9D2F6D947B39DEDE0279EE45B47F2F3D4EEEF93F9261F8F5A571AFBFB569C150370A78F6683D687CB677777B2E7ABEFCFC8F5F93501736997E8310EE0FD87AFAC5DA772BA277F88B44459FCA563555017CD0D66771437F8B6608AA1A665F88D846403E4C41AFEEDB9729C2B2511CFE228B50C1B152B2A60BBF61D8913E086210023A3AA499E423"
                                withExponentOfPublicKey:@"03"],

                      // AMEX
                      [[RUAPublicKey alloc] initWithRID:AID_AMEX
                                   withCAPublicKeyIndex:@"0E" withPublicKey:@"AA94A8C6DAD24F9BA56A27C09B01020819568B81A026BE9FD0A3416CA9A71166ED5084ED91CED47DD457DB7E6CBCD53E560BC5DF48ABC380993B6D549F5196CFA77DFB20A0296188E969A2772E8C4141665F8BB2516BA2C7B5FC91F8DA04E8D512EB0F6411516FB86FC021CE7E969DA94D33937909A53A57F907C40C22009DA7532CB3BE509AE173B39AD6A01BA5BB85"
                                withExponentOfPublicKey:@"03"],

                      [[RUAPublicKey alloc] initWithRID:AID_AMEX
                                   withCAPublicKeyIndex:@"0F" withPublicKey:@"C8D5AC27A5E1FB89978C7C6479AF993AB3800EB243996FBB2AE26B67B23AC482C4B746005A51AFA7D2D83E894F591A2357B30F85B85627FF15DA12290F70F05766552BA11AD34B7109FA49DE29DCB0109670875A17EA95549E92347B948AA1F045756DE56B707E3863E59A6CBE99C1272EF65FB66CBB4CFF070F36029DD76218B21242645B51CA752AF37E70BE1A84FF31079DC0048E928883EC4FADD497A719385C2BBBEBC5A66AA5E5655D18034EC5"
                                withExponentOfPublicKey:@"03"],

                      [[RUAPublicKey alloc] initWithRID:AID_AMEX
                                   withCAPublicKeyIndex:@"10" withPublicKey:@"CF98DFEDB3D3727965EE7797723355E0751C81D2D3DF4D18EBAB9FB9D49F38C8C4A826B99DC9DEA3F01043D4BF22AC3550E2962A59639B1332156422F788B9C16D40135EFD1BA94147750575E636B6EBC618734C91C1D1BF3EDC2A46A43901668E0FFC136774080E888044F6A1E65DC9AAA8928DACBEB0DB55EA3514686C6A732CEF55EE27CF877F110652694A0E3484C855D882AE191674E25C296205BBB599455176FDD7BBC549F27BA5FE35336F7E29E68D783973199436633C67EE5A680F05160ED12D1665EC83D1997F10FD05BBDBF9433E8F797AEE3E9F02A34228ACE927ABE62B8B9281AD08D3DF5C7379685045D7BA5FCDE58637"
                                withExponentOfPublicKey:@"03"],

                      nil];

    // TODO: figure out Terminal Application Version
    _aidsList = [[NSMutableArray alloc] initWithObjects:
                 // Mastercard
                 [[RUAApplicationIdentifier alloc]initWithRID:AID_MCRD withPIX:@"1010" withAID:nil withApplicationLabel:nil withTerminalApplicationVersion:@"3033" withLowestSupportedICCApplicationVersion:@"3031" withPriorityIndex:@"00" withApplicationSelectionFlags:@"01"],
                 [[RUAApplicationIdentifier alloc]initWithRID:AID_MCRD withPIX:@"2010" withAID:nil withApplicationLabel:nil withTerminalApplicationVersion:@"3033" withLowestSupportedICCApplicationVersion:@"3031" withPriorityIndex:@"00" withApplicationSelectionFlags:@"01"],
                 [[RUAApplicationIdentifier alloc]initWithRID:AID_MCRD withPIX:@"2203" withAID:nil withApplicationLabel:nil withTerminalApplicationVersion:@"3033" withLowestSupportedICCApplicationVersion:@"3031" withPriorityIndex:@"00" withApplicationSelectionFlags:@"01"],
                 [[RUAApplicationIdentifier alloc]initWithRID:AID_MCRD withPIX:@"3010" withAID:nil withApplicationLabel:nil withTerminalApplicationVersion:@"3033" withLowestSupportedICCApplicationVersion:@"3031" withPriorityIndex:@"00" withApplicationSelectionFlags:@"01"],
                 [[RUAApplicationIdentifier alloc]initWithRID:AID_MCRD withPIX:@"3060" withAID:nil withApplicationLabel:nil withTerminalApplicationVersion:@"3033" withLowestSupportedICCApplicationVersion:@"3031" withPriorityIndex:@"00" withApplicationSelectionFlags:@"01"],
                 [[RUAApplicationIdentifier alloc]initWithRID:AID_MCRD withPIX:@"4010" withAID:nil withApplicationLabel:nil withTerminalApplicationVersion:@"3033" withLowestSupportedICCApplicationVersion:@"3031" withPriorityIndex:@"00" withApplicationSelectionFlags:@"01"],
                 [[RUAApplicationIdentifier alloc]initWithRID:AID_MCRD withPIX:@"5010" withAID:nil withApplicationLabel:nil withTerminalApplicationVersion:@"3033" withLowestSupportedICCApplicationVersion:@"3031" withPriorityIndex:@"00" withApplicationSelectionFlags:@"01"],
                 [[RUAApplicationIdentifier alloc]initWithRID:AID_MCRD withPIX:@"6000" withAID:nil withApplicationLabel:nil withTerminalApplicationVersion:@"3033" withLowestSupportedICCApplicationVersion:@"3031" withPriorityIndex:@"00" withApplicationSelectionFlags:@"01"],
                 [[RUAApplicationIdentifier alloc]initWithRID:AID_MCRD withPIX:@"9999" withAID:nil withApplicationLabel:nil withTerminalApplicationVersion:@"3033" withLowestSupportedICCApplicationVersion:@"3031" withPriorityIndex:@"00" withApplicationSelectionFlags:@"01"],

                 // VISA
                 [[RUAApplicationIdentifier alloc]initWithRID:AID_VISA withPIX:@"1010" withAID:nil withApplicationLabel:nil withTerminalApplicationVersion:@"3033" withLowestSupportedICCApplicationVersion:@"3031" withPriorityIndex:@"00" withApplicationSelectionFlags:@"01"],
                 [[RUAApplicationIdentifier alloc]initWithRID:AID_VISA withPIX:@"2010" withAID:nil withApplicationLabel:nil withTerminalApplicationVersion:@"3033" withLowestSupportedICCApplicationVersion:@"3031" withPriorityIndex:@"00" withApplicationSelectionFlags:@"01"],
                 [[RUAApplicationIdentifier alloc]initWithRID:AID_VISA withPIX:@"2020" withAID:nil withApplicationLabel:nil withTerminalApplicationVersion:@"3033" withLowestSupportedICCApplicationVersion:@"3031" withPriorityIndex:@"00" withApplicationSelectionFlags:@"01"],
                 [[RUAApplicationIdentifier alloc]initWithRID:AID_VISA withPIX:@"8010" withAID:nil withApplicationLabel:nil withTerminalApplicationVersion:@"3033" withLowestSupportedICCApplicationVersion:@"3031" withPriorityIndex:@"00" withApplicationSelectionFlags:@"01"],
                 
                 // Discover
                 [[RUAApplicationIdentifier alloc]initWithRID:AID_DISC withPIX:@"3010" withAID:nil withApplicationLabel:nil withTerminalApplicationVersion:@"3033" withLowestSupportedICCApplicationVersion:@"3031" withPriorityIndex:@"00" withApplicationSelectionFlags:@"01"],
                 
                 // AMEX
                 [[RUAApplicationIdentifier alloc]initWithRID:AID_AMEX withPIX:@"01" withAID:nil withApplicationLabel:nil withTerminalApplicationVersion:@"0001" withLowestSupportedICCApplicationVersion:@"0001" withPriorityIndex:@"00" withApplicationSelectionFlags:@"01"],
                 
                 nil];
    
    _configHash = [self constructConfigHashWithKeysList:_publicKeyList aidsList:_aidsList];\
}

- (void) setupTACsForTesting
{
    _tacList = @{
                 AID_MCRD:@{
                            TAC_DENIAL_KEY:  @"0000000000",
                            TAC_ONLINE_KEY:  @"FE50BCF800", // Use @"FC50BCF800" if terminal does not support the “SDA selected” setting
                            TAC_DEFAULT_KEY: @"FE50BCA0800" // Use @"FC50BCA000" if terminal does not support the “SDA selected” setting
                         },
                 AID_VISA:@{
                         TAC_DENIAL_KEY:  @"0010000000",
                         TAC_ONLINE_KEY:  @"DC4004F800",
                         TAC_DEFAULT_KEY: @"DC4000A800"
                         },
                 AID_DISC:@{
                         TAC_DENIAL_KEY:  @"0010000000",
                         TAC_ONLINE_KEY:  @"30E09CF800",
                         TAC_DEFAULT_KEY: @"1000002000"
                         },
                 AID_AMEX:@{
                         TAC_DENIAL_KEY:  @"0000000000",
                         TAC_ONLINE_KEY:  @"0000000000",
                         TAC_DEFAULT_KEY: @"0000000000"
                         },
                 };
}

- (void) setupTACsForProduction
{
    _tacList = @{
                 AID_MCRD:@{
                         TAC_DENIAL_KEY:  @"0000000000",
                         TAC_ONLINE_KEY:  @"FE50BCF800", // Use @"FC50BCF800" if terminal does not support the “SDA selected” setting
                         TAC_DEFAULT_KEY: @"FE50BCA0800" // Use @"FC50BCA000" if terminal does not support the “SDA selected” setting
                         },
                 AID_VISA:@{
                         TAC_DENIAL_KEY:  @"0010000000",
                         TAC_ONLINE_KEY:  @"DC4004F800",
                         TAC_DEFAULT_KEY: @"DC4000A800"
                         },
                 AID_DISC:@{
                         TAC_DENIAL_KEY:  @"0010000000",
                         TAC_ONLINE_KEY:  @"30E09CF800",
                         TAC_DEFAULT_KEY: @"1000002000"
                         },
                 AID_AMEX:@{
                         TAC_DENIAL_KEY:  @"C800000000",
                         TAC_ONLINE_KEY:  @"C800000000",
                         TAC_DEFAULT_KEY: @"0000000000"
                         },
                 };
}


- (NSString *)md5:(NSString *) input
{
    const char *cStr = [input UTF8String];
    unsigned char digest[16];
    CC_MD5(cStr, (CC_LONG)strlen(cStr), digest ); // This is the md5 call

    NSMutableString *output = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];

    for(int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) {
        [output appendFormat:@"%02x", digest[i]];
    }
    
    return  output;
}

- (NSString *)constructConfigHashWithKeysList:(NSArray *)publicKeys aidsList:(NSArray *)aidsList
{
    NSMutableArray *keysArray = [@[] mutableCopy];
    NSMutableArray *aidsArray = [@[] mutableCopy];

    for(RUAPublicKey *key in publicKeys) {
        [keysArray addObject:@{
                               @"RID"       :key.rid                 ? key.rid                   : [NSNull null],
                               @"KeyIndex"  :key.caPublicKeyIndex    ? key.caPublicKeyIndex      : [NSNull null],
                               @"PublicKey" :key.publicKey           ? key.publicKey             : [NSNull null],
                               @"Exponent"  :key.exponentOfPublicKey ? key.exponentOfPublicKey   : [NSNull null]
                               }
         ];
    }

    for(RUAApplicationIdentifier *aid in aidsList) {
        [aidsArray addObject:@{
                               @"RID"       :aid.rid                                    ? aid.rid                                   : [NSNull null],
                               @"PIX"       :aid.pix                                    ? aid.pix                                   : [NSNull null],
                               @"AID"       :aid.aid                                    ? aid.aid                                   : [NSNull null],
                               @"AppLabel"  :aid.applicationLabel                       ? aid.applicationLabel                      : [NSNull null],
                               @"TAV"       :aid.terminalApplicationVersion             ? aid.terminalApplicationVersion            : [NSNull null],
                               @"LSIAV"     :aid.lowestSupportedICCApplicationVersion   ? aid.lowestSupportedICCApplicationVersion  : [NSNull null],
                               @"PI"        :aid.priorityIndex                          ? aid.priorityIndex                         : [NSNull null],
                               @"ASF"       :aid.applicationSelectionFlags              ? aid.applicationSelectionFlags             : [NSNull null]
                               }
         ];
    }

    NSDictionary * readerConfig = @{@"keys":keysArray, @"aids":aidsArray};

    // compute hash of the config
    NSError *error;
    NSString *json = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:readerConfig options:kNilOptions error:&error] encoding:NSUTF8StringEncoding];

    return [self md5:json];
}

/**
 *  Compares the current config hash with the stored hash for the given key.
 *
 *  @param hash      Current config hash.
 *  @param key       The key against which teh config hash is stored.
 *
 *  @return YES if hash is different or not stored, NO otherwise.
 */
- (BOOL)compareStoredConfigHash:(NSString *)currentHash forKey:(NSString *)key
{
    if (key == nil || [key length] <= 1) {
        return YES;
    }

    // fetch saved hashes
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary *configHashes = [defaults objectForKey:WEPAY_CONFIG_HASH_KEY];
    if (configHashes == nil) {
        configHashes = @{};
    }

    // extract hash for current ksn
    NSString *storedHash = [configHashes objectForKey:key];

    // determine if hashes are different
    return (storedHash == nil || ![storedHash isEqualToString:currentHash]);
}

/**
 *  Stores the current config hash for the given KSN.
 *
 *  @param hash      Current config hash.
 *  @param key       The key against which the config hash will be stored.
 */

- (void) storeConfigHash:(NSString *)currentHash forKey:(NSString *)key
{
    if (key == nil || [key length] <= 1) {
        return;
    }

    // fetch hashes
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary *configHashes = [defaults objectForKey:WEPAY_CONFIG_HASH_KEY];
    if (configHashes == nil) {
        configHashes = @{};
    }

    // update hash
    NSMutableDictionary *updatedConfig = [configHashes mutableCopy];
    [updatedConfig setValue:currentHash forKey:key];

    [defaults setObject:updatedConfig forKey:WEPAY_CONFIG_HASH_KEY];
    [defaults synchronize];
}

- (void)setupAIDSandPublicKeys {

    [processor clearAIDSList];
}

- (void) clearAIDSList
{
    //inform external about reader config
    [self.delegate informExternalCardReader:kWPCardReaderStatusConfiguringReader];

    id <RUAConfigurationManager> cmgr = [self.roamDeviceManager getConfigurationManager];
    [cmgr clearAIDSList:NULL
               response: ^(RUAResponse *ruaResponse) {
                   NSLog(@"[debug] %@", [WPRoamHelper RUAResponse_toString:ruaResponse]);
                   [processor clearPublicKeys];
               }];
}

- (void)clearPublicKeys {
    id <RUAConfigurationManager> cmgr = [self.roamDeviceManager getConfigurationManager];
    [cmgr clearPublicKeys:NULL
                 response: ^(RUAResponse *ruaResponse) {
                     NSLog(@"[debug] %@", [WPRoamHelper RUAResponse_toString:ruaResponse]);
                     [processor submitAIDs];
                 }];
}

- (void)submitAIDs {
    id <RUAConfigurationManager> cmgr = [self.roamDeviceManager getConfigurationManager];
    [cmgr submitAIDList:_aidsList
               progress:^(RUAProgressMessage messageType, NSString* additionalMessage) {
                   NSLog(@"[debug] %s", __FUNCTION__);
               }
               response: ^(RUAResponse *ruaResponse) {
                   NSLog(@"[debug] %@", [WPRoamHelper RUAResponse_toString:ruaResponse]);
                   [processor submitPublicKeys];
               }];
}

- (void)submitPublicKeys {
    id <RUAConfigurationManager> cmgr = [self.roamDeviceManager getConfigurationManager];

    if ([_publicKeyList count] > _currentPublicKeyIndex) {
        RUAPublicKey *pubKey = (RUAPublicKey *)[_publicKeyList objectAtIndex:_currentPublicKeyIndex++];

        [cmgr submitPublicKey:pubKey
                     progress:^(RUAProgressMessage messageType, NSString* additionalMessage) {
                         NSLog(@"[debug] %s", __FUNCTION__);
                     }
                     response: ^(RUAResponse *ruaResponse) {
                         NSLog(@"[debug] %@", [WPRoamHelper RUAResponse_toString:ruaResponse]);
                         if (_currentPublicKeyIndex < [_publicKeyList count]) {
                             [processor submitPublicKeys];
                         }
                         else {
                             [processor storeConfigHash:_configHash forKey:self.deviceSerialNumber];
                             self.readerSetupCompleted = YES;
                             [processor setupExpectedDOLs];
                         }
                     }];
    } else {
        [processor storeConfigHash:_configHash forKey:self.deviceSerialNumber];
        self.readerSetupCompleted = YES;
        [processor setupExpectedDOLs];
    }
}



#pragma mark ReaderStatusHandler

- (void)onConnected
{
    NSLog(@"onConnected");
    // TODO: no magic strings
    [self.delegate connectedDevice:@"rp350x"];

    // TODO: this callback is being called twice, investigate why.
    if (!self.swiperIsConnected) {
        [processor fetchDeviceSerialNumber];

        // Cancel any scheduled calls for swiper not connected
        [NSObject cancelPreviousPerformRequestsWithTarget:self.delegate
                                                 selector:@selector(informExternalCardReader:)
                                                   object:kWPCardReaderStatusNotConnected];
    }
}

- (void)onDisconnected
{
    NSLog(@"onDisconnected");
    [self.delegate disconnectedDevice];

    // Inform external delegate if we should wait for swipe, and the swiper was previously connected
    if (self.swiperShouldWaitForSwipe && self.swiperIsConnected) {
        //TODO: should only inform once
        [self.delegate informExternalCardReader:kWPCardReaderStatusNotConnected];
        // self.swiperIsConnected = NO;

        //TODO: trying here
        [self stopWaitingForCard];
    }

    self.swiperIsConnected = NO;

    self.readerSetupCompleted = NO;
    // [self stopWaitingForCard];
}

- (void)onError:(NSString *)message
{
    // gets called when wrong reader type is connected

    NSLog(@"onError");
    self.swiperIsConnected = NO;
    self.readerSetupCompleted = NO;

    // Stop waiting for card
    // TODO: should be silent
//    [self stopDevice];

    // inform delegate
    [self.delegate handleDeviceStatusError:message];
}


@end

#endif
#endif