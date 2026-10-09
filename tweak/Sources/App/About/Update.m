// GitHub Releases for Taurus. The settings page checks quietly when it opens and caches the result.
#import "Core/SGCore.h"
#import "About.h"

static NSString *const kGitHubURL = @"https://api.github.com/repos/samj-exe/taurus/releases?per_page=20";
NSString *const SGUpdateCheckedNotification = @"spotifyglass.update.checked.notification";

static NSString *const kLatestRelease = @"spotifyglass.update.taurus.latest";

static BOOL sg_running;

@implementation SGUpdateRelease
@end

// "0.14.1" against "0.15": the numbers position by position, a missing one counting zero.
static BOOL isNewer(NSString *candidate, NSString *current) {
    NSArray<NSString *> *left = [candidate componentsSeparatedByString:@"."];
    NSArray<NSString *> *right = [current componentsSeparatedByString:@"."];
    for (NSUInteger i = 0; i < MAX(left.count, right.count); i++) {
        NSInteger a = i < left.count ? left[i].integerValue : 0;
        NSInteger b = i < right.count ? right[i].integerValue : 0;
        if (a != b) return a > b;
    }
    return NO;
}

static NSString *stringOr(id value, NSString *fallback) {
    return [value isKindOfClass:NSString.class] ? value : fallback;
}

#pragma mark - latest release

SGUpdateRelease *SGUpdateNewestRelease(void) {
    NSDictionary *stored = [NSUserDefaults.standardUserDefaults dictionaryForKey:kLatestRelease];
    NSString *version = stringOr(stored[@"version"], nil);
    if (!version.length) return nil;
    SGUpdateRelease *release = [SGUpdateRelease new];
    release.version = version;
    release.url = stringOr(stored[@"url"], nil);
    return release;
}

NSString *SGUpdateVersion(void) {
    NSString *version = SGUpdateNewestRelease().version;
    return version.length && isNewer(version, @(SG_VERSION)) ? version : nil;
}

#pragma mark - the check

// Ignore drafts and pre-releases; compare stable tags rather than trusting API ordering.
static NSDictionary *latestReleaseFrom(NSData *data) {
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    if (![json isKindOfClass:NSArray.class]) return nil;
    NSDictionary *latest = nil;
    for (id item in (NSArray *)json) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *release = item;
        if ([release[@"draft"] boolValue] || [release[@"prerelease"] boolValue]) continue;
        NSString *tag = stringOr(release[@"tag_name"], nil);
        if (!tag.length) continue;
        NSString *version = [tag hasPrefix:@"v"] ? [tag substringFromIndex:1] : tag;
        if (!latest || isNewer(version, latest[@"version"])) {
            latest = @{@"version": version, @"url": stringOr(release[@"html_url"], @"")};
        }
    }
    return latest ?: @{};
}

static void ask(NSString *url, void (^done)(NSDictionary *release, NSInteger status, NSError *error)) {
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.timeoutIntervalForRequest = 10;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:10];
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    NSURLSessionDataTask *task = [[NSURLSession sessionWithConfiguration:configuration]
        dataTaskWithRequest:request
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
                done(status == 200 ? latestReleaseFrom(data) : nil, status, error);
    }];
    [task resume];
}

void SGCheckForUpdate(void) {
    if (sg_running) return;
    NSUserDefaults *store = NSUserDefaults.standardUserDefaults;

    sg_running = YES;
    void (^finish)(NSDictionary *, NSInteger, NSError *) = ^(NSDictionary *release, NSInteger status, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            sg_running = NO;
            if (!release) {
                // Unauthenticated GitHub allows sixty requests an hour per address; a phone behind a
                // carrier NAT can be told to wait, and that is worth reading apart from a dead network.
                SGLog(@"update check failed: HTTP %ld, %@", (long)status,
                      error.localizedDescription ?: @"no release in the reply");
            } else {
                [store setObject:release forKey:kLatestRelease];
                SGLog(@"update check: the newest is %@, this build is %s", release[@"version"] ?: @"none", SG_VERSION);
            }
            [NSNotificationCenter.defaultCenter postNotificationName:SGUpdateCheckedNotification object:nil];
        });
    };
    SGLog(@"update check: asking Taurus GitHub Releases");
    ask(kGitHubURL, finish);
}
