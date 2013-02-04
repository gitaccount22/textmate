#import "FindWindowController.h"
#import <OakAppKit/OakAppKit.h>
#import <OakAppKit/OakPasteboard.h>
#import <OakFoundation/OakFoundation.h>
#import <Preferences/Keys.h>

NSString* const FFSearchInDocument   = @"FFSearchInDocument";
NSString* const FFSearchInSelection  = @"FFSearchInSelection";
NSString* const FFSearchInOpenFiles  = @"FFSearchInOpenFiles";
NSString* const FFSearchInFolder     = @"FFSearchInFolder";

@interface OakAutoSizingTextField : NSTextField
@property (nonatomic) NSSize myIntrinsicContentSize;
@end

@implementation OakAutoSizingTextField
- (NSSize)intrinsicContentSize
{
	if(NSEqualSizes(self.myIntrinsicContentSize, NSZeroSize))
		return [super intrinsicContentSize];
	return self.myIntrinsicContentSize;
}
@end

static NSTextField* OakCreateLabel (NSString* label)
{
	NSTextField* res = [[[NSTextField alloc] initWithFrame:NSZeroRect] autorelease];
	res.font            = [NSFont controlContentFontOfSize:[NSFont labelFontSize]];
	res.stringValue     = label;
	res.bordered        = NO;
	res.editable        = NO;
	res.selectable      = NO;
	res.bezeled         = NO;
	res.drawsBackground = NO;
	return res;
}

static OakAutoSizingTextField* OakCreateTextField (id <NSTextFieldDelegate> delegate)
{
	OakAutoSizingTextField* res = [[[OakAutoSizingTextField alloc] initWithFrame:NSZeroRect] autorelease];
	res.font = [NSFont controlContentFontOfSize:0];
	[[res cell] setWraps:YES];
	res.delegate = delegate;
	return res;
}

static NSButton* OakCreateHistoryButton ()
{
	NSButton* res = [[[NSButton alloc] initWithFrame:NSZeroRect] autorelease];
	res.bezelStyle = NSRoundedDisclosureBezelStyle;
	res.buttonType = NSOnOffButton;
	res.title      = @"";
	return res;
}

static NSButton* OakCreateCheckBox (NSString* label)
{
	NSButton* res = [[[NSButton alloc] initWithFrame:NSZeroRect] autorelease];
	res.buttonType = NSSwitchButton;
	res.font       = [NSFont controlContentFontOfSize:0];
	res.title      = label;
	return res;
}

static NSPopUpButton* OakCreatePopUpButton ()
{
	NSPopUpButton* res = [[[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO] autorelease];
	res.font = [NSFont controlContentFontOfSize:0];
	[res.menu removeAllItems];
	[res.menu addItemWithTitle:@"Document" action:@selector(takeSearchFolderFrom:) keyEquivalent:@""];
	[res.menu addItemWithTitle:@"Selection" action:@selector(takeSearchFolderFrom:) keyEquivalent:@""];
	[res.menu addItem:[NSMenuItem separatorItem]];
	[res.menu addItemWithTitle:@"Open Files" action:@selector(takeSearchFolderFrom:) keyEquivalent:@""];
	[res.menu addItemWithTitle:@"Project Folder" action:@selector(takeSearchFolderFrom:) keyEquivalent:@""];
	[res.menu addItemWithTitle:@"Other Folder…" action:@selector(takeSearchFolderFrom:) keyEquivalent:@""];
	[res.menu addItem:[NSMenuItem separatorItem]];
	[res.menu addItemWithTitle:@"~" action:@selector(takeSearchFolderFrom:) keyEquivalent:@""];

	NSInteger tag = 0;
	for(NSMenuItem* item : [res.menu itemArray])
		item.tag = item.isSeparatorItem ? 0 : ++tag;

	return res;
}

static NSComboBox* OakCreateComboBox ()
{
	NSComboBox* res = [[[NSComboBox alloc] initWithFrame:NSZeroRect] autorelease];
	res.font = [NSFont controlContentFontOfSize:0];
	return res;
}

static NSOutlineView* OakCreateOutlineView ()
{
	NSOutlineView* res = [[[NSOutlineView alloc] initWithFrame:NSZeroRect] autorelease];
	res.focusRingType                      = NSFocusRingTypeNone;
	res.allowsMultipleSelection            = YES;
	res.autoresizesOutlineColumn           = NO;
	res.usesAlternatingRowBackgroundColors = YES;
	res.headerView                         = nil;

	NSTableColumn* tableColumn = [[[NSTableColumn alloc] initWithIdentifier:@"checkbox"] autorelease];
	NSButtonCell* dataCell = [[[NSButtonCell alloc] init] autorelease];
	dataCell.buttonType    = NSSwitchButton;
	dataCell.controlSize   = NSSmallControlSize;
	dataCell.imagePosition = NSImageOnly;
	dataCell.font          = [NSFont controlContentFontOfSize:[NSFont smallSystemFontSize]];
	tableColumn.dataCell = dataCell;
	tableColumn.width    = 50;
	[res addTableColumn:tableColumn];

	tableColumn = [[[NSTableColumn alloc] initWithIdentifier:@"match"] autorelease];
	NSTextFieldCell* cell = tableColumn.dataCell;
	cell.font = [NSFont controlContentFontOfSize:[NSFont smallSystemFontSize]];
	[res addTableColumn:tableColumn];

	res.rowHeight = 14;

	NSScrollView* scrollView = [[[NSScrollView alloc] initWithFrame:NSZeroRect] autorelease];
	scrollView.hasVerticalScroller   = YES;
	scrollView.hasHorizontalScroller = NO;
	scrollView.borderType            = NSNoBorder;
	scrollView.documentView          = res;

	return res;
}

static NSProgressIndicator* OakCreateProgressIndicator ()
{
	NSProgressIndicator* res = [[[NSProgressIndicator alloc] initWithFrame:NSZeroRect] autorelease];
	res.style                = NSProgressIndicatorSpinningStyle;
	res.controlSize          = NSSmallControlSize;
	res.displayedWhenStopped = NO;
	return res;
}

static NSButton* OakCreateButton (NSString* label, NSBezelStyle bezel = NSRoundedBezelStyle)
{
	NSButton* res = [[[NSButton alloc] initWithFrame:NSZeroRect] autorelease];
	res.buttonType = NSMomentaryPushInButton;
	res.bezelStyle = bezel;
	res.title      = label;
	res.font       = [NSFont controlContentFontOfSize:13];
	return res;
}

@interface FindWindowController () <NSTextFieldDelegate, NSWindowDelegate>
{
	BOOL _wrapAround;
	BOOL _ignoreCase;
}
@property (nonatomic, retain) NSTextField*              findLabel;
@property (nonatomic, retain) OakAutoSizingTextField*   findTextField;
@property (nonatomic, retain) NSButton*                 findHistoryButton;

@property (nonatomic, retain) NSButton*                 countButton;

@property (nonatomic, retain) NSTextField*              replaceLabel;
@property (nonatomic, retain) OakAutoSizingTextField*   replaceTextField;
@property (nonatomic, retain) NSButton*                 replaceHistoryButton;

@property (nonatomic, retain) NSTextField*              optionsLabel;
@property (nonatomic, retain) NSButton*                 ignoreCaseCheckBox;
@property (nonatomic, retain) NSButton*                 ignoreWhitespaceCheckBox;
@property (nonatomic, retain) NSButton*                 regularExpressionCheckBox;
@property (nonatomic, retain) NSButton*                 wrapAroundCheckBox;

@property (nonatomic, retain) NSTextField*              whereLabel;
@property (nonatomic, retain) NSPopUpButton*            wherePopUpButton;
@property (nonatomic, retain) NSTextField*              matchingLabel;
@property (nonatomic, retain) NSComboBox*               globTextField;

@property (nonatomic, retain) NSView*                   resultsActionBar;
@property (nonatomic, retain, readwrite) NSOutlineView* resultsOutlineView;

@property (nonatomic, retain) NSProgressIndicator*      progressIndicator;
@property (nonatomic, retain) NSTextField*              statusTextField;

@property (nonatomic, retain) NSButton*                 findAllButton;
@property (nonatomic, retain) NSButton*                 replaceAllButton;
@property (nonatomic, retain) NSButton*                 replaceAndFindButton;
@property (nonatomic, retain) NSButton*                 findPreviousButton;
@property (nonatomic, retain) NSButton*                 findNextButton;

@property (nonatomic, retain) NSObjectController*       objectController;

@property (nonatomic, assign)   BOOL                    folderSearch;
@property (nonatomic, readonly) BOOL                    canIgnoreWhitespace;
@property (nonatomic, readonly) BOOL                    canWrapAround;
@property (nonatomic, readonly) BOOL                    canChangeGlob;
@end

@implementation FindWindowController
+ (NSSet*)keyPathsForValuesAffectingCanIgnoreWhitespace { return [NSSet setWithObject:@"regularExpression"]; }
+ (NSSet*)keyPathsForValuesAffectingIgnoreWhitespace    { return [NSSet setWithObject:@"regularExpression"]; }
+ (NSSet*)keyPathsForValuesAffectingWrapAround          { return [NSSet setWithObject:@"folderSearch"]; }

- (id)init
{
	NSRect r = [[NSScreen mainScreen] visibleFrame];
	if((self = [super initWithWindow:[[NSPanel alloc] initWithContentRect:NSMakeRect(NSMidX(r)-100, NSMidY(r)+100, 200, 200) styleMask:(NSTitledWindowMask|NSClosableWindowMask|NSResizableWindowMask|NSMiniaturizableWindowMask) backing:NSBackingStoreBuffered defer:NO]]))
	{
		self.window.title             = @"Find";
		self.window.frameAutosaveName = @"Find";
		self.window.hidesOnDeactivate = NO;
		self.window.delegate          = self;

		self.findLabel                 = OakCreateLabel(@"Find:");
		self.findTextField             = OakCreateTextField(self);
		self.findHistoryButton         = OakCreateHistoryButton();
		self.countButton               = OakCreateButton(@"Σ", NSSmallSquareBezelStyle);

		self.replaceLabel              = OakCreateLabel(@"Replace:");
		self.replaceTextField          = OakCreateTextField(self);
		self.replaceHistoryButton      = OakCreateHistoryButton();

		self.optionsLabel              = OakCreateLabel(@"Options:");

		self.ignoreCaseCheckBox        = OakCreateCheckBox(@"Ignore Case");
		self.ignoreWhitespaceCheckBox  = OakCreateCheckBox(@"Ignore Whitespace");
		self.regularExpressionCheckBox = OakCreateCheckBox(@"Regular Expression");
		self.wrapAroundCheckBox        = OakCreateCheckBox(@"Wrap Around");

		self.whereLabel                = OakCreateLabel(@"In:");
		self.wherePopUpButton          = OakCreatePopUpButton();
		self.matchingLabel             = OakCreateLabel(@"matching");
		self.globTextField             = OakCreateComboBox();

		self.resultsOutlineView        = OakCreateOutlineView();

		self.progressIndicator         = OakCreateProgressIndicator();
		self.statusTextField           = OakCreateLabel(@"Found 1,234 results.");
		self.statusTextField.font      = [NSFont controlContentFontOfSize:[NSFont smallSystemFontSize]];

		self.findAllButton             = OakCreateButton(@"Find All");
		self.replaceAllButton          = OakCreateButton(@"Replace All");
		self.replaceAndFindButton      = OakCreateButton(@"Replace & Find");
		self.findPreviousButton        = OakCreateButton(@"Previous");
		self.findNextButton            = OakCreateButton(@"Next");

		self.findAllButton.action        = @selector(findAll:);
		self.replaceAllButton.action     = @selector(replaceAll:);
		self.replaceAndFindButton.action = @selector(replaceAndFind:);
		self.findPreviousButton.action   = @selector(findPrevious:);
		self.findNextButton.action       = @selector(findNext:);
		self.countButton.action          = @selector(countOccurrences:);

		self.objectController = [[[NSObjectController alloc] initWithContent:self] autorelease];

		[self.findTextField             bind:@"value"   toObject:_objectController withKeyPath:@"content.findString"          options:nil];
		[self.replaceTextField          bind:@"value"   toObject:_objectController withKeyPath:@"content.replaceString"       options:nil];

		[self.globTextField             bind:@"value"   toObject:_objectController withKeyPath:@"content.globString"          options:nil];
		[self.globTextField             bind:@"enabled" toObject:_objectController withKeyPath:@"content.folderSearch"        options:nil];

		[self.ignoreCaseCheckBox        bind:@"value"   toObject:_objectController withKeyPath:@"content.ignoreCase"          options:nil];
		[self.ignoreWhitespaceCheckBox  bind:@"value"   toObject:_objectController withKeyPath:@"content.ignoreWhitespace"    options:nil];
		[self.regularExpressionCheckBox bind:@"value"   toObject:_objectController withKeyPath:@"content.regularExpression"   options:nil];
		[self.wrapAroundCheckBox        bind:@"value"   toObject:_objectController withKeyPath:@"content.wrapAround"          options:nil];

		[self.ignoreWhitespaceCheckBox  bind:@"enabled" toObject:_objectController withKeyPath:@"content.canIgnoreWhitespace" options:nil];
		[self.wrapAroundCheckBox        bind:@"enabled" toObject:_objectController withKeyPath:@"content.folderSearch"        options:@{ NSValueTransformerNameBindingOption : NSNegateBooleanTransformerName }];

		[self.statusTextField           bind:@"value"   toObject:_objectController withKeyPath:@"content.statusString"        options:nil];

		NSDictionary* views = @{
			@"findLabel"         : self.findLabel,
			@"find"              : self.findTextField,
			@"findHistory"       : self.findHistoryButton,
			@"count"             : self.countButton,
			@"replaceLabel"      : self.replaceLabel,
			@"replace"           : self.replaceTextField,
			@"replaceHistory"    : self.replaceHistoryButton,

			@"optionsLabel"      : self.optionsLabel,
			@"regularExpression" : self.regularExpressionCheckBox,
			@"ignoreWhitespace"  : self.ignoreWhitespaceCheckBox,
			@"ignoreCase"        : self.ignoreCaseCheckBox,
			@"wrapAround"        : self.wrapAroundCheckBox,

			@"whereLabel"        : self.whereLabel,
			@"where"             : self.wherePopUpButton,
			@"matching"          : self.matchingLabel,
			@"glob"              : self.globTextField,

			@"resultsTopDivider"    : OakCreateHorizontalLine([NSColor colorWithCalibratedWhite:0.500 alpha:1]),
			@"results"              : [self.resultsOutlineView enclosingScrollView],
			@"resultsBottomDivider" : OakCreateHorizontalLine([NSColor colorWithCalibratedWhite:0.500 alpha:1]),

			@"busy"              : self.progressIndicator,
			@"status"            : self.statusTextField,

			@"findAll"           : self.findAllButton,
			@"replaceAll"        : self.replaceAllButton,
			@"replaceAndFind"    : self.replaceAndFindButton,
			@"previous"          : self.findPreviousButton,
			@"next"              : self.findNextButton,
		};

		NSView* contentView = self.window.contentView;
		for(NSView* view in [views allValues])
		{
			[view setTranslatesAutoresizingMaskIntoConstraints:NO];
			[contentView addSubview:view];
		}

		[contentView addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-(==20@100)-[findLabel]-[find(>=100)]"            options:0 metrics:nil views:views]];
		[contentView addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:[find]-(5)-[findHistory]-[count(==findHistory)]-|" options:NSLayoutFormatAlignAllTop metrics:nil views:views]];
		[contentView addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:[count(==21)]"                                     options:NSLayoutFormatAlignAllLeft|NSLayoutFormatAlignAllRight metrics:nil views:views]];
		[contentView addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-(==20@100)-[replaceLabel]-[replace]"             options:0 metrics:nil views:views]];
		[contentView addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:[replace]-(5)-[replaceHistory]"                    options:NSLayoutFormatAlignAllTop metrics:nil views:views]];
		[contentView addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|-[find]-[replace]"                                options:NSLayoutFormatAlignAllLeft|NSLayoutFormatAlignAllRight metrics:nil views:views]];

		[contentView addConstraint:[NSLayoutConstraint constraintWithItem:self.findLabel attribute:NSLayoutAttributeTop relatedBy:NSLayoutRelationEqual toItem:self.findTextField attribute:NSLayoutAttributeTop multiplier:1 constant:6]];
		[contentView addConstraint:[NSLayoutConstraint constraintWithItem:self.replaceLabel attribute:NSLayoutAttributeTop relatedBy:NSLayoutRelationEqual toItem:self.replaceTextField attribute:NSLayoutAttributeTop multiplier:1 constant:6]];

		[contentView addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-(==20@100)-[optionsLabel]-[regularExpression]-[ignoreWhitespace]-(>=20)-|" options:NSLayoutFormatAlignAllBaseline metrics:nil views:views]];
		[contentView addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:[ignoreCase(==regularExpression)]-[wrapAround(==ignoreWhitespace)]"      options:NSLayoutFormatAlignAllTop|NSLayoutFormatAlignAllBottom metrics:nil views:views]];
		[contentView addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:[replace]-[regularExpression]-[ignoreCase]"                              options:NSLayoutFormatAlignAllLeft metrics:nil views:views]];
		[contentView addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:[replace]-[ignoreWhitespace]-[wrapAround]"                               options:0 metrics:nil views:views]];

		[contentView addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-(==20@100)-[whereLabel]-[where]-[matching]" options:NSLayoutFormatAlignAllBaseline metrics:nil views:views]];
		[contentView addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:[matching]-[glob]"             options:0 metrics:nil views:views]];
		[contentView addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:[where]-(>=8)-[glob]"          options:NSLayoutFormatAlignAllTop metrics:nil views:views]];
		[contentView addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:[replace]-(>=20)-[glob]"       options:NSLayoutFormatAlignAllRight metrics:nil views:views]];
		[contentView addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:[ignoreCase]-[where]"          options:NSLayoutFormatAlignAllLeft metrics:nil views:views]];

		[contentView addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|[results(==resultsTopDivider,==resultsBottomDivider)]|"    options:0 metrics:nil views:views]];
		[contentView addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:[where]-[resultsTopDivider][results][resultsBottomDivider]" options:0 metrics:nil views:views]];

		[contentView addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-[busy]-[status]-|"           options:NSLayoutFormatAlignAllCenterY metrics:nil views:views]];
		[contentView addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:[resultsBottomDivider]-[busy]" options:0 metrics:nil views:views]];

		[contentView addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-[findAll]-[replaceAll]-(>=8)-[replaceAndFind]-[previous]-[next]-|" options:NSLayoutFormatAlignAllBottom metrics:nil views:views]];
		[contentView addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:[busy]-[findAll]-|" options:0 metrics:nil views:views]];

		NSView* keyViewLoop[] = { self.findTextField, self.replaceTextField, self.globTextField, self.countButton, self.regularExpressionCheckBox, self.ignoreWhitespaceCheckBox, self.ignoreCaseCheckBox, self.wrapAroundCheckBox, self.wherePopUpButton, self.resultsOutlineView, self.findAllButton, self.replaceAllButton, self.replaceAndFindButton, self.findPreviousButton, self.findNextButton };
		self.window.initialFirstResponder = keyViewLoop[0];
		for(size_t i = 0; i < sizeofA(keyViewLoop); ++i)
			keyViewLoop[i].nextKeyView = keyViewLoop[(i + 1) % sizeofA(keyViewLoop)];

		self.searchIn   = FFSearchInDocument;
		self.globString = @"*";

		// setup find/replace strings/options
		[self userDefaultsDidChange:nil];
		[self findClipboardDidChange:nil];
		[self replaceClipboardDidChange:nil];

		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(userDefaultsDidChange:) name:NSUserDefaultsDidChangeNotification object:[NSUserDefaults standardUserDefaults]];
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(findClipboardDidChange:) name:OakPasteboardDidChangeNotification object:[OakPasteboard pasteboardWithName:NSFindPboard]];
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(replaceClipboardDidChange:) name:OakPasteboardDidChangeNotification object:[OakPasteboard pasteboardWithName:NSReplacePboard]];
	}
	return self;
}

- (void)userDefaultsDidChange:(NSNotification*)aNotification
{
	self.ignoreCase = [[NSUserDefaults standardUserDefaults] boolForKey:kUserDefaultsFindIgnoreCase];
	self.wrapAround = [[NSUserDefaults standardUserDefaults] boolForKey:kUserDefaultsFindWrapAround];
}

- (void)findClipboardDidChange:(NSNotification*)aNotification
{
	OakPasteboardEntry* entry = [[OakPasteboard pasteboardWithName:NSFindPboard] current];
	self.findString        = entry.string ?: @"";
	self.fullWords         = entry.fullWordMatch;
	self.ignoreWhitespace  = entry.ignoreWhitespace;
	self.regularExpression = entry.regularExpression;
}

- (void)replaceClipboardDidChange:(NSNotification*)aNotification
{
	self.replaceString = [[[OakPasteboard pasteboardWithName:NSReplacePboard] current] string] ?: @"";
}

- (void)showWindow:(id)sender
{
	[super showWindow:sender];
	[self.window makeFirstResponder:self.findTextField];
}

- (void)dealloc
{
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[super dealloc];
}

- (BOOL)commitEditing
{
	id currentResponder = [[self window] firstResponder];
	id view = [currentResponder isKindOfClass:[NSTextView class]] ? [currentResponder delegate] : currentResponder;
	BOOL res = [self.objectController commitEditing];
	if([[self window] firstResponder] != currentResponder && view)
		[[self window] makeFirstResponder:view];

	// =====================
	// = Update Pasteboard =
	// =====================

	NSDictionary* newOptions = @{
		OakFindRegularExpressionOption : @(self.regularExpression),
		OakFindIgnoreWhitespaceOption  : @(self.ignoreWhitespace),
		OakFindFullWordsOption         : @(self.fullWords),
	};

	if(NSNotEmptyString(_findString))
	{
		OakPasteboardEntry* oldEntry = [[OakPasteboard pasteboardWithName:NSFindPboard] current];
		if(!oldEntry || ![oldEntry.string isEqualToString:_findString])
			[[OakPasteboard pasteboardWithName:NSFindPboard] addEntry:[OakPasteboardEntry pasteboardEntryWithString:_findString andOptions:newOptions]];
		else if(![oldEntry.options isEqualToDictionary:newOptions])
			oldEntry.options = newOptions;
	}

	if(_replaceString)
	{
		NSString* oldReplacement = [[[OakPasteboard pasteboardWithName:NSReplacePboard] current] string];
		if(!oldReplacement || ![oldReplacement isEqualToString:_replaceString])
			[[OakPasteboard pasteboardWithName:NSReplacePboard] addEntry:[OakPasteboardEntry pasteboardEntryWithString:_replaceString]];
	}

	return res;
}

- (void)windowDidResignKey:(NSNotification*)aNotification
{
	[self commitEditing];
}

- (void)windowWillClose:(NSNotification*)aNotification
{
	[self commitEditing];
}

- (void)takeSearchFolderFrom:(NSMenuItem*)menuItem
{
	switch([menuItem tag])
	{
		case 1: self.searchIn = FFSearchInDocument;  break;
		case 2: self.searchIn = FFSearchInSelection; break;
		case 3: self.searchIn = FFSearchInOpenFiles; break;
		case 4: self.searchIn = FFSearchInFolder;    break;
		case 5: self.searchIn = FFSearchInFolder;    break;
	}
	self.searchFolder = [menuItem representedObject];
}

- (void)showPopoverWithString:(NSString*)aString
{
	NSViewController* viewController = [[[NSViewController alloc] init] autorelease];
	NSTextField* textField = OakCreateLabel(aString);
	[textField sizeToFit];
	viewController.view = textField;

	NSPopover* popover = [[[NSPopover alloc] init] autorelease];
	popover.behavior = NSPopoverBehaviorTransient;
	popover.contentViewController = viewController;
	[popover showRelativeToRect:NSZeroRect ofView:self.findTextField preferredEdge:NSMaxYEdge];

	[self.window makeFirstResponder:self.findTextField];
}

- (void)setBusy:(BOOL)busyFlag
{
	if(_busy != busyFlag)
	{
		if(_busy = busyFlag)
				[self.progressIndicator startAnimation:self];
		else	[self.progressIndicator stopAnimation:self];
	}
}

- (void)setSearchIn:(NSString*)aString
{
	_searchIn = aString;
	self.folderSearch = ![@[ FFSearchInDocument, FFSearchInSelection ] containsObject:_searchIn];
}

- (void)setFolderSearch:(BOOL)flag
{
	_folderSearch = flag;
	self.findNextButton.keyEquivalent = flag ? @"" : @"\r";
	self.findAllButton.keyEquivalent  = flag ? @"\r" : @"";
}

- (NSString*)findString    { [self commitEditing]; return _findString; }
- (NSString*)replaceString { [self commitEditing]; return _replaceString; }
- (NSString*)globString    { [self commitEditing]; return _globString; }

- (void)setIgnoreCase:(BOOL)flag       { if(_ignoreCase != flag) [[NSUserDefaults standardUserDefaults] setObject:@(_ignoreCase = flag) forKey:kUserDefaultsFindIgnoreCase]; }
- (void)setWrapAround:(BOOL)flag       { if(_wrapAround != flag) [[NSUserDefaults standardUserDefaults] setObject:@(_wrapAround = flag) forKey:kUserDefaultsFindWrapAround]; }
- (BOOL)ignoreWhitespace               { return _ignoreWhitespace && self.canIgnoreWhitespace; }
- (BOOL)wrapAround                     { return _wrapAround && !self.folderSearch; }
- (BOOL)canIgnoreWhitespace            { return _regularExpression == NO; }

- (void)controlTextDidChange:(NSNotification*)aNotification
{
	OakAutoSizingTextField* textField = [aNotification object];
	NSDictionary* userInfo = [aNotification userInfo];
	NSTextView* textView = userInfo[@"NSFieldEditor"];

	if(textView && textField)
	{
		NSTextFieldCell* cell = [[textField.cell copy] autorelease];
		cell.stringValue = textView.string;

		NSRect bounds = [textField bounds];
		bounds.size.height = CGFLOAT_MAX;
		bounds.size = [cell cellSizeForBounds:bounds];

		textField.myIntrinsicContentSize = NSMakeSize(NSViewNoInstrinsicMetric, NSHeight(bounds));
		[textField invalidateIntrinsicContentSize];
	}
}
@end
