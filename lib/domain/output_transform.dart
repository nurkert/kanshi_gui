/// Rotation lives in two conventions, and they disagree.
///
/// Sway's own `output <name> transform <t>` command — and the value
/// `swaymsg -t get_outputs` reports back — call one thing `90`. The
/// wlr-output-management protocol, which is what kanshi and `wlr-randr`
/// speak, calls the *same physical orientation* `270`. Measured on sway
/// 1.12 with one portrait panel:
///
/// ```text
/// swaymsg output HDMI-A-2 transform 270   ->  get_outputs says 270
/// wlr-randr --output HDMI-A-2 -t 270      ->  get_outputs says  90
/// kanshi config `transform 270`           ->  get_outputs says  90
/// ```
///
/// `normal` and `180` are unaffected — they are their own inverse — so the
/// whole disagreement is a swap of 90 and 270.
///
/// This app stores rotation in the **wlr-output-management** sense. That is
/// not an arbitrary pick: a kanshi config file's `transform` keyword is
/// defined by kanshi, so a file the user wrote by hand has to be read the way
/// kanshi will execute it. Everything that speaks the protocol — the config
/// writer, the config parser, the `wlr-randr` backend — therefore passes the
/// number through untouched, and the *sway* backend is the one place that
/// converts.
///
/// Getting this wrong is invisible in the GUI and only shows up after a
/// reboot: the app applied the live preview through swaymsg (right way up),
/// then wrote the same number into the config, where kanshi read it as the
/// other portrait orientation and stood the screen on its head.
library;

/// The value to hand sway's `output … transform` command for a monitor whose
/// stored [rotation] is in the wlr-output-management sense.
String swayTransformFor(int rotation) => switch (rotation % 360) {
      90 => '270',
      180 => '180',
      270 => '90',
      _ => 'normal',
    };

/// The stored rotation for a `transform` value sway reported over IPC.
///
/// `flipped-*` gets the same swap as its plain counterpart. The app has no
/// way to express a flip and drops it here, so only the rotation component
/// survives — approximate by construction, and unreachable from the GUI.
int rotationFromSwayTransform(String transform) => switch (transform) {
      '90' || 'flipped-90' => 270,
      '180' || 'flipped-180' => 180,
      '270' || 'flipped-270' => 90,
      _ => 0,
    };
