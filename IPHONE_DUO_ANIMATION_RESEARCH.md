# iPhone Duo Opening Animation Research

## Goal

Replicate the visual language of the iPhone Duo opening transition on the
MacBook display when the lid opens. The Mac implementation should feel driven
by the physical hinge rather than playing an unrelated full-screen effect.

## Primary sources

- [iPhone Duo product page](https://www.apple.com/iphone-duo/)
- [Leverage multiple displays and scenes on iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111464/)
- [Design for iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111466/)
- [Strike a pose with adaptive layouts on iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111463/)
- [Meet Liquid Glass](https://developer.apple.com/videos/play/wwdc2025/219/)
- [NSGlassEffectView](https://developer.apple.com/documentation/appkit/nsglasseffectview)

## Frame analysis

The Apple hero animation is 3.03 seconds long, rendered at 30 fps, with 91
frames at 1932 x 1280. Its opening section establishes these rules:

1. One half of the interface remains sharp and spatially stable.
2. The other half rotates around the physical hinge with real 3D perspective.
3. The newly exposed half begins as a thick, rounded glass plate. It samples
   and blurs color from the content beneath it instead of using a white wash.
4. Refraction and specular highlights stay attached to the plate geometry.
   There is no independent light band sweeping over the entire display.
5. Near the fully open position, the glass materializes into sharp content.
   Apple describes this as changing lensing and light bending rather than a
   conventional opacity fade.
6. Motion follows the hinge continuously. A settling animation belongs only at
   an endpoint; it must not fight the user's physical movement.

The product viewer confirms that Apple uses a real-time 3D scene rather than a
flat blur animation. Its assets include GLTF geometry, KTX textures, HDR/EXR
lighting data, separate inner and outer lock-screen textures, and a continuous
0...1 interaction value.

## Relevant Apple behavior

On iPhone Duo, SwiftUI `onHingeChange` and UIKit `UIHingeInteraction` report
closed, partially open, and fully open states plus continuous hinge-angle
updates. Apple explicitly recommends live hinge data for effects and
interactions; layout should use reserved-region and arrangement APIs instead.

Liquid Glass is a layered optical material. It combines lensing, refraction,
adaptive tint, dynamic range, shadows, and geometry-aware highlights. Apple
recommends native glass and warns against stacking glass on glass.

On macOS 26 and later, `NSGlassEffectView` is the native AppKit implementation.
It provides regular and clear glass styles, tinting, and a configurable corner
radius. It should be preferred over a hand-painted blur whenever available.

## macOS hardware boundary

macOS does not publish a supported continuous MacBook lid-angle API. MSG can
read the built-in Apple HID orientation sensor on compatible MacBooks, but this
is undocumented/private behavior. It is suitable for this personal build, not
a safe dependency for Mac App Store distribution.

macOS also prevents an ordinary app window from appearing above the Lock
Screen. When the lid opens into a locked session, MSG must capture the hinge
trajectory while hidden and replay it immediately after the session becomes
visible. When the session is already visible, the effect can follow the live
angle directly.

## MSG implementation specification

### Geometry

- Leave the right half of the desktop completely unobscured.
- Create one rounded glass plate for the left half.
- Anchor the plate to the display's vertical center seam.
- Rotate it around the Y axis from nearly edge-on to flat.
- Use perspective projection; do not fake the fold with horizontal scaling.
- Keep all highlights clipped to the glass plate.

### Materialization

- Keep the glass optically strong through most of the opening.
- Begin materialization only in the final portion of travel.
- Remove lensing and the edge highlight together.
- Do not add a second disappear animation after the hinge reaches open.

### Timing and input

- Poll the compatible lid sensor at 30 Hz.
- Render at 60 Hz and lightly smooth sensor quantization.
- Preserve the user's motion profile when replaying a locked-screen opening.
- Use a short deterministic fallback only if the sensor is unavailable.

### Accessibility and safety

- Keep the overlay click-through and non-activating.
- Restrict it to the built-in display and all Spaces.
- Cap its lifetime so a missing sensor sample can never obstruct work.
- Fall back to `NSVisualEffectView` before macOS 26.
- Respect the application's presentation-state gate.

## Acceptance criteria

- No full-screen blur, wash, or traveling light stripe.
- The fixed half stays sharp for the complete transition.
- The glass half visibly pivots from the center seam.
- A real lid opening drives the effect when the session is visible.
- A locked opening is replayed after unlock instead of completing invisibly.
- Preview and real wake use the same renderer and mapping.
- The installed Release app remains signed and launches from
  `/Applications/MSG.app/Contents/MacOS/MSG`.
