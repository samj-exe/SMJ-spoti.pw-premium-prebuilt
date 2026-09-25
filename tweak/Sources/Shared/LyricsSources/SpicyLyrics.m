// Spicy Lyrics, the source behind the Spicetify extension of the same name (spicylyrics.org). Like
// Musixmatch it is asked by Spotify's own track id rather than by name, so it never answers with a
// live cut of the song by mistake; unlike Musixmatch, what it has is Apple Music's syllable timing,
// down to the backing vocals and the two sides of a duet.
//
// Two things about it are like nothing else here. It answers no one who cannot show they are a
// signed-in Spotify client, so the request carries the same Authorization header Spotify's own
// requests carry — the account's own access token. That is more than any other source is told, which
// is why the Lyrics page says so plainly and why this source, like the rest, is off until you turn it
// on. And it answers in a packed shape rather than plain JSON: every distinct value in the document
// once, then a stream of opcodes rebuilding it. unpack() below puts it back together.
#import "Core/SGCore.h"
#import "LyricsSources.h"
#import "Shared/Lyrics/Lyrics.h"

static NSString *const kAPI = @"https://api.spicylyrics.org/query";
// The header the token rides in. The request names it in the query's variables as well, which is how
// the server is told which of the headers it accepts this caller is using.
static NSString *const kAuthHeader = @"SpicyLyrics-WebAuth";
// The extension release this file was written against. The server reads it to tell old clients from
// new, so it moves when the shapes read below do.
static NSString *const kClientVersion = @"6.3.20";
// Only one query goes out per ask, and the reply names its answers by the index they came in at.
static NSString *const kOperationID = @"0";

#pragma mark - the packed shape

// A reply is [values, stream]: every distinct string, number, boolean and null in the document, and
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

// The API answers a browser. The extension runs inside Spotify's desktop client, which is Chromium,
// and the server reads the identity Chromium puts on every request by itself — none of which a
// native URLSession sends. Without it the reply is the plain-text tier rather than Apple Music's
// syllables, which is why hundreds of tracks came back Type=Static.
//
// Spicy Lyrics' author was asked directly (2026-09-20) and allowed the mod to present itself this
// way, on the one condition that it stays open source, which spoti.pw is. He said he would not add a
// client of his own for us, and that this is the way, as EeveeSpotify already does it.
static NSDictionary<NSString *, NSString *> *desktopClient(void) {
    return @{
        @"Origin": @"https://xpui.app.spotify.com",
        @"Referer": @"https://xpui.app.spotify.com/",
        @"User-Agent": @"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) "
                        "Chrome/146.0.7680.179 Spotify/1.2.92.148 Safari/537.36",
        @"sec-ch-ua": @"\"Not-A.Brand\";v=\"24\", \"Chromium\";v=\"146\"",
        @"sec-ch-ua-mobile": @"?0",
        @"sec-ch-ua-platform": @"\"Windows\"",
        @"sec-fetch-site": @"cross-site",
        @"sec-fetch-mode": @"cors",
        @"sec-fetch-dest": @"empty",
        @"Accept": @"*/*",
        @"Accept-Language": @"en-Latn-US,en-US;q=0.9,en-Latn;q=0.8,en;q=0.7",
        @"priority": @"u=1, i",
        // Accept-Encoding is deliberately left to NSURLSession, which asks for what it can actually
        // decode. Claiming br and zstd as the browser does risks a body nothing here can read.
    };
}

SGLyricsAsk SGSpicyLyricsAsk = ^(SGLyricsQuery *query, void (^done)(SGLyricsResult *result)) {
    NSString *authorization = SGKaraokeSpotifyAuthorization();
    if (!query.trackID.length || !authorization.length) {
        SGLog(@"spicy: nothing to ask with for %@%@", query.trackID,
              authorization.length ? @"" : @", no request of Spotify's own seen yet to borrow the token from");
        done(nil);
        return;
    }
    NSDictionary *body = @{
        @"queries": @[@{@"operation": @"lyrics", @"variables": @{@"id": query.trackID, @"auth": kAuthHeader}}],
        @"client": @{@"version": kClientVersion},
    };
    NSURL *url = [NSURL URLWithString:kAPI];
    NSMutableDictionary<NSString *, NSString *> *headers = [desktopClient() mutableCopy];
    headers[@"X-mode"] = @"2";   // answer in the packed shape unpack() reads
    headers[@"SpicyLyrics-Version"] = kClientVersion;
    headers[kAuthHeader] = authorization;   // already a "Bearer ..." of Spotify's own making
    SGLyricsPostJSON(url, headers, body, ^(id root) {
        NSDictionary *job = nil;
        for (id raw in arrayIn(dictionaryIn(root)[@"queries"]) ?: @[]) {
            if ([dictionaryIn(raw)[@"operationId"] isEqual:kOperationID]) {
                job = raw;
                break;
            }
        }
        NSDictionary *answer = dictionaryIn(job[@"result"]);
        NSInteger status = [answer[@"httpStatus"] integerValue];
        if (!answer) {
            SGLog(@"spicy: no answer to the query for %@", query.trackID);
            done(nil);
            return;
        }
        // The query's own status rides inside an envelope that is a 200 either way, so the walk is
        // told here about a server too busy to answer: a 503 means the lyrics are being prepared and
        // a later ask will have them, which must not stick to the track as "this one has none".
        if (status == 429 || status >= 500) {
            SGLyricsNoteReply([[NSHTTPURLResponse alloc] initWithURL:url statusCode:status HTTPVersion:nil headerFields:nil], nil);
        }
        if (status != 200) {
            SGLog(@"spicy: %@ answered %ld", query.trackID, (long)status);
            done(nil);
            return;
        }
        NSDictionary *document = dictionaryIn(unpack(answer[@"data"]));
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
