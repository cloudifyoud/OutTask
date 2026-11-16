#import "DecoratedAppSceneViewController.h"
#import "ResizeHandleView.h"
#import "LiveContainerSwiftUI-Swift.h"
#import "AppSceneViewController.h"
#import "UIKitPrivate+MultitaskSupport.h"
#import "PiPManager.h"
#import "VirtualWindowsHostView.h"
#import "../LiveContainer/Localization.h"
#import "utils.h"

static const CGFloat kMacTitleBarHeight = 38.0;
static const CGFloat kTrafficLightSize = 12.0;
static const CGFloat kTrafficLightSpacing = 8.0;
static const CGSize kMinMacWindowSize = {260.0, 200.0};

@interface DecoratedAppSceneViewController ()
@property(nonatomic) NSArray<NSLayoutConstraint *> *activatedVerticalConstraints;
@property(nonatomic) NSString *dataUUID;
@property(nonatomic) int pid;
@property(nonatomic) CGRect originalFrame;
@property(nonatomic) UIBarButtonItem *maximizeButton;
@property(nonatomic) UIButton *closeTrafficBtn;
@property(nonatomic) UIButton *minimizeTrafficBtn;
@property(nonatomic) UIButton *zoomTrafficBtn;
@property(nonatomic) UIView *macTitleBar;
@property(nonatomic) UILabel *macTitleLabel;
@property(nonatomic) BOOL isAppTerminationRequested;
@property(nonatomic) BOOL isObservingBottomWindowBar;
@property(nonatomic) CFTimeInterval lastSceneResizeTime;
@property(nonatomic) NSMutableDictionary<NSString *, id> *fflagsDictionary;
@property(nonatomic) NSString *selectedFFlagPreset;
@end

@implementation DecoratedAppSceneViewController

#pragma mark - Lifecycle & Setup

- (void)dealloc {
    if (_isObservingBottomWindowBar) {
        [NSUserDefaults.lcSharedDefaults removeObserver:self forKeyPath:@"LCMultitaskBottomWindowBar"];
        _isObservingBottomWindowBar = NO;
    }
}

- (instancetype)initWindowName:(NSString *)windowName bundleId:(NSString *)bundleId dataUUID:(NSString *)dataUUID rootVC:(UIViewController *)rootVC {
    self = [super initWithNibName:nil bundle:nil];
    if (!self) return nil;

    self.view = [[UIStackView alloc] initWithFrame:CGRectZero];
    [MultitaskDockManager.shared.windowHostingView addSubview:self.view];
    [rootVC addChildViewController:self];

    _dataUUID = [dataUUID copy];
    _scaleRatio = 1.0;
    _isMaximized = [NSUserDefaults.lcUserDefaults boolForKey:@"LCLaunchMultitaskMaximized"];
    _appSceneVC = [[AppSceneViewController alloc] initWithBundleId:bundleId dataUUID:dataUUID delegate:self];
    self.title = windowName;

    [self loadFFlagsForCurrentApp];
    [self setupDecoratedView];
    [self setupMenusAndGestures];

    [MultitaskDockManager.shared addRunningApp:windowName appUUID:dataUUID view:self.view];
    return self;
}

- (UIButton *)makeTrafficButtonWithColor:(UIColor *)color symbolName:(NSString *)symbol action:(SEL)action {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    btn.backgroundColor = color;
    btn.layer.cornerRadius = kTrafficLightSize / 2.0;
    btn.layer.masksToBounds = YES;
    btn.layer.borderWidth = 0.5;
    btn.layer.borderColor = [UIColor colorWithWhite:0.0 alpha:0.18].CGColor;

    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:7.0 weight:UIImageSymbolWeightBold];
    UIImage *img = [[UIImage systemImageNamed:symbol] imageWithConfiguration:cfg];
    [btn setImage:img forState:UIControlStateNormal];
    btn.tintColor = [UIColor colorWithWhite:0.0 alpha:0.65];
    [btn addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];

    [NSLayoutConstraint activateConstraints:@[
        [btn.widthAnchor constraintEqualToConstant:kTrafficLightSize],
        [btn.heightAnchor constraintEqualToConstant:kTrafficLightSize]
    ]];
    return btn;
}

- (void)rebuildTrafficLightsOnLeadingEdge:(BOOL)leading {
    [self.closeTrafficBtn removeFromSuperview];
    [self.minimizeTrafficBtn removeFromSuperview];
    [self.zoomTrafficBtn removeFromSuperview];

    self.closeTrafficBtn = [self makeTrafficButtonWithColor:[UIColor systemRedColor] symbolName:@"xmark" action:@selector(closeWindow)];
    self.minimizeTrafficBtn = [self makeTrafficButtonWithColor:[UIColor systemYellowColor] symbolName:@"minus" action:@selector(minimizeWindow)];
    self.zoomTrafficBtn = [self makeTrafficButtonWithColor:[UIColor systemGreenColor]
                                                 symbolName:_isMaximized ? @"arrow.down.right.and.arrow.up.left" : @"plus"
                                                     action:@selector(maximizeWindow)];

    UIStackView *cluster = [[UIStackView alloc] initWithArrangedSubviews:@[self.closeTrafficBtn, self.minimizeTrafficBtn, self.zoomTrafficBtn]];
    cluster.axis = UILayoutConstraintAxisHorizontal;
    cluster.spacing = kTrafficLightSpacing;
    cluster.alignment = UIStackViewAlignmentCenter;
    cluster.translatesAutoresizingMaskIntoConstraints = NO;

    [self.macTitleBar addSubview:cluster];
    [NSLayoutConstraint activateConstraints:@[
        [cluster.centerYAnchor constraintEqualToAnchor:self.macTitleBar.centerYAnchor],
        leading ? [cluster.leadingAnchor constraintEqualToAnchor:self.macTitleBar.leadingAnchor constant:14.0]
                : [cluster.trailingAnchor constraintEqualToAnchor:self.macTitleBar.trailingAnchor constant:-14.0]
    ]];
}

- (void)setupDecoratedView {
    BOOL isLandscape = UIInterfaceOrientationIsLandscape(UIApp.statusBarOrientation);
    CGRect frame = CGRectMake(0, 0, isLandscape ? 520.0 : 340.0, (isLandscape ? 340.0 : 520.0) + kMacTitleBarHeight);
    CGPoint parentCenter = self.view.superview ? self.view.superview.center : CGPointMake(200.0, 400.0);
    frame.origin = CGPointMake(parentCenter.x - frame.size.width / 2.0, parentCenter.y - frame.size.height / 2.0);

    if (_isMaximized && self.view.window) {
        CGRect maxFrame = UIEdgeInsetsInsetRect(self.view.window.frame, self.view.window.safeAreaInsets);
        frame.origin.x /= MAX(1.0, maxFrame.size.width);
        frame.origin.y /= MAX(1.0, maxFrame.size.height);
        self.originalFrame = frame;
    } else {
        self.view.frame = frame;
    }

    UIView *titleBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, kMacTitleBarHeight)];
    titleBar.backgroundColor = [[UIColor secondarySystemBackgroundColor] colorWithAlphaComponent:0.94];
    titleBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = self.title;
    titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    titleLabel.textColor = UIColor.labelColor;
    titleLabel.textAlignment = NSTextAlignmentCenter;
    titleLabel.userInteractionEnabled = YES;
    [titleBar addSubview:titleLabel];

    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.centerXAnchor constraintEqualToAnchor:titleBar.centerXAnchor],
        [titleLabel.centerYAnchor constraintEqualToAnchor:titleBar.centerYAnchor],
        [titleLabel.widthAnchor constraintLessThanOrEqualToAnchor:titleBar.widthAnchor multiplier:0.55]
    ]];

    self.macTitleBar = titleBar;
    self.macTitleLabel = titleLabel;

    BOOL bottomBar = [NSUserDefaults.lcSharedDefaults boolForKey:@"LCMultitaskBottomWindowBar"];
    [self rebuildTrafficLightsOnLeadingEdge:bottomBar];

    UIView *hairline = [[UIView alloc] init];
    hairline.translatesAutoresizingMaskIntoConstraints = NO;
    hairline.backgroundColor = [UIColor separatorColor];
    [titleBar addSubview:hairline];
    [NSLayoutConstraint activateConstraints:@[
        [hairline.leadingAnchor constraintEqualToAnchor:titleBar.leadingAnchor],
        [hairline.trailingAnchor constraintEqualToAnchor:titleBar.trailingAnchor],
        [hairline.heightAnchor constraintEqualToConstant:0.5],
        bottomBar ? [hairline.topAnchor constraintEqualToAnchor:titleBar.topAnchor]
                  : [hairline.bottomAnchor constraintEqualToAnchor:titleBar.bottomAnchor]
    ]];

    self.view.axis = UILayoutConstraintAxisVertical;
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.view.layer.cornerRadius = _isMaximized ? 0.0 : 12.0;
    self.view.layer.masksToBounds = YES;
    self.view.layer.borderWidth = _isMaximized ? 0.0 : 1.0;
    self.view.layer.borderColor = [UIColor colorWithWhite:0.5 alpha:0.25].CGColor;
    [self.view addArrangedSubview:titleBar];

    self.resizeHandle = [[ResizeHandleView alloc] initWithFrame:CGRectMake(self.view.bounds.size.width - 28.0,
                                                                          self.view.bounds.size.height - 28.0,
                                                                          28.0, 28.0)];
    self.resizeHandle.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
    self.resizeHandle.alpha = _isMaximized ? 0.0 : 1.0;
    [self.view addSubview:self.resizeHandle];

    [self addChildViewController:_appSceneVC];
    [self.view insertSubview:_appSceneVC.view atIndex:0];
    _appSceneVC.view.translatesAutoresizingMaskIntoConstraints = NO;

    [self updateVerticalConstraintsAnimated:NO];
    [NSLayoutConstraint activateConstraints:@[
        [_appSceneVC.view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_appSceneVC.view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]
    ]];

    if (!_isObservingBottomWindowBar) {
        [NSUserDefaults.lcSharedDefaults addObserver:self forKeyPath:@"LCMultitaskBottomWindowBar" options:NSKeyValueObservingOptionNew context:NULL];
        _isObservingBottomWindowBar = YES;
    }
    [self updateOriginalFrame];
}

- (void)setupMenusAndGestures {
    UIPanGestureRecognizer *moveGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(moveWindow:)];
    moveGesture.minimumNumberOfTouches = 1;
    moveGesture.maximumNumberOfTouches = 1;
    [self.macTitleBar addGestureRecognizer:moveGesture];

    UITapGestureRecognizer *doubleTapZoom = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(maximizeWindow)];
    doubleTapZoom.numberOfTapsRequired = 2;
    [self.macTitleBar addGestureRecognizer:doubleTapZoom];

    UILongPressGestureRecognizer *longPressTitle = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(presentQuickActionsSheet:)];
    [self.macTitleLabel addGestureRecognizer:longPressTitle];

    UIPanGestureRecognizer *resizeGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(resizeWindow:)];
    resizeGesture.minimumNumberOfTouches = 1;
    resizeGesture.maximumNumberOfTouches = 1;
    [self.resizeHandle addGestureRecognizer:resizeGesture];

    __weak typeof(self) weakSelf = self;
    NSArray<UIMenuElement *> *menuItems = @[
        [UIAction actionWithTitle:@"lc.multitask.copyPid".loc image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(UIAction * _Nonnull action) {
            UIPasteboard.generalPasteboard.string = @(weakSelf.appSceneVC.pid).stringValue;
        }],
        [UIAction actionWithTitle:@"Roblox FFlags & Presets" image:[UIImage systemImageNamed:@"slider.horizontal.3"] identifier:nil handler:^(UIAction * _Nonnull action) {
            [weakSelf presentFFlagsManager];
        }],
        [UIAction actionWithTitle:@"lc.multitask.enablePip".loc image:[UIImage systemImageNamed:@"pip.enter"] identifier:nil handler:^(UIAction * _Nonnull action) {
            if ([PiPManager.shared isPiPWithVC:weakSelf.appSceneVC]) {
                [PiPManager.shared stopPiP];
            } else {
                [PiPManager.shared startPiPWithVC:weakSelf.appSceneVC];
            }
        }],
        [UICustomViewMenuElement elementWithViewProvider:^UIView *(UICustomViewMenuElement *element) {
            return [weakSelf scaleSliderViewWithTitle:@"lc.multitask.scale".loc min:0.5 max:2.0 value:weakSelf.scaleRatio stepInterval:0.01];
        }]
    ];

    [self.navigationItem setTitleMenuProvider:^UIMenu *(NSArray<UIMenuElement *> *suggestedActions) {
        if (!weakSelf.appSceneVC.isAppRunning) {
            return [UIMenu menuWithTitle:NSLocalizedString(@"lc.multitaskAppWindow.appTerminated", nil) children:@[]];
        }
        return [UIMenu menuWithTitle:[NSString stringWithFormat:@"PID: %d", weakSelf.pid] children:menuItems];
    }];
}

- (void)presentQuickActionsSheet:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    __weak typeof(self) weakSelf = self;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:self.title
                                                                 message:[NSString stringWithFormat:@"PID: %d • Scale: %.2fx • FFlags: %lu",
                                                                          self.pid, self.scaleRatio, (unsigned long)self.fflagsDictionary.count]
                                                          preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Roblox FFlags & Presets" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [weakSelf presentFFlagsManager];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Copy PID" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        UIPasteboard.generalPasteboard.string = @(weakSelf.pid).stringValue;
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Toggle PiP" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        if ([PiPManager.shared isPiPWithVC:weakSelf.appSceneVC]) {
            [PiPManager.shared stopPiP];
        } else {
            [PiPManager.shared startPiPWithVC:weakSelf.appSceneVC];
        }
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = self.macTitleLabel;
        sheet.popoverPresentationController.sourceRect = self.macTitleLabel.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - Roblox FFlags Presets & Exporter

- (NSURL *)fflagsJSONFileURL {
    NSArray<NSURL *> *docs = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask];
    NSURL *baseDir = docs.firstObject ?: [NSURL fileURLWithPath:NSTemporaryDirectory()];
    NSString *folderName = self.dataUUID.length > 0 ? self.dataUUID : @"DefaultApp";
    NSURL *settingsDir = [[baseDir URLByAppendingPathComponent:@"Data"]
                                    URLByAppendingPathComponent:folderName];
    settingsDir = [settingsDir URLByAppendingPathComponent:@"ClientSettings" isDirectory:YES];
    return [settingsDir URLByAppendingPathComponent:@"ClientAppSettings.json"];
}

- (NSDictionary<NSString *, id> *)presetDictionaryForName:(NSString *)presetName {
    if ([presetName isEqualToString:@"Smooth FPS"]) {
        return @{
            @"FFlagDisablePostFx": @YES,
            @"FFlagDisableBloom": @YES,
            @"FFlagRenderOptimizedShadows": @YES,
            @"FFlagEnableReducedLatency": @YES,
            @"DFIntTaskSchedulerTargetFps": @120
        };
    } else if ([presetName isEqualToString:@"Ultra Low-End"]) {
        return @{
            @"FFlagDisablePostFx": @YES,
            @"FFlagDisableBloom": @YES,
            @"FFlagDisableGlobalShadows": @YES,
            @"FFlagFastGPULightCulling3": @YES,
            @"FFlagEnableReducedLatency": @YES,
            @"DFIntTaskSchedulerTargetFps": @120,
            @"DFIntGCJobFrequencyMs": @250
        };
    } else if ([presetName isEqualToString:@"Network Smooth"]) {
        return @{
            @"DFIntConnectionMTUSize": @1400,
            @"DFIntRakNetResendBufferArrayLength": @128,
            @"FFlagEnableReducedLatency": @YES
        };
    }
    return @{};
}

- (void)loadFFlagsForCurrentApp {
    self.fflagsDictionary = [NSMutableDictionary dictionary];
    self.selectedFFlagPreset = @"Stock";

    NSURL *url = [self fflagsJSONFileURL];
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (data.length > 0) {
        NSError *err = nil;
        NSDictionary *loaded = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
        if ([loaded isKindOfClass:[NSDictionary class]]) {
            [self.fflagsDictionary addEntriesFromDictionary:loaded];
            self.selectedFFlagPreset = @"Custom";
        }
    }
}

- (void)persistFFlagsToDiskWithCompletion:(void (^)(NSString *statusText))completion {
    NSURL *fileURL = [self fflagsJSONFileURL];
    NSURL *dirURL = [fileURL URLByDeletingLastPathComponent];
    NSError *err = nil;
    [[NSFileManager defaultManager] createDirectoryAtURL:dirURL withIntermediateDirectories:YES attributes:nil error:&err];
    if (err) {
        if (completion) completion([NSString stringWithFormat:@"Folder error: %@", err.localizedDescription]);
        return;
    }

    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:self.fflagsDictionary options:NSJSONSerializationWritingPrettyPrinted | NSJSONSerializationWritingSortedKeys error:&err];
    if (err || !jsonData) {
        if (completion) completion([NSString stringWithFormat:@"JSON error: %@", err.localizedDescription]);
        return;
    }

    if ([jsonData writeToURL:fileURL options:NSDataWritingAtomic error:&err]) {
        if (completion) completion([NSString stringWithFormat:@"Saved %lu flags to %@", (unsigned long)self.fflagsDictionary.count, fileURL.path]);
    } else {
        if (completion) completion([NSString stringWithFormat:@"Write failed: %@", err.localizedDescription]);
    }
}

- (void)presentFFlagsManager {
    __weak typeof(self) weakSelf = self;
    NSString *msg = [NSString stringWithFormat:@"Preset: %@ • Active Flags: %lu\nSaved to: %@",
                     self.selectedFFlagPreset, (unsigned long)self.fflagsDictionary.count, [self fflagsJSONFileURL].lastPathComponent];

    UIAlertController *mgr = [UIAlertController alertControllerWithTitle:@"Roblox FFlags & Presets" message:msg preferredStyle:UIAlertControllerStyleActionSheet];

    NSArray<NSString *> *presets = @[@"Stock", @"Smooth FPS", @"Ultra Low-End", @"Network Smooth"];
    for (NSString *p in presets) {
        [mgr addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Preset: %@", p] style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            weakSelf.selectedFFlagPreset = p;
            weakSelf.fflagsDictionary = [[weakSelf presetDictionaryForName:p] mutableCopy];
            [weakSelf persistFFlagsToDiskWithCompletion:^(NSString *statusText) {
                [weakSelf showToastAlertWithTitle:@"FFlags Updated" message:statusText];
            }];
        }]];
    }

    [mgr addAction:[UIAlertAction actionWithTitle:@"Add / Edit Custom FFlag..." style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [weakSelf presentAddCustomFFlagDialog];
    }]];

    [mgr addAction:[UIAlertAction actionWithTitle:@"View / Clear Active FFlags" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *summary = weakSelf.fflagsDictionary.count > 0 ? weakSelf.fflagsDictionary.description : @"(Empty — Stock defaults)";
        UIAlertController *listAlert = [UIAlertController alertControllerWithTitle:@"Active FFlags" message:summary preferredStyle:UIAlertControllerStyleAlert];
        [listAlert addAction:[UIAlertAction actionWithTitle:@"Clear All" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
            [weakSelf.fflagsDictionary removeAllObjects];
            weakSelf.selectedFFlagPreset = @"Stock";
            [weakSelf persistFFlagsToDiskWithCompletion:nil];
        }]];
        [listAlert addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:nil]];
        [weakSelf presentViewController:listAlert animated:YES completion:nil];
    }]];

    [mgr addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    if (mgr.popoverPresentationController) {
        mgr.popoverPresentationController.sourceView = self.macTitleLabel;
        mgr.popoverPresentationController.sourceRect = self.macTitleLabel.bounds;
    }
    [self presentViewController:mgr animated:YES completion:nil];
}

- (void)presentAddCustomFFlagDialog {
    __weak typeof(self) weakSelf = self;
    UIAlertController *dialog = [UIAlertController alertControllerWithTitle:@"Add Custom FFlag"
                                                                  message:@"Enter flag name and value (true/false, number, or text)."
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [dialog addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull tf) {
        tf.placeholder = @"FFlagDisableGlobalShadows";
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [dialog addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull tf) {
        tf.placeholder = @"true / 120 / value";
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];

    [dialog addAction:[UIAlertAction actionWithTitle:@"Save Flag" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *key = [dialog.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *raw = [dialog.textFields.lastObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (key.length == 0 || raw.length == 0) return;

        id parsedValue = raw;
        NSString *lower = raw.lowercaseString;
        NSNumberFormatter *fmt = [[NSNumberFormatter alloc] init];
        fmt.numberStyle = NSNumberFormatterDecimalStyle;
        NSNumber *num = [fmt numberFromString:raw];

        if ([lower isEqualToString:@"true"]) {
            parsedValue = @YES;
        } else if ([lower isEqualToString:@"false"]) {
            parsedValue = @NO;
        } else if (num != nil) {
            parsedValue = num;
        }

        weakSelf.fflagsDictionary[key] = parsedValue;
        weakSelf.selectedFFlagPreset = @"Custom";
        [weakSelf persistFFlagsToDiskWithCompletion:^(NSString *statusText) {
            [weakSelf showToastAlertWithTitle:@"Flag Saved" message:statusText];
        }];
    }]];
    [dialog addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:dialog animated:YES completion:nil];
}

- (void)showToastAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Scale Slider & Window Controls

- (UIView *)scaleSliderViewWithTitle:(NSString *)title min:(CGFloat)minValue max:(CGFloat)maxValue value:(CGFloat)initialValue stepInterval:(CGFloat)step {
    UIView *containerView = [[UIView alloc] init];
    containerView.translatesAutoresizingMaskIntoConstraints = NO;
    containerView.exclusiveTouch = YES;

    UIStackView *stackView = [[UIStackView alloc] init];
    stackView.axis = UILayoutConstraintAxisVertical;
    stackView.spacing = 0.0;
    stackView.translatesAutoresizingMaskIntoConstraints = NO;
    [containerView addSubview:stackView];

    [NSLayoutConstraint activateConstraints:@[
        [stackView.topAnchor constraintEqualToAnchor:containerView.topAnchor constant:10.0],
        [stackView.bottomAnchor constraintEqualToAnchor:containerView.bottomAnchor constant:-8.0],
        [stackView.leadingAnchor constraintEqualToAnchor:containerView.leadingAnchor constant:16.0],
        [stackView.trailingAnchor constraintEqualToAnchor:containerView.trailingAnchor constant:-16.0]
    ]];

    UILabel *label = [[UILabel alloc] init];
    label.text = title;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [UIFont boldSystemFontOfSize:12.0];
    [stackView addArrangedSubview:label];

    _UIPrototypingMenuSlider *slider = [[_UIPrototypingMenuSlider alloc] init];
    slider.minimumValue = minValue;
    slider.maximumValue = maxValue;
    slider.value = initialValue;
    slider.stepSize = step;
    [[slider.heightAnchor constraintEqualToConstant:40.0] setActive:YES];
    [stackView addArrangedSubview:slider];
    [slider addTarget:self action:@selector(scaleSliderChanged:) forControlEvents:UIControlEventValueChanged];

    return containerView;
}

- (void)scaleSliderChanged:(_UIPrototypingMenuSlider *)slider {
    self.scaleRatio = slider.value;
    self.appSceneVC.scaleRatio = _scaleRatio;
    if (self.appSceneVC.usesHostingControllerAPI) {
        self.appSceneVC.contentView.transform = CGAffineTransformMakeScale(_scaleRatio, _scaleRatio);
    } else {
        self.appSceneVC.contentView.layer.sublayerTransform = CATransform3DMakeScale(_scaleRatio, _scaleRatio, 1.0);
    }
    __weak typeof(self) weakSelf = self;
    [self.appSceneVC updateFrameWithSettingsBlock:^(UIMutableApplicationSceneSettings *settings) {
        if (weakSelf.isMaximized) {
            [weakSelf updateMaximizedSafeAreaWithSettings:settings];
        } else {
            settings.peripheryInsets = UIEdgeInsetsZero;
            settings.safeAreaInsetsPortrait = UIEdgeInsetsZero;
        }
    }];
}

- (void)closeWindow {
    _isAppTerminationRequested = YES;
    if ([_appSceneVC isAppRunning]) {
        [_appSceneVC terminate];
    } else {
        [self appSceneVCAppDidExit:self.appSceneVC];
    }
}

- (void)minimizeWindow {
    if (self.view.hidden) return;
    [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        self.view.alpha = 0.0;
        self.view.transform = CGAffineTransformMakeScale(0.15, 0.15);
    } completion:^(BOOL finished) {
        if (!finished) return;
        self.view.hidden = YES;
        self.view.transform = CGAffineTransformIdentity;
        [self.view.superview sendSubviewToBack:self.view];
    }];
}

- (void)minimizeWindowPiP {
    [UIView animateWithDuration:0.22 animations:^{
        self.view.alpha = 0.0;
    } completion:^(BOOL finished) {
        if (finished) self.view.hidden = YES;
    }];
}

- (void)unminimizeWindowPiP {
    self.view.hidden = NO;
    [UIView animateWithDuration:0.22 animations:^{
        self.view.alpha = 1.0;
    }];
}

- (void)maximizeWindow {
    if (!self.view.window) return;
    __weak typeof(self) weakSelf = self;
    UIImageSymbolConfiguration *iconCfg = [UIImageSymbolConfiguration configurationWithPointSize:7.0 weight:UIImageSymbolWeightBold];

    if (self.isMaximized) {
        CGRect maxFrame = UIEdgeInsetsInsetRect(self.view.window.frame, self.view.window.safeAreaInsets);
        CGRect restored = CGRectMake(self.originalFrame.origin.x * maxFrame.size.width,
                                     self.originalFrame.origin.y * maxFrame.size.height,
                                     self.originalFrame.size.width,
                                     self.originalFrame.size.height);
        self.isMaximized = NO;
        [self updateVerticalConstraintsAnimated:YES];

        [UIView animateWithDuration:0.24 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
            weakSelf.view.frame = restored;
            weakSelf.view.layer.borderWidth = 1.0;
            weakSelf.view.layer.cornerRadius = 12.0;
            weakSelf.resizeHandle.alpha = 1.0;
            [weakSelf.appSceneVC updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
                [weakSelf updateWindowedFrameWithSettings:settings animate:NO];
            }];
        } completion:^(BOOL finished) {
            [weakSelf.zoomTrafficBtn setImage:[[UIImage systemImageNamed:@"plus"] imageWithConfiguration:iconCfg] forState:UIControlStateNormal];
        }];
    } else {
        [self updateOriginalFrame];
        self.isMaximized = YES;
        [self updateVerticalConstraintsAnimated:YES];

        [UIView animateWithDuration:0.24 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
            weakSelf.view.layer.borderWidth = 0.0;
            weakSelf.view.layer.cornerRadius = 0.0;
            weakSelf.resizeHandle.alpha = 0.0;
            [weakSelf.appSceneVC updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
                [weakSelf updateMaximizedFrameWithSettings:settings];
            }];
        } completion:^(BOOL finished) {
            [weakSelf.zoomTrafficBtn setImage:[[UIImage systemImageNamed:@"arrow.down.right.and.arrow.up.left"] imageWithConfiguration:iconCfg] forState:UIControlStateNormal];
        }];
    }
}

#pragma mark - AppSceneViewControllerDelegate

- (void)appSceneVCAppDidExit:(AppSceneViewController *)vc {
    BOOL skipTerminationScreen = [NSUserDefaults.lcSharedDefaults boolForKey:@"LCSkipTerminatedScreen"];
    BOOL isManual = _isAppTerminationRequested;
    if (isManual || skipTerminationScreen) {
        [[MultitaskDockManager shared] removeRunningApp:self.dataUUID];
        [UIView animateWithDuration:0.24 animations:^{
            self.view.alpha = 0.0;
            self.view.transform = CGAffineTransformMakeScale(0.92, 0.92);
        } completion:^(BOOL finished) {
            [self.view removeFromSuperview];
        }];
        if (skipTerminationScreen) {
            [MultitaskRelaunchManager scheduleRelaunchIfNeededWithBundleId:self.appSceneVC.bundleId dataUUID:self.dataUUID isManualTermination:isManual];
        }
    } else {
        UILabel *label = [[UILabel alloc] initWithFrame:self.view.bounds];
        label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        label.numberOfLines = 0;
        label.text = NSLocalizedString(@"lc.multitaskAppWindow.appTerminated", @"");
        label.textAlignment = NSTextAlignmentCenter;
        [self.view insertSubview:label atIndex:0];
    }
}

- (void)appSceneVC:(AppSceneViewController *)vc didInitializeWithError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (error) {
            [vc appTerminationCleanUp];
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"lc.common.error".loc message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"lc.common.ok".loc style:UIAlertActionStyleCancel handler:nil]];
            [alert addAction:[UIAlertAction actionWithTitle:@"lc.common.copy".loc style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                UIPasteboard.generalPasteboard.string = error.localizedDescription;
            }]];
            [self presentViewController:alert animated:YES completion:nil];
        } else {
            self.pid = vc.pid;
            [self updateOriginalFrame];
            if (self.pidAvailableHandler) {
                self.pidAvailableHandler(@(self.pid), nil);
            }
        }
    });
}

- (void)appSceneVCWillActivateScene:(AppSceneViewController *)vc {
    [self appSceneVC:vc didUpdateFromSettings:vc.presenter.scene.settings.mutableCopy transitionContext:nil lifecycleActionType:0];
}

- (void)appSceneVC:(AppSceneViewController *)vc didUpdateFromSettings:(UIMutableApplicationSceneSettings *)baseSettings transitionContext:(id)newContext lifecycleActionType:(uint32_t)actionType {
    __weak typeof(self) weakSelf = self;
    [self.appSceneVC updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
        settings.userInterfaceStyle = baseSettings.userInterfaceStyle;
        settings.interfaceOrientation = baseSettings.interfaceOrientation;
        settings.deviceOrientation = baseSettings.deviceOrientation;
        settings.foreground = YES;

        if (weakSelf.isMaximized) {
            [weakSelf updateMaximizedFrameWithSettings:settings];
        } else {
            [weakSelf updateWindowedFrameWithSettings:settings animate:NO];
        }

        CGFloat barH = weakSelf.macTitleBar.hidden ? 0.0 : kMacTitleBarHeight;
        CGFloat safeScale = MAX(0.1, weakSelf.scaleRatio);
        CGRect newFrame = CGRectMake(0, 0, weakSelf.view.bounds.size.width, weakSelf.view.bounds.size.height - barH / safeScale);
        settings.frame = UIInterfaceOrientationIsLandscape(baseSettings.interfaceOrientation)
            ? CGRectMake(0, 0, newFrame.size.height, newFrame.size.width)
            : CGRectMake(0, 0, newFrame.size.width, newFrame.size.height);
    }];
}

#pragma mark - Observers, Dragging, Resizing & Frame Math

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (![keyPath isEqualToString:@"LCMultitaskBottomWindowBar"]) return;
    BOOL bottomBar = [change[NSKeyValueChangeNewKey] boolValue];
    [self.view removeArrangedSubview:self.macTitleBar];
    if (bottomBar) {
        [self.view addArrangedSubview:self.macTitleBar];
    } else {
        [self.view insertArrangedSubview:self.macTitleBar atIndex:0];
    }
    [self rebuildTrafficLightsOnLeadingEdge:bottomBar];
    [self updateVerticalConstraintsAnimated:YES];

    if (_isMaximized) {
        __weak typeof(self) weakSelf = self;
        [self.appSceneVC updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
            [weakSelf updateMaximizedFrameWithSettings:settings];
        }];
    }
}

- (void)moveWindow:(UIPanGestureRecognizer *)sender {
    if (_isMaximized) return;
    UIView *ref = self.view.superview ?: self.view;
    CGPoint delta = [sender translationInView:ref];
    [sender setTranslation:CGPointZero inView:ref];

    self.view.center = CGPointMake(self.view.center.x + delta.x, self.view.center.y + delta.y);
    if (sender.state == UIGestureRecognizerStateEnded || sender.state == UIGestureRecognizerStateCancelled) {
        [self updateOriginalFrame];
    }
}

- (void)resizeWindow:(UIPanGestureRecognizer *)sender {
    if (_isMaximized) return;
    CGPoint delta = [sender translationInView:self.view];
    [sender setTranslation:CGPointZero inView:self.view];

    CGRect frame = self.view.frame;
    frame.size.width = MAX(kMinMacWindowSize.width, frame.size.width + delta.x);
    frame.size.height = MAX(kMinMacWindowSize.height, frame.size.height + delta.y);
    self.view.frame = frame;

    CFTimeInterval now = CACurrentMediaTime();
    if (now - _lastSceneResizeTime >= (1.0 / 60.0) || sender.state == UIGestureRecognizerStateEnded) {
        _lastSceneResizeTime = now;
        __weak typeof(self) weakSelf = self;
        [self.appSceneVC updateFrameWithSettingsBlock:^(UIMutableApplicationSceneSettings *settings) {
            [weakSelf updateWindowedFrameWithSettings:settings animate:NO];
        }];
    }

    if (sender.state == UIGestureRecognizerStateEnded || sender.state == UIGestureRecognizerStateCancelled) {
        [self updateOriginalFrame];
    }
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    [self.view.superview bringSubviewToFront:self.view];
}

- (void)updateVerticalConstraints {
    [self updateVerticalConstraintsAnimated:YES];
}

- (void)updateVerticalConstraintsAnimated:(BOOL)animated {
    BOOL bottomBar = [NSUserDefaults.lcSharedDefaults boolForKey:@"LCMultitaskBottomWindowBar"];
    BOOL hideBar = MultitaskDockManager.shared.isCollapsed && self.isMaximized;
    CGFloat barHeight = hideBar ? 0.0 : kMacTitleBarHeight;

    void (^apply)(void) = ^{
        self.macTitleBar.alpha = hideBar ? 0.0 : 1.0;
        self.macTitleBar.hidden = hideBar;

        [NSLayoutConstraint deactivateConstraints:self.activatedVerticalConstraints];
        if (bottomBar) {
            self.activatedVerticalConstraints = @[
                [self.appSceneVC.view.topAnchor constraintEqualToAnchor:self.view.topAnchor],
                [self.appSceneVC.view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-barHeight],
                [self.macTitleBar.heightAnchor constraintEqualToConstant:barHeight]
            ];
        } else {
            self.activatedVerticalConstraints = @[
                [self.appSceneVC.view.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:barHeight],
                [self.appSceneVC.view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
                [self.macTitleBar.heightAnchor constraintEqualToConstant:barHeight]
            ];
        }
        [NSLayoutConstraint activateConstraints:self.activatedVerticalConstraints];
    };

    if (animated) {
        [UIView animateWithDuration:0.22 animations:apply];
    } else {
        apply();
    }

    if (self.isMaximized) {
        self.appSceneVC.shouldSkipDebounceOnce = YES;
        __weak typeof(self) weakSelf = self;
        [self.appSceneVC updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
            [weakSelf updateMaximizedFrameWithSettings:settings];
        }];
    }
}

- (UIEdgeInsets)updateMaximizedSafeAreaWithSettings:(UIMutableApplicationSceneSettings *)settings {
    if (!self.view.window) return UIEdgeInsetsZero;
    BOOL bottomBar = [NSUserDefaults.lcSharedDefaults boolForKey:@"LCMultitaskBottomWindowBar"];
    UIEdgeInsets safeAreaInsets = self.view.window.safeAreaInsets;

    if (self.macTitleBar.hidden) {
        settings.peripheryInsets = safeAreaInsets;
        safeAreaInsets = UIEdgeInsetsZero;
    } else if (bottomBar) {
        safeAreaInsets.bottom = 0;
        settings.peripheryInsets = safeAreaInsets;
        safeAreaInsets.top = safeAreaInsets.left = safeAreaInsets.right = 0;
    } else {
        settings.peripheryInsets = UIEdgeInsetsMake(0, safeAreaInsets.left, safeAreaInsets.bottom, safeAreaInsets.right);
        safeAreaInsets.bottom = safeAreaInsets.left = safeAreaInsets.right = 0;
    }

    CGFloat scale = MAX(0.1, _scaleRatio);
    settings.peripheryInsets = UIEdgeInsetsMake(settings.peripheryInsets.top / scale,
                                                settings.peripheryInsets.left / scale,
                                                settings.peripheryInsets.bottom / scale,
                                                settings.peripheryInsets.right / scale);

    if (UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPad) {
        UIInterfaceOrientation orientation = UIApp.statusBarOrientation;
        if (UIInterfaceOrientationIsLandscape(orientation)) {
            safeAreaInsets.top = 0;
        }
        settings.safeAreaInsetsPortrait = LCUIEdgeInsetsRotateToOrientation(settings.peripheryInsets, orientation);
    } else {
        settings.safeAreaInsetsPortrait = settings.peripheryInsets;
    }

    safeAreaInsets.bottom = 0;
    return safeAreaInsets;
}

- (void)updateMaximizedFrameWithSettings:(UIMutableApplicationSceneSettings *)settings {
    if (!self.view.window) return;
    self.view.frame = UIEdgeInsetsInsetRect(self.view.window.frame, [self updateMaximizedSafeAreaWithSettings:settings]);
}

- (void)updateWindowedFrameWithSettings:(UIMutableApplicationSceneSettings *)settings animate:(BOOL)animate {
    if (!self.view.window) return;
    UIEdgeInsets safeAreaInsets = self.view.window.safeAreaInsets;
    CGRect maxFrame = UIEdgeInsetsInsetRect(self.view.window.frame, safeAreaInsets);
    settings.peripheryInsets = UIEdgeInsetsZero;
    settings.safeAreaInsetsPortrait = UIEdgeInsetsZero;

    CGRect desired = CGRectMake(self.originalFrame.origin.x * maxFrame.size.width,
                                self.originalFrame.origin.y * maxFrame.size.height,
                                self.originalFrame.size.width,
                                self.originalFrame.size.height);
    CGPoint center = self.view.center;
    CGRect target = CGRectZero;
    target.size.width = MIN(desired.size.width, maxFrame.size.width);
    target.size.height = MIN(desired.size.height, maxFrame.size.height);
    CGFloat oobOffset = MAX(30.0, target.size.width - 30.0);
    target.origin.x = MAX(maxFrame.origin.x - oobOffset, MIN(CGRectGetMaxX(maxFrame) - target.size.width + oobOffset, center.x - target.size.width / 2.0));
    target.origin.y = MAX(maxFrame.origin.y, MIN(center.y - target.size.height / 2.0, CGRectGetMaxY(maxFrame) - target.size.height));

    if (animate) {
        [UIView animateWithDuration:0.22 animations:^{
            self.view.frame = target;
        }];
    } else {
        self.view.frame = target;
    }
}

- (void)updateOriginalFrame {
    if (_isMaximized || !self.view.window) return;
    CGRect maxFrame = UIEdgeInsetsInsetRect(self.view.window.frame, self.view.window.safeAreaInsets);
    CGFloat w = MAX(1.0, maxFrame.size.width);
    CGFloat h = MAX(1.0, maxFrame.size.height);
    self.originalFrame = CGRectMake(self.view.frame.origin.x / w,
                                    self.view.frame.origin.y / h,
                                    self.view.frame.size.width,
                                    self.view.frame.size.height);
}

@end
