#pragma once

#include <wtypes.h>

#include <windows.h>
#include <atomic>
#include <chrono>
#include <functional>
#include <list>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
// GameInput v2 API (Microsoft.GameInput NuGet): v0 from the Windows SDK has
// no way to receive input while another app is in the foreground.
#include "gameinput/GameInput.h"
using namespace GameInput::v2;

struct Event {
  int time;
  std::string type;
  std::string key;
  double value;
};

// What listGamepads reports. A copy, so it stays valid after the pad is gone.
struct GamepadInfo {
  std::string id;
  std::string name;
  int vendor_id;
  int product_id;
};

// One connected device and the thread polling it. Owned by Gamepads; the
// reader thread is always joined before this is destroyed.
struct GamepadData {
  GamepadInfo info;
  // False for generic (DirectInput/HID) controllers GameInput has no gamepad
  // mapping for. They are read as raw buttons, axes and switches.
  bool is_gamepad = false;
  bool supports_rumble = false;
  IGameInputDevice* device = nullptr;  // One reference, released on destroy.
  std::atomic<bool> stop_thread{false};
  std::thread thread;

  // Rumble is set from the platform thread and expired by the reader thread.
  std::mutex rumble_mutex;
  bool rumble_active = false;
  std::chrono::steady_clock::time_point rumble_until;

  ~GamepadData();
};

// Both run on GameInput's callback thread or a reader thread, never the
// platform thread: they must not block and must not call into Flutter.
using GamepadEventEmitter =
    std::function<void(const GamepadInfo& gamepad, const Event& event)>;
using GamepadConnectionEmitter =
    std::function<void(const GamepadInfo& gamepad, bool connected)>;

class Gamepads {
 public:
  ~Gamepads();

  void init(GamepadEventEmitter event_emitter,
            GamepadConnectionEmitter connection_emitter);
  // Returns once no callback or reader thread is running and none will start.
  void stop();

  std::vector<GamepadInfo> get_gamepads();
  bool has_rumble(const std::string& id);
  // Replaces the current effect; zero intensities or duration stop it.
  bool set_rumble(const std::string& id,
                  double low,
                  double high,
                  int milliseconds);

 private:
  IGameInput* game_input_ = nullptr;
  GameInputCallbackToken device_callback_token_ = 0;

  std::mutex gamepads_mutex_;
  std::list<std::shared_ptr<GamepadData>> gamepads_;

  // Held while emitting, so stop() can clear the emitters and know no event
  // is still on its way out.
  std::mutex emit_mutex_;
  GamepadEventEmitter event_emitter_;
  GamepadConnectionEmitter connection_emitter_;

  void on_gamepad_connected(IGameInputDevice* device);
  void on_gamepad_disconnected(IGameInputDevice* device);
  std::shared_ptr<GamepadData> remove_gamepad(const std::string& id);
  std::shared_ptr<GamepadData> find_gamepad(const std::string& id);

  void read_gamepad(GamepadData* gamepad);
  void read_controller(GamepadData* gamepad);
  void expire_rumble(GamepadData* gamepad);
  void emit_event(const GamepadData* gamepad, const Event& event);
  void emit_connection(const GamepadInfo& gamepad, bool connected);
};
