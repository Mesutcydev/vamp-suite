# Arcade site redesign

Shared system: `docs/assets/arcade.css`. Monochrome charcoal and silver framing, silver chrome display type, a single illustrated marquee, and quiet rectangular content panels. Light mode uses neutral white and darker readable gray accents. The generated artwork is displayed through CSS grayscale; the source image and original product screenshots are unchanged. Body copy has no distortion; reduced motion disables transitions. Existing original app previews are unchanged.

Reusable CSS components: ArcadeFrame, ArcadeButton, ArcadeHeading, ArcadeBadge, RetroDivider, ScanlineOverlay. The generated marquee contains the perspective grid and sunset instead of duplicating these graphics across the site.

Artwork: `docs/assets/arcade/marquee-art.png`, generated with the built-in image generation tool. Original generated image retained in Codex generated_images. This asset contains no UI text; all functional lettering and actions are live accessible HTML.

Validation: screenshot inspection at desktop and 390px mobile; no horizontal overflow on home, Assistant, Sync, Stream, About, Privacy, Contact. Light/dark screenshot switching and modal opening/Escape verified. Release tests and link validation passed.

## Generation prompt

Use case: stylized-concept. Asset type: production website arcade cabinet marquee background, wide landscape 3:2. Create professional original 1983–1989 arcade-machine control-panel decal art and early computer advertising airbrush illustration. Near-black violet #160D2B base, dark navy purple #21133D; fine electric cyan #16E6F4 and hot magenta #F2258F nested rectangular framing with 45-degree corner cuts, cream #F8F0D8 highlights, warm orange #FF7657. Strong symmetrical composition. A striped magenta/orange sunset disk centered in upper middle, thin precise cyan perspective grid occupying bottom quarter, small geometric mountain silhouettes only at left and right horizon, mechanical horizontal speed rails extending inward from both edges. Keep central 65% uncluttered and dark enough for large live HTML lettering laid on top; sun behind that lettering. Highly crafted crisp screenprinted lines, subtly airbrushed sunset, restrained authentic print texture. Frame stays inside outer 3% safe margin. Flat front-on illustration, no photographic physical cabinet. No text, letters, numbers, logos, badges, watermarks, UI controls, app screenshots, people, or devices. Not modern cyberpunk, no blobs, no glossy 3D render, no purple-gradient wallpaper. This is an illustrated arcade marquee panel.
