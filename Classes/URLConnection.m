#import "PreferencesController.h"
#import "URLConnection.h"

@implementation URLConnection

static void URLConnectionStreamCallback(CFReadStreamRef aStream,
                                        CFStreamEventType eventType,
                                        void* _conn) {
  UInt8 buf[1024];
  int len, release = 0;
  URLConnection* conn = (__bridge URLConnection*) _conn;

  switch (eventType) {
    case kCFStreamEventHasBytesAvailable:
      while ((len = CFReadStreamRead(aStream, buf, sizeof(buf))) > 0) {
        [conn->bytes appendBytes:buf length:len];
      }
      break;
    case kCFStreamEventErrorOccurred:
      conn->cb(nil, (__bridge_transfer NSError*) CFReadStreamCopyError(aStream));
      release = 1;
      break;
    case kCFStreamEventEndEncountered: {
      conn->cb(conn->bytes, nil);
      release = 1;
      break;
    }
    default:
      assert(0);
  }

  if (release) {
    /* Transfer ownership to us so we release it eventually */
    //conn = (__bridge_transfer URLConnection*) _conn;
  }
}

- (void) dealloc {
  if (stream != nil) {
    CFReadStreamClose(stream);
    CFRelease(stream);
  }
}

/**
 * @brief Creates a new instance for the specified request
 *
 * @param request the request to be sent
 * @param cb the callback to invoke when the request is done. If an error
 *        happened, then the data will be nil, and the error will be valid.
 *        Otherwise the data will be valid and the error will be nil.
 */
+ (URLConnection*) connectionForRequest:(NSURLRequest*)request
                      completionHandler:(void(^)(NSData*, NSError*)) cb {

  URLConnection *c = [[URLConnection alloc] init];

  /* Create the HTTP message to send */
  CFHTTPMessageRef message =
      CFHTTPMessageCreateRequest(NULL,
                                 (__bridge CFStringRef)[request HTTPMethod],
                                 (__bridge CFURLRef)   [request URL],
                                 kCFHTTPVersion1_1);

  /* Copy headers over */
  NSDictionary *headers = [request allHTTPHeaderFields];
  for (NSString *header in headers) {
    CFHTTPMessageSetHeaderFieldValue(message,
                         (__bridge CFStringRef) header,
                         (__bridge CFStringRef) [headers objectForKey:header]);
  }

  /* Also the http body */
  if ([request HTTPBody] != nil) {
    CFHTTPMessageSetBody(message, (__bridge CFDataRef) [request HTTPBody]);
  }
  c->stream = CFReadStreamCreateForHTTPRequest(NULL, message);
  CFRelease(message);

  /* Handle SSL connections */
  if ([[[request URL] absoluteString] rangeOfString:@"https"].location != NSNotFound) {
    NSDictionary *settings =
    [NSDictionary dictionaryWithObjectsAndKeys:
     (NSString *)kCFStreamSocketSecurityLevelNegotiatedSSL, kCFStreamSSLLevel,
     [NSNumber numberWithBool:NO], kCFStreamSSLAllowsExpiredCertificates,
     [NSNumber numberWithBool:NO], kCFStreamSSLAllowsExpiredRoots,
     [NSNumber numberWithBool:NO], kCFStreamSSLAllowsAnyRoot,
     [NSNumber numberWithBool:YES], kCFStreamSSLValidatesCertificateChain,
     [NSNull null], kCFStreamSSLPeerName,
     nil];

    CFReadStreamSetProperty(c->stream, kCFStreamPropertySSLSettings,
                            (__bridge CFDictionaryRef) settings);
  }

  c->cb = [cb copy];
  c->bytes = [NSMutableData dataWithCapacity:100];
  [c setHermesProxy];
  return c;
}

/**
 * @brief Start sending this request to the server
 */
- (void) start {
  if (!CFReadStreamOpen(stream)) {
    assert(0);
  }
  CFStreamClientContext context = {0, (__bridge_retained void*) self, NULL,
                                   NULL, NULL};
  CFReadStreamSetClient(stream,
                        kCFStreamEventHasBytesAvailable |
                          kCFStreamEventErrorOccurred |
                          kCFStreamEventEndEncountered,
                        URLConnectionStreamCallback,
                        &context);
  CFReadStreamScheduleWithRunLoop(stream, CFRunLoopGetCurrent(),
                                  kCFRunLoopCommonModes);
}

- (void) setHermesProxy {
  [URLConnection setHermesProxy:stream];
}

/**
 * @brief Helper for setting whatever proxy is specified in the Hermes
 *        preferences
 */
+ (void) setHermesProxy:(CFReadStreamRef) stream {
  switch ([[NSUserDefaults standardUserDefaults] integerForKey:ENABLED_PROXY]) {
    case PROXY_HTTP:
      [self setHTTPProxy:stream
                     host:PREF_KEY_VALUE(PROXY_HTTP_HOST)
                     port:[PREF_KEY_VALUE(PROXY_HTTP_PORT) intValue]];
      break;

    case PROXY_SOCKS:
      [self setSOCKSProxy:stream
                     host:PREF_KEY_VALUE(PROXY_SOCKS_HOST)
                     port:[PREF_KEY_VALUE(PROXY_SOCKS_PORT) intValue]];
      break;

    case PROXY_SYSTEM:
    default:
      [self setSystemProxy:stream];
      break;
  }
}

+ (void) setHTTPProxy:(CFReadStreamRef)stream
                 host:(NSString*)host
                 port:(NSInteger)port {
  NSLogd(@"HTTP proxy => %@:%ld", host, port);
  CFDictionaryRef proxySettings = (__bridge CFDictionaryRef)
    [NSMutableDictionary dictionaryWithObjectsAndKeys:
      host, kCFStreamPropertyHTTPProxyHost,
      [NSNumber numberWithInt:port], kCFStreamPropertyHTTPProxyPort,
      nil];
  CFReadStreamSetProperty(stream, kCFStreamPropertyHTTPProxy, proxySettings);
}

+ (void) setSOCKSProxy:(CFReadStreamRef)stream
                 host:(NSString*)host
                 port:(NSInteger)port {
  NSLogd(@"SOCKS proxy => %@:%ld", host, port);
  CFDictionaryRef proxySettings = (__bridge CFDictionaryRef)
    [NSMutableDictionary dictionaryWithObjectsAndKeys:
      host, kCFStreamPropertySOCKSProxyHost,
      [NSNumber numberWithInt:port], kCFStreamPropertySOCKSProxyPort,
      nil];
  CFReadStreamSetProperty(stream, kCFStreamPropertySOCKSProxy, proxySettings);
}

+ (void) setSystemProxy:(CFReadStreamRef)stream {
  CFDictionaryRef proxySettings = CFNetworkCopySystemProxySettings();
  CFReadStreamSetProperty(stream, kCFStreamPropertyHTTPProxy, proxySettings);
  CFRelease(proxySettings);
}

@end