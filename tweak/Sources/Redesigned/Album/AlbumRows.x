// Album redesign: the track rows on the field, the way the Music app has them -- no surface of their own
// and a hairline from the text's edge between one row and the next.
//
// Tree (trees/clean/album/03.txt:524-575): every row of the page is an Element_List.CollectionViewCell
// holding an Encore.ListRow, id=Components.UI.RetrievalRowElementUI, with the title
// (EncoreConsumerMobile.View.Granular.Title), the artists under it (…Granular.Subtitle) and, at the
// trailing edge, Components.UI.ContextMenuButton. An album row carries no artwork -- every track on the
// page shares the cover the header is already showing -- so the hairline runs from the page's own margin,
// where the text starts.
//
// The row's paint is cleared here rather than left to the Kit's repaint hook, which only hears about a
// colour when Spotify sets it and not when a reused cell already carries one.
//
// Spotify's type is left alone: a row with metadata is 56pt for a title of 13pt, and a larger font of
// the Kit's would be cut off by the box the element framework measured for it. Rows without metadata close up.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Album.h"

// Under the text rather than the whole row, as the Music app draws it; the trailing end clears the page
// margin.
static const CGFloat kHairline = 0.5, kCompactTrackRowHeight = 44;

static char kRowKey, kSubtitleKey, kLineKey, kAlbumHeaderKey, kAlbumParentKey, kAlbumArtistsKey;
static char kOriginalSubtitleKey, kAppliedSubtitleKey;
static char kExplicitStateKey;

static NSString *normalizedArtist(NSString *artist) {
    NSString *trimmed = [artist stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return [[trimmed lowercaseString] stringByFoldingWithOptions:NSDiacriticInsensitiveSearch locale:NSLocale.currentLocale];
}

static void addArtistNames(NSString *text, NSMutableSet<NSString *> *names) {
    for (NSString *part in [text componentsSeparatedByString:@","]) {
        NSString *name = normalizedArtist(part);
        if (name.length) [names addObject:name];
    }
}

static NSSet<NSString *> *albumArtists(UIView *page) {
    NSSet<NSString *> *cached = objc_getAssociatedObject(page, &kAlbumArtistsKey);
    if (cached) return cached;
    UIView *header = SGRFindByIdentifier(page, @"CreativeWorkPlatform.Components.UI.CreativeWorkHeader", &kAlbumHeaderKey);
    UIView *parent = SGRFindByIdentifier(header, @"CreativeWorkPlatform.Components.UI.ParentRow", &kAlbumParentKey);
    NSMutableSet<NSString *> *names = [NSMutableSet set];
    SGForEachView(parent, ^(UIView *view) {
        if ([view isKindOfClass:UILabel.class]) addArtistNames(((UILabel *)view).text, names);
    });
    addArtistNames(parent.accessibilityLabel, names);
    if (names.count) {
        cached = [names copy];
        objc_setAssociatedObject(page, &kAlbumArtistsKey, cached, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return cached;
    }
    return names;
}

static void applyArtistFilter(UILabel *label, NSSet<NSString *> *albumArtistNames, BOOL hideAll) {
    NSString *current = label.text ?: @"";
    NSString *original = objc_getAssociatedObject(label, &kOriginalSubtitleKey);
    NSString *applied = objc_getAssociatedObject(label, &kAppliedSubtitleKey);
    if (!original || ![current isEqualToString:applied]) original = current;

    NSMutableArray<NSString *> *visible = [NSMutableArray array];
    if (!hideAll) {
        for (NSString *part in [original componentsSeparatedByString:@","]) {
            NSString *trimmed = [part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (trimmed.length && ![albumArtistNames containsObject:normalizedArtist(trimmed)]) [visible addObject:trimmed];
        }
    }
    NSString *filtered = [visible componentsJoinedByString:@", "];
    if (![filtered isEqualToString:current]) label.text = filtered;
    if (![filtered isEqualToString:original]) {
        objc_setAssociatedObject(label, &kOriginalSubtitleKey, original, OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(label, &kAppliedSubtitleKey, filtered, OBJC_ASSOCIATION_COPY_NONATOMIC);
    } else {
        objc_setAssociatedObject(label, &kOriginalSubtitleKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(label, &kAppliedSubtitleKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
}

static BOOL explicitMarker(UIView *view) {
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithObject:NSStringFromClass(view.class) ?: @""];
    if (view.accessibilityIdentifier.length) [parts addObject:view.accessibilityIdentifier];
    if (view.accessibilityLabel.length) [parts addObject:view.accessibilityLabel];
    NSString *identity = [[parts componentsJoinedByString:@" "] lowercaseString];
    return [identity containsString:@"explicit"] || [identity containsString:@"contentrating"] || [identity containsString:@"content-rating"];
}

static void applyExplicitTagFilter(UIView *row, BOOL hide) {
    SGForEachView(row, ^(UIView *view) {
        if (!explicitMarker(view)) return;
        NSArray<NSNumber *> *original = objc_getAssociatedObject(view, &kExplicitStateKey);
        if (hide) {
            if (!original) {
                original = @[@(view.alpha), @(view.userInteractionEnabled), @(view.accessibilityElementsHidden)];
                objc_setAssociatedObject(view, &kExplicitStateKey, original, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            view.alpha = 0;
            view.userInteractionEnabled = NO;
            view.accessibilityElementsHidden = YES;
        } else if (original) {
            view.alpha = original[0].doubleValue;
            view.userInteractionEnabled = original[1].boolValue;
            view.accessibilityElementsHidden = original[2].boolValue;
            objc_setAssociatedObject(view, &kExplicitStateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    });
}

static BOOL hasVisibleTrackMetadata(UIView *row, UIView *page) {
    applyExplicitTagFilter(row, SGHidden(SGRKeyHideExplicitAlbumTags));

    UIView *subtitle = SGRFindByIdentifier(row, @"EncoreConsumerMobile.View.Granular.Subtitle", &kSubtitleKey);
    BOOL hideAll = SGHidden(SGRKeyHideAllAlbumArtists);
    NSSet<NSString *> *artistsToHide = SGHidden(SGRKeyHideAlbumArtists) ? albumArtists(page) : [NSSet set];
    __block BOOL hasMetadata = NO;
    SGForEachView(subtitle, ^(UIView *view) {
        if (![view isKindOfClass:UILabel.class]) return;
        UILabel *label = (UILabel *)view;
        applyArtistFilter(label, artistsToHide, hideAll);
        hasMetadata = hasMetadata || label.text.length > 0;
    });
    if (hasMetadata) return YES;

    SGForEachView(row, ^(UIView *view) {
        if (explicitMarker(view) && !view.hidden && view.alpha > 0.01) hasMetadata = YES;
    });
    return hasMetadata;
}

static void clearSurface(UIView *view) {
    UIColor *color = view.backgroundColor;
    if (color && SGIsBaseSurface(color.CGColor)) view.backgroundColor = UIColor.clearColor;
}

static void applyHairline(UIView *row) {
    CALayer *line = objc_getAssociatedObject(row, &kLineKey);
    if (!line) {
        line = [CALayer layer];
        line.zPosition = 1;
        objc_setAssociatedObject(row, &kLineKey, line, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    line.backgroundColor = SGRHairline().CGColor;
    if (line.superlayer != row.layer) [row.layer addSublayer:line];
    CGRect bounds = row.bounds;
    CGRect frame = CGRectMake(SGRSideMargin, bounds.size.height - kHairline,
                              MAX(0, bounds.size.width - 2 * SGRSideMargin), kHairline);
    if (CGRectEqualToRect(line.frame, frame)) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    line.frame = frame;
    [CATransaction commit];
}

static void applyRow(UIView *cell, UIView *page) {
    clearSurface(cell);
    UIView *row = SGRFindByIdentifier(cell, @"Components.UI.RetrievalRow*", &kRowKey);
    if (!row) return;
    // The first track with its title in is the list the page waits for (Kit/SGRReveal.h); a row still loading
    // draws grey bars with empty labels.
    if (SGRRevealWaitsFor(page, SGRRevealList) && SGRRevealShowsText(row)) SGRRevealMark(page, SGRRevealList);
    // The row, and every box the element framework wraps it in on the way back up to the cell.
    for (UIView *v = row; v; v = v.superview) {
        clearSurface(v);
        if (v == cell) break;
    }
    applyExplicitTagFilter(row, SGHidden(SGRKeyHideExplicitAlbumTags));

    UIView *subtitle = SGRFindByIdentifier(row, @"EncoreConsumerMobile.View.Granular.Subtitle", &kSubtitleKey);
    BOOL hideAll = SGHidden(SGRKeyHideAllAlbumArtists);
    NSSet<NSString *> *artistsToHide = SGHidden(SGRKeyHideAlbumArtists) ? albumArtists(page) : [NSSet set];
    SGForEachView(subtitle, ^(UIView *v) {
        if (![v isKindOfClass:UILabel.class]) return;
        UILabel *label = (UILabel *)v;
        applyArtistFilter(label, artistsToHide, hideAll);
        if (![label.textColor isEqual:SGRSecondary()]) label.textColor = SGRSecondary();
    });

    applyHairline(row);
}

// Which cells of Element_List belong to an album's track list, answered once per content class: the same
// cell class carries Home's sections and the album's footer too, and a walk up to the page on every pass of
// every cell is what the answer is cached to avoid.
static BOOL isTrackContent(UIView *content) {
    static NSMutableDictionary<id, NSNumber *> *answers;
    if (!answers) answers = [NSMutableDictionary dictionary];
    Class cls = object_getClass(content);
    if (!cls) return NO;
    NSNumber *answer = answers[(id<NSCopying>)cls];
    if (!answer) {
        answer = @([NSStringFromClass(cls) containsString:@"RetrievalListStructuredData"]);
        answers[(id<NSCopying>)cls] = answer;
    }
    return answer.boolValue;
}

%hook _TtC12Element_List18CollectionViewCell
- (UICollectionViewLayoutAttributes *)preferredLayoutAttributesFittingAttributes:(UICollectionViewLayoutAttributes *)attributes {
    UICollectionViewCell *cell = (UICollectionViewCell *)self;
    UIView *content = cell.contentView.subviews.firstObject;
    if (!isTrackContent(content)) return %orig;

    UICollectionViewLayoutAttributes *result = %orig;
    UIView *page = SGRAlbumPageOf(cell);
    UIView *row = SGRFindByIdentifier(cell, @"Components.UI.RetrievalRow*", &kRowKey);
    if (page && row && !hasVisibleTrackMetadata(row, page)) {
        result.size = CGSizeMake(result.size.width, MIN(result.size.height, kCompactTrackRowHeight));
    }
    return result;
}

- (void)layoutSubviews {
    %orig;
    UICollectionViewCell *cell = (UICollectionViewCell *)self;
    if (!isTrackContent(cell.contentView.subviews.firstObject)) return;
    UIView *page = SGRAlbumPageOf(cell);
    if (page) applyRow(cell, page);
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    SGRequireClasses(@[@"_TtC12Element_List18CollectionViewCell"]);
}
