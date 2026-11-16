#import "DecoratedAppSceneViewController.h"
#import "ResizeHandleView.h"
#import "LiveContainerSwiftUI-Swift.h"
#import "AppSceneViewController.h"
#import "UIKitPrivate+MultitaskSupport.h"
#import "PiPManager.h"
#import "VirtualWindowsHostView.h"
#import "../LiveContainer/Localization.h"
#import "utils.h"

static const CGFloat kCompactTabBarHeight = 24.0;
static const CGFloat kMacCornerRadius = 11.0;
static const CGSize kMinWindowDimensions = {240.0, 170.0};
static NSString *const kWallpaperLayerName = @"OutTaskCustomWallpaperLayer";
static NSString *const kWallpaperDimLayerName = @"OutTaskCustomWallpaperDimLayer";
static void *const kOutTaskKVOContext = &kOutTaskKVOContext;

typedef NS_ENUM(NSInteger, OutTaskSnapPosition) {
    OutTaskSnapPositionNone = 0,
    OutTaskSnapPositionLeft,
    OutTaskSnapPositionRight,
    OutTaskSnapPositionCenter
};

@interface DecoratedAppSceneViewController ()
@property(nonatomic) NSArray<NSLayoutConstraint *> *activatedVerticalConstraints;
@property(nonatomic) NSString *dataUUID;
@property(nonatomic) int pid;
@property(nonatomic) CGRect originalFrame;
@property(nonatomic) UIBarButtonItem *maximizeButton;
@property(nonatomic) bool isAppTerminationRequested;
@property(nonatomic) BOOL isObservingSettings;
@property(nonatomic) BOOL isActiveWindow;

- (void)applyNoLagSettings;
- (void)applyCustomWallpaperInHostView:(UIView *)hostView;
- (void)applyMacOSWindowChrome;
- (void)snapWindowToPosition:(OutTaskSnapPosition)position;
- (void)applyVerticalConstraintsAnimated:(BOOL)animated;
- (void)applyWindowedSceneSettings:(UIMutableApplicationSceneSettings *)settings;
@end

@implementation DecoratedAppSceneViewController

- (UIStackView *)containerStackView {
    return (UIStackView *)self.view;
}

- (NSUserDefaults *)outTaskDefaults {
    return NSUserDefaults.lcSharedDefaults ?: NSUserDefaults.lcUserDefaults;
}

- (BOOL)isNoLagEnabled {
    id val = [[self outTaskDefaults] objectForKey:@"OutTaskNoLagMode"];
    return val ? [val boolValue] : YES;
}

- (BOOL)areFastAnimationsEnabled {
    id val = [[self outTaskDefaults] objectForKey:@"OutTaskFastAnimations"];
    return val ? [val boolValue] : YES;
}

- (NSTimeInterval)transitionDurationForStyle:(NSTimeInterval)baseDuration {
    if ([self isNoLagEnabled]) {
        return MIN(baseDuration * 0.55, 0.16);
    }
    return [self areFastAnimationsEnabled] ? MIN(baseDuration * 0.75, 0.22) : baseDuration;
}

- (void)dealloc {
    if (_isObservingSettings) {
        NSUserDefaults *defaults = [self outTaskDefaults];
        NSArray<NSString *> *observedKeys = @[
            @"LCMultitaskBottomWindowBar",
            @"OutTaskWallpaperPath",
            @"OutTaskWallpaperData",
            @"OutTaskWallpaperDimAlpha",
            @"OutTaskNoLagMode",
            @"OutTaskFastAnimations",
            @"OutTaskWindowOpacity"
        ];
        for (NSString *key in observedKeys) {
            @try {
                [defaults removeObserver:self forKeyPath:key context:kOutTaskKVOContext];
            } @catch (__unused NSException *ex) {
            }
        }
        _isObservingSettings = NO;
    }
}

- (instancetype)initWindowName:(NSString *)windowName bundleId:(NSString *)bundleId dataUUID:(NSString *)dataUUID rootVC:(UIViewController *)rootVC {
    self = [super initWithNibName:nil bundle:nil];
    if (!self) return nil;

    self.view = [[UIStackView alloc] initWithFrame:CGRectZero];
    UIView *hostView = MultitaskDockManager.shared.windowHostingView;
    [hostView addSubview:self.view];
    [rootVC addChildViewController:self];

    _dataUUID = dataUUID;
    _scaleRatio = 1.0;
    _isActiveWindow = YES;
    _isMaximized = [[self outTaskDefaults] boolForKey:@"LCLaunchMultitaskMaximized"];
    _appSceneVC = [[AppSceneViewController alloc] initWithBundleId:bundleId dataUUID:dataUUID delegate:self];
    self.title = windowName;

    [self applyNoLagSettings];
    [self applyCustomWallpaperInHostView:hostView];
    [self setupDecoratedView];
    [self applyMacOSWindowChrome];

    [MultitaskDockManager.shared addRunningApp:windowName appUUID:dataUUID view:self.view];

    __weak typeof(self) weakSelf = self;
    NSArray<UIMenuElement *> *windowActionsMenu = @[
        [UIAction actionWithTitle:@"Snap Left" image:[UIImage systemImageNamed:@"rectangle.lefthalf.inset.filled"] identifier:nil handler:^(UIAction * _Nonnull action) {
            [weakSelf snapWindowToPosition:OutTaskSnapPositionLeft];
        }],
        [UIAction actionWithTitle:@"Snap Right" image:[UIImage systemImageNamed:@"rectangle.righthalf.inset.filled"] identifier:nil handler:^(UIAction * _Nonnull action) {
            [weakSelf snapWindowToPosition:OutTaskSnapPositionRight];
        }],
        [UIAction actionWithTitle:@"Center Window" image:[UIImage systemImageNamed:@"rectangle.center.inset.filled"] identifier:nil handler:^(UIAction * _Nonnull action) {
            [weakSelf snapWindowToPosition:OutTaskSnapPositionCenter];
        }],
        [UIAction actionWithTitle:weakSelf.isMaximized ? @"Restore Window" : @"Zoom Window"
                          image:[UIImage systemImageNamed:weakSelf.isMaximized ? @"arrow.down.right.and.arrow.up.left" : @"arrow.up.left.and.arrow.down.right"]
                     identifier:nil
                        handler:^(UIAction * _Nonnull action) {
            [weakSelf maximizeWindow];
        }]
    ];

    UIMenu *arrangeSubmenu = [UIMenu menuWithTitle:@"Window Tiling" image:[UIImage systemImageNamed:@"macwindow.on.rectangle"] children:windowActionsMenu];

    NSArray<UIMenuElement *> *menuItems = @[
        arrangeSubmenu,
        [UIAction actionWithTitle:[weakSelf isNoLagEnabled] ? @"No-Lag Mode: ON" : @"No-Lag Mode: OFF"
                          image:[UIImage systemImageNamed:@"bolt.fill"]
                     identifier:nil
                        handler:^(UIAction * _Nonnull action) {
            NSUserDefaults *defaults = [weakSelf outTaskDefaults];
            [defaults setBool:![weakSelf isNoLagEnabled] forKey:@"OutTaskNoLagMode"];
        }],
        [UIAction actionWithTitle:@"Toggle Bottom Bar" image:[UIImage systemImageNamed:@"dock.arrow.down.rectangle"] identifier:nil handler:^(UIAction * _Nonnull action) {
            NSUserDefaults *defaults = [weakSelf outTaskDefaults];
            BOOL current = [defaults boolForKey:@"LCMultitaskBottomWindowBar"];
            [defaults setBool:!current forKey:@"LCMultitaskBottomWindowBar"];
        }],
        [UIAction actionWithTitle:@"Refresh Wallpaper" image:[UIImage systemImageNamed:@"photo.on.rectangle"] identifier:nil handler:^(UIAction * _Nonnull action) {
            [weakSelf applyCustomWallpaperInHostView:MultitaskDockManager.shared.windowHostingView];
        }],
        [UIAction actionWithTitle:@"lc.multitask.enablePip".loc image:[UIImage systemImageNamed:@"pip.enter"] identifier:nil handler:^(UIAction * _Nonnull action) {
            if ([PiPManager.shared isPiPWithVC:weakSelf.appSceneVC]) {
                [PiPManager.shared stopPiP];
            } else {
                [PiPManager.shared startPiPWithVC:weakSelf.appSceneVC];
            }
        }],
        [UIAction actionWithTitle:@"lc.multitask.copyPid".loc image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(UIAction * _Nonnull action) {
            UIPasteboard.generalPasteboard.string = @(weakSelf.appSceneVC.pid).stringValue;
        }],
        [UICustomViewMenuElement elementWithViewProvider:^UIView *(UICustomViewMenuElement *element) {
            return [weakSelf scaleSliderViewWithTitle:@"lc.multitask.scale".loc min:0.5 max:2.0 value:weakSelf.scaleRatio stepInterval:0.01];
        }]
    ];

    [self.navigationItem setTitleMenuProvider:^UIMenu *(NSArray<UIMenuElement *> *suggestedActions) {
        if (!weakSelf.appSceneVC.isAppRunning) {
            return [UIMenu menuWithTitle:NSLocalizedString(@"lc.multitaskAppWindow.appTerminated", nil) children:@[]];
        }
        NSString *header = [NSString stringWithFormat:@"OutTask Container • PID: %d", weakSelf.pid];
        return [UIMenu menuWithTitle:header children:menuItems];
    }];

    UIImageConfiguration *trafficConfig = [UIImageSymbolConfiguration configurationWithPointSize:10.5 weight:UIImageSymbolWeightSemibold];

    UIImage *closeImage = [[UIImage systemImageNamed:@"xmark.circle.fill"] imageWithConfiguration:trafficConfig];
    UIBarButtonItem *closeButton = [[UIBarButtonItem alloc] initWithImage:closeImage style:UIBarButtonItemStylePlain target:self action:@selector(closeWindow)];
    closeButton.tintColor = [UIColor systemRedColor];

    UIImage *minimizeImage = [[UIImage systemImageNamed:@"minus.circle.fill"] imageWithConfiguration:trafficConfig];
    UIBarButtonItem *minimizeButton = [[UIBarButtonItem alloc] initWithImage:minimizeImage style:UIBarButtonItemStylePlain target:self action:@selector(minimizeWindow)];
    minimizeButton.tintColor = [UIColor systemYellowColor];

    NSString *maximizeImageName = _isMaximized ? @"arrow.down.right.and.arrow.up.left.circle.fill" : @"plus.circle.fill";
    UIImage *maximizeImage = [[UIImage systemImageNamed:maximizeImageName] imageWithConfiguration:trafficConfig];
    self.maximizeButton = [[UIBarButtonItem alloc] initWithImage:maximizeImage style:UIBarButtonItemStylePlain target:self action:@selector(maximizeWindow)];
    self.maximizeButton.tintColor = [UIColor systemGreenColor];

    self.navigationItem.leftBarButtonItems = @[closeButton, minimizeButton, self.maximizeButton];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf adjustNavigationBarButtonSpacingWithNegativeSpacing:-12.0 rightMargin:-6.0];
    });

    return self;
}

- (void)applyNoLagSettings {
    NSUserDefaults *defaults = [self outTaskDefaults];
    if ([defaults objectForKey:@"OutTaskNoLagMode"] == nil) {
        [defaults setBool:YES forKey:@"OutTaskNoLagMode"];
    }
    if ([defaults objectForKey:@"OutTaskFastAnimations"] == nil) {
        [defaults setBool:YES forKey:@"OutTaskFastAnimations"];
    }

    BOOL noLag = [self isNoLagEnabled];
    self.view.opaque = noLag;
    self.view.clearsContextBeforeDrawing = !noLag;
    self.view.layer.drawsAsynchronously = noLag;
    self.contentView.layer.drawsAsynchronously = noLag;
    self.appSceneVC.view.layer.drawsAsynchronously = noLag;

    CGFloat opacity = 1.0;
    id opacityObj = [defaults objectForKey:@"OutTaskWindowOpacity"];
    if ([opacityObj respondsToSelector:@selector(doubleValue)]) {
        opacity = MIN(1.0, MAX(0.45, (CGFloat)[opacityObj doubleValue]));
    }
    if (!self.view.hidden) {
        self.view.alpha = opacity;
    }
}

- (void)applyCustomWallpaperInHostView:(UIView *)hostView {
    if (!hostView) return;

    for (CALayer *sublayer in [hostView.layer.sublayers copy]) {
        if ([sublayer.name isEqualToString:kWallpaperLayerName] || [sublayer.name isEqualToString:kWallpaperDimLayerName]) {
            [sublayer removeFromSuperlayer];
        }
    }

    NSUserDefaults *defaults = [self outTaskDefaults];
    UIImage *wallpaperImage = nil;

    NSString *wallpaperPath = [defaults stringForKey:@"OutTaskWallpaperPath"];
    if (wallpaperPath.length > 0) {
        wallpaperImage = [UIImage imageWithContentsOfFile:wallpaperPath];
    }
    if (!wallpaperImage) {
        NSData *wallpaperData = [defaults dataForKey:@"OutTaskWallpaperData"];
        if (wallpaperData.length > 0) {
            wallpaperImage = [UIImage imageWithData:wallpaperData];
        }
    }
    if (!wallpaperImage) return;

    CGRect hostBounds = hostView.bounds;
    if (CGRectIsEmpty(hostBounds) && hostView.window) {
        hostBounds = hostView.window.bounds;
    }

    CALayer *wallpaperLayer = [CALayer layer];
    wallpaperLayer.name = kWallpaperLayerName;
    wallpaperLayer.frame = hostBounds;
    wallpaperLayer.contents = (__bridge id)wallpaperImage.CGImage;
    wallpaperLayer.contentsGravity = kCAGravityResizeAspectFill;
    wallpaperLayer.masksToBounds = YES;
    wallpaperLayer.drawsAsynchronously = [self isNoLagEnabled];
    wallpaperLayer.zPosition = -100.0;
    [hostView.layer insertSublayer:wallpaperLayer atIndex:0];

    CGFloat dimAlpha = 0.0;
    id dimObj = [defaults objectForKey:@"OutTaskWallpaperDimAlpha"];
    if ([dimObj respondsToSelector:@selector(doubleValue)]) {
        dimAlpha = MIN(0.85, MAX(0.0, (CGFloat)[dimObj doubleValue]));
    }
    if (dimAlpha > 0.001) {
        CALayer *dimLayer = [CALayer layer];
        dimLayer.name = kWallpaperDimLayerName;
        dimLayer.frame = hostBounds;
        dimLayer.backgroundColor = [UIColor colorWithWhite:0.0 alpha:dimAlpha].CGColor;
        dimLayer.zPosition = -99.0;
        [hostView.layer insertSublayer:dimLayer atIndex:1];
    }
}

- (void)applyMacOSWindowChrome {
    UIStackView *stack = [self containerStackView];
    stack.layer.cornerRadius = _isMaximized ? 0.0 : kMacCornerRadius;
    stack.layer.masksToBounds = YES;
    stack.layer.borderWidth = _isMaximized ? 0.0 : (_isActiveWindow ? 1.0 : 0.6);
    stack.layer.borderColor = (_isActiveWindow ? [UIColor separatorColor] : [UIColor colorWithWhite:0.5 alpha:0.2]).CGColor;

    if ([self isNoLagEnabled]) {
        stack.layer.shadowOpacity = 0.0;
        stack.layer.shadowRadius = 0.0;
    } else {
        stack.layer.shadowColor = UIColor.blackColor.CGColor;
        stack.layer.shadowOpacity = _isMaximized ? 0.0 : (_isActiveWindow ? 0.16 : 0.06);
        stack.layer.shadowRadius = _isMaximized ? 0.0 : 10.0;
        stack.layer.shadowOffset = CGSizeMake(0.0, 4.0);
    }
}

- (void)snapWindowToPosition:(OutTaskSnapPosition)position {
    if (!self.view.window) return;
    if (_isMaximized) {
        _isMaximized = NO;
        [self applyVerticalConstraintsAnimated:NO];
        [self applyMacOSWindowChrome];
    }

    CGRect bounds = UIEdgeInsetsInsetRect(self.view.window.frame, self.view.window.safeAreaInsets);
    CGFloat barHeight = self.navigationBar.hidden ? 0.0 : kCompactTabBarHeight;
    CGFloat inset = 6.0;
    CGRect targetFrame = self.view.frame;

    switch (position) {
        case OutTaskSnapPositionLeft:
            targetFrame = CGRectMake(bounds.origin.x + inset,
                                     bounds.origin.y + inset,
                                     MAX(kMinWindowDimensions.width, bounds.size.width * 0.5 - inset * 1.5),
                                     MAX(kMinWindowDimensions.height, bounds.size.height - inset * 2.0));
            break;
        case OutTaskSnapPositionRight:
            targetFrame = CGRectMake(bounds.origin.x + bounds.size.width * 0.5 + inset * 0.5,
                                     bounds.origin.y + inset,
                                     MAX(kMinWindowDimensions.width, bounds.size.width * 0.5 - inset * 1.5),
                                     MAX(kMinWindowDimensions.height, bounds.size.height - inset * 2.0));
            break;
        case OutTaskSnapPositionCenter: {
            CGFloat w = MIN(bounds.size.width * 0.72, MAX(targetFrame.size.width, 380.0));
            CGFloat h = MIN(bounds.size.height * 0.78, MAX(targetFrame.size.height, 440.0 + barHeight));
            targetFrame = CGRectMake(CGRectGetMidX(bounds) - w * 0.5,
                                     CGRectGetMidY(bounds) - h * 0.5,
                                     w,
                                     h);
            break;
        }
        case OutTaskSnapPositionNone:
        default:
            return;
    }

    __weak typeof(self) weakSelf = self;
    [UIView animateWithDuration:[self transitionDurationForStyle:0.2]
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        weakSelf.view.frame = targetFrame;
    } completion:^(BOOL finished) {
        [weakSelf updateOriginalFrame];
        [weakSelf.appSceneVC updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
            [weakSelf applyWindowedSceneSettings:settings];
        }];
    }];
}

- (void)setupDecoratedView {
    BOOL isLandscape = UIInterfaceOrientationIsLandscape(UIApp.statusBarOrientation);
    CGRect frame = CGRectMake(0, 0, isLandscape ? 500.0 : 320.0, (isLandscape ? 320.0 : 500.0) + kCompactTabBarHeight);
    CGPoint rootViewCenter = self.view.superview ? self.view.superview.center : CGPointMake(200.0, 380.0);
    frame.origin = CGPointMake(rootViewCenter.x - frame.size.width / 2.0, rootViewCenter.y - frame.size.height / 2.0);

    if (_isMaximized && self.view.window) {
        CGRect maxFrame = UIEdgeInsetsInsetRect(self.view.window.frame, self.view.window.safeAreaInsets);
        frame.origin.x /= MAX(1.0, maxFrame.size.width);
        frame.origin.y /= MAX(1.0, maxFrame.size.height);
        self.originalFrame = frame;
    } else {
        self.view.frame = frame;
    }

    UINavigationBarAppearance *compactAppearance = [[UINavigationBarAppearance alloc] init];
    [compactAppearance configureWithDefaultBackground];
    compactAppearance.titleTextAttributes = @{
        NSFontAttributeName: [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: UIColor.labelColor
    };

    UINavigationBar *navigationBar = [[UINavigationBar alloc] initWithFrame:CGRectMake(0, 0, self.view.frame.size.width, kCompactTabBarHeight)];
    navigationBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    navigationBar.standardAppearance = compactAppearance;
    navigationBar.scrollEdgeAppearance = compactAppearance;
    UINavigationItem *navigationItem = [[UINavigationItem alloc] initWithTitle:self.title];
    navigationBar.items = @[navigationItem];

    UIStackView *stack = [self containerStackView];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.backgroundColor = UIColor.systemBackgroundColor;

    self.navigationBar = navigationBar;
    self.navigationItem = navigationBar.items.firstObject;
    if (!self.navigationBar.superview) {
        [stack addArrangedSubview:self.navigationBar];
    }

    CGRect contentFrame = CGRectMake(0, 0, self.view.frame.size.width, MAX(0.0, self.view.frame.size.height - kCompactTabBarHeight));
    UIView *fixedPositionContentView = [[UIView alloc] initWithFrame:contentFrame];
    fixedPositionContentView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    if ([[self outTaskDefaults] boolForKey:@"LCMultitaskBottomWindowBar"]) {
        [stack insertArrangedSubview:fixedPositionContentView atIndex:0];
    } else {
        [stack addArrangedSubview:fixedPositionContentView];
    }
    [self.view sendSubviewToBack:fixedPositionContentView];

    self.contentView = [[UIView alloc] initWithFrame:contentFrame];
    self.contentView.layer.anchorPoint = CGPointZero;
    self.contentView.layer.position = CGPointZero;
    self.contentView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [fixedPositionContentView addSubview:self.contentView];

    UIPanGestureRecognizer *moveGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(moveWindow:)];
    moveGesture.minimumNumberOfTouches = 1;
    moveGesture.maximumNumberOfTouches = 1;
    [self.navigationBar addGestureRecognizer:moveGesture];

    UITapGestureRecognizer *zoomGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(maximizeWindow)];
    zoomGesture.numberOfTapsRequired = 2;
    [self.navigationBar addGestureRecognizer:zoomGesture];
    [moveGesture requireGestureRecognizerToFail:zoomGesture];

    UIPanGestureRecognizer *resizeGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(resizeWindow:)];
    resizeGesture.minimumNumberOfTouches = 1;
    resizeGesture.maximumNumberOfTouches = 1;
    self.resizeHandle = [[ResizeHandleView alloc] initWithFrame:CGRectMake(self.view.frame.size.width - 26.0,
                                                                           self.view.frame.size.height - 26.0,
                                                                           26.0, 26.0)];
    self.resizeHandle.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
    self.resizeHandle.alpha = _isMaximized ? 0.0 : 1.0;
    [self.resizeHandle addGestureRecognizer:resizeGesture];
    [self.view addSubview:self.resizeHandle];

    [self addChildViewController:_appSceneVC];
    [self.view insertSubview:_appSceneVC.view atIndex:0];
    _appSceneVC.view.translatesAutoresizingMaskIntoConstraints = NO;

    [self applyVerticalConstraintsAnimated:NO];
    [NSLayoutConstraint activateConstraints:@[
        [_appSceneVC.view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_appSceneVC.view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]
    ]];

    if (!_isObservingSettings) {
        NSUserDefaults *defaults = [self outTaskDefaults];
        NSArray<NSString *> *observedKeys = @[
            @"LCMultitaskBottomWindowBar",
            @"OutTaskWallpaperPath",
            @"OutTaskWallpaperData",
            @"OutTaskWallpaperDimAlpha",
            @"OutTaskNoLagMode",
            @"OutTaskFastAnimations",
            @"OutTaskWindowOpacity"
        ];
        for (NSString *key in observedKeys) {
            [defaults addObserver:self forKeyPath:key options:NSKeyValueObservingOptionNew context:kOutTaskKVOContext];
        }
        _isObservingSettings = YES;
    }
    [self updateOriginalFrame];
}

// Stolen from UIKitester
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
    _isAppTerminationRequested = true;
    if ([_appSceneVC isAppRunning]) {
        [_appSceneVC terminate];
    } else {
        [self appSceneVCAppDidExit:self.appSceneVC];
    }
}

- (void)minimizeWindow {
    if (self.view.hidden) return;
    __weak typeof(self) weakSelf = self;
    [UIView animateWithDuration:[self transitionDurationForStyle:0.22]
                          delay:0
                        options:UIViewAnimationOptionCurveEaseInOut
                     animations:^{
        weakSelf.view.alpha = 0.0;
        weakSelf.view.transform = CGAffineTransformMakeScale(0.15, 0.15);
    } completion:^(BOOL finished) {
        if (!finished) return;
        weakSelf.view.hidden = YES;
        weakSelf.view.transform = CGAffineTransformIdentity;
        [weakSelf.view.superview sendSubviewToBack:weakSelf.view];
    }];
}

- (void)minimizeWindowPiP {
    __weak typeof(self) weakSelf = self;
    [UIView animateWithDuration:[self transitionDurationForStyle:0.22]
                          delay:0
                        options:UIViewAnimationOptionCurveEaseInOut
                     animations:^{
        weakSelf.view.alpha = 0.0;
    } completion:^(BOOL finished) {
        if (finished) weakSelf.view.hidden = YES;
    }];
}

- (void)unminimizeWindowPiP {
    self.view.hidden = NO;
    __weak typeof(self) weakSelf = self;
    [UIView animateWithDuration:[self transitionDurationForStyle:0.22]
                          delay:0
                        options:UIViewAnimationOptionCurveEaseInOut
                     animations:^{
        weakSelf.view.alpha = 1.0;
    } completion:nil];
}

- (void)maximizeWindow {
    if (!self.view.window) return;
    __weak typeof(self) weakSelf = self;
    UIImageConfiguration *trafficConfig = [UIImageSymbolConfiguration configurationWithPointSize:10.5 weight:UIImageSymbolWeightSemibold];
    NSTimeInterval duration = [self transitionDurationForStyle:0.24];

    if (self.isMaximized) {
        CGRect maxFrame = UIEdgeInsetsInsetRect(self.view.window.frame, self.view.window.safeAreaInsets);
        CGRect restoredFrame = CGRectMake(self.originalFrame.origin.x * maxFrame.size.width,
                                          self.originalFrame.origin.y * maxFrame.size.height,
                                          self.originalFrame.size.width,
                                          self.originalFrame.size.height);
        self.isMaximized = NO;
        [self applyVerticalConstraintsAnimated:NO];

        [UIView animateWithDuration:duration delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
            weakSelf.view.frame = restoredFrame;
            weakSelf.resizeHandle.alpha = 1.0;
            [weakSelf applyMacOSWindowChrome];
            [weakSelf.appSceneVC updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
                [weakSelf updateWindowedFrameWithSettings:settings];
            }];
            [weakSelf.view layoutIfNeeded];
        } completion:^(BOOL finished) {
            UIImage *maximizeImage = [[UIImage systemImageNamed:@"plus.circle.fill"] imageWithConfiguration:trafficConfig];
            weakSelf.maximizeButton.image = maximizeImage;
        }];
    } else {
        [self updateOriginalFrame];
        self.isMaximized = YES;
        [self applyVerticalConstraintsAnimated:NO];

        [UIView animateWithDuration:duration delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
            weakSelf.resizeHandle.alpha = 0.0;
            [weakSelf applyMacOSWindowChrome];
            [weakSelf.appSceneVC updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
                [weakSelf updateMaximizedFrameWithSettings:settings];
            }];
            [weakSelf.view layoutIfNeeded];
        } completion:^(BOOL finished) {
            UIImage *restoreImage = [[UIImage systemImageNamed:@"arrow.down.right.and.arrow.up.left.circle.fill"] imageWithConfiguration:trafficConfig];
            weakSelf.maximizeButton.image = restoreImage;
        }];
    }
}

- (void)appSceneVCAppDidExit:(AppSceneViewController *)vc {
    BOOL skipTerminationScreen = [[self outTaskDefaults] boolForKey:@"LCSkipTerminatedScreen"];
    BOOL isManual = _isAppTerminationRequested;
    if (isManual || skipTerminationScreen) {
        MultitaskDockManager *dock = [MultitaskDockManager shared];
        [dock removeRunningApp:self.dataUUID];

        self.view.layer.masksToBounds = NO;
        __weak typeof(self) weakSelf = self;
        [UIView animateWithDuration:[self transitionDurationForStyle:0.22]
                              delay:0
                            options:UIViewAnimationOptionCurveEaseIn
                         animations:^{
            weakSelf.view.alpha = 0.0;
            weakSelf.view.transform = CGAffineTransformMakeScale(0.94, 0.94);
        } completion:^(BOOL finished) {
            [weakSelf.view removeFromSuperview];
        }];

        if (skipTerminationScreen) {
            [MultitaskRelaunchManager scheduleRelaunchIfNeededWithBundleId:self.appSceneVC.bundleId dataUUID:self.dataUUID isManualTermination:isManual];
        }
    } else {
        UILabel *label = [[UILabel alloc] initWithFrame:self.view.bounds];
        label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        label.lineBreakMode = NSLineBreakByWordWrapping;
        label.numberOfLines = 0;
        label.text = NSLocalizedString(@"lc.multitaskAppWindow.appTerminated", @"");
        label.textAlignment = NSTextAlignmentCenter;
        [self.view insertSubview:label atIndex:0];
    }
}

- (void)appSceneVC:(AppSceneViewController *)vc didInitializeWithError:(NSError *)error {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (error) {
            [vc appTerminationCleanUp];
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"lc.common.error".loc message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"lc.common.ok".loc style:UIAlertActionStyleCancel handler:nil]];
            [alert addAction:[UIAlertAction actionWithTitle:@"lc.common.copy".loc style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                UIPasteboard.generalPasteboard.string = error.localizedDescription;
            }]];
            [weakSelf presentViewController:alert animated:YES completion:nil];
        } else {
            weakSelf.pid = vc.pid;
            [weakSelf updateOriginalFrame];
            if (weakSelf.pidAvailableHandler) {
                weakSelf.pidAvailableHandler(@(weakSelf.pid), nil);
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
            [weakSelf applyWindowedSceneSettings:settings];
        }

        CGFloat scale = MAX(0.1, weakSelf.scaleRatio);
        CGFloat navHeight = weakSelf.navigationBar.hidden ? 0.0 : weakSelf.navigationBar.frame.size.height;
        CGRect newFrame = CGRectMake(0, 0, weakSelf.view.bounds.size.width, MAX(1.0, weakSelf.view.bounds.size.height - navHeight / scale));

        if (UIInterfaceOrientationIsLandscape(baseSettings.interfaceOrientation)) {
            settings.frame = CGRectMake(0, 0, newFrame.size.height, newFrame.size.width);
        } else {
            settings.frame = CGRectMake(0, 0, newFrame.size.width, newFrame.size.height);
        }
    }];
}

- (void)adjustNavigationBarButtonSpacingWithNegativeSpacing:(CGFloat)spacing rightMargin:(CGFloat)margin {
    if (!self.navigationBar) return;
    [self findAndAdjustButtonBarStackView:self.navigationBar withSpacing:spacing rightMargin:margin];
}

- (void)findAndAdjustButtonBarStackView:(UIView *)view withSpacing:(CGFloat)spacing rightMargin:(CGFloat)margin {
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:NSClassFromString(@"_UIButtonBarStackView")]) {
            if ([subview respondsToSelector:@selector(setSpacing:)]) {
                [(_UIButtonBarStackView *)subview setSpacing:spacing];
            }

            if (subview.superview) {
                for (NSLayoutConstraint *constraint in subview.superview.constraints) {
                    if ((constraint.firstItem == subview && constraint.firstAttribute == NSLayoutAttributeTrailing) ||
                        (constraint.secondItem == subview && constraint.secondAttribute == NSLayoutAttributeTrailing)) {
                        constraint.constant = (constraint.firstItem == subview) ? -margin : margin;
                        break;
                    }
                }
                [subview setNeedsLayout];
                [subview.superview setNeedsLayout];
            }
            return;
        }
        [self findAndAdjustButtonBarStackView:subview withSpacing:spacing rightMargin:margin];
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context != kOutTaskKVOContext) {
        return;
    }

    if ([keyPath isEqualToString:@"OutTaskWallpaperPath"] ||
        [keyPath isEqualToString:@"OutTaskWallpaperData"] ||
        [keyPath isEqualToString:@"OutTaskWallpaperDimAlpha"]) {
        [self applyCustomWallpaperInHostView:MultitaskDockManager.shared.windowHostingView];
        return;
    }

    if ([keyPath isEqualToString:@"OutTaskNoLagMode"] ||
        [keyPath isEqualToString:@"OutTaskFastAnimations"] ||
        [keyPath isEqualToString:@"OutTaskWindowOpacity"]) {
        [self applyNoLagSettings];
        [self applyMacOSWindowChrome];
        return;
    }

    if ([keyPath isEqualToString:@"LCMultitaskBottomWindowBar"]) {
        BOOL bottomWindowBar = [change[NSKeyValueChangeNewKey] boolValue];
        UIStackView *stack = [self containerStackView];
        if (bottomWindowBar) {
            [stack addArrangedSubview:self.navigationBar];
        } else {
            [stack insertArrangedSubview:self.navigationBar atIndex:0];
        }

        [self applyVerticalConstraintsAnimated:![self isNoLagEnabled]];
        [self adjustNavigationBarButtonSpacingWithNegativeSpacing:-12.0 rightMargin:-6.0];

        if (_isMaximized) {
            __weak typeof(self) weakSelf = self;
            [self.appSceneVC updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
                [weakSelf updateMaximizedFrameWithSettings:settings];
            }];
        }
    }
}

- (void)moveWindow:(UIPanGestureRecognizer *)sender {
    if (_isMaximized) return;

    UIView *hostView = self.view.superview ?: self.view;
    CGPoint point = [sender translationInView:hostView];
    [sender setTranslation:CGPointZero inView:hostView];

    self.view.center = CGPointMake(self.view.center.x + point.x, self.view.center.y + point.y);

    if (sender.state == UIGestureRecognizerStateEnded || sender.state == UIGestureRecognizerStateCancelled) {
        [self updateOriginalFrame];
    }
}

- (void)resizeWindow:(UIPanGestureRecognizer *)sender {
    if (_isMaximized) return;

    CGPoint point = [sender translationInView:self.view];
    [sender setTranslation:CGPointZero inView:self.view];

    CGRect frame = self.view.frame;
    frame.size.width = MAX(kMinWindowDimensions.width, frame.size.width + point.x);
    frame.size.height = MAX(kMinWindowDimensions.height, frame.size.height + point.y);
    self.view.frame = frame;

    if (sender.state == UIGestureRecognizerStateEnded || sender.state == UIGestureRecognizerStateCancelled) {
        [self updateOriginalFrame];
    }
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    UIView *parent = self.view.superview;
    if (parent) {
        [parent bringSubviewToFront:self.view];
        _isActiveWindow = YES;
        [self applyMacOSWindowChrome];
    }
}

- (void)updateVerticalConstraints {
    [self applyVerticalConstraintsAnimated:![self isNoLagEnabled]];
}

- (void)applyVerticalConstraintsAnimated:(BOOL)animated {
    __weak typeof(self) weakSelf = self;
    void (^updateBlock)(void) = ^{
        BOOL bottomWindowBar = [[weakSelf outTaskDefaults] boolForKey:@"LCMultitaskBottomWindowBar"];
        BOOL hideWindowBar = MultitaskDockManager.shared.isCollapsed && weakSelf.isMaximized;
        CGFloat navBarHeight = hideWindowBar ? 0.0 : kCompactTabBarHeight;
        weakSelf.navigationBar.alpha = hideWindowBar ? 0.0 : 1.0;
        weakSelf.navigationBar.hidden = hideWindowBar;

        if (weakSelf.isMaximized) {
            weakSelf.appSceneVC.shouldSkipDebounceOnce = YES;
            [weakSelf.appSceneVC updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
                [weakSelf updateMaximizedFrameWithSettings:settings];
            }];
        }

        [NSLayoutConstraint deactivateConstraints:weakSelf.activatedVerticalConstraints];
        if (bottomWindowBar) {
            weakSelf.activatedVerticalConstraints = @[
                [weakSelf.appSceneVC.view.topAnchor constraintEqualToAnchor:weakSelf.view.topAnchor],
                [weakSelf.appSceneVC.view.bottomAnchor constraintEqualToAnchor:weakSelf.view.bottomAnchor constant:-navBarHeight],
                [weakSelf.navigationBar.heightAnchor constraintEqualToConstant:navBarHeight]
            ];
        } else {
            weakSelf.activatedVerticalConstraints = @[
                [weakSelf.appSceneVC.view.topAnchor constraintEqualToAnchor:weakSelf.view.topAnchor constant:navBarHeight],
                [weakSelf.appSceneVC.view.bottomAnchor constraintEqualToAnchor:weakSelf.view.bottomAnchor],
                [weakSelf.navigationBar.heightAnchor constraintEqualToConstant:navBarHeight]
            ];
        }
        [NSLayoutConstraint activateConstraints:weakSelf.activatedVerticalConstraints];
        if (![weakSelf isNoLagEnabled]) {
            [weakSelf.view layoutIfNeeded];
        }
    };

    if (animated) {
        [UIView animateWithDuration:[self transitionDurationForStyle:0.2]
                              delay:0
                            options:UIViewAnimationOptionCurveEaseInOut
                         animations:updateBlock
                         completion:nil];
    } else {
        updateBlock();
    }
}

- (UIEdgeInsets)updateMaximizedSafeAreaWithSettings:(UIMutableApplicationSceneSettings *)settings {
    BOOL bottomWindowBar = [[self outTaskDefaults] boolForKey:@"LCMultitaskBottomWindowBar"];
    UIEdgeInsets safeAreaInsets = self.view.window ? self.view.window.safeAreaInsets : UIEdgeInsetsZero;
    if (self.navigationBar.hidden) {
        settings.peripheryInsets = safeAreaInsets;
        safeAreaInsets = UIEdgeInsetsZero;
    } else if (bottomWindowBar) {
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
        UIInterfaceOrientation currentOrientation = UIApp.statusBarOrientation;
        if (UIInterfaceOrientationIsLandscape(currentOrientation)) {
            safeAreaInsets.top = 0;
        }
        settings.safeAreaInsetsPortrait = LCUIEdgeInsetsRotateToOrientation(settings.peripheryInsets, currentOrientation);
    } else {
        settings.safeAreaInsetsPortrait = UIEdgeInsetsMake(settings.peripheryInsets.top,
                                                           settings.peripheryInsets.left,
                                                           settings.peripheryInsets.bottom,
                                                           settings.peripheryInsets.right);
    }

    safeAreaInsets.bottom = 0;
    return safeAreaInsets;
}

- (void)updateMaximizedFrameWithSettings:(UIMutableApplicationSceneSettings *)settings {
    if (!self.view.window) return;
    CGRect maxFrame = UIEdgeInsetsInsetRect(self.view.window.frame, [self updateMaximizedSafeAreaWithSettings:settings]);
    self.view.frame = maxFrame;
}

- (void)applyWindowedSceneSettings:(UIMutableApplicationSceneSettings *)settings {
    if (!self.view.window) return;
    UIEdgeInsets safeAreaInsets = self.view.window.safeAreaInsets;
    CGRect maxFrame = UIEdgeInsetsInsetRect(self.view.window.frame, safeAreaInsets);
    settings.peripheryInsets = UIEdgeInsetsZero;
    settings.safeAreaInsetsPortrait = UIEdgeInsetsZero;

    CGRect newFrame = CGRectMake(self.originalFrame.origin.x * maxFrame.size.width,
                                 self.originalFrame.origin.y * maxFrame.size.height,
                                 self.originalFrame.size.width,
                                 self.originalFrame.size.height);
    CGPoint center = self.view.center;
    CGRect frame = CGRectZero;
    frame.size.width = MIN(newFrame.size.width, maxFrame.size.width);
    frame.size.height = MIN(newFrame.size.height, maxFrame.size.height);
    CGFloat oobOffset = MAX(30.0, frame.size.width - 30.0);
    frame.origin.x = MAX(maxFrame.origin.x - oobOffset, MIN(CGRectGetMaxX(maxFrame) - frame.size.width + oobOffset, center.x - frame.size.width / 2.0));
    frame.origin.y = MAX(maxFrame.origin.y, MIN(center.y - frame.size.height / 2.0, CGRectGetMaxY(maxFrame) - frame.size.height));
    self.view.frame = frame;
}

- (void)updateWindowedFrameWithSettings:(UIMutableApplicationSceneSettings *)settings {
    [self applyWindowedSceneSettings:settings];
}

- (void)updateOriginalFrame {
    if (_isMaximized || !self.view.window) return;
    CGRect maxFrame = UIEdgeInsetsInsetRect(self.view.window.frame, self.view.window.safeAreaInsets);
    self.originalFrame = CGRectMake(self.view.frame.origin.x / MAX(1.0, maxFrame.size.width),
                                    self.view.frame.origin.y / MAX(1.0, maxFrame.size.height),
                                    self.view.frame.size.width,
                                    self.view.frame.size.height);
}

@end
