#import "Find.h"
#import "FindWindowController.h"
#import "FFDocumentSearch.h"
#import "Strings.h"
#import "attr_string.h"
#import "FFFilePathCell.h"
#import <OakFoundation/OakFindProtocol.h>
#import <OakFoundation/NSArray Additions.h>
#import <OakFoundation/NSString Additions.h>
#import <OakAppKit/OakAppKit.h>
#import <OakAppKit/OakPasteboard.h>
#import <ns/ns.h>
#import <text/types.h>
#import <text/utf8.h>
#import <regexp/format_string.h>
#import <editor/editor.h>
#import "Strings.h"

OAK_DEBUG_VAR(Find_Base);

enum FindActionTag
{
	FindActionFindNext = 1,
	FindActionFindPrevious,
	FindActionCountMatches,
	FindActionFindAll,
	FindActionReplaceAll,
	FindActionReplaceAndFind,
	FindActionReplaceSelected,
};

@interface Find () <NSOutlineViewDataSource, NSOutlineViewDelegate>
@property (nonatomic, retain) FindWindowController* windowController;
@property (nonatomic, retain) FFDocumentSearch* documentSearch;
@property (nonatomic, assign) BOOL closeWindowOnSuccess;
@property (nonatomic, assign) BOOL previewReplacements;
@end

NSString* const FFFindWasTriggeredByEnter = @"FFFindWasTriggeredByEnter";
NSString* const FolderOptionsDefaultsKey  = @"Folder Search Options";

@implementation Find
+ (Find*)sharedInstance
{
	static Find* instance = [Find new];
	return instance;
}

- (id)init
{
	if(self = [super init])
	{
		D(DBF_Find_Base, bug("\n"););
		self.windowController = [[FindWindowController new] autorelease];
		[self.windowController setNextResponder:self];
		self.windowController.resultsOutlineView.dataSource = self;
		self.windowController.resultsOutlineView.delegate = self;

		if(NSDictionary* options = [[NSUserDefaults standardUserDefaults] objectForKey:FolderOptionsDefaultsKey])
		{
			self.windowController.followLinks         = [options objectForKey:@"followLinks"] != nil;
			self.windowController.searchHiddenFolders = [options objectForKey:@"searchHiddenFolders"] != nil;
		}

		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillTerminate:) name:NSApplicationWillTerminateNotification object:nil];
	}
	return self;
}

- (void)applicationWillTerminate:(NSNotification*)notification
{
	NSMutableDictionary* options = [NSMutableDictionary dictionary];
	if(self.windowController.followLinks)
		[options setObject:@YES forKey:@"followLinks"];
	if(self.windowController.searchHiddenFolders)
		[options setObject:@YES forKey:@"searchHiddenFolders"];
	[[NSUserDefaults standardUserDefaults] setObject:options forKey:FolderOptionsDefaultsKey];
}

// ====================================
// = Actions for displaying the panel =
// ====================================

- (IBAction)showFindPanel:(id)sender
{
	[self.windowController showWindow:self];
}

- (IBAction)showFolderSelectionPanel:(id)sender
{
	[self showFindPanel:sender]; // TODO
}

// ================
// = Find actions =
// ================

- (IBAction)countOccurrences:(id)sender { [self performFindAction:FindActionCountMatches   withWindowController:self.windowController]; }
- (IBAction)findAll:(id)sender          { [self performFindAction:FindActionFindAll        withWindowController:self.windowController]; }
- (IBAction)findNext:(id)sender         { NSLog(@"%s %@ %@", sel_getName(_cmd), NSStringFromRect([sender frame]), [sender font]); [self performFindAction:FindActionFindNext       withWindowController:self.windowController]; }
- (IBAction)findPrevious:(id)sender     { [self performFindAction:FindActionFindPrevious   withWindowController:self.windowController]; }
- (IBAction)replaceAll:(id)sender       { [self performFindAction:FindActionReplaceAll     withWindowController:self.windowController]; }
- (IBAction)replaceAndFind:(id)sender   { [self performFindAction:FindActionReplaceAndFind withWindowController:self.windowController]; }

- (void)performFindAction:(FindActionTag)action withWindowController:(FindWindowController*)controller
{
	if(controller.regularExpression)
	{
		std::string const& error = regexp::validate(to_s(controller.findString));
		if(error != NULL_STR)
		{
			[controller showPopoverWithString:[NSString stringWithCxxString:text::format("Invalid regular expression: %s.", error.c_str())]];
			return;
		}
	}

	_findOptions = (controller.regularExpression ? find::regular_expression : find::none) | (controller.ignoreWhitespace ? find::ignore_whitespace : find::none) | (controller.fullWords ? find::full_words : find::none) | (controller.ignoreCase ? find::ignore_case : find::none) | (controller.wrapAround ? find::wrap_around : find::none);
	if(action == FindActionFindPrevious)
		_findOptions |= find::backwards;
	else if(action == FindActionCountMatches || action == FindActionFindAll || action == FindActionReplaceAll)
		_findOptions |= find::all_matches;

	if([@[ FFSearchInDocument, FFSearchInSelection ] containsObject:controller.searchIn])
	{
		bool onlySelection = [controller.searchIn isEqualToString:FFSearchInSelection];
		switch(action)
		{
			case FindActionFindNext:
			case FindActionFindPrevious:
			case FindActionFindAll:       _findOperation = onlySelection ? kFindOperationFindInSelection    : kFindOperationFind;    break;
			case FindActionCountMatches:  _findOperation = onlySelection ? kFindOperationCountInSelection   : kFindOperationCount;   break;
			case FindActionReplaceAll:    _findOperation = onlySelection ? kFindOperationReplaceInSelection : kFindOperationReplace; break;
		}

		self.closeWindowOnSuccess = action == FindActionFindNext && [[NSApp currentEvent] type] == NSKeyDown && to_s([NSApp currentEvent]) == utf8::to_s(NSCarriageReturnCharacter);
		[NSApp sendAction:@selector(performFindOperation:) to:nil from:self];
	}
	else
	{
		switch(action)
		{
			case FindActionFindAll:
			{
				FFDocumentSearch* folderSearch = [[FFDocumentSearch new] autorelease];
				folderSearch.searchString      = controller.findString;
				folderSearch.options           = _findOptions;
				folderSearch.projectIdentifier = self.projectIdentifier;
				if(self.documentIdentifier && [controller.searchIn isEqualToString:FFSearchInDocument])
				{
					folderSearch.documentIdentifier = self.documentIdentifier;
				}
				else
				{
					path::glob_list_t globs;
					if(![controller.searchIn isEqualToString:FFSearchInOpenFiles])
					{
						auto const settings = settings_for_path(NULL_STR, "", to_s(self.searchFolder));
						globs.add_exclude_glob(settings.get(kSettingsExcludeDirectoriesInFolderSearchKey, NULL_STR), path::kPathItemDirectory);
						globs.add_exclude_glob(settings.get(kSettingsExcludeDirectoriesKey,               NULL_STR), path::kPathItemDirectory);
						globs.add_exclude_glob(settings.get(kSettingsExcludeFilesInFolderSearchKey,       NULL_STR), path::kPathItemFile);
						globs.add_exclude_glob(settings.get(kSettingsExcludeFilesKey,                     NULL_STR), path::kPathItemFile);
						for(auto key : { kSettingsExcludeInFolderSearchKey, kSettingsExcludeKey, kSettingsBinaryKey })
							globs.add_exclude_glob(settings.get(key, NULL_STR));
						globs.add_include_glob(controller.searchHiddenFolders ? "{,.}*" : "*", path::kPathItemDirectory);
						globs.add_include_glob(to_s(controller.globString), path::kPathItemFile);
					}

					find::folder_scan_settings_t search([controller.searchIn isEqualToString:FFSearchInOpenFiles] ? find::folder_scan_settings_t::open_files : to_s(self.searchFolder), globs, controller.followLinks);
					[folderSearch setFolderOptions:search];
				}
				self.documentSearch = folderSearch;
			}
			break;

			case FindActionReplaceAll:
			case FindActionReplaceSelected:
			{
				NSUInteger replaceCount = 0, fileCount = 0;
				std::string replaceString = to_s(controller.replaceString);
				for(FFMatch* fileMatch in [self.documentSearch allDocumentsWithSelectedMatches])
				{
					std::multimap<text::range_t, std::string> replacements;
					for(FFMatch* match in [self.documentSearch allSelectedMatchesForDocumentIdentifier:[fileMatch identifier]])
					{
						++replaceCount;
						replacements.insert(std::make_pair([match match].range, controller.regularExpression ? format_string::expand(replaceString, [match match].captures) : replaceString));
					}

					if(document::document_ptr doc = [fileMatch match].document)
					{
						if(doc->is_open())
								ng::editor_for_document(doc)->perform_replacements(replacements);
						else	doc->replace(replacements);
					}

					++fileCount;
				}
				self.documentSearch.hasPerformedReplacement = YES;
				self.windowController.statusString = [NSString stringWithFormat:MSG_REPLACE_ALL_RESULTS, replaceCount, fileCount];
			}
			break;

			case FindActionFindNext:     break; // TODO FindActionFindNext for folder searches
			case FindActionFindPrevious: break; // TODO FindActionFindPrevious for folder searches
		}
	}
}

- (NSString*)findString    { return self.windowController.findString;    }
- (NSString*)replaceString { return self.windowController.replaceString; }

- (void)didFind:(NSUInteger)aNumber occurrencesOf:(NSString*)aFindString atPosition:(text::pos_t const&)aPosition
{
	static std::string const formatStrings[4][3] = {
		{ "No more occurrences of “${found}”.", "Found “${found}”${line:+ at line ${line}, column ${column}}.",               "${count} occurrences of “${found}”." },
		{ "No more matches for “${found}”.",    "Found one match for “${found}”${line:+ at line ${line}, column ${column}}.", "${count} matches for “${found}”."    },
	};

	format_string::string_map_t variables;
	variables["count"]  = std::to_string(aNumber);
	variables["found"]  = to_s(aFindString);
	variables["line"]   = aPosition ? std::to_string(aPosition.line + 1)   : NULL_STR;
	variables["column"] = aPosition ? std::to_string(aPosition.column + 1) : NULL_STR;
	self.windowController.statusString = [NSString stringWithCxxString:format_string::expand(formatStrings[(_findOptions & find::regular_expression) ? 1 : 0][std::min<size_t>(aNumber, 2)], variables)];

	if(self.closeWindowOnSuccess && aNumber != 0)
		return [self.windowController close];
}

- (void)didReplace:(NSUInteger)aNumber occurrencesOf:(NSString*)aFindString with:(NSString*)aReplacementString
{
	static NSString* const formatStrings[2][3] = {
		{ @"Nothing replaced (no occurrences of “%@”).", @"Replaced one occurrence of “%@”.", @"Replaced %2$ld occurrences of “%@”." },
		{ @"Nothing replaced (no matches for “%@”).",    @"Replaced one match of “%@”.",      @"Replaced %2$ld matches of “%@”."     }
	};
	NSString* format = formatStrings[(_findOptions & find::regular_expression) ? 1 : 0][aNumber > 2 ? 2 : aNumber];
	self.windowController.statusString = [NSString stringWithFormat:format, aFindString, aNumber];
}

// =============
// = Accessors =
// =============

- (NSString*)projectFolder
{
	return self.windowController.projectFolder;
}

- (void)setProjectFolder:(NSString*)folder
{
	self.windowController.projectFolder = folder;
}

- (NSString*)searchFolder
{
	return self.windowController.searchFolder ?: self.windowController.projectFolder;
}

- (void)setSearchFolder:(NSString*)folder
{
	self.windowController.searchIn = folder;
}

- (int)searchScope
{
	if([self.windowController.searchIn isEqualToString:FFSearchInSelection])
		return find::in::selection;
	else if([self.windowController.searchIn isEqualToString:FFSearchInDocument])
		return find::in::document;
	else if([self.windowController.searchIn isEqualToString:FFSearchInOpenFiles])
		return find::in::open_files;
	return find::in::folder;
}

- (void)setSearchScope:(int)newSearchScope
{
	switch(newSearchScope)
	{
		case find::in::selection:  self.windowController.searchIn = FFSearchInSelection;                break;
		case find::in::document:   self.windowController.searchIn = FFSearchInDocument;                 break;
		case find::in::folder:     self.windowController.searchIn = self.windowController.searchFolder; break;
		case find::in::open_files: self.windowController.searchIn = FFSearchInOpenFiles;                break;
		default:
			ASSERTF(false, "Unknown search scope tag %d\n", newSearchScope);
	}
}

- (BOOL)isVisible
{
	return self.windowController.window.isVisible;
}

// ===========
// = Options =
// ===========

- (IBAction)takeFindOptionToToggleFrom:(id)sender
{
	ASSERT([sender respondsToSelector:@selector(tag)]);

	find::options_t option = find::options_t([sender tag]);
	switch(option)
	{
		case find::full_words:         self.windowController.fullWords         = !self.windowController.fullWords;         break;
		case find::ignore_case:        self.windowController.ignoreCase        = !self.windowController.ignoreCase;        break;
		case find::ignore_whitespace:  self.windowController.ignoreWhitespace  = !self.windowController.ignoreWhitespace;  break;
		case find::regular_expression: self.windowController.regularExpression = !self.windowController.regularExpression; break;
		case find::wrap_around:        self.windowController.wrapAround        = !self.windowController.wrapAround;        break;
		default:
			ASSERTF(false, "Unknown find option tag %d\n", option);
	}

	if([[[[OakPasteboard pasteboardWithName:NSFindPboard] current] string] isEqualToString:self.windowController.findString])
		[self.windowController commitEditing]; // update the options on the pasteboard immediately if the find string has not been changed
}

// ====================
// = Search in Folder =
// ====================

- (void)setDocumentSearch:(FFDocumentSearch*)newSearcher
{
	if(_documentSearch)
	{
		[_documentSearch removeObserver:self forKeyPath:@"currentPath"];
		[_documentSearch removeObserver:self forKeyPath:@"hasPerformedReplacement"];
		[[NSNotificationCenter defaultCenter] removeObserver:self name:FFDocumentSearchDidReceiveResultsNotification object:_documentSearch];
		[[NSNotificationCenter defaultCenter] removeObserver:self name:FFDocumentSearchDidFinishNotification object:_documentSearch];

		for(FFMatch* fileMatch in [_documentSearch allDocumentsWithMatches])
		{
			if(document::document_ptr doc = [fileMatch match].document)
				doc->remove_all_marks("search");
		}

		[_documentSearch release];
		_documentSearch = nil;
	}

	[self.windowController.resultsOutlineView reloadData];

	if(_documentSearch = [newSearcher retain])
	{
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(folderSearchDidReceiveResults:) name:FFDocumentSearchDidReceiveResultsNotification object:_documentSearch];
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(folderSearchDidFinish:) name:FFDocumentSearchDidFinishNotification object:_documentSearch];
		[_documentSearch addObserver:self forKeyPath:@"currentPath" options:(NSKeyValueObservingOptionNew|NSKeyValueObservingOptionOld) context:NULL];
		[_documentSearch addObserver:self forKeyPath:@"hasPerformedReplacement" options:0 context:NULL];
		[_documentSearch start];

		[self.windowController.resultsOutlineView deselectAll:nil];
		self.windowController.statusString = MSG_SEARCHING_FMT;
		self.windowController.busy = YES;
	}
}

- (void)folderSearchDidReceiveResults:(NSNotification*)notification
{
	int first = [self.windowController.resultsOutlineView numberOfRows];
	[self.windowController.resultsOutlineView reloadData];
	int last = [self.windowController.resultsOutlineView numberOfRows];
	while(last-- != first)
		[self.windowController.resultsOutlineView expandItem:[self.windowController.resultsOutlineView itemAtRow:last]];
	[self.windowController.resultsOutlineView sizeLastColumnToFit];
}

- (void)folderSearchDidFinish:(NSNotification*)notification
{
	self.windowController.busy = NO;
	if(!_documentSearch)
		return;

	for(FFMatch* fileMatch in [_documentSearch allDocumentsWithMatches])
	{
		if(document::document_ptr doc = [fileMatch match].document)
		{
			for(FFMatch* match in [_documentSearch allMatchesForDocumentIdentifier:[NSString stringWithCxxString:doc->identifier()]])
				doc->add_mark([match match].range, "search");
		}
	}

	NSUInteger totalMatches = [_documentSearch countOfMatches];
	NSString* fmt = MSG_ZERO_MATCHES_FMT;
	switch(totalMatches)
	{
		case 0:  fmt = MSG_ZERO_MATCHES_FMT;     break;
		case 1:  fmt = MSG_ONE_MATCH_FMT;        break;
		default: fmt = MSG_MULTIPLE_MATCHES_FMT; break;
	}

	NSNumberFormatter* formatter = [[NSNumberFormatter new] autorelease]; // FIXME we want to cache this as it is expensive
	[formatter setPositiveFormat:@"#,##0"];
	[formatter setLocalizesFormat:YES];

	NSString* msg = [NSString localizedStringWithFormat:fmt, [_documentSearch searchString], [formatter stringFromNumber:@(totalMatches)]];
	if(!_documentSearch.documentIdentifier)
		msg = [msg stringByAppendingFormat:([_documentSearch scannedFileCount] == 1 ? MSG_SEARCHED_FILES_ONE : MSG_SEARCHED_FILES_MULTIPLE), [formatter stringFromNumber:@([_documentSearch scannedFileCount])], [_documentSearch searchDuration]];

	self.windowController.statusString = msg;
}
#if 0
- (void)folderSearchDidFinish:(NSNotification*)aNotification
{
	FFDocumentSearch* obj = [aNotification object];
	NSMutableArray* documents = [NSMutableArray array];
	for(FFMatch* fileMatch in [obj allDocumentsWithMatches])
	{
		if(document::document_ptr doc = [fileMatch match].document)
		{
			NSArray* matches    = [obj allMatchesForDocumentIdentifier:[NSString stringWithCxxString:doc->identifier()]];
			FFMatch* firstMatch = [matches firstObject];
			FFMatch* lastMatch  = [matches lastObject];
			if(firstMatch && lastMatch)
			{
				[documents addObject:@{
					@"path"            : firstMatch.path,
					@"identifier"      : [NSString stringWithCxxString:doc->identifier()],
					@"firstMatchRange" : [NSString stringWithCxxString:[firstMatch match].range],
					@"lastMatchRange"  : [NSString stringWithCxxString:[lastMatch match].range],
				}];
			}
		}
	}
	[OakPasteboard pasteboardWithName:NSFindPboard].auxiliaryOptionsForCurrent = @{ @"documents" : documents };
}
#endif
- (void)observeValueForKeyPath:(NSString*)keyPath ofObject:(id)object change:(NSDictionary*)change context:(void*)context
{
	if([keyPath isEqualToString:@"currentPath"])
	{
		id newValue = [change objectForKey:NSKeyValueChangeNewKey], oldValue = [change objectForKey:NSKeyValueChangeOldKey];
		std::string searchPath     = [newValue respondsToSelector:@selector(UTF8String)] ? [newValue UTF8String] : "";
		std::string lastSearchPath = [oldValue respondsToSelector:@selector(UTF8String)] ? [oldValue UTF8String] : "";

		// Show only the directory part unless the file name hasn’t changed since last poll of the scanner
		if(searchPath != lastSearchPath && !path::is_directory(searchPath))
			searchPath = path::parent(searchPath);

		std::string relative = path::relative_to(searchPath, to_s(NSHomeDirectory()));
		if(path::is_directory(searchPath))
			relative += "/";

		self.windowController.statusString = [NSString localizedStringWithFormat:MSG_SEARCHING_FOLDER_FMT, [NSString stringWithCxxString:relative]];
	}
	else if([keyPath isEqualToString:@"hasPerformedReplacement"])
	{
		[self.windowController.resultsOutlineView reloadData];
	}
}

// ============================
// = Outline view data source =
// ============================

- (NSInteger)outlineView:(NSOutlineView*)outlineView numberOfChildrenOfItem:(id)item
{
	if(_documentSearch.hasPerformedReplacement)
			return item ? 1 : [[_documentSearch allDocumentsWithSelectedMatches] count];
	else	return [(item ? [_documentSearch allMatchesForDocumentIdentifier:[item identifier]] : [_documentSearch allDocumentsWithMatches]) count];
}

- (BOOL)outlineView:(NSOutlineView*)outlineView isItemExpandable:(id)item
{
	return [self outlineView:outlineView isGroupItem:item];
}

- (id)outlineView:(NSOutlineView*)outlineView child:(NSInteger)childIndex ofItem:(id)item
{
	if(item)
		return [[_documentSearch allMatchesForDocumentIdentifier:[item identifier]] objectAtIndex:childIndex];
	else if(_documentSearch.hasPerformedReplacement)
		return [[_documentSearch allDocumentsWithSelectedMatches] objectAtIndex:childIndex];
	else
		return [[_documentSearch allDocumentsWithMatches] objectAtIndex:childIndex];
}

static NSAttributedString* AttributedStringForMatch (std::string const& text, size_t from, size_t to, size_t n)
{
	ns::attr_string_t str;
	str.add(ns::style::line_break(NSLineBreakByTruncatingTail));
	str.add([NSColor darkGrayColor]);
	str.add([NSFont systemFontOfSize:11]);

	str.add(text::pad(++n, 4) + ": ");

	bool inMatch = false;
	size_t last = text.size();
	for(size_t it = 0; it != last; )
	{
		size_t eol = std::find(text.begin() + it, text.end(), '\n') - text.begin();

		if(oak::cap(it, from, eol) == from)
		{
			str.add(text.substr(it, from-it));
			it = from;
			inMatch = true;
		}

		if(inMatch)
		{
			str.add([NSFont boldSystemFontOfSize:11]);
			str.add([NSColor blackColor]);
		}

		if(inMatch && oak::cap(it, to, eol) == to)
		{
			str.add(text.substr(it, to-it));
			it = to;
			inMatch = false;

			str.add([NSColor darkGrayColor]);
			str.add([NSFont systemFontOfSize:11]);
		}

		str.add(text.substr(it, eol-it));

		if(eol != last)
		{
			str.add("¬");

			if(inMatch)
			{
				str.add([NSFont systemFontOfSize:11]);
				str.add([NSColor darkGrayColor]);
			}

			if(++eol == to)
				inMatch = false;

			if(eol != last)
				str.add("\n" + text::pad(++n, 4) + ": ");
		}

		it = eol;
	}

	return str;
}

- (id)outlineView:(NSOutlineView*)outlineView objectValueForTableColumn:(NSTableColumn*)tableColumn byItem:(id)item
{
	if([self outlineView:outlineView isGroupItem:item])
	{
		return item;
	}
	else if([[tableColumn identifier] isEqualToString:@"checkbox"])
	{
		return @(![_documentSearch skipReplacementForMatch:item]);
	}
	else if([[tableColumn identifier] isEqualToString:@"match"])
	{
		if(_documentSearch.hasPerformedReplacement)
		{
			NSUInteger count = [[_documentSearch allSelectedMatchesForDocumentIdentifier:[item identifier]] count];
			return [NSString stringWithFormat:@"%lu occurence%s replaced.", count, count == 1 ? "" : "s"];
		}
		else if([(FFMatch*)item match].binary)
		{
			ns::attr_string_t res;
			res = ns::attr_string_t([NSColor darkGrayColor])
			    << ns::style::line_break(NSLineBreakByTruncatingTail)
			    << "(binary file)";
			return res.get();
		}
		else
		{
			find::match_t const& m = [(FFMatch*)item match];
			std::string str = [(FFMatch*)item matchText];

			size_t from = std::min<size_t>(m.first - m.bol_offset, str.size());
			size_t to   = std::min<size_t>(m.last  - m.bol_offset, str.size());

			std::string prefix = str.substr(0, from);
			std::string middle = str.substr(from, to - from);
			std::string suffix = str.substr(to);

			if(!suffix.empty() && suffix[suffix.size()-1] == '\n')
				suffix = suffix.substr(0, suffix.size()-1);

			if(utf8::is_valid(prefix.begin(), prefix.end()) && utf8::is_valid(middle.begin(), middle.end()) && utf8::is_valid(suffix.begin(), suffix.end()))
			{
				if(self.previewReplacements && ![_documentSearch skipReplacementForMatch:item])
					middle = self.windowController.regularExpression ? format_string::expand(to_s(self.replaceString), m.captures) : to_s(self.replaceString);
				return AttributedStringForMatch(prefix + middle + suffix, prefix.size(), prefix.size() + middle.size(), m.range.from.line);
			}
			else
			{
				ns::attr_string_t res;
				res = ns::attr_string_t([NSColor darkGrayColor])
				    << ns::style::line_break(NSLineBreakByTruncatingTail)
				    << text::format("%ld-%ld: (file has changed, re-run the search)", m.first, m.last);
				return res.get();
			}
		}
	}
	return nil;
}

- (void)outlineView:(NSOutlineView*)outlineView setObjectValue:(id)objectValue forTableColumn:(NSTableColumn*)tableColumn byItem:(id)item
{
	if(![tableColumn.identifier isEqualToString:@"checkbox"])
		return;

	if(OakIsAlternateKeyOrMouseEvent())
	{
		// Toggle all flags for the file
		for(FFMatch* match in [_documentSearch allMatchesForDocumentIdentifier:[item identifier]])
			[_documentSearch setSkipReplacement:![objectValue boolValue] forMatch:match];
		[outlineView reloadData];
	}
	else
	{
		[_documentSearch setSkipReplacement:![objectValue boolValue] forMatch:item];
	}
}

- (void)outlineView:(NSOutlineView*)outlineView willDisplayCell:(id)cell forTableColumn:(NSTableColumn*)tableColumn item:(id)item
{
	if([self outlineView:outlineView isGroupItem:item])
	{
		if(!tableColumn && [cell isKindOfClass:[FFFilePathCell class]])
		{
			FFFilePathCell* pathCell = (FFFilePathCell*)cell;
			pathCell.icon = [item icon];
			pathCell.path = [item path] ?: [NSString stringWithCxxString:[(FFMatch*)item match].document->display_name()];
			pathCell.base = NSHomeDirectory();
			pathCell.count = [outlineView isItemExpanded:item] ? 0 : [[_documentSearch allMatchesForDocumentIdentifier:[item identifier]] count];
		}
	}
	else if([[tableColumn identifier] isEqualToString:@"match"] && [cell isHighlighted])
	{
		id obj = [cell objectValue];
		if([obj isKindOfClass:[NSAttributedString class]])
		{
			NSMutableAttributedString* str = [[obj mutableCopy] autorelease];
			[str addAttribute:NSForegroundColorAttributeName value:[NSColor selectedTextColor] range:NSMakeRange(0, [str length])];
			[cell setAttributedStringValue:str];
		}
	}
}

- (BOOL)outlineView:(NSOutlineView*)outlineView isGroupItem:(id)item
{
	return [outlineView levelForItem:item] == 0;
}

- (CGFloat)outlineView:(NSOutlineView*)outlineView heightOfRowByItem:(id)item
{
	if([self outlineView:outlineView isGroupItem:item])
		return 22;

	size_t lines = 1;

	find::match_t const& m = [(FFMatch*)item match];
	if(!m.binary && !_documentSearch.hasPerformedReplacement)
	{
		size_t firstLine = m.range.from.line;
		size_t lastLine = m.range.to.line;
		if(firstLine == lastLine || m.range.to.column != 0)
			++lastLine;
		lines = (lastLine - firstLine);
	}

	return lines * [outlineView rowHeight];
}

- (NSCell*)outlineView:(NSOutlineView*)outlineView dataCellForTableColumn:(NSTableColumn*)tableColumn item:(id)item
{
	if(tableColumn == nil && [self outlineView:outlineView isGroupItem:item])
		return [[FFFilePathCell new] autorelease];
	return [tableColumn dataCell];
}
@end
