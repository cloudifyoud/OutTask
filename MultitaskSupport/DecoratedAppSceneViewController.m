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
static const CGFloat kMacCornerRadius = 12.0;
static const CGSize kMinMacWindowSize = {280.0, 200.0};

@interface DecoratedAppSceneViewController ()
@property(nonatomic) NSArray<NSLayoutConstraint *> *activatedVerticalConstraints;
@property(nonatomic) NSString *dataUUID;
@property(nonatomic) int pid;
@property(nonatomic) CGRect originalFrame;
@property(nonatomic) UIBarButtonItem *maximizeButton;
@property(nonatomic) bool isAppTerminationRequested;
@property(nonatomic) BOOL isObservingDefaults;
@end

@implementation DecoratedAppSceneViewController

- (UIStackView *)rootStackView {
    return (UIStackView *)self.view;
}

- (void)dealloc {
    if (_isObservingDefaults) {
        [NSUserDefaults.lcSharedDefaults removeObserver:self forKeyPath:@"LCMultitaskBottomWindowBar"];
        _isObservingDefaults = NO;
    }
}

- (instancetype)initWindowName:(NSString *)windowName bundleId:(NSString *)bundleId dataUUID:(NSString *)dataUUID rootVC:(UIViewController *)rootVC {
    self = [super initWithNibName:nil bundle:nil];
    if (!self) return nil;

    self.view = [[UIStackView alloc] initWithFrame:CGRectZero];
    [MultitaskDockManager.shared.windowHostingView addSubview:self.view];
    [rootVC addChildViewController:self];

    _dataUUID = dataUUID;
    _scaleRatio = 1.0;
    _isMaximized = [NSUserDefaults.lcUserDefaults boolForKey:@"LCLaunchMultitaskMaximized"];
    _appSceneVC = [[AppSceneViewController alloc] initWithBundleId:bundleId dataUUID:dataUUID delegate:self];
    self.title = windowName;
    [self setupDecoratedView];

    [MultitaskDockManager.shared addRunningApp:windowName appUUID:dataUUID view:self.view];

    __weak typeof(self) weakSelf = self;
    NSArray<UIMenuElement *> *menuItems = @[
        [UIAction actionWithTitle:@"lc.multitask.copyPid".loc image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(UIAction * _Nonnull action) {
            UIPasteboard.generalPasteboard.string = @(weakSelf.appSceneVC.pid).stringValue;
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
        NSString *pidText = [NSString stringWithFormat:@"PID: %d", weakSelf.pid];
        return [UIMenu menuWithTitle:pidText children:menuItems];
    }];

    // macOS traffic lights (Red Close, Yellow Minimize, Green Zoom)
    UIImageConfiguration *trafficConfig = [UIImageSymbolConfiguration configurationWithPointSize:13.5 weight:UIImageSymbolWeightSemibold];

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

    // Left-to-right macOS order: Close -> Minimize -> Zoom
    self.navigationItem.leftBarButtonItems = @[closeButton, minimizeButton, self.maximizeButton];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf adjustNavigationBarButtonSpacingWithNegativeSpacing:-10.0 rightMargin:-4.0];
    });

    return self;
}

- (void)setupDecoratedView {
    BOOL isLandscape = UIInterfaceOrientationIsLandscape(UIApp.statusBarOrientation);
    CGRect frame = CGRectMake(0, 0, isLandscape ? 520.0 : 340.0, (isLandscape ? 340.0 : 520.0) + kMacTitleBarHeight);
    CGPoint rootViewCenter = self.view.superview ? self.view.superview.center : CGPointMake(200.0, 400.0);
    frame.origin = CGPointMake(rootViewCenter.x - frame.size.width / 2.0, rootViewCenter.y - frame.size.height / 2.0);

    if (_isMaximized && self.view.window) {
        CGRect maxFrame = UIEdgeInsetsInsetRect(self.view.window.frame, self.view.window.safeAreaInsets);
        frame.origin.x /= MAX(1.0, maxFrame.size.width);
        frame.origin.y /= MAX(1.0, maxFrame.size.height);
        self.originalFrame = frame;
    } else {
        self.view.frame = frame;
    }

    // Compact macOS-style title bar
    UINavigationBarAppearance *barAppearance = [[UINavigationBarAppearance alloc] init];
    [barAppearance configureWithDefaultBackground];
    barAppearance.titleTextAttributes = @{
        NSFontAttributeName: [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: UIColor.labelColor
    };

    UINavigationBar *navigationBar = [[UINavigationBar alloc] initWithFrame:CGRectMake(0, 0, self.view.frame.size.width, kMacTitleBarHeight)];
    navigationBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    navigationBar.standardAppearance = barAppearance;
    navigationBar.scrollEdgeAppearance = barAppearance;
    UINavigationItem *navigationItem = [[UINavigationItem alloc] initWithTitle:self.title];
    navigationBar.items = @[navigationItem];

    UIStackView *stack = [self rootStackView];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.backgroundColor = UIColor.systemBackgroundColor;
    stack.layer.cornerRadius = _isMaximized ? 0.0 : kMacCornerRadius;
    stack.layer.masksToBounds = YES;

    self.navigationBar = navigationBar;
    self.navigationItem = navigationBar.items.firstObject;
    if (!self.navigationBar.superview) {
        [stack addArrangedSubview:self.navigationBar];
    }

    CGRect contentFrame = CGRectMake(0, 0, self.view.frame.size.width, MAX(0.0, self.view.frame.size.height - kMacTitleBarHeight));
    UIView *fixedPositionContentView = [[UIView alloc] initWithFrame:contentFrame];
    fixedPositionContentView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    if ([NSUserDefaults.lcSharedDefaults boolForKey:@"LCMultitaskBottomWindowBar"]) {
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

    // Window drag gesture + macOS double-tap title bar to zoom
    UIPanGestureRecognizer *moveGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(moveWindow:)];
    moveGesture.minimumNumberOfTouches = 1;
    moveGesture.maximumNumberOfTouches = 1;
    [self.navigationBar addGestureRecognizer:moveGesture];

    UITapGestureRecognizer *zoomTapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(maximizeWindow)];
    zoomTapGesture.numberOfTapsRequired = 2;
    [self.navigationBar addGestureRecognizer:zoomTapGesture];
    [moveGesture requireGestureRecognizerToFail:zoomTapGesture];

    // Bottom-right resize corner handle
    UIPanGestureRecognizer *resizeGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(resizeWindow:)];
    resizeGesture.minimumNumberOfTouches = 1;
    resizeGesture.maximumNumberOfTouches = 1;
    self.resizeHandle = [[ResizeHandleView alloc] initWithFrame:CGRectMake(self.view.frame.size.width - 32.0,
                                                                           self.view.frame.size.height - 32.0,
                                                                           32.0, 32.0)];
    self.resizeHandle.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
    self.resizeHandle.alpha = _isMaximized ? 0.0 : 1.0;
    [self.resizeHandle addGestureRecognizer:resizeGesture];
    [self.view addSubview:self.resizeHandle];

    self.view.layer.borderWidth = _isMaximized ? 0.0 : 0.75;
    self.view.layer.borderColor = [UIColor separatorColor].CGColor;

    [self addChildViewController:_appSceneVC];
    [self.view insertSubview:_appSceneVC.view atIndex:0];
    _appSceneVC.view.translatesAutoresizingMaskIntoConstraints = NO;

    [self applyVerticalConstraintsAnimated:NO];
    [NSLayoutConstraint activateConstraints:@[
        [_appSceneVC.view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_appSceneVC.view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]
    ]];

    if (!_isObservingDefaults) {
        [NSUserDefaults.lcSharedDefaults addObserver:self forKeyPath:@"LCMultitaskBottomWindowBar" options:NSKeyValueObservingOptionNew context:NULL];
        _isObservingDefaults = YES;
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

    NSLayoutConstraint *sliderHeight = [slider.heightAnchor constraintEqualToConstant:40.0];
    sliderHeight.active = YES;

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
    [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
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
    [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        weakSelf.view.alpha = 0.0;
    } completion:^(BOOL finished) {
        if (finished) weakSelf.view.hidden = YES;
    }];
}

- (void)unminimizeWindowPiP {
    self.view.hidden = NO;
    __weak typeof(self) weakSelf = self;
    [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        weakSelf.view.alpha = 1.0;
    } completion:nil];
}

- (void)maximizeWindow {
    if (!self.view.window) return;
    __weak typeof(self) weakSelf = self;
    UIImageConfiguration *trafficConfig = [UIImageSymbolConfiguration configurationWithPointSize:13.5 weight:UIImageSymbolWeightSemibold];

    if (self.isMaximized) {
        CGRect maxFrame = UIEdgeInsetsInsetRect(self.view.window.frame, self.view.window.safeAreaInsets);
        CGRect restoredFrame = CGRectMake(self.originalFrame.origin.x * maxFrame.size.width,
                                          self.originalFrame.origin.y * maxFrame.size.height,
                                          self.originalFrame.size.width,
                                          self.originalFrame.size.height);
        self.isMaximized = NO;
        [self applyVerticalConstraintsAnimated:NO];

        [UIView animateWithDuration:0.24 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
            weakSelf.view.frame = restoredFrame;
            weakSelf.view.layer.borderWidth = 0.75;
            weakSelf.view.layer.cornerRadius = kMacCornerRadius;
            weakSelf.resizeHandle.alpha = 1.0;
            [weakSelf.appSceneVC updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
                [weakSelf applyWindowedFrameImmediatelyWithSettings:settings];
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

        [UIView animateWithDuration:0.24 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
            weakSelf.view.layer.borderWidth = 0.0;
            weakSelf.view.layer.cornerRadius = 0.0;
            weakSelf.resizeHandle.alpha = 0.0;
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
    BOOL skipTerminationScreen = [NSUserDefaults.lcSharedDefaults boolForKey:@"LCSkipTerminatedScreen"];
    BOOL isManual = _isAppTerminationRequested;
    if (isManual || skipTerminationScreen) {
        MultitaskDockManager *dock = [MultitaskDockManager shared];
        [dock removeRunningApp:self.dataUUID];

        self.view.layer.masksToBounds = NO;
        __weak typeof(self) weakSelf = self;
        [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
            weakSelf.view.alpha = 0.0;
            weakSelf.view.transform = CGAffineTransformMakeScale(0.92, 0.92);
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
            [weakSelf updateWindowedFrameWithSettings:settings];
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
    if (![keyPath isEqualToString:@"LCMultitaskBottomWindowBar"]) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }

    BOOL bottomWindowBar = [change[NSKeyValueChangeNewKey] boolValue];
    UIStackView *stack = [self rootStackView];
    if (bottomWindowBar) {
        [stack addArrangedSubview:self.navigationBar];
    } else {
        [stack insertArrangedSubview:self.navigationBar atIndex:0];
    }

    [self applyVerticalConstraintsAnimated:YES];
    [self adjustNavigationBarButtonSpacingWithNegativeSpacing:-10.0 rightMargin:-4.0];

    if (_isMaximized) {
        __weak typeof(self) weakSelf = self;
        [self.appSceneVC updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
            [weakSelf updateMaximizedFrameWithSettings:settings];
        }];
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
    frame.size.width = MAX(kMinMacWindowSize.width, frame.size.width + point.x);
    frame.size.height = MAX(kMinMacWindowSize.height, frame.size.height + point.y);
    self.view.frame = frame;

    if (sender.state == UIGestureRecognizerStateEnded || sender.state == UIGestureRecognizerStateCancelled) {
        [self updateOriginalFrame];
    }
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    [self.view.superview bringSubviewToFront:self.view];
}

- (void)updateVerticalConstraints {
    [self applyVerticalConstraintsAnimated:YES];
}

- (void)applyVerticalConstraintsAnimated:(BOOL)animated {
    __weak typeof(self) weakSelf = self;
    void (^updateBlock)(void) = ^{
        BOOL bottomWindowBar = [NSUserDefaults.lcSharedDefaults boolForKey:@"LCMultitaskBottomWindowBar"];
        BOOL hideWindowBar = MultitaskDockManager.shared.isCollapsed && weakSelf.isMaximized;
        CGFloat navBarHeight = hideWindowBar ? 0.0 : kMacTitleBarHeight;
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
        [weakSelf.view layoutIfNeeded];
    };

    if (animated) {
        [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:updateBlock completion:nil];
    } else {
        updateBlock();
    }
}

- (UIEdgeInsets)updateMaximizedSafeAreaWithSettings:(UIMutableApplicationSceneSettings *)settings {
    BOOL bottomWindowBar = [NSUserDefaults.lcSharedDefaults boolForKey:@"LCMultitaskBottomWindowBar"];
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

- (CGRect)computedWindowedFrameWithSettings:(UIMutableApplicationSceneSettings *)settings {
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
    return frame;
}

- (void)applyWindowedFrameImmediatelyWithSettings:(UIMutableApplicationSceneSettings *)settings {
    if (!self.view.window) return;
    self.view.frame = [self computedWindowedFrameWithSettings:settings];
}

- (void)updateWindowedFrameWithSettings:(UIMutableApplicationSceneSettings *)settings {
    if (!self.view.window) return;
    CGRect frame = [self computedWindowedFrameWithSettings:settings];
    [UIView animateWithDuration:0.22 animations:^{
        self.view.frame = frame;
    }];
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
