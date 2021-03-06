//
//  WPError+internal.h
//  WePay
//
//  Created by Chaitanya Bagaria on 12/23/14.
//  Copyright (c) 2014 WePay. All rights reserved.
//

#import "WPError.h"


@interface WPError : NSError

@end


@interface WPError (internal)

/**
 *  Converts API Call Error into an NSError object.
 *
 *  @param data WePay API json response.
 *
 *  @return NSError object representing the error.
 */

+ (NSError *) errorWithApiResponseData:(NSDictionary *)data;

/**
 *  Converts card reader Error data into an NSError object.
 *
 *  @param data card reader response.
 *
 *  @return NSError object representing the error.
 */
+ (NSError *) errorWithCardReaderResponseData:(NSDictionary *)data;

/**
 *  Creates an NSError object representing card reader initialization failure.
 *
 *  @return NSError object representing the error.
 */
+ (NSError *) errorInitializingCardReader;

/**
 *  Creates an NSError object representing card reader timeout.
 *
 *  @return NSError object representing the error.
 */
+ (NSError *) errorForCardReaderTimeout;

/**
 *  Creates an NSError object representing card reader status = error
 *
 *  @param message Error message from card reader.
 *
 *  @return NSError object representing the error.
 */
+ (NSError *) errorForCardReaderStatusErrorWithMessage:(NSString *)message;

/**
 *  Creates an NSError object representing invalid signature image error.
 *
 *  @return object representing the error.
 */
+ (NSError *) errorInvalidSignatureImage;

/**
 *  Creates an NSError object representing name not found error.
 *
 *  @return object representing the error.
 */
+ (NSError *) errorNameNotFound;

/**
 *  Creates an NSError object representing invalid card data error.
 *
 *  @return object representing the error.
 */
+ (NSError *) errorInvalidCardData;

/**
 *  Creates an NSError object representing card not supported error.
 *
 *  @return object representing the error.
 */
+ (NSError *) errorCardNotSupported;

/**
 *  Creates an NSError object representing a generic EMV transaction error
 *
 *  @param message Error message from card reader.
 *
 *  @return NSError object representing the error.
 */
+ (NSError *) errorForEMVTransactionErrorWithMessage:(NSString *)message;

/**
 *  Creates an NSError object representing invalid application id error.
 *
 *  @return object representing the error.
 */
+ (NSError *) errorInvalidApplicationId;

/**
 *  Creates an NSError object representing declined by card error.
 *
 *  @return object representing the error.
 */
+ (NSError *) errorDeclinedByCard;

/**
 *  Creates an NSError object representing card blocked error.
 *
 *  @return object representing the error.
 */
+ (NSError *) errorCardBlocked;

/**
 *  Creates an NSError object representing declined by issuer error.
 *
 *  @return object representing the error.
 */
+ (NSError *) errorDeclinedByIssuer;

/**
 *  Creates an NSError object representing issuer unreachable error.
 *
 *  @return object representing the error.
 */
+ (NSError *) errorIssuerUnreachable;

/**
 *  Creates an NSError object representing invalid auth info error.
 *
 *  @return object representing the error.
 */
+ (NSError *) errorInvalidAuthInfo;

/**
 *  Creates an NSError object representing auth info not provided error.
 *
 *  @return object representing the error.
 */
+ (NSError *) errorAuthInfoNotProvided;

@end
