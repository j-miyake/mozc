// Copyright 2010, Google Inc.
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//     * Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above
// copyright notice, this list of conditions and the following disclaimer
// in the documentation and/or other materials provided with the
// distribution.
//     * Neither the name of Google Inc. nor the names of its
// contributors may be used to endorse or promote products derived from
// this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#import "mac/GoogleJapaneseInputController.h"

#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#import <InputMethodKit/IMKServer.h>
#import <InputMethodKit/IMKInputController.h>

#include <unistd.h>
#include <stdlib.h>

#import "mac/GoogleJapaneseInputControllerInterface.h"
#import "mac/GoogleJapaneseInputServer.h"
#import "mac/KeyCodeMap.h"

#include "base/const.h"
#include "base/logging.h"
#include "base/mac_process.h"
#include "base/mac_util.h"
#include "base/mutex.h"
#include "base/process.h"
#include "base/util.h"
#include "client/session.h"
#include "ipc/ipc.h"
#include "renderer/renderer_client.h"
#include "session/commands.pb.h"
#include "session/config.pb.h"
#include "session/ime_switch_util.h"

using mozc::commands::Candidates;
using mozc::commands::Capability;
using mozc::commands::CompositionMode;
using mozc::commands::Input;
using mozc::commands::KeyEvent;
using mozc::commands::Output;
using mozc::commands::Preedit;
using mozc::commands::RendererCommand;
using mozc::commands::SessionCommand;
using mozc::config::Config;
using mozc::config::ImeSwitchUtil;
using mozc::kProductNameInEnglish;
using mozc::once_t;
using mozc::CallOnce;
using mozc::MacProcess;

namespace {
// set of bundle IDs of applications on which Mozc should not open urls.
NSSet *gNoOpenLinkApps = nil;
// The mapping from the CompositionMode enum to the actual id string
// of composition modes.
const map<CompositionMode, NSString *> *gModeIdMap = NULL;
NSSet *gNoSelectedRangeApps = nil;

NSString *GetLabelForSuffix(const string &suffix) {
  string label = mozc::MacUtil::GetLabelForSuffix(suffix);
  return [[NSString stringWithUTF8String:label.c_str()] retain];
}

CompositionMode GetCompositionMode(NSString *modeID) {
  if (modeID == NULL) {
    LOG(ERROR) << "modeID could not be initialized.";
    return mozc::commands::DIRECT;
  }

  // The name of direct input mode.  This name is determined at
  // Info.plist.  We don't use com.google... instead of
  // com.apple... because of a hack for Java Swing applications like
  // JEdit.  If we use our own IDs for those modes, such applications
  // work incorrectly for some reasons.
  //
  // The document for ID names is available at:
  // http://developer.apple.com/legacy/mac/library/documentation/Carbon/
  // Reference/Text_Services_Manager/Reference/reference.html
  if ([modeID isEqual:@"com.apple.inputmethod.Roman"]) {
    // TODO(komatsu): This should be mozc::commands::HALF_ASCII, when
    // we can handle the difference between the direct mode and the
    // half ascii mode.
    DLOG(INFO) << "com.apple.inputmethod.Roman";
    return mozc::commands::HALF_ASCII;
  }

  if ([modeID isEqual:@"com.apple.inputmethod.Japanese.Katakana"]) {
    DLOG(INFO) << "com.apple.inputmethod.Japanese.Katakana";
    return mozc::commands::FULL_KATAKANA;
  }

  if ([modeID isEqual:@"com.apple.inputmethod.Japanese.HalfWidthKana"]) {
    DLOG(INFO) << "com.apple.inputmethod.Japanese.HalfWidthKana";
    return mozc::commands::HALF_KATAKANA;
  }

  if ([modeID isEqual:@"com.apple.inputmethod.Japanese.FullWidthRoman"]) {
    DLOG(INFO) << "com.apple.inputmethod.Japanese.FullWidthRoman";
    return mozc::commands::FULL_ASCII;
  }

  if ([modeID isEqual:@"com.apple.inputmethod.Japanese"]) {
    DLOG(INFO) << "com.apple.inputmethod.Japanese";
    return mozc::commands::HIRAGANA;
  }

  LOG(ERROR) << "The code should not reach here.";
  return mozc::commands::DIRECT;
}

}  // anonymous namespace


@implementation GoogleJapaneseInputController
#pragma mark accessors for testing
@synthesize keyCodeMap = keyCodeMap_;
@synthesize yenSignCharacter = yenSignCharacter_;
@synthesize mode = mode_;
@synthesize rendererCommand = rendererCommand_;
@synthesize replacementRange = replacementRange_;
- (mozc::client::SessionInterface *)session {
  return session_;
}
- (void)setSession:(mozc::client::SessionInterface *)newSession {
  delete session_;
  session_ = newSession;
}
- (mozc::renderer::RendererInterface *)renderer {
  return candidateController_;
}
- (void)setRenderer:(mozc::renderer::RendererInterface *)newRenderer {
  delete candidateController_;
  candidateController_ = newRenderer;
}


#pragma mark object init/dealloc
// Initializer designated in IMKInputController. see:
// http://developer.apple.com/documentation/Cocoa/Reference/IMKInputController_Class/

- (id)initWithServer:(IMKServer *)server
            delegate:(id)delegate
              client:(id)inputClient {
  self = [super initWithServer:server delegate:delegate client:inputClient];
  if (!self) {
    return self;
  }
  keyCodeMap_ = [[KeyCodeMap alloc] init];
  clientBundle_ = [[inputClient bundleIdentifier] copy];
  replacementRange_ = NSMakeRange(NSNotFound, 0);
  originalString_ = [[NSMutableString alloc] init];
  composedString_ = [[NSMutableAttributedString alloc] init];
  cursorPosition_ = NSNotFound;
  mode_ = mozc::commands::DIRECT;
  checkInputMode_ = YES;
  yenSignCharacter_ = mozc::config::Config::YEN_SIGN;
  candidateController_ = new(nothrow) mozc::renderer::RendererClient;
  rendererCommand_ = new(nothrow)RendererCommand;
  session_ = new(nothrow) mozc::client::Session();
  server_ = reinterpret_cast<id<ServerCallback> >(server);

  // We don't check the return value of NSBundle because it fails during tests.
  [NSBundle loadNibNamed:@"Config" owner:self];
  if (!originalString_ || !composedString_ || !candidateController_ ||
      !rendererCommand_ || !session_) {
    [self release];
    self = nil;
  } else {
    DLOG(INFO) << [[NSString stringWithFormat:@"initWithServer: %@ %@ %@",
                             server, delegate, inputClient] UTF8String];
    if (!candidateController_->Activate()) {
      LOG(ERROR) << "Cannot activate renderer";
      delete candidateController_;
      candidateController_ = NULL;
    }
    RendererCommand::ApplicationInfo *applicationInfo =
        rendererCommand_->mutable_application_info();
    applicationInfo->set_process_id(::getpid());
    // thread_id and receiver_handle are not used currently in Mac but
    // set some values to prevent warning.
    applicationInfo->set_thread_id(0);
    applicationInfo->set_receiver_handle(0);
  }

  return self;
}

- (void)dealloc {
  [keyCodeMap_ release];
  [originalString_ release];
  [composedString_ release];
  [clientBundle_ release];
  delete candidateController_;
  delete session_;
  delete rendererCommand_;
  DLOG(INFO) << "dealloc server";
  [super dealloc];
}

- (NSMenu*)menu {
  return menu_;
}

+ (void)initializeConstants {
  // should not open links during screensaver.
  gNoOpenLinkApps =
      [NSSet setWithObjects:@"com.apple.securityagent", nil];

  map<CompositionMode, NSString *> *newMap =
      new map<CompositionMode, NSString *>;
  (*newMap)[mozc::commands::DIRECT] = GetLabelForSuffix("Roman");
  (*newMap)[mozc::commands::HIRAGANA] = GetLabelForSuffix("base");
  (*newMap)[mozc::commands::FULL_KATAKANA] = GetLabelForSuffix("Katakana");
  (*newMap)[mozc::commands::HALF_ASCII] = GetLabelForSuffix("Roman");
  (*newMap)[mozc::commands::FULL_ASCII] = GetLabelForSuffix("FullWidthRoman");
  (*newMap)[mozc::commands::HALF_KATAKANA] =
      GetLabelForSuffix("FullWidthRoman");
  gModeIdMap = newMap;

  // Do not call selectedRange: method for the following applications
  // because it could lead to application crash.
  gNoSelectedRangeApps =
    [NSSet setWithObjects:@"com.microsoft.Excel",
           @"com.microsoft.Powerpoint",
           @"com.microsoft.Word",
           nil];
}

#pragma mark IMKStateSetting Protocol
// Currently it just ignores the following methods:
//   Modes, showPreferences, valueForTag
// They are described at
// http://developer.apple.com/documentation/Cocoa/Reference/IMKStateSetting_Protocol/

- (void)activateServer:(id)sender {
  [super activateServer:sender];
  [clientBundle_ release];
  clientBundle_ = [[sender bundleIdentifier] copy];
  checkInputMode_ = YES;
  if (rendererCommand_->visible() && candidateController_) {
    candidateController_->ExecCommand(*rendererCommand_);
  }
  [self handleConfig];
  [server_ setCurrentController:self];
  DLOG(INFO) << [[NSString stringWithFormat:
                             @"%s client (%@): activated for %@",
                           kProductNameInEnglish, self, sender] UTF8String];
  DLOG(INFO) << [[NSString stringWithFormat:
                             @"sender bundleID: %@", clientBundle_] UTF8String];
}

- (void)deactivateServer:(id)sender {
  RendererCommand clearCommand;
  clearCommand.set_type(RendererCommand::UPDATE);
  clearCommand.set_visible(false);
  clearCommand.clear_output();
  if (candidateController_) {
    candidateController_->ExecCommand(clearCommand);
  }
  DLOG(INFO) << [[NSString stringWithFormat:
                             @"%s client (%@): deactivated",
                           kProductNameInEnglish, self] UTF8String];
  DLOG(INFO) << [[NSString stringWithFormat:
                             @"sender bundleID: %@", clientBundle_] UTF8String];
  [super deactivateServer:sender];
}

- (NSUInteger)recognizedEvents:(id)sender {
  // Because we want to handle single Shift key pressing later, now I
  // turned on NSFlagsChanged also.
  return NSKeyDownMask | NSFlagsChangedMask;
}

// This method is called when a user changes the input mode.
- (void)setValue:(id)value forTag:(long)tag client:(id)sender {
  CompositionMode new_mode = GetCompositionMode(value);

  if (new_mode == mozc::commands::HALF_ASCII && [composedString_ length] == 0) {
    new_mode = mozc::commands::DIRECT;
  }

  [self switchMode:new_mode client:sender];
  [self handleConfig];
  [super setValue:value forTag:tag client:sender];
}


#pragma mark internal methods

- (void)handleConfig {
  // Get the config and set client-side behaviors
  Config config;
  if (!session_->GetConfig(&config)) {
    LOG(ERROR) << "Cannot obtain the current config";
    return;
  }

  InputMode input_mode = ASCII;
  if (config.preedit_method() == Config::KANA) {
    input_mode = KANA;
  }
  [keyCodeMap_ setInputMode:input_mode];
  yenSignCharacter_ = config.yen_sign_character();

  if (config.use_japanese_layout()) {
    // Apple does not have "Japanese" layout actually -- here sets
    // "US" layout, which means US-ASCII layout or JIS layout
    // depending on which type of keyboard is actually connected.
    [[self client] overrideKeyboardWithKeyboardNamed:@"com.apple.keylayout.US"];
  }
}

// Mode changes to direct and clean up the status.
- (void)switchModeToDirect:(id)sender {
  mode_ = mozc::commands::DIRECT;
  DLOG(INFO) << "Mode switch: HIRAGANA, KATAKANA, etc. -> DIRECT";
  KeyEvent keyEvent;
  Output output;
  keyEvent.set_special_key(mozc::commands::KeyEvent::OFF);
  session_->SendKey(keyEvent, &output);
  if (output.has_result()) {
    [self commitText:output.result().value().c_str() client:sender];
  }
  if ([composedString_ length] > 0) {
    [self updateComposedString:NULL];
    [self clearCandidates];
  }
}

// change the mode to the new mode and turn-on the IME if necessary.
- (void)switchModeInternal:(CompositionMode)new_mode {
  if (mode_ == mozc::commands::DIRECT) {
    // Input mode changes from direct to an active mode.
    DLOG(INFO) << "Mode switch: DIRECT -> HIRAGANA, KATAKANA, etc.";
    KeyEvent keyEvent;
    Output output;
    keyEvent.set_special_key(mozc::commands::KeyEvent::ON);
    session_->SendKey(keyEvent, &output);
  }

  if (mode_ != new_mode) {
    // Switch input mode.
    DLOG(INFO) << "Switch input mode.";
    SessionCommand command;
    command.set_type(mozc::commands::SessionCommand::SWITCH_INPUT_MODE);
    command.set_composition_mode(new_mode);
    Output output;
    session_->SendCommand(command, &output);
    mode_ = new_mode;
  }
}

- (void)switchMode:(CompositionMode)new_mode client:(id)sender {
  if (mode_ != mozc::commands::DIRECT && new_mode == mozc::commands::DIRECT) {
    [self switchModeToDirect:sender];
  } else if (new_mode != mozc::commands::DIRECT) {
    [self switchModeInternal:new_mode];
  }
}

- (void)switchDisplayMode {
  if (gModeIdMap == NULL) {
    LOG(ERROR) << "gModeIdMap is not initialized correctly.";
    return;
  }

  map<CompositionMode, NSString *>::const_iterator it = gModeIdMap->find(mode_);
  if (it == gModeIdMap->end()) {
    LOG(ERROR) << "mode: " << mode_ << " is invalid";
    return;
  }

  [[self client] selectInputMode:it->second];
}

- (void)commitText:(const char *)text client:(id)sender {
  if (text == NULL) {
    return;
  }

  [sender insertText:[NSString stringWithUTF8String:text]
    replacementRange:replacementRange_];
  replacementRange_ = NSMakeRange(NSNotFound, 0);
}

- (void)launchWordRegisterTool:(id)client {
  ::setenv(mozc::kWordRegisterEnvironmentName, "", 1);
  if (![gNoSelectedRangeApps containsObject:clientBundle_]) {
    NSRange selectedRange = [client selectedRange];
    if (selectedRange.location != NSNotFound &&
        selectedRange.length != NSNotFound) {
      NSString *text =
        [[client attributedSubstringFromRange:selectedRange] string];
     :: setenv(mozc::kWordRegisterEnvironmentName, [text UTF8String], 1);
    }
  }
  MacProcess::LaunchMozcTool("word_register_dialog");
}

- (void)processOutput:(const mozc::commands::Output *)output client:(id)sender {
  if (output == NULL) {
    return;
  }

  DLOG(INFO) << output->DebugString();
  if (output->has_url()) {
    NSString *url = [NSString stringWithUTF8String:output->url().c_str()];
    [self openLink:[NSURL URLWithString:url]];
  }

  if (output->has_result()) {
    [self commitText:output->result().value().c_str() client:sender];
  }

  [self updateComposedString:&(output->preedit())];
  [self updateCandidates:output];

  if (output->has_mode()) {
    CompositionMode new_mode = output->mode();
    // Do not allow HALF_ASCII with empty composition.  This should be
    // handled in the converter, but just in case.
    if (new_mode == mozc::commands::HALF_ASCII &&
        (!output->has_preedit() || output->preedit().segment_size() == 0)) {
      new_mode = mozc::commands::DIRECT;
      [self switchMode:new_mode client:sender];
    }
    if (new_mode != mode_) {
      mode_ = new_mode;
      [self switchDisplayMode];
    }
  }

  if (output->has_launch_tool_mode()) {
    switch (output->launch_tool_mode()) {
    case mozc::commands::Output::CONFIG_DIALOG:
      MacProcess::LaunchMozcTool("config_dialog");
      break;
    case mozc::commands::Output::DICTIONARY_TOOL:
      MacProcess::LaunchMozcTool("dictionary_tool");
      break;
    case mozc::commands::Output::WORD_REGISTER_DIALOG:
      [self launchWordRegisterTool:sender];
      break;
    default:
      // do nothing
      break;
    }
  }
}

#pragma mark Mozc Server methods


#pragma mark IMKServerInput Protocol
// Currently GoogleJapaneseInputController uses handleEvent:client:
// method to handle key events.  It does not support inputText:client:
// nor inputText:key:modifiers:client:.
// Because GoogleJapaneseInputController does not use IMKCandidates,
// the following methods are not needed to implement:
//   candidates
//
// The meaning of these methods are described at:
// http://developer.apple.com/documentation/Cocoa/Reference/IMKServerInput_Additions/

- (id)originalString:(id)sender {
  return originalString_;
}

- (void)updateComposedString:(const Preedit *)preedit {
  [composedString_
    deleteCharactersInRange:NSMakeRange(0, [composedString_ length])];
  cursorPosition_ = NSNotFound;
  if (preedit != NULL) {
    cursorPosition_ = preedit->cursor();
    for (size_t i = 0; i < preedit->segment_size(); ++i) {
      NSDictionary *highlightAttributes =
          [self markForStyle:kTSMHiliteSelectedConvertedText
                     atRange:NSMakeRange(NSNotFound, 0)];
      NSDictionary *underlineAttributes =
          [self markForStyle:kTSMHiliteConvertedText
                     atRange:NSMakeRange(NSNotFound, 0)];
      const Preedit::Segment& seg = preedit->segment(i);
      NSDictionary *attr = (seg.annotation() == Preedit::Segment::HIGHLIGHT)?
          highlightAttributes : underlineAttributes;
      NSString *seg_string =
          [NSString stringWithUTF8String:seg.value().c_str()];
      NSAttributedString *seg_attributed_string =
          [[[NSAttributedString alloc]
             initWithString:seg_string attributes:attr]
            autorelease];
      [composedString_ appendAttributedString:seg_attributed_string];
    }
  }
  if ([composedString_ length] == 0) {
    [originalString_ setString:@""];
    replacementRange_ = NSMakeRange(NSNotFound, 0);
  }

  // Make composed string visible to the client applications.
  [self updateComposition];
}

- (void)commitComposition:(id)sender {
  if ([composedString_ length] == 0) {
    DLOG(INFO) << "Nothing is committed.";
    return;
  }
  [self commitText:[[composedString_ string] UTF8String] client:sender];

  SessionCommand command;
  Output output;
  command.set_type(SessionCommand::SUBMIT);
  session_->SendCommand(command, &output);
  [self clearCandidates];
  [self updateComposedString:NULL];
}

- (id)composedString:(id)sender {
  return composedString_;
}

- (void)clearCandidates {
  rendererCommand_->set_type(RendererCommand::UPDATE);
  rendererCommand_->set_visible(false);
  rendererCommand_->clear_output();
  if (candidateController_) {
    candidateController_->ExecCommand(*rendererCommand_);
  }
}

// |selecrionRange| method is defined at IMKInputController class and
// means the position of cursor actually.
- (NSRange)selectionRange {
  return (cursorPosition_ == NSNotFound) ?
      [super selectionRange] : // default behavior defined at super class
      NSMakeRange(cursorPosition_, 0);
}

- (void)updateCandidates:(const Output *)output {
  if (output == NULL) {
    [self clearCandidates];
    return;
  }

  rendererCommand_->set_type(RendererCommand::UPDATE);
  rendererCommand_->mutable_output()->CopyFrom(*output);

  // The candidate window position is not recalculated if the
  // candidate already appears on the screen.  Therefore, if a user
  // moves client application window by mouse, candidate window won't
  // follow the move of window.  This is done because:
  //  - some applications like Emacs or Google Chrome don't return the
  //    cursor position correctly.  The candidate window moves
  //    frequently with those application, which irritates users.
  //  - Kotoeri does this too.
  if (!rendererCommand_->visible()) {
    NSRect preeditRect = NSZeroRect;
    [[self client] attributesForCharacterIndex:output->candidates().position()
                           lineHeightRectangle:&preeditRect];
    NSScreen *baseScreen = nil;
    NSRect baseFrame = NSZeroRect;
    for (baseScreen in [NSScreen screens]) {
      baseFrame = [baseScreen frame];
      if (baseFrame.origin.x == 0 && baseFrame.origin.y == 0) {
        break;
      }
    }
    int baseHeight = baseFrame.size.height;
    rendererCommand_->mutable_preedit_rectangle()->set_left(
        preeditRect.origin.x);
    rendererCommand_->mutable_preedit_rectangle()->set_top(
        baseHeight - preeditRect.origin.y - preeditRect.size.height);
    rendererCommand_->mutable_preedit_rectangle()->set_right(
        preeditRect.origin.x + preeditRect.size.width);
    rendererCommand_->mutable_preedit_rectangle()->set_bottom(
        baseHeight - preeditRect.origin.y);
  }

  rendererCommand_->set_visible(output->candidates().candidate_size() > 0);
  if (candidateController_) {
    candidateController_->ExecCommand(*rendererCommand_);
  }
}

- (void)openLink:(NSURL *)url {
  // Open a link specified by |url|.  Any opening link behavior should
  // call this method because it checks the capability of application.
  // On some application like login window of screensaver, opening
  // link behavior should not happen because it can cause some
  // security issues.
  if (!clientBundle_ || [gNoOpenLinkApps containsObject:clientBundle_]) {
    return;
  }
  [[NSWorkspace sharedWorkspace] openURL:url];
}

- (BOOL)handleEvent:(NSEvent *)event client:(id)sender {
  if ([event type] == NSCursorUpdate) {
    [self updateComposition];
    return NO;
  }
  if ([event type] != NSKeyDown && [event type] != NSFlagsChanged) {
    return NO;
  }

  if ([keyCodeMap_ isModeSwitchingKey:event]) {
    // Special hack for Eisu/Kana keys.  Sometimes those key events
    // come to this method but we should ignore them because some
    // applications like PhotoShop is stuck.
    return YES;
  }

  // Get the Mozc key event
  KeyEvent keyEvent;
  if (![keyCodeMap_ getMozcKeyCodeFromKeyEvent:event
                    toMozcKeyEvent:&keyEvent]) {
    // Modifier flags change (not submitted to the server yet), or
    // unsupported key pressed.
    return NO;
  }

  // If the key event is turn on event, the key event has to be sent
  // to the server anyway.
  if (mode_ == mozc::commands::DIRECT &&
      !ImeSwitchUtil::IsTurnOnInDirectMode(keyEvent)) {
    // Yen sign special hack: although the current mode is DIRECT,
    // backslash is sent instead of yen sign for JIS yen key with no
    // modifiers.  This behavior is based on the configuration.
    if ([event keyCode] == kVK_JIS_Yen &&
        [event modifierFlags] == 0 &&
        yenSignCharacter_ == mozc::config::Config::BACKSLASH) {
      [self commitText:"\\" client:sender];
      return YES;
    }
    return NO;
  }


  // Send the key event to the server actually
  Output output;

  if (isprint(keyEvent.key_code())) {
    [originalString_ appendFormat:@"%c", keyEvent.key_code()];
  }

  if (!session_->SendKey(keyEvent, &output)) {
    return NO;
  }

  [self processOutput:&output client:sender];
  return output.consumed();
}

#pragma mark callbacks
- (void)candidateClicked:(int)id {
  SessionCommand command;
  command.set_type(SessionCommand::SELECT_CANDIDATE);
  command.set_id(id);
  Output output;
  if (!session_->SendCommand(command, &output)) {
    return;
  }

  [self processOutput:&output client:[self client]];
}

- (IBAction)reconversionClicked:(id)sender {
  id client = [self client];
  NSRange selectedRange = NSMakeRange(NSNotFound, NSNotFound);
  if (![gNoSelectedRangeApps containsObject:clientBundle_]) {
    selectedRange = [client selectedRange];
  }
  if (selectedRange.location == NSNotFound ||
      selectedRange.length == NSNotFound) {
    // the application does not support reconversion.
    return;
  }

  DLOG(INFO) << selectedRange.location << ", " << selectedRange.length;
  NSAttributedString *text =
      [client attributedSubstringFromRange:selectedRange];
  SessionCommand command;
  Output output;
  command.set_type(SessionCommand::CONVERT_REVERSE);
  command.set_text([[text string] UTF8String]);
  if (session_->SendCommand(command, &output)) {
    replacementRange_ = selectedRange;
    [self processOutput:&output client:[self client]];
  }
}

- (IBAction)configClicked:(id)sender {
  MacProcess::LaunchMozcTool("config_dialog");
}

- (IBAction)dictionaryToolClicked:(id)sender {
  MacProcess::LaunchMozcTool("dictionary_tool");
}

- (IBAction)registerWordClicked:(id)sender {
  [self launchWordRegisterTool:[self client]];
}

- (IBAction)characterPadClicked:(id)sender {
  MacProcess::LaunchMozcTool("character_pad");
}

- (IBAction)aboutDialogClicked:(id)sender {
  MacProcess::LaunchMozcTool("about_dialog");
}

- (void)outputResult:(mozc::commands::Output *)output {
  if (output == NULL || !output->has_result()) {
    return;
  }
  [self commitText:output->result().value().c_str() client:[self client]];
}
@end
