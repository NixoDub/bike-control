---
workflow: general-video
flow: automation
storyboard: no
message: "Virtual shifting for any smart trainer, shifted from your handlebars"
destination: App Store product page header (creative asset, iOS 27+)
aspect: "21:9"
length: 10s seamless loop, muted
language: [en, de, es, fr, it, pl]
---

## Intent
Animated version of the still header (store_screenshots/scripts/graphics.mjs):
BikeControl brand band (blue → deep-teal 120° with terrain contours), the
localized headline still, and the app's drivetrain card shifting gears.

## Customizations
- 3840x1646, 30 fps, 10 s, loops seamlessly (Apple loops header videos, muted).
- Copy and focal art inside Apple's header template art safe area
  (x 1097–2743, y 493–1154).
- Drivetrain: the design system's DrivetrainView geometry (prop
  marketing/setup-videos/composition), shifting 12 → 13 → 14 → 13 → 12 with
  the + / − press and the landing ripple; contours drift on a closed path.
- Headline stays still so it reads at any moment.

## Notes
User picked option A (design-system drivetrain rendered in HyperFrames) over
frames from the Flutter widget. Review the finished loop before any upload.
