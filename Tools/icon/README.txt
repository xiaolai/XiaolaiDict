XIAOLAIDICT — dictionary for macOS
App icon set

A D with a sparkle in it: the dictionary's initial, and the mark of
something that reads for you. One geometry across every appearance and size.


FILES

  layer1-background-light.svg   Ground, light appearance
  layer1-background-dark.svg    Ground, dark appearance

  layer2-contour-light.svg      The D, stroke 8
  layer2-contour-dark.svg
  layer2-contour-mono.svg

  layer3-sparkle-light.svg      The sparkle, filled
  layer3-sparkle-dark.svg
  layer3-sparkle-mono.svg

  menubarTemplate.svg           Menu bar icon

Every file is one layer in one appearance. A layer's appearances differ in
colour and in nothing else; Tools/make-icon.py holds them against each other
and refuses a run where one has drifted.


SPECS

  Canvas        Square, 1024 x 1024 on a 100-unit viewBox, fully opaque to
                the edge. Transparent border pixels make Tahoe wrap the art
                in its own grey squircle and shrink it, so the ground bleeds
                out.

  Corner mask   Not baked in. The system clips the squircle.

  Mark          66% of the canvas, centred. The squircle and the inset eat
                the old 52%-of-a-square framing.

  Layers        Icon Composer composes from layers, not a flat image. The
                ground is not one of them: it is the document's own fill, so
                the system can draw its own ground in the tinted and clear
                appearances, where an opaque plate would cover what those
                appearances exist to show.

  Appearances   Light and dark are authored. Tinted and clear share one
                override, and the generator sets it to white on the mark
                layers. Left to derive one, the system draws the mark at a
                WCAG contrast of 1.13:1 against its own ground in TintedDark
                and 1.47:1 in ClearLight — which is not a faint mark, it is
                no mark. White takes those to 2.33 and 3.92, and TintedLight
                from 1.57 to 5.09 (measured 2026-09-22).

                White is not a colour choice: the value is read as a
                luminance and its hue is thrown away — a garish green tinted
                fill renders pale lavender — so white is simply the top of
                the one scale the system reads.

                The override goes on the layers and never on the document
                fill, where it is ignored: the system replaces the ground
                outright in those appearances.

                The -mono files supply no colour, and black would be the
                worst possible tinted value. They are read for their
                geometry, and a mono file that has drifted from its light
                and dark siblings stops the run.

  Strokes       The contour is stroked; the sparkle is filled. A mark may be
                either, and fill="none" is what says which — a path carrying
                both a fill and a stroke is refused, because icon.json gives
                a layer one colour and a shape painted twice cannot be
                reproduced.

                The contour being stroked is a live risk on the oldest OS
                this app supports. Under Icon Composer's generation-26
                renderer a stroked layer draws as a solid filled blob,
                because the stroke on a fill="none" path is ignored;
                generation 27 draws it correctly, as does the compiled
                bundle on macOS 27. No macOS 26 machine was available to
                settle which reading is right, and shipping the SVG anyway
                is a decision on record (AGENTS.md). The sparkle, being
                filled, is not exposed to it; re-drawing the contour as a
                filled outline would close the question entirely.

  Flat          No glass, no specular bevel, no shadow, no translucency. The
                platform's default treatment puts a fixed-width bevel on
                every layer, and on a mark that is nothing but an 8-unit and
                a 4-unit stroke that bevel is most of the stroke: it reads as
                chrome piping rather than as ink. The switches are set in
                icon.json by the generator and asserted by its tests.

  Sparkle       An eight-sided star: four tips, and between each adjacent
                pair a straight edge meeting at an inner vertex on the
                diagonal. That inner radius IS the belly — the distance from
                the crossing point to the narrowest part of the outline — so
                it is set directly rather than fallen into. Belly 3.

                It is drawn, not borrowed. SF Symbols may not be used in an
                app icon, nor may a glyph substantially similar to one, and
                sparkle is a filled symbol whose weight axis barely moves it
                in any case.

                Two constructions were tried first and both failed in ways
                worth not repeating:

                  One cubic per quadrant, controls at radius w on each tip's
                  own axis, puts the edge midpoint at sqrt2 x (0.125R +
                  0.375w). The 0.125R term is the tip's own contribution, so
                  with 32-unit arms the belly cannot go below 5.66 whatever w
                  is. The family has a floor; the parameter was never the
                  problem.

                  Any single curve spanning two tips draws LENSES, not arms.
                  It has to travel in to the waist and back out, which puts
                  each arm's widest point in the middle of the arm. A
                  sparkle's arm is widest at its base, so the outline is
                  built per edge segment — tip to waist, waist to tip.

  Asymmetry     The sparkle's arms meet at x = 57, not at the centre: up 32,
                down 32, left 39, right 25. It is where the window cross that
                preceded it crossed, and it squares up the left of the D and
                lands where the bowl begins.

  Menu bar      Fixed 22pt working area, nothing taller. Template image:
                colour is discarded, only alpha is read.

                One path: the D solid, with the sparkle cut out of it as an
                even-odd hole. Not the app icon's own drawing, because at
                22pt an 8-unit stroke is under 2px and the sparkle's arms
                are under one — it renders as a grey smear inside a thin
                ring. At this size mass survives and lines do not, which is
                the same reason the glyph before it was solid blocks rather
                than an outlined D.

                The star's arms stop short of the D's edge (up 27, down 27,
                left 33, right 20, belly 5) so the silhouette stays whole;
                run out to the full 18..82 they notch its outline.

                It costs crispness and that is the trade: 21.7% of the glyph
                is antialiased edge at 22pt against the old one's 14.1%. The
                old one was crisper and depicted a mark that no longer
                exists.

                No <mask>. CoreSVG — what NSImage loads this through —
                rasterises a mask at 1x and scales it up, and an earlier
                glyph blurred on every Retina menu bar because of it. The
                generator refuses one. The even-odd hole is not a mask and
                was measured through CoreSVG to confirm it: the star's
                centre reads alpha 0, the D's stem 255, and the whole glyph
                is within 17 of 255 of a reference renderer at 2x, against
                233 for the mask it replaced.

  Legacy .icns  Not included, and not wanted: the app is macOS 26 and later,
                so there is no ladder that needs the squircle, the inset
                tile and the drop shadow baked into the art.


BUILDING

  make icon     Regenerates Resources/XiaolaiDict.icon and
                Resources/MenuBarIcon.svg from this directory.

  Every length, every path and every colour below is read from these files;
  nothing is retyped in the generator. A layer asset is this art with its
  paint set to white, byte for byte otherwise, and the colour lives in
  icon.json per appearance.


COLOR

  Ground        #FBFAF6 (light)
                #1B2A4A (dark)
  Mark          #23407A (light)
                #EDF1F7 (dark)
