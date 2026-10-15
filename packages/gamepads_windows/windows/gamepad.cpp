#include <algorithm>
#include <cmath>
#include <memory>
#include <ppl.h>
#include <vector>
#include <concrt.h>
#include <winerror.h>

#include "gamepad.h"
#include "utils.h"
#include <iomanip>
#include <sstream>

// Exported by gameinput/GameInput.cpp. It loads the newest GameInput runtime
// available: the GameInputRedist.dll bundled next to the exe, or a newer one
// installed system-wide.
STDAPI GameInputInitialize(_In_ REFIID riid, _COM_Outptr_ LPVOID* ppv);

Gamepads gamepads;

static IGameInput* g_gameInput = nullptr;

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

void Gamepads::init() {
  HRESULT hr = GameInputInitialize(IID_IGameInput,
                                   reinterpret_cast<void**>(&g_gameInput));
  if (FAILED(hr) || g_gameInput == nullptr) {
    std::cerr << "GameInput init failed: 0x" << std::hex << hr << std::dec
              << std::endl;
    g_gameInput = nullptr;
    return;
  }

  // GameInput only delivers input to the foreground app by default, which
  // makes a gamepad useless while the trainer app (Zwift, ...) has focus.
  g_gameInput->SetFocusPolicy(GameInputEnableBackgroundInput);

  // Controller also covers generic HID pads that GameInput can't map to a
  // gamepad (every gamepad is a controller too).
  g_gameInput->RegisterDeviceCallback(
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
      &this->deviceCallbackToken);
}

void Gamepads::stop() {
  if (g_gameInput) {
    g_gameInput->UnregisterCallback(this->deviceCallbackToken);
  }

  // Stop/cleanup threads
  for (auto gp : this->gamepads) {
    if (!gp->stop_thread) {
      if (gp->alive) {
        gp->stop_thread = true;
      } else {
        // Cleanup data of threads that exited due to error state.
        delete gp;
      }
    }
  }
  this->gamepads.clear();
}

std::list<GamepadData*> Gamepads::get_gamepads() {
  return this->gamepads;
}

void Gamepads::on_gamepad_connected(IGameInputDevice* device) {
  const GameInputDeviceInfo* info = nullptr;
  if (FAILED(device->GetDeviceInfo(&info)) || info == nullptr) {
    std::cerr << "Gamepad connected but failed to read info" << std::endl;
    return;
  }
  auto gp = new GamepadData();
  gp->id = AppLocalDeviceIdToString(info->deviceId);
  gp->name = info->displayName != nullptr ? info->displayName : "";
  gp->num_buttons = info->controllerButtonCount;
  gp->stop_thread = false;
  gp->alive = true;
  gp->vendor_id = static_cast<int>(info->vendorId);
  gp->product_id = static_cast<int>(info->productId);
  gp->is_gamepad = (info->supportedInput & GameInputKindGamepad) != 0;
  this->gamepads.push_back(gp);

  std::cout << "Gamepad connected: " << gp->id << " : " << gp->name
            << (gp->is_gamepad ? "" : " (generic controller)") << std::endl;

  // The reading thread outlives this callback; keep the device alive for it.
  device->AddRef();
  std::thread read_thread([this, gp, device]() {
    if (gp->is_gamepad) {
      this->read_gamepad(gp, device);
    } else {
      this->read_controller(gp, device);
    }
  });
  read_thread.detach();
}

void Gamepads::on_gamepad_disconnected(IGameInputDevice* device) {
  const GameInputDeviceInfo* info = nullptr;
  if (FAILED(device->GetDeviceInfo(&info)) || info == nullptr) {
    std::cerr << "Gamepad disconnected but failed to read info" << std::endl;
    return;
  }
  std::string removeId = AppLocalDeviceIdToString(info->deviceId);
  std::cout << "Gamepad disconnected: " << removeId << std::endl;
  GamepadData* removeGp = nullptr;
  for (auto gp : this->gamepads) {
    if (gp->id == removeId) {
      gp->stop_thread = true;
      removeGp = gp;
      break;
    }
  }
  // Remove the gamepad from list. The thread will free up memory.
  if (removeGp != nullptr) {
    this->gamepads.remove(removeGp);
  }
}

void Gamepads::read_gamepad(GamepadData* gamepad, IGameInputDevice* device) {
  GameInputGamepadState previous_state = {
      GameInputGamepadNone, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0};
  while (!gamepad->stop_thread && g_gameInput != nullptr) {
    IGameInputReading* reading = nullptr;
    if (SUCCEEDED(g_gameInput->GetCurrentReading(GameInputKindGamepad, device,
                                                 &reading))) {
      GameInputGamepadState state;
      if (reading->GetGamepadState(&state)) {
        if (are_states_different(previous_state, state)) {
          auto events = diff_states(previous_state, state);
          for (auto event : events) {
            if (event_emitter.has_value()) {
              (*event_emitter)(gamepad, event);
            }
          }
        }
        previous_state = state;
      }
      reading->Release();
    }

    Sleep(8);
  }

  on_thread_exit(gamepad, device);
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
void Gamepads::read_controller(GamepadData* gamepad,
                               IGameInputDevice* device) {
  std::vector<bool> previous_buttons;
  std::vector<float> previous_axes;
  std::vector<GameInputSwitchPosition> previous_switches;
  bool has_previous = false;

  while (!gamepad->stop_thread && g_gameInput != nullptr) {
    IGameInputReading* reading = nullptr;
    if (SUCCEEDED(g_gameInput->GetCurrentReading(GameInputKindController,
                                                 device, &reading))) {
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

        for (auto& event : events) {
          if (event_emitter.has_value()) {
            (*event_emitter)(gamepad, event);
          }
        }
      }
    }

    Sleep(8);
  }

  on_thread_exit(gamepad, device);
}

void Gamepads::on_thread_exit(GamepadData* gamepad, IGameInputDevice* device) {
  device->Release();

  if (gamepad->stop_thread) {
    std::cout << "Gamepad thread exit (via signal) " << gamepad->id
              << std::endl;
    delete gamepad;
  } else {
    std::cout << "Gamepad thread exit (due to error state) " << gamepad->id
              << std::endl;
    gamepad->alive = false;
  }
}
