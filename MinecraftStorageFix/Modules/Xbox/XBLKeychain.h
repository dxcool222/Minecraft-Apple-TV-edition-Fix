#pragma once

#import <Foundation/Foundation.h>

typedef id (*XBL_DictionaryForQuery_t)(id self, SEL _cmd, id key);
extern XBL_DictionaryForQuery_t gXBLKeychainStorage_orig_dictForQuery;

id        mcfix_xbl_replacement_dictForKeychainQuery(id self, SEL _cmd, id key);
NSString *mcfix_msaAppID_replacement(id self, SEL _cmd);
