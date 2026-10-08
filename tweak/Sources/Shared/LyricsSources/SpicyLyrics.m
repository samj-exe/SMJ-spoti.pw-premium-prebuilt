// Spicy Lyrics, the source behind the Spicetify extension of the same name (spicylyrics.org). Like
// Musixmatch it is asked by Spotify's own track id rather than by name, so it never answers with a
// live cut of the song by mistake; unlike Musixmatch, what it has is Apple Music's syllable timing,
// down to the backing vocals and the two sides of a duet.
//
// Its Developer Platform API returns the best sync from its catalogue and names the provider it
// chose. The user supplies a publishable client key; it is kept in Keychain, never in preferences.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "LyricsSources.h"
#import "Shared/Lyrics/Lyrics.h"
#import <Security/Security.h>

static NSString *const kAPI = @"https://api.spicylyrics.org/v1/lyrics";
static NSString *const kKeychainService = @"pw.spoti.spotifyglass.spicylyrics";
static NSString *const kKeychainAccount = @"publishable-client-key";

NSString *SGSpicyLyricsAPIKey(void) {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kKeychainService,
        (__bridge id)kSecAttrAccount: kKeychainAccount,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
    };
    CFTypeRef result = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) != errSecSuccess || !result) return nil;
    NSData *data = CFBridgingRelease(result);
    NSString *key = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return [key hasPrefix:@"sl_pk_"] ? key : nil;
}

static BOOL storeSpicyLyricsAPIKey(NSString *key) {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kKeychainService,
        (__bridge id)kSecAttrAccount: kKeychainAccount,
    };
    SecItemDelete((__bridge CFDictionaryRef)query);
    if (!key.length) return YES;
    NSMutableDictionary *item = [query mutableCopy];
    item[(__bridge id)kSecValueData] = [key dataUsingEncoding:NSUTF8StringEncoding];
    item[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    return SecItemAdd((__bridge CFDictionaryRef)item, NULL) == errSecSuccess;
}

static void spicyKeyNotice(NSString *title, NSString *message) {
    UIAlertController *notice = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [notice addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [SGTopController() presentViewController:notice animated:YES completion:nil];
}

SGModRow *SGSpicyLyricsAPIKeyRow(void) {
    return SGStatActionRow(@"Spicy Lyrics API key", @"Use a publishable sl_pk_ key; enable native no-Origin access", ^NSString *{
        return SGSpicyLyricsAPIKey().length ? @"Set" : @"Not set";
    }, ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Spicy Lyrics API key"
            message:@"Create a publishable client key in the Spicy Lyrics Developer Platform and enable its native-client no-Origin access. Do not use a secret sl_sk_ key in a distributed app."
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
            field.placeholder = @"sl_pk_…";
            field.secureTextEntry = YES;
            field.text = SGSpicyLyricsAPIKey();
            field.autocorrectionType = UITextAutocorrectionTypeNo;
            field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        }];
        [alert addAction:[UIAlertAction actionWithTitle:@"Remove key" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            storeSpicyLyricsAPIKey(nil);
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            NSString *key = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (![key hasPrefix:@"sl_pk_"] || key.length <= 6) {
                spicyKeyNotice(@"Invalid client key", @"Enter a publishable Spicy Lyrics key beginning with sl_pk_.");
                return;
            }
            if (!storeSpicyLyricsAPIKey(key)) spicyKeyNotice(@"Could not save key", @"Keychain rejected the Spicy Lyrics key.");
        }]];
        [SGTopController() presentViewController:alert animated:YES completion:nil];
    });
}

#pragma mark - the packed shape

// Legacy packed replies use [values, stream]: every distinct string, number, boolean and null in the document, and
// a stream of integers rebuilding it. A number at or above zero is an index into the values; below
// zero it opens a structure. Straight from the extension's own packer, which is the only writer of
// this shape there is.
typedef NS_ENUM(NSInteger, SGSpicyOp) {
    SGSpicyOpObject = -1,        // key count, that many key indexes, then that many values
    SGSpicyOpArray = -2,         // item count, then that many values
    SGSpicyOpRows = -3,          // item count, key count, the keys once, then the rows' values
    SGSpicyOpEmptyArray = -4,
    SGSpicyOpOneItemArray = -5,  // the one value
    SGSpicyOpEmptyObject = -6,
};

// Deep enough for any lyrics document and shallow enough that a malformed reply cannot run the
// stack out: the shape below nests six levels, not sixty.
static const NSUInteger kMaxDepth = 64;

@interface SGSpicyReader : NSObject {
@public
    NSArray *values, *stream;
    NSUInteger cursor;
    BOOL bad;   // the reply did not hold together; whatever has been read of it is thrown away
}
@end

@implementation SGSpicyReader
@end

static NSInteger nextNumber(SGSpicyReader *reader) {
    if (reader->cursor >= reader->stream.count) {
        reader->bad = YES;
        return 0;
    }
    id number = reader->stream[reader->cursor++];
    if (![number isKindOfClass:NSNumber.class]) {
        reader->bad = YES;
        return 0;
    }
    return [number integerValue];
}

static id valueAt(SGSpicyReader *reader, NSInteger index) {
    if (index < 0 || (NSUInteger)index >= reader->values.count) {
        reader->bad = YES;
        return nil;
    }
    return reader->values[index];
}

static NSString *nextKey(SGSpicyReader *reader) {
    id key = valueAt(reader, nextNumber(reader));
    if (![key isKindOfClass:NSString.class]) {
        reader->bad = YES;
        return nil;
    }
    return key;
}

static id decode(SGSpicyReader *reader, NSUInteger depth) {
    if (reader->bad || depth > kMaxDepth) {
        reader->bad = YES;
        return nil;
    }
    NSInteger op = nextNumber(reader);
    if (reader->bad) return nil;
    if (op >= 0) return valueAt(reader, op);
    // A count is read before anything is built with it, so a reply claiming a million keys cannot
    // have a million slots reserved for it before the stream is found to be shorter than that.
    NSInteger count = op == SGSpicyOpObject || op == SGSpicyOpArray || op == SGSpicyOpRows ? nextNumber(reader) : 0;
    if (reader->bad || count < 0 || (NSUInteger)count > reader->stream.count) {
        reader->bad = YES;
        return nil;
    }
    switch (op) {
        case SGSpicyOpObject: {
            NSMutableArray<NSString *> *keys = [NSMutableArray arrayWithCapacity:count];
            for (NSInteger i = 0; i < count; i++) {
                NSString *key = nextKey(reader);
                if (reader->bad) return nil;
                [keys addObject:key];
            }
            NSMutableDictionary *object = [NSMutableDictionary dictionaryWithCapacity:count];
            for (NSInteger i = 0; i < count; i++) {
                id value = decode(reader, depth + 1);
                if (reader->bad) return nil;
                object[keys[i]] = value;
            }
            return object;
        }
        case SGSpicyOpArray: {
            NSMutableArray *items = [NSMutableArray arrayWithCapacity:count];
            for (NSInteger i = 0; i < count; i++) {
                id item = decode(reader, depth + 1);
                if (reader->bad) return nil;
                [items addObject:item];
            }
            return items;
        }
        // A run of objects sharing their keys — every line of a song — with the keys written once.
        case SGSpicyOpRows: {
            NSInteger keyCount = nextNumber(reader);
            if (reader->bad || keyCount < 0 || (NSUInteger)keyCount > reader->stream.count) {
                reader->bad = YES;
                return nil;
            }
            NSMutableArray<NSString *> *keys = [NSMutableArray arrayWithCapacity:keyCount];
            for (NSInteger i = 0; i < keyCount; i++) {
                NSString *key = nextKey(reader);
                if (reader->bad) return nil;
                [keys addObject:key];
            }
            NSMutableArray *rows = [NSMutableArray arrayWithCapacity:count];
            for (NSInteger i = 0; i < count; i++) {
                NSMutableDictionary *row = [NSMutableDictionary dictionaryWithCapacity:keyCount];
                for (NSInteger k = 0; k < keyCount; k++) {
                    id value = decode(reader, depth + 1);
                    if (reader->bad) return nil;
                    row[keys[k]] = value;
                }
                [rows addObject:row];
            }
            return rows;
        }
        case SGSpicyOpEmptyArray: return @[];
        case SGSpicyOpOneItemArray: {
            id only = decode(reader, depth + 1);
            return reader->bad ? nil : @[only];
        }
        case SGSpicyOpEmptyObject: return @{};
    }
    reader->bad = YES;
    return nil;
}

static id unpack(id packed) {
    // Should the server ever answer a caller of ours with the document itself, it is already what
    // the rest of this file wants.
    if ([packed isKindOfClass:NSDictionary.class]) return packed;
    if (![packed isKindOfClass:NSArray.class] || [packed count] != 2) return nil;
    id values = packed[0], stream = packed[1];
    if (![values isKindOfClass:NSArray.class] || ![stream isKindOfClass:NSArray.class]) return nil;
    SGSpicyReader *reader = [SGSpicyReader new];
    reader->values = values;
    reader->stream = stream;
    id document = decode(reader, 0);
    // Anything left in the stream means it was not the document it claimed to be.
    if (reader->bad || reader->cursor != reader->stream.count) {
        SGLog(@"spicy: the packed reply did not hold together, %lu of %lu read",
              (unsigned long)reader->cursor, (unsigned long)reader->stream.count);
        return nil;
    }
    return document;
}

#pragma mark - the document as lines

// The API times in seconds, the mod in milliseconds.
static NSInteger msIn(id seconds) {
    return [seconds isKindOfClass:NSNumber.class] ? (NSInteger)llround([seconds doubleValue] * 1000.0) : 0;
}

static NSDictionary *dictionaryIn(id value) {
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static NSArray *arrayIn(id value) {
    return [value isKindOfClass:NSArray.class] ? value : nil;
}

// One voice's syllables as words. A syllable is a piece of a word — the API marks the ones that run
// into the next with IsPartOfWord, which is the same thing the mod calls a word being joined to the
// one before it, read from the other end.
static NSArray<SGKaraokeWord *> *wordsFrom(NSArray *syllables) {
    NSMutableArray<SGKaraokeWord *> *words = [NSMutableArray array];
    BOOL joinToPrevious = NO;
    for (id raw in syllables ?: @[]) {
        NSDictionary *syllable = dictionaryIn(raw);
        if (!syllable) continue;
        BOOL runsOn = [syllable[@"IsPartOfWord"] boolValue];
        id text = syllable[@"Text"];
        NSString *said = [text isKindOfClass:NSString.class]
            ? [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] : nil;
        if (said.length) {
            SGKaraokeWord *word = [SGKaraokeWord new];
            word.text = said;
            word.start = msIn(syllable[@"StartTime"]);
            word.end = msIn(syllable[@"EndTime"]);
            word.joined = joinToPrevious && words.count > 0;
            [words addObject:word];
        }
        joinToPrevious = runsOn;
    }
    return words;
}

static SGKaraokeLine *lineFrom(NSArray<SGKaraokeWord *> *words, id start, id end) {
    if (!words.count) return nil;
    SGKaraokeLine *line = [SGKaraokeLine new];
    line.words = words;
    // The line's own times where it has them; the words it is made of where it does not.
    line.start = start ? msIn(start) : words.firstObject.start;
    line.end = end ? msIn(end) : words.lastObject.end;
    return line;
}

// Content: [ { Type: "Vocal", OppositeAligned, Lead: { StartTime, EndTime, Syllables }, Background } ]
static NSArray<SGKaraokeLine *> *linesFromSyllables(NSArray *content) {
    NSMutableArray<SGKaraokeLine *> *lines = [NSMutableArray array];
    for (id raw in content ?: @[]) {
        NSDictionary *vocal = dictionaryIn(raw);
        NSDictionary *lead = dictionaryIn(vocal[@"Lead"]);
        if (!lead) continue;
        SGKaraokeLine *line = lineFrom(wordsFrom(arrayIn(lead[@"Syllables"])), lead[@"StartTime"], lead[@"EndTime"]);
        if (!line) continue;
        // The (oh, aye) sung under the line. The API keeps it in groups, one per run of it; the page
        // has one backing line under each line, so the runs read on as one.
        NSMutableArray<SGKaraokeWord *> *backing = [NSMutableArray array];
        for (id rawGroup in arrayIn(vocal[@"Background"]) ?: @[]) {
            NSDictionary *group = dictionaryIn(rawGroup);
            if (group) [backing addObjectsFromArray:wordsFrom(arrayIn(group[@"Syllables"]))];
        }
        line.backing = lineFrom(backing, nil, nil);
        // The far side of a duet. The API says outright which lines belong to the second voice, so
        // unlike TTML there are no voices here to work an alignment out from.
        if ([vocal[@"OppositeAligned"] boolValue] || [lead[@"OppositeAligned"] boolValue]) {
            line.align = SGKaraokeAlignTrailing;
        }
        [lines addObject:line];
    }
    return lines.count ? lines : nil;
}

// Content: [ { Type: "Vocal", Text, StartTime, EndTime } ] — timed by the line, the words inside it
// left to the mod's own estimate, as Spotify's own lines and LRCLIB's are.
static NSArray<SGKaraokeLine *> *linesFromLines(NSArray *content) {
    NSMutableArray<NSNumber *> *starts = [NSMutableArray array];
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    for (id raw in content ?: @[]) {
        NSDictionary *vocal = dictionaryIn(raw);
        id text = vocal[@"Text"];
        if (![text isKindOfClass:NSString.class]) continue;
        [starts addObject:@(msIn(vocal[@"StartTime"]))];
        [texts addObject:text];
    }
    return SGKaraokeEstimatedLines(starts, texts);
}

// What the server actually sent, named rather than quoted: the field names and counts, never the
// words. For telling a document that has no timing from one whose timing we failed to read.
static NSString *shapeOf(NSDictionary *document) {
    NSMutableString *shape = [NSMutableString stringWithFormat:@"Type=%@ keys=[%@]",
                              document[@"Type"], [document.allKeys componentsJoinedByString:@" "]];
    NSArray *content = arrayIn(document[@"Content"]);
    if (content) [shape appendFormat:@" Content=%lu", (unsigned long)content.count];
    NSDictionary *first = dictionaryIn(content.firstObject);
    if (first) [shape appendFormat:@" Content[0]=[%@]", [first.allKeys componentsJoinedByString:@" "]];
    NSDictionary *lead = dictionaryIn(first[@"Lead"]);
    if (lead) [shape appendFormat:@" Lead=[%@] syllables=%lu", [lead.allKeys componentsJoinedByString:@" "],
               (unsigned long)arrayIn(lead[@"Syllables"]).count];
    NSDictionary *syllable = dictionaryIn(arrayIn(lead[@"Syllables"]).firstObject);
    if (syllable) [shape appendFormat:@" Syllable[0]=[%@]", [syllable.allKeys componentsJoinedByString:@" "]];
    NSArray *staticLines = arrayIn(document[@"Lines"]);
    if (staticLines) [shape appendFormat:@" Lines=%lu", (unsigned long)staticLines.count];
    // Whose words these are, where the document says so: a static reply is text Spicy is passing on
    // from somewhere else, and its name tells us why it came without timing.
    if (document[@"source"]) [shape appendFormat:@" source=%@", document[@"source"]];
    NSDictionary *staticLine = dictionaryIn(staticLines.firstObject);
    if (staticLine) [shape appendFormat:@" Lines[0]=[%@]", [staticLine.allKeys componentsJoinedByString:@" "]];
    return shape;
}

#pragma mark - the source

// Uses the official Developer Platform API and a user-supplied publishable key. Secret keys never
// ship in this client; the API's native-client no-Origin option must be enabled for the key.
SGLyricsAsk SGSpicyLyricsAsk = ^(SGLyricsQuery *query, void (^done)(SGLyricsResult *result)) {
    NSString *key = SGSpicyLyricsAPIKey();
    if (!query.trackID.length || !key.length) {
        SGLog(@"spicy: no request for %@%@", query.trackID, key.length ? @"" : @", client key not configured");
        done(nil);
        return;
    }
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/%@", kAPI, query.trackID]];
    NSDictionary *headers = @{@"Authorization": [@"Bearer " stringByAppendingString:key], @"Accept": @"application/json"};
    SGLyricsGetJSON(url, headers, ^(id root) {
        NSDictionary *envelope = dictionaryIn(root);
        NSInteger status = [envelope[@"Status"] integerValue];
        if (status && status != 200) {
            SGLog(@"spicy: %@ API status %ld", query.trackID, (long)status);
            done(nil);
            return;
        }
        NSDictionary *document = dictionaryIn(unpack(envelope[@"Body"] ?: envelope));
        if (!document) {
            SGLog(@"spicy: %@ returned no document", query.trackID);
            done(nil);
            return;
        }
        SGLog(@"spicy: %@ came back as %@", query.trackID, shapeOf(document));
        NSString *type = [document[@"Type"] isKindOfClass:NSString.class] ? document[@"Type"] : nil;
        NSArray *content = arrayIn(document[@"Content"]);
        BOOL wordTimed = [type isEqualToString:@"Syllable"];
        NSArray<SGKaraokeLine *> *lines = wordTimed ? linesFromSyllables(content)
            : [type isEqualToString:@"Line"] ? linesFromLines(content) : nil;
        SGLyricsResult *result = [SGLyricsResult new];
        if (lines) {
            result.synced = YES;
            result.wordTimed = wordTimed;
            result.karaokeLines = lines;
            NSArray<NSNumber *> *starts;
            NSArray<NSString *> *texts;
            SGLyricsPageLines(lines, &starts, &texts);
            result.starts = starts;
            result.texts = texts;
        } else if ([type isEqualToString:@"Static"]) {
            // The words with nothing to time them by: the page shows them, and a source under this
            // one in the order can still time them.
            NSMutableArray<NSNumber *> *starts = [NSMutableArray array];
            NSMutableArray<NSString *> *texts = [NSMutableArray array];
            for (id raw in arrayIn(document[@"Lines"]) ?: @[]) {
                id text = dictionaryIn(raw)[@"Text"];
                if (![text isKindOfClass:NSString.class]) continue;
                [starts addObject:@0];
                [texts addObject:[text length] ? text : @"♪"];
            }
            result.starts = starts;
            result.texts = texts;
            result.karaokeLines = SGKaraokeStaticLines(texts);
        }
        NSString *source = [document[@"source"] isKindOfClass:NSString.class] ? document[@"source"] : nil;
        NSDictionary<NSString *, NSString *> *sourceNames = @{
            @"spicy_lyrics": @"Spicy Lyrics",
            @"apple_music": @"Apple Music",
            @"spotify": @"Spotify",
        };
        result.provider = sourceNames[source] ?: @"Spicy Lyrics";
        if (!result.texts.count) {
            SGLog(@"spicy: %@ came back as %@ with nothing the page could show", query.trackID, type ?: @"no shape at all");
            done(nil);
            return;
        }
        SGLog(@"spicy: %@ has %lu %@ lines", query.trackID, (unsigned long)result.texts.count,
              result.wordTimed ? @"word timed" : result.synced ? @"line timed" : @"untimed");
        done(result);
    });
};
