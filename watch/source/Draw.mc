import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.System;

//! Drawing helpers. The arrow is a polygon because system fonts on these
//! devices have no "→" glyph (shows as a box in the simulator).
(:glance)
module Draw {

    //! Right-pointing filled triangle, centered vertically on y, starting at x.
    function arrow(dc as Dc, x as Number, y as Number, size as Number) as Void {
        var half = size / 2;
        dc.fillPolygon([[x, y - half], [x + size, y], [x, y + half]]);
    }

    function arrowSize(dc as Dc, font as FontType) as Number {
        return dc.getFontHeight(font) / 3;
    }

    //! "▸ text" centered on cx; the arrow takes the current color.
    function arrowTextCentered(dc as Dc, cx as Number, y as Number, font as FontType, text as String) as Void {
        var size = arrowSize(dc, font);
        var gap = size / 2 + 2;
        var width = size + gap + dc.getTextWidthInPixels(text, font);
        var x = cx - width / 2;
        arrow(dc, x, y, size);
        dc.drawText(x + size + gap, y, font, text, Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    //! Width usable at height y: the chord of a round screen, less `margin`
    //! on each side, so text near the top and bottom is not cut by the bezel.
    function chord(dc as Dc, y as Number, margin as Number) as Number {
        var w = dc.getWidth();
        if (System.getDeviceSettings().screenShape != System.SCREEN_SHAPE_ROUND) {
            return w - 2 * margin;
        }
        var r = w / 2;
        var d = y - dc.getHeight() / 2;
        if (d * d >= r * r) {
            return 0;
        }
        return (Math.sqrt(r * r - d * d) * 2).toNumber() - 2 * margin;
    }

    //! The first text that fits `width` in the first font that allows it
    //! (a bigger font with a shorter text reads better than a tiny full one);
    //! else the last text cut with "…" in the last font.
    function fit(dc as Dc, texts as Array<String>, fonts as Array<FontType>, width as Number) as [String, FontType] {
        for (var f = 0; f < fonts.size(); f++) {
            for (var t = 0; t < texts.size(); t++) {
                if (dc.getTextWidthInPixels(texts[t], fonts[f]) <= width) {
                    return [texts[t], fonts[f]];
                }
            }
        }
        var font = fonts[fonts.size() - 1];
        var text = texts[texts.size() - 1];
        while (text.length() > 1 && dc.getTextWidthInPixels(text + "…", font) > width) {
            text = text.substring(0, text.length() - 1) as String;
        }
        return [text + "…", font];
    }

    //! Pieces of text in their own colors on one line, as [text, color, ...]:
    //! centered on x, or starting at x with `centered` false.
    function pieces(dc as Dc, x as Number, y as Number, font as FontType, parts as Array, centered as Boolean) as Void {
        if (centered) {
            x -= piecesWidth(dc, font, parts) / 2;
        }
        for (var i = 0; i < parts.size(); i += 2) {
            dc.setColor(parts[i + 1] as ColorType, Graphics.COLOR_TRANSPARENT);
            dc.drawText(x, y, font, parts[i] as String, Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
            x += dc.getTextWidthInPixels(parts[i] as String, font);
        }
    }

    function piecesWidth(dc as Dc, font as FontType, parts as Array) as Number {
        var width = 0;
        for (var i = 0; i < parts.size(); i += 2) {
            width += dc.getTextWidthInPixels(parts[i] as String, font);
        }
        return width;
    }
}
