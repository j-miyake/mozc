# Copyright 2010-2021, Google Inc.
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are
# met:
#
#     * Redistributions of source code must retain the above copyright
# notice, this list of conditions and the following disclaimer.
#     * Redistributions in binary form must reproduce the above
# copyright notice, this list of conditions and the following disclaimer
# in the documentation and/or other materials provided with the
# distribution.
#     * Neither the name of Google Inc. nor the names of its
# contributors may be used to endorse or promote products derived from
# this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
# "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
# LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
# A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
# OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
# SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
# LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
# DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
# THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

{
  'variables': {
    'relative_dir': 'unix/emacs',
  },
  'targets': [
    {
      'target_name': 'mozc_emacs_helper',
      'type': 'executable',
      'sources': [
        'mozc_emacs_helper.cc',
      ],
      'dependencies': [
        '<(mozc_src_dir)/base/absl.gyp:absl_strings',
        '<(mozc_src_dir)/base/base.gyp:base',
        '<(mozc_src_dir)/base/base.gyp:version',
        '<(mozc_oss_src_dir)/config/config.gyp:config_handler',
        '<(mozc_oss_src_dir)/ipc/ipc.gyp:ipc',
        '<(mozc_src_dir)/protocol/protocol.gyp:commands_proto',
        '<(mozc_src_dir)/protocol/protocol.gyp:config_proto',
        'mozc_emacs_helper_lib',
      ],
    },
    {
      'target_name': 'mozc_emacs_helper_lib',
      'type': 'static_library',
      'sources': [
        'mozc_emacs_helper_lib.cc',
        'client_pool.cc',
      ],
      'dependencies': [
        '<(mozc_src_dir)/base/absl.gyp:absl_strings',
        '<(mozc_src_dir)/base/base.gyp:base',
        '<(mozc_src_dir)/base/base.gyp:number_util',
        '<(mozc_oss_src_dir)/client/client.gyp:client',
        '<(mozc_oss_src_dir)/composer/composer.gyp:key_parser',
        '<(mozc_src_dir)/protocol/protocol.gyp:commands_proto',
        '<(mozc_src_dir)/protocol/protocol.gyp:config_proto',
        '<(mozc_oss_src_dir)/storage/storage.gyp:storage',
      ],
    },
    {
      'target_name': 'mozc_emacs_helper_lib_test',
      'type': 'executable',
      'sources': [
        'mozc_emacs_helper_lib_test.cc',
      ],
      'dependencies': [
        '<(mozc_src_dir)/base/absl.gyp:absl_strings',
        '<(mozc_oss_src_dir)/testing/testing.gyp:gtest_main',
        '<(mozc_oss_src_dir)/testing/testing.gyp:testing_util',
        'mozc_emacs_helper_lib',
      ],
      'variables': {
        'test_size': 'small',
      },
    },
    # Test cases meta target: this target is referred from gyp/tests.gyp
    {
      'target_name': 'emacs_all_test',
      'type': 'none',
      'dependencies': [
        'mozc_emacs_helper_lib_test',
      ],
    },
  ],
}
