XIAOLAIDICT — dictionary for macOS
App icon set

Entry cards stacked into a comb cell: three definition layers, the front
one in honey. One geometry across every appearance and size.


FILES

  xiaolaidict-icon.svg                     Dock icon, light appearance (default)
  xiaolaidict-icon-dark.svg                Dock icon, dark appearance
  xiaolaidict-icon-tinted.svg              Dock icon, tinted (grayscale) override
  xiaolaidict-tray-slots-Template.svg      Menu bar icon

  xiaolaidict-icon-layer-1-background.svg  Layered artwork for Icon Composer
  xiaolaidict-icon-layer-2-stack.svg
  xiaolaidict-icon-layer-3-card.svg


SPECS

  Canvas        Square, 1024 x 1024, sRGB, fully opaque to the edge.
                Transparent border pixels make Tahoe wrap the art in its
                own gray squircle and shrink it, so the ground bleeds out.

  Corner mask   Not baked in. The system clips the squircle.

  Layers        Icon Composer composes from layers, not a flat image.

  Appearances   Light and dark are authored. Icon Composer derives tinted
                from the layers; the tinted file is a manual override if
                its version drifts.

  Menu bar      Fixed 22pt working area, nothing taller — glyph is 16.4pt.
                Template image: color is discarded, only alpha is read.
                A single SVG is a valid asset; a 1x / 2x PNG pair works too.

  Legacy .icns  macOS 15 and earlier do not round or inset anything. That
                ladder needs the squircle, the ~80% inset tile and the drop
                shadow baked into the art — not included here.


BUILDING

  macOS 26      Drop the three layer SVGs into Icon Composer, export .icon.

  Older .icns   Export PNGs at 16, 32, 128, 256, 512 plus their @2x pairs
                into XiaolaiDict.iconset, then:

                  iconutil -c icns XiaolaiDict.iconset


COLOR

  Honey card    #EFAE3C -> #C6761A   (light)
                #E2A841 -> #B87418   (dark)
  Ground        #FCFCFA -> #E7E7E2   (light)
                #1D1E21 -> #0B0C0E   (dark)
  Stack         #D5D5D0 / #B9B9B2    (light)
                #2B2D32 / #3E4147    (dark)
  Entry lines   #241704 (light), #1B1105 (dark)
