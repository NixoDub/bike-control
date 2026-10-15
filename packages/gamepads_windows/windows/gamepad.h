
#include <wtypes.h>

#include <windows.h>
#include <functional>
#include <iostream>
#include <list>
#include <map>
#include <optional>
// GameInput v2 API (Microsoft.GameInput NuGet): v0 from the Windows SDK has
// no way to receive input while another app is in the foreground.
#include "gameinput/GameInput.h"
using namespace GameInput::v2;

struct GamepadData {
  std::string id;
  std::string name;
  int num_buttons;
  bool stop_thread;
  bool alive;
  int vendor_id;
  int product_id;
  // False for generic (DirectInput/HID) controllers GameInput has no gamepad
  // mapping for. They are read as raw buttons, axes and switches.
  bool is_gamepad;
};

struct Event {
  int time;
  std::string type;
  std::string key;
  double value;
};

class Gamepads {
 private:
  std::list<GamepadData*> gamepads;

  GameInputCallbackToken deviceCallbackToken = 0;
  void read_gamepad(GamepadData* gamepad, IGameInputDevice* device);
  void read_controller(GamepadData* gamepad, IGameInputDevice* device);
  void on_thread_exit(GamepadData* gamepad, IGameInputDevice* device);

  void on_gamepad_connected(IGameInputDevice* device);
  void on_gamepad_disconnected(IGameInputDevice* device);

 public:
  std::optional<std::function<void(GamepadData* gamepad, const Event& event)>>
      event_emitter;
  void init();
  void stop();
  std::list<GamepadData*> get_gamepads();
};

extern Gamepads gamepads;
