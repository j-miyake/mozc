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

// Session manager of Mozc server.

#ifndef MOZC_SESSION_SESSION_HANDLER_H_
#define MOZC_SESSION_SESSION_HANDLER_H_

#include <map>
#include <string>
#include <utility>

#include "base/base.h"
#include "session/common.h"
#include "session/session_handler_interface.h"
#include "storage/lru_cache.h"

namespace mozc {
class SessionWatchDog;
class Stopwatch;

namespace commands {
class Command;
} // namespace commands

namespace keymap {
class KeyMapManager;
}  // namespace keymap

namespace session {
class SessionObserverHandler;
class SessionObserverInterface;
class Session;
}  // namespace session

class SessionHandler : public SessionHandlerInterface {
 public:
  SessionHandler();
  virtual ~SessionHandler();

  // Returns true if SessionHandle is available.
  virtual bool IsAvailable() const;

  virtual bool EvalCommand(commands::Command *command);

  // Starts watch dog timer to cleanup sessions.
  virtual bool StartWatchDog();

  // NewSession returns new Sessoin.
  // Client needs to delete it properly
  session::Session *NewSession();

  virtual void AddObserver(session::SessionObserverInterface *observer);

 private:
  // Reload settings which are managed by SessionHandler
  void ReloadSession();

  bool CreateSession(commands::Command *command);
  bool DeleteSession(commands::Command *command);
  bool TestSendKey(commands::Command *command);
  bool SendKey(commands::Command *command);
  bool SendCommand(commands::Command *command);
  bool SyncData(commands::Command *command);
  bool ClearUserHistory(commands::Command *command);
  bool ClearUserPrediction(commands::Command *command);
  bool ClearUnusedUserPrediction(commands::Command *command);
  bool Shutdown(commands::Command *command);
  bool Reload(commands::Command *command);
  bool GetConfig(commands::Command *command);
  bool SetConfig(commands::Command *command);
  bool Cleanup(commands::Command *command);
  bool NoOperation(commands::Command *command);

  SessionID CreateNewSessionID();
  bool DeleteSessionID(SessionID id);

  typedef LRUCache<SessionID, session::Session*> SessionMap;
  typedef LRUCache<SessionID, session::Session*>::Element SessionElement;
  scoped_ptr<SessionMap> session_map_;
  scoped_ptr<keymap::KeyMapManager> keymap_;
  scoped_ptr<SessionWatchDog> session_watch_dog_;
  bool is_available_;
  int keyevent_counter_;
  uint32 max_session_size_;
  uint64 last_session_empty_time_;
  uint64 last_cleanup_time_;
  uint64 last_create_session_time_;

  scoped_ptr<session::SessionObserverHandler> observer_handler_;
  scoped_ptr<Stopwatch> stopwatch_;

  DISALLOW_COPY_AND_ASSIGN(SessionHandler);
};

}  // namespace mozc
#endif  // MOZC_SESSION_SESSION_HANDLER_H_
