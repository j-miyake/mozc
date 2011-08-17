// Copyright 2010-2011, Google Inc.
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

#include "rewriter/symbol_rewriter.h"

#include <algorithm>
#include <string>
#include <vector>
#include <set>

#include "base/base.h"
#include "base/singleton.h"
#include "base/util.h"
#include "config/config_handler.h"
#include "config/config.pb.h"
#include "converter/converter_interface.h"
#include "converter/segments.h"
#include "converter/character_form_manager.h"
#include "rewriter/rewriter_interface.h"
#include "rewriter/embedded_dictionary.h"
#include "session/commands.pb.h"

// SymbolRewriter:
// When updating the rule
// 1. Export the spreadsheet into TEXT (TSV)
// 2. Copy the TSV to mozc/data/symbol/symbol.tsv
// 3. Run symbol_rewriter_dictionary_generator_main in this directory
// 4. Make sure symbol_rewriter_data.h is correct

namespace mozc {

namespace {
// Try to start inserting symbols from this position
const size_t kOffsetSize = 3;
// Number of symbols which are inserted to first part
const size_t kMaxInsertToMedium = 15;
// Insert rest symbols from this position
const size_t kInsertRestSymbolsPos = 100;

#include "rewriter/symbol_rewriter_data.h"

class SymbolDictionary {
 public:
  SymbolDictionary()
      : dic_(new EmbeddedDictionary(kSymbolData_token_data,
                                    kSymbolData_token_size)) {}

  ~SymbolDictionary() {}

  EmbeddedDictionary *GetDictionary() const {
    return dic_.get();
  }

 private:
  scoped_ptr<EmbeddedDictionary> dic_;
};
} // namespace

// Some characters may have different description for full/half width forms.
// Here we just change the description in this function.
// If the symbol has description and additional description,
// Return merged description.
// TODO(taku): allow us to define two descriptions in *.tsv file
// static function
const string SymbolRewriter::GetDescription(
    const string &value,
    const char *description,
    const char *additional_description) {
  if (description == NULL) {
    return "";
  }
  if (value == "\x5C") {   // 0x5c
    // return "円記号,バックスラッシュ";
    return "\xE5\x86\x86\xE8\xA8\x98\xE5\x8F\xB7 "
        "\xE3\x83\x90\xE3\x83\x83\xE3\x82\xAF"
        "\xE3\x82\xB9\xE3\x83\xA9\xE3\x83\x83\xE3\x82\xB7\xE3\x83\xA5";
  }
  string result = description;
  // Merge description
  if (additional_description != NULL) {
    result.append("(");
    result.append(additional_description);
    result.append(")");
  }
  return result;
}

// return true key has no-hiragana
// static function
bool SymbolRewriter::IsSymbol(const string &key) {
  const char *begin  = key.data();
  const char *end = key.data() + key.size();
  while (begin < end) {
    size_t mblen = 0;
    const uint16 ucs2 = Util::UTF8ToUCS2(begin, end, &mblen);
    if (ucs2 >= 0x3041 && ucs2 <= 0x309F) {  // hiragana
      return false;
    }
    begin += mblen;
  }
  return true;
}

// static function
void SymbolRewriter::ExpandSpace(Segment *segment) {
  for (size_t i = 0; i < segment->candidates_size(); ++i) {
    if (segment->candidate(i).value == " ") {
      Segment::Candidate *c = segment->insert_candidate(i + 1);
      *c = segment->candidate(i);
      // "　"
      c->value = "\xe3\x80\x80";
      c->content_value = "\xe3\x80\x80";
      return;
    // "　"
    } else if (segment->candidate(i).value == "\xe3\x80\x80") {
      Segment::Candidate *c = segment->insert_candidate(i + 1);
      *c = segment->candidate(i);
      c->value = " ";
      c->content_value = " ";
      return;
    }
  }
}

// TODO(toshiyuki): Should we move this under Util module?
bool SymbolRewriter::IsPlatformDependent(
    const EmbeddedDictionary::Value &value) {
  if (value.value == NULL) {
    return false;
  }
  const Util::CharacterSet cset = Util::GetCharacterSet(value.value);
  return (cset >= Util::JISX0212);
}

// Return true if two symbols are in same group
// static function
bool SymbolRewriter::InSameSymbolGroup(const EmbeddedDictionary::Value &lhs,
                                       const EmbeddedDictionary::Value &rhs) {
  // "矢印記号", "矢印記号"
  // "ギリシャ(大文字)", "ギリシャ(小文字)"
  if (lhs.description == NULL || rhs.description == NULL) {
    return false;
  }
  const int cmp_len = max(strlen(lhs.description), strlen(rhs.description));
  if (strncmp(lhs.description, rhs.description, cmp_len) == 0) {
    return true;
  }
  return false;
}

// Insert Symbol into segment.
// static function
void SymbolRewriter::InsertCandidates(const EmbeddedDictionary::Value *value,
                                      size_t size,
                                      bool context_sensitive,
                                      Segment *segment) {
  if (segment->candidates_size() == 0) {
    LOG(WARNING) << "candiadtes_size is 0";
    return;
  }

  // work around for space.
  // space is not expanded in ExpandAlternative because it is not registered in
  // CharacterFormManager.
  // We do not want to make the form of spaces configurable, so we do not
  // register space to CharacterFormManager.
  ExpandSpace(segment);

  // If the original candidates given by ImmutableConveter already
  // include the target symbols, do assign description to these candidates.
  for (size_t i = 0; i < segment->candidates_size(); ++i) {
    Segment::Candidate *candidate = segment->mutable_candidate(i);
    string full_width_value, half_width_value;
    Util::HalfWidthToFullWidth(candidate->value, &full_width_value);
    Util::FullWidthToHalfWidth(candidate->value, &half_width_value);

    for (size_t j = 0; j < size; ++j) {
      if (candidate->value == value[j].value ||
          full_width_value == value[j].value ||
          half_width_value == value[j].value) {
        candidate->description =
            GetDescription(candidate->value,
                           value[j].description,
                           value[j].additional_description);
        break;
      }
    }
  }

  // Find the position wehere we start to insert the symbols
  // We want to skip the single-kanji we inserted by single-kanji rewriter.
  // We also skip transliterated key candidates.
  const Segment::Candidate &base_candidate = segment->candidate(0);
  size_t offset = min(kOffsetSize, segment->candidates_size());

  for (size_t i = offset; i < segment->candidates_size(); ++i) {
    const string &value = segment->candidate(i).value;
    if ((Util::CharsLen(value) == 1 &&
         Util::IsScriptType(value, Util::KANJI)) ||
        Util::IsScriptType(value, Util::HIRAGANA) ||
        Util::IsScriptType(value, Util::KATAKANA)) {
      ++offset;
    } else {
      break;
    }
  }

  size_t inserted_count = 0;
  bool finish_first_part = false;
  for (size_t i = 0; i < size; ++i) {
    Segment::Candidate *candidate = segment->insert_candidate(offset);
    DCHECK(candidate);

    candidate->Init();
    candidate->lid = value[i].lid;
    candidate->rid = value[i].rid;
    candidate->cost = base_candidate.cost;
    candidate->structure_cost = base_candidate.structure_cost;
    candidate->value = value[i].value;
    candidate->content_value = value[i].value;
    candidate->key = base_candidate.key;
    candidate->content_key = base_candidate.content_key;

    if (context_sensitive) {
      candidate->attributes |= Segment::Candidate::CONTEXT_SENSITIVE;
    }

    // they have two characters and the one of characters doesn't have
    // alternative character.
    if (candidate->value == "\xE2\x80\x9C\xE2\x80\x9D" ||  // "“”"
        candidate->value == "\xE2\x80\x98\xE2\x80\x99") {  // "‘’"
      candidate->attributes |= Segment::Candidate::NO_VARIANTS_EXPANSION;
    }

    candidate->description = GetDescription(candidate->value,
                                            value[i].description,
                                            value[i].additional_description);
    ++offset;
    ++inserted_count;

    // Insert to latter position
    // If number of rest symbols is small, insert current position.
    if (i + 1 < size &&
        !finish_first_part &&
        inserted_count >= kMaxInsertToMedium &&
        size - inserted_count >= 5 &&
        // Do not divide symbols which seem to be in the same group
        // providing that they are not platform dependent characters.
        (!InSameSymbolGroup(value[i], value[i + 1]) ||
         IsPlatformDependent(value[i + 1]))) {
      offset = segment->candidates_size();
      finish_first_part = true;
    }
  }
}

// static function
bool SymbolRewriter::RewriteEachCandidate(Segments *segments) {
  bool modified = false;
  for (size_t i = 0; i < segments->conversion_segments_size(); ++i) {
    const string &key = segments->conversion_segment(i).key();
    const EmbeddedDictionary::Token *token =
        Singleton<SymbolDictionary>::get()->GetDictionary()->Lookup(key);
    if (token == NULL) {
      continue;
    }

    // if key is symbol, no need to see the context
    const bool context_sensitive = !IsSymbol(key);

    InsertCandidates(token->value, token->value_size,
                     context_sensitive,
                     segments->mutable_conversion_segment(i));

    modified = true;
  }

  return modified;
}

// static function
bool SymbolRewriter::RewriteEntireCandidate(Segments *segments) {
  string key;
  for (size_t i = 0; i < segments->conversion_segments_size(); ++i) {
    key += segments->conversion_segment(i).key();
  }

  const EmbeddedDictionary::Token *token =
      Singleton<SymbolDictionary>::get()->GetDictionary()->Lookup(key);
  if (token == NULL) {
    return false;
  }

  if (segments->conversion_segments_size() > 1) {
    if (segments->resized()) {
      // the given segments are resized by user
      // so don't modify anymore
      return false;
    }
    // need to resize
    const size_t all_length = Util::CharsLen(key);
    const size_t first_length =
        Util::CharsLen(segments->conversion_segment(0).key());
    const int diff = static_cast<int>(all_length - first_length);
    if (diff > 0) {
      ConverterFactory::GetConverter()->ResizeSegment(segments, 0, diff);
    }
  } else {
    InsertCandidates(token->value, token->value_size,
                     false,   // not context sensitive
                     segments->mutable_conversion_segment(0));
  }

  return true;
}

SymbolRewriter::SymbolRewriter() {}

SymbolRewriter::~SymbolRewriter() {}

int SymbolRewriter::capability() const {
  return RewriterInterface::CONVERSION;
}

bool SymbolRewriter::Rewrite(Segments *segments) const {
  if (!GET_CONFIG(use_symbol_conversion)) {
    VLOG(2) << "no use_symbol_conversion";
    return false;
  }

  // apply entire candidate first, as we want to
  // find character combinations first, e.g.,
  // "－＞" -> "→"
  return (RewriteEntireCandidate(segments) ||
          RewriteEachCandidate(segments));
}
}  // namespace mozc
