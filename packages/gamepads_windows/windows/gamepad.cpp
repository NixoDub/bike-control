#include <algorithm>
#include <cmath>
#include <ctime>
#include <iomanip>
#include <iostream>
#include <memory>
#include <sstream>
#include <vector>

#include "gamepad.h"

// Exported by gameinput/GameInput.cpp. It loads the newest GameInput runtime
// available: the GameInputRedist.dll bundled next to the exe, or a newer one
// installed system-wide.
STDAPI GameInputInitialize(_In_ REFIID riid, _COM_Outptr_ LPVOID* ppv);

std::string get_button_name(uint32_t button) {
  switch (button) {
    case GameInputGamepadMenu:
      return "menu";
    case GameInputGamepadView:
      return "view";
    case GameInputGamepadA:
      return "a";
    case GameInputGamepadB:
      return "b";
    case GameInputGamepadX:
      return "x";
    case GameInputGamepadY:
      return "y";
    case GameInputGamepadDPadUp:
      return "dpadUp";
    case GameInputGamepadDPadDown:
      return "dpadDown";
    case GameInputGamepadDPadLeft:
      return "dpadLeft";
    case GameInputGamepadDPadRight:
      return "dpadRight";
    case GameInputGamepadLeftShoulder:
      return "leftShoulder";
    case GameInputGamepadRightShoulder:
      return "rightShoulder";
    case GameInputGamepadLeftThumbstick:
      return "leftThumbstick";
    case GameInputGamepadRightThumbstick:
      return "rightThumbstick";
  }
  return "button-" + std::to_string(button);
}

std::string AppLocalDeviceIdToString(const APP_LOCAL_DEVICE_ID& id) {
  std::ostringstream oss;
  oss << std::hex << std::setfill('0');
  for (size_t i = 0; i < APP_LOCAL_DEVICE_ID_SIZE; ++i) {
    oss << std::setw(2) << static_cast<int>(id.value[i]);
  }
  return oss.str();
}

std::list<Event> diff_states(const GameInputGamepadState& old,
                             const GameInputGamepadState& current) {
  std::time_t now = std::time(nullptr);
  int time = static_cast<int>(now);

  std::list<Event> events;
  if (old.leftThumbstickX != current.leftThumbstickX) {
    events.push_back(
        {time, "analog", "leftThumbstickX", current.leftThumbstickX});
  }
  if (old.leftThumbstickY != current.leftThumbstickY) {
    events.push_back(
        {time, "analog", "leftThumbstickY", current.leftThumbstickY});
  }
  if (old.rightThumbstickX != current.rightThumbstickX) {
    events.push_back(
        {time, "analog", "rightThumbstickX", current.rightThumbstickX});
  }
  if (old.rightThumbstickY != current.rightThumbstickY) {
    events.push_back(
        {time, "analog", "rightThumbstickY", current.rightThumbstickY});
  }
  if (old.leftTrigger != current.leftTrigger) {
    events.push_back({time, "analog", "leftTrigger", current.leftTrigger});
  }
  if (old.rightTrigger != current.rightTrigger) {
    events.push_back({time, "analog", "rightTrigger", current.rightTrigger});
  }
  if (old.buttons != current.buttons) {
    // While GameInputDeviceInfo.controllerButtonCount often gives 14,
    // if you install GameInput v3 redistributable, the reported
    // button count drops to zero. Button input is still reported.
    for (uint32_t i = 0; i < 14; ++i) {
      bool was_pressed = old.buttons & (1 << i);
      bool is_pressed = current.buttons & (1 << i);
      if (was_pressed != is_pressed) {
        double value = is_pressed ? 1.0 : 0.0;
        auto key = get_button_name(1 << i);
        events.push_back({time, "button", key, value});
      }
    }
  }
  return events;
}

bool are_states_different(const GameInputGamepadState& a,
                          const GameInputGamepadState& b) {
  return a.leftThumbstickX != b.leftThumbstickX ||
         a.leftThumbstickY != b.leftThumbstickY ||
         a.leftTrigger != b.leftTrigger ||
         a.rightThumbstickX != b.rightThumbstickX ||
         a.rightThumbstickY != b.rightThumbstickY ||
         a.rightTrigger != b.rightTrigger || a.buttons != b.buttons;
}


GamepadData::~GamepadData() {
  if (device != nullptr) {
    device->Release();
  }
}

Gamepads::~Gamepads() {
  stop();
}

void Gamepads::init(GamepadEventEmitter event_emitter,
                    GamepadConnectionEmitter connection_emitter) {
  {
    std::lock_guard<std::mutex> lock(emit_mutex_);
    event_emitter_ = std::move(event_emitter);
    connection_emitter_ = std::move(connection_emitter);
  }

  HRESULT hr = GameInputInitialize(IID_IGameInput,
                                   reinterpret_cast<void**>(&game_input_));
  if (FAILED(hr) || game_input_ == nullptr) {
    std::cerr << "GameInput init failed: 0x" << std::hex << hr << std::dec
              << std::endl;
    game_input_ = nullptr;
    return;
  }

  // GameInput only delivers input to the foreground app by default, which
  // makes a gamepad useless while the trainer app (Zwift, ...) has focus.
  game_input_->SetFocusPolicy(GameInputEnableBackgroundInput);

  // Controller also covers generic HID pads that GameInput can't map to a
  // gamepad (every gamepad is a controller too).
  game_input_->RegisterDeviceCallback(
      nullptr,  // All devices
      static_cast<GameInputKind>(GameInputKindGamepad | GameInputKindController),
      GameInputDeviceConnected, GameInputAsyncEnumeration,
      static_cast<void*>(this),
      [](_In_ GameInputCallbackToken callbackToken, _In_ void* context,
         _In_ IGameInputDevice* device, _In_ uint64_t timestamp,
         _In_ GameInputDeviceStatus currentStatus,
         _In_ GameInputDeviceStatus previousStatus) {
        auto* self = static_cast<Gamepads*>(context);
        if (currentStatus & GameInputDeviceConnected) {
          self->on_gamepad_connected(device);
        } else {
          self->on_gamepad_disconnected(device);
        }
      },
      &device_callback_token_);
}

void Gamepads::stop() {
  // Waits for a device callback that is already running, so none can add a
  // gamepad after the list is taken below.
  if (game_input_ != nullptr && device_callback_token_ != 0) {
    game_input_->UnregisterCallback(device_callback_token_);
    device_callback_token_ = 0;
  }
  {
    std::lock_guard<std::mutex> lock(emit_mutex_);
    event_emitter_ = nullptr;
    connection_emitter_ = nullptr;
  }

  std::list<std::shared_ptr<GamepadData>> stopping;
  {
    std::lock_guard<std::mutex> lock(gamepads_mutex_);
    stopping.swap(gamepads_);
  }
  for (auto& gamepad : stopping) {
    gamepad->stop_thread = true;
  }
  for (auto& gamepad : stopping) {
    if (gamepad->thread.joinable()) {
      gamepad->thread.join();
    }
  }
  stopping.clear();

  if (game_input_ != nullptr) {
    game_input_->Release();
    game_input_ = nullptr;
  }
}

std::vector<GamepadInfo> Gamepads::get_gamepads() {
  std::lock_guard<std::mutex> lock(gamepads_mutex_);
  std::vector<GamepadInfo> list;
  list.reserve(gamepads_.size());
  for (const auto& gamepad : gamepads_) {
    list.push_back(gamepad->info);
  }
  return list;
}

std::shared_ptr<GamepadData> Gamepads::find_gamepad(const std::string& id) {
  std::lock_guard<std::mutex> lock(gamepads_mutex_);
  for (const auto& gamepad : gamepads_) {
    if (gamepad->info.id == id) {
      return gamepad;
    }
  }
  return nullptr;
}

std::shared_ptr<GamepadData> Gamepads::remove_gamepad(const std::string& id) {
  std::lock_guard<std::mutex> lock(gamepads_mutex_);
  for (auto it = gamepads_.begin(); it != gamepads_.end(); ++it) {
    if ((*it)->info.id == id) {
      auto gamepad = *it;
      gamepads_.erase(it);
      return gamepad;
    }
  }
  return nullptr;
}

bool Gamepads::has_rumble(const std::string& id) {
  const auto gamepad = find_gamepad(id);
  return gamepad != nullptr && gamepad->supports_rumble;
}

bool Gamepads::set_rumble(const std::string& id,
                          double low,
                          double high,
                          int milliseconds) {
  if (!(low >= 0 && low <= 1 && high >= 0 && high <= 1) || milliseconds < 0 ||
      milliseconds > 30000) {
    return false;
  }
  const auto gamepad = find_gamepad(id);
  if (gamepad == nullptr || !gamepad->supports_rumble) {
    return false;
  }
  const bool stop = milliseconds == 0 || (low == 0 && high == 0);
  // Some GameInput runtimes dereference null rumble parameters: always pass
  // an explicit state, all zero to stop.
  GameInputRumbleParams params{};
  if (!stop) {
    params.lowFrequency = static_cast<float>(low);
    params.highFrequency = static_cast<float>(high);
  }
  std::lock_guard<std::mutex> lock(gamepad->rumble_mutex);
  gamepad->device->SetRumbleState(&params);
  gamepad->rumble_active = !stop;
  gamepad->rumble_until = std::chrono::steady_clock::now() +
                          std::chrono::milliseconds(milliseconds);
  return true;
}

// GameInput has no timed rumble, so the reader thread, which wakes every few
// milliseconds anyway, turns the motors off once the effect has run out.
void Gamepads::expire_rumble(GamepadData* gamepad) {
  std::lock_guard<std::mutex> lock(gamepad->rumble_mutex);
  if (gamepad->rumble_active &&
      (gamepad->stop_thread ||
       std::chrono::steady_clock::now() >= gamepad->rumble_until)) {
    const GameInputRumbleParams zero{};
    gamepad->device->SetRumbleState(&zero);
    gamepad->rumble_active = false;
  }
}

void Gamepads::emit_event(const GamepadData* gamepad, const Event& event) {
  std::lock_guard<std::mutex> lock(emit_mutex_);
  if (event_emitter_) {
    event_emitter_(gamepad->info, event);
  }
}

void Gamepads::emit_connection(const GamepadInfo& gamepad, bool connected) {
  std::lock_guard<std::mutex> lock(emit_mutex_);
  if (connection_emitter_) {
    connection_emitter_(gamepad, connected);
  }
}

void Gamepads::on_gamepad_connected(IGameInputDevice* device) {
  const GameInputDeviceInfo* info = nullptr;
  if (FAILED(device->GetDeviceInfo(&info)) || info == nullptr) {
    std::cerr << "Gamepad connected but failed to read info" << std::endl;
    return;
  }
  auto gp = std::make_shared<GamepadData>();
  gp->info.id = AppLocalDeviceIdToString(info->deviceId);
  gp->info.name = info->displayName != nullptr ? info->displayName : "";
  gp->info.vendor_id = static_cast<int>(info->vendorId);
  gp->info.product_id = static_cast<int>(info->productId);
  gp->is_gamepad = (info->supportedInput & GameInputKindGamepad) != 0;
  gp->supports_rumble =
      (info->supportedRumbleMotors &
       (GameInputRumbleLowFrequency | GameInputRumbleHighFrequency)) != 0;
  // The reading thread outlives this callback; keep the device alive for it.
  device->AddRef();
  gp->device = device;

  // A device that reconnects without a disconnect in between replaces its
  // old entry instead of getting a second reader.
  on_gamepad_disconnected(device);

  std::cout << "Gamepad connected: " << gp->info.id << " : " << gp->info.name
            << (gp->is_gamepad ? "" : " (generic controller)") << std::endl;

  GamepadData* raw = gp.get();
  gp->thread = std::thread([this, raw]() {
    if (raw->is_gamepad) {
      this->read_gamepad(raw);
    } else {
      this->read_controller(raw);
    }
  });
  {
    std::lock_guard<std::mutex> lock(gamepads_mutex_);
    gamepads_.push_back(gp);
  }
  emit_connection(gp->info, true);
}

void Gamepads::on_gamepad_disconnected(IGameInputDevice* device) {
  const GameInputDeviceInfo* info = nullptr;
  if (FAILED(device->GetDeviceInfo(&info)) || info == nullptr) {
    std::cerr << "Gamepad disconnected but failed to read info" << std::endl;
    return;
  }
  const auto gamepad = remove_gamepad(AppLocalDeviceIdToString(info->deviceId));
  if (gamepad == nullptr) {
    return;
  }
  std::cout << "Gamepad disconnected: " << gamepad->info.id << std::endl;
  // listGamepads no longer returns it; stop the reader before it is freed.
  gamepad->stop_thread = true;
  if (gamepad->thread.joinable()) {
    gamepad->thread.join();
  }
  emit_connection(gamepad->info, false);
}

void Gamepads::read_gamepad(GamepadData* gamepad) {
  GameInputGamepadState previous_state = {
      GameInputGamepadNone, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0};
  while (!gamepad->stop_thread) {
    IGameInputReading* reading = nullptr;
    if (SUCCEEDED(game_input_->GetCurrentReading(GameInputKindGamepad,
                                                 gamepad->device, &reading))) {
      GameInputGamepadState state;
      if (reading->GetGamepadState(&state)) {
        if (are_states_different(previous_state, state)) {
          for (const auto& event : diff_states(previous_state, state)) {
            emit_event(gamepad, event);
          }
        }
        previous_state = state;
      }
      reading->Release();
    }

    expire_rumble(gamepad);
    Sleep(8);
  }
  expire_rumble(gamepad);
}

// Directions (up, right, down, left) a hat switch position presses.
static const bool kSwitchDirections[][4] = {
    {false, false, false, false},  // GameInputSwitchCenter
    {true, false, false, false},   // GameInputSwitchUp
    {true, true, false, false},    // GameInputSwitchUpRight
    {false, true, false, false},   // GameInputSwitchRight
    {false, true, true, false},    // GameInputSwitchDownRight
    {false, false, true, false},   // GameInputSwitchDown
    {false, false, true, true},    // GameInputSwitchDownLeft
    {false, false, false, true},   // GameInputSwitchLeft
    {true, false, false, true},    // GameInputSwitchUpLeft
};
static const char* kDpadKeys[] = {"dpadUp", "dpadRight", "dpadDown",
                                  "dpadLeft"};

// Generic controllers have no fixed layout, so they emit raw keys:
// "button-N", "axis-N" (-1.0 to 1.0) and, for the first hat switch, the
// regular d-pad keys. Further hat switches emit "switchN-dpadUp" etc.
void Gamepads::read_controller(GamepadData* gamepad) {
  std::vector<bool> previous_buttons;
  std::vector<float> previous_axes;
  std::vector<GameInputSwitchPosition> previous_switches;
  bool has_previous = false;

  while (!gamepad->stop_thread) {
    IGameInputReading* reading = nullptr;
    if (SUCCEEDED(game_input_->GetCurrentReading(GameInputKindController,
                                                 gamepad->device, &reading))) {
      uint32_t button_count = reading->GetControllerButtonCount();
      std::unique_ptr<bool[]> button_state(new bool[button_count]());
      reading->GetControllerButtonState(button_count, button_state.get());
      std::vector<bool> buttons(button_state.get(),
                                button_state.get() + button_count);

      std::vector<float> axes(reading->GetControllerAxisCount());
      reading->GetControllerAxisState(static_cast<uint32_t>(axes.size()),
                                      axes.data());

      std::vector<GameInputSwitchPosition> switches(
          reading->GetControllerSwitchCount(), GameInputSwitchCenter);
      reading->GetControllerSwitchState(
          static_cast<uint32_t>(switches.size()), switches.data());
      reading->Release();

      // The first reading is the resting state: only report changes to it,
      // so e.g. a trigger axis resting at -1.0 doesn't fire on connect.
      if (!has_previous || buttons.size() != previous_buttons.size() ||
          axes.size() != previous_axes.size() ||
          switches.size() != previous_switches.size()) {
        previous_buttons = buttons;
        previous_axes = axes;
        previous_switches = switches;
        has_previous = true;
      } else {
        int time = static_cast<int>(std::time(nullptr));
        std::list<Event> events;
        for (size_t i = 0; i < buttons.size(); ++i) {
          if (buttons[i] != previous_buttons[i]) {
            events.push_back({time, "button", "button-" + std::to_string(i),
                              buttons[i] ? 1.0 : 0.0});
          }
        }
        for (size_t i = 0; i < axes.size(); ++i) {
          // Ignore sensor noise; axes are 0.0 to 1.0.
          if (std::abs(axes[i] - previous_axes[i]) >= 0.01f) {
            events.push_back({time, "analog", "axis-" + std::to_string(i),
                              axes[i] * 2.0 - 1.0});
            previous_axes[i] = axes[i];
          }
        }
        for (size_t i = 0; i < switches.size(); ++i) {
          if (switches[i] == previous_switches[i] ||
              switches[i] > GameInputSwitchUpLeft ||
              previous_switches[i] > GameInputSwitchUpLeft) {
            continue;
          }
          std::string prefix =
              i == 0 ? "" : "switch" + std::to_string(i) + "-";
          for (int d = 0; d < 4; ++d) {
            bool was_pressed = kSwitchDirections[previous_switches[i]][d];
            bool is_pressed = kSwitchDirections[switches[i]][d];
            if (was_pressed != is_pressed) {
              events.push_back({time, "button", prefix + kDpadKeys[d],
                                is_pressed ? 1.0 : 0.0});
            }
          }
        }
        previous_buttons = buttons;
        previous_switches = switches;

        for (const auto& event : events) {
          emit_event(gamepad, event);
        }
      }
    }

    expire_rumble(gamepad);
    Sleep(8);
  }
  expire_rumble(gamepad);
}
