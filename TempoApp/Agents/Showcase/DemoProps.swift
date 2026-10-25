import Foundation
import CoreGraphics
import CoreText
import ImageIO
#if canImport(UIKit)
import UIKit
#endif

// Props for present mode, made in code (no asset files): a council-tax reminder letter for the Letter reader and
// an HMRC "refund" text for Scam Shield. Everything in them is made up for the demo: the resident, the account
// numbers, and the phone numbers (01632 960xxx and 07700 900xxx are Ofcom's ranges reserved for drama). The letter
// carries a small "specimen" mark so a photo of the screen can never pass for a real bill.

/// Something the overlay can show while a step runs.
enum ShowProp: String, Sendable, Equatable, CaseIterable {
    case letter
    case scamText

    /// The photo Kairos is given, for props that are pictures.
    var jpeg: Data? { self == .letter ? DemoProps.letterJPEG : nil }
    /// The words the overlay shows, for props that are text.
    var text: String? { self == .scamText ? DemoProps.scamText : nil }
    var title: String { self == .letter ? "Council-tax letter" : "Text message from “HMRC”" }
}

enum DemoProps {
    // MARK: Facts the script relies on

    static let letterAmount = "£142.50"
    static let letterDue = "8 November 2026"
    /// The Letter reader offers a reminder the day before the deadline, at 10:00.
    static func reminderDueISO(calendar: Calendar = .current) -> String {
        var c = DateComponents()
        c.year = 2026; c.month = 11; c.day = 7; c.hour = 10; c.minute = 0
        let date = calendar.date(from: c) ?? Date()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
        return f.string(from: date)
    }

    static let photoCaption = "Hello from the judges' table — sent by Kairos"

    // MARK: The scam text

    static let scamSender = "HMRC-INFO"
    /// A typical HMRC refund smishing text: a refund, a deadline, "verify your bank details", a look-alike link.
    static let scamText = "HMRC: You are due a tax refund of £326.40 for the 2025/26 tax year. Your refund will be cancelled if not claimed within 24 hours. Verify your bank details now to receive it: https://hmrc-taxrefund-claim.uk-secure.net/refund"

    // MARK: The letter

    /// A4 at 150 dpi.
    static let letterSize = CGSize(width: 1240, height: 1754)

    /// The letter as a JPEG, made once on first use (~0.1 s).
    static let letterJPEG: Data = renderLetterJPEG()

    #if canImport(UIKit)
    static var letterImage: UIImage? { UIImage(data: letterJPEG) }
    #endif

    static func renderLetterJPEG(quality: CGFloat = 0.82) -> Data {
        #if canImport(UIKit)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: letterSize, format: format)
        return renderer.jpegData(withCompressionQuality: quality) { context in
            drawLetter(in: context.cgContext, size: letterSize)
        }
        #else
        guard let ctx = CGContext(data: nil, width: Int(letterSize.width), height: Int(letterSize.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return Data() }
        // Same top-left origin as UIKit.
        ctx.translateBy(x: 0, y: letterSize.height)
        ctx.scaleBy(x: 1, y: -1)
        drawLetter(in: ctx, size: letterSize)
        guard let image = ctx.makeImage() else { return Data() }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, "public.jpeg" as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return out as Data
        #endif
    }

    /// Draws the letter into a context whose origin is the top left (UIKit's), `size` points.
    static func drawLetter(in ctx: CGContext, size: CGSize) {
        let ink = LetterInk(ctx)
        let w = size.width
        let left: CGFloat = 104, right = w - 104
        let navy = LetterInk.rgb(0.07, 0.20, 0.36)
        let teal = LetterInk.rgb(0.00, 0.43, 0.45)
        let body = LetterInk.rgb(0.10, 0.10, 0.11)
        let grey = LetterInk.rgb(0.38, 0.39, 0.41)
        let pale = LetterInk.rgb(0.94, 0.95, 0.96)

        // Paper.
        ctx.setFillColor(LetterInk.rgb(1, 1, 1))
        ctx.fill(CGRect(origin: .zero, size: size))

        // Emblem and name (a generic emblem: a shield with a river, not the council's real crest).
        let shield = CGRect(x: left, y: 92, width: 88, height: 100)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: shield.minX, y: shield.minY))
        path.addLine(to: CGPoint(x: shield.maxX, y: shield.minY))
        path.addLine(to: CGPoint(x: shield.maxX, y: shield.minY + 58))
        path.addQuadCurve(to: CGPoint(x: shield.midX, y: shield.maxY), control: CGPoint(x: shield.maxX, y: shield.maxY - 14))
        path.addQuadCurve(to: CGPoint(x: shield.minX, y: shield.minY + 58), control: CGPoint(x: shield.minX, y: shield.maxY - 14))
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setFillColor(navy)
        ctx.fillPath()
        ctx.setStrokeColor(LetterInk.rgb(1, 1, 1))
        ctx.setLineWidth(5)
        for i in 0..<3 {
            let y = shield.minY + 34 + CGFloat(i) * 17
            let wave = CGMutablePath()
            wave.move(to: CGPoint(x: shield.minX + 16, y: y))
            wave.addCurve(to: CGPoint(x: shield.maxX - 16, y: y), control1: CGPoint(x: shield.midX - 8, y: y - 10),
                          control2: CGPoint(x: shield.midX + 8, y: y + 10))
            ctx.addPath(wave)
        }
        ctx.strokePath()
        ink.text("Oxford City Council", x: left + 112, y: 98, width: 520, font: ink.font("Helvetica-Bold", 44), color: navy)
        ink.text("Council Tax Services", x: left + 114, y: 152, width: 520, font: ink.font("Helvetica", 26), color: teal)

        // Return address, right-aligned.
        let infoFont = ink.font("Helvetica", 19)
        var y: CGFloat = 96
        for line in ["Town Hall, St Aldate's", "Oxford OX1 1BX", "Telephone 01632 960 123", "www.oxford.gov.uk/counciltax"] {
            y += ink.text(line, x: right - 420, y: y, width: 420, font: infoFont, color: grey, alignRight: true) + 2
        }

        ctx.setFillColor(navy)
        ctx.fill(CGRect(x: left, y: 232, width: right - left, height: 4))

        // The resident (made up).
        let addressFont = ink.font("Helvetica", 24)
        y = 296
        for line in ["Mrs M Ellis", "14 Juniper Close", "Headington", "Oxford", "OX3 9ZZ"] {
            y += ink.text(line, x: left, y: y, width: 520, font: addressFont, color: body) + 3
        }

        // Reference box.
        let box = CGRect(x: right - 430, y: 284, width: 430, height: 196)
        ctx.setFillColor(pale)
        ctx.fill(box)
        let labelFont = ink.font("Helvetica", 18), valueFont = ink.font("Helvetica-Bold", 19)
        y = box.minY + 18
        for (label, value) in [("Date", "18 October 2026"), ("Account reference", "4471 0098 2"),
                               ("Property reference", "00110452"), ("Council Tax band", "C"), ("Paying by", "10 instalments")] {
            ink.text(label, x: box.minX + 20, y: y, width: 200, font: labelFont, color: grey)
            y += ink.text(value, x: box.minX + 200, y: y, width: 210, font: valueFont, color: body, alignRight: true) + 12
        }

        // Title.
        y = 540
        y += ink.text("COUNCIL TAX REMINDER NOTICE", x: left, y: y, width: right - left, font: ink.font("Helvetica-Bold", 36), color: navy) + 6
        y += ink.text("Financial year 1 April 2026 to 31 March 2027", x: left, y: y, width: right - left, font: ink.font("Helvetica", 21), color: grey) + 28

        let bodyFont = ink.font("Helvetica", 23), bold = ink.font("Helvetica-Bold", 23)
        y += ink.text("Dear Mrs Ellis,", x: left, y: y, width: right - left, font: bodyFont, color: body) + 18
        y += ink.text("Our records show that the instalment due on 1 October 2026 has not been paid. Please pay the amount below by \(letterDue).",
                      x: left, y: y, width: right - left, font: bodyFont, color: body, lineGap: 7) + 26

        // Amount table.
        let rows: [(String, String)] = [("Instalment due 1 October 2026", letterAmount), ("Amount received", "£0.00")]
        let table = CGRect(x: left, y: y, width: right - left, height: 56 * 3)
        ctx.setStrokeColor(LetterInk.rgb(0.78, 0.80, 0.83))
        ctx.setLineWidth(2)
        ctx.stroke(table)
        var rowY = y
        for (label, value) in rows {
            ink.text(label, x: left + 22, y: rowY + 15, width: 600, font: bodyFont, color: body)
            ink.text(value, x: right - 322, y: rowY + 15, width: 300, font: bodyFont, color: body, alignRight: true)
            rowY += 56
            ctx.fill(CGRect(x: left, y: rowY - 1, width: right - left, height: 2))
        }
        ctx.setFillColor(navy)
        ctx.fill(CGRect(x: left, y: rowY, width: right - left, height: 56))
        ink.text("Amount to pay by \(letterDue)", x: left + 22, y: rowY + 14, width: 640, font: bold, color: LetterInk.rgb(1, 1, 1))
        ink.text(letterAmount, x: right - 322, y: rowY + 14, width: 300, font: bold, color: LetterInk.rgb(1, 1, 1), alignRight: true)
        y = table.maxY + 30

        y += ink.text("If you pay this amount by \(letterDue), you can keep paying by instalments as shown on your bill. If it is not paid, you will lose the right to pay by instalments and the rest of the year's charge will become due in one payment. We may then apply to the magistrates' court for a liability order, which adds costs to your account.",
                      x: left, y: y, width: right - left, font: bodyFont, color: body, lineGap: 7) + 24

        y += ink.text("How to pay", x: left, y: y, width: right - left, font: ink.font("Helvetica-Bold", 25), color: navy) + 10
        let bullets = ["Online at www.oxford.gov.uk/counciltax, with your account reference to hand.",
                       "By phone, any time, on our automated line 01632 960 124.",
                       "By Direct Debit, so you never miss a payment. Call us or sign up online."]
        for b in bullets {
            ink.text("•", x: left + 6, y: y, width: 20, font: bodyFont, color: teal)
            y += ink.text(b, x: left + 34, y: y, width: right - left - 34, font: bodyFont, color: body, lineGap: 6) + 10
        }
        y += 14
        y += ink.text("Already paid? Thank you, and please ignore this notice. Finding it hard to pay? Please contact us as soon as you can. We can help, and you may be entitled to a reduction.",
                      x: left, y: y, width: right - left, font: bodyFont, color: body, lineGap: 7) + 26
        y += ink.text("Yours sincerely,", x: left, y: y, width: 500, font: bodyFont, color: body) + 8
        y += ink.text("Revenues Manager, Council Tax Services", x: left, y: y, width: 700, font: bold, color: body) + 8

        // Tear-off payment slip.
        let slipTop = max(y + 36, size.height - 196)
        ctx.setStrokeColor(LetterInk.rgb(0.55, 0.56, 0.58))
        ctx.setLineWidth(2)
        ctx.setLineDash(phase: 0, lengths: [12, 9])
        ctx.move(to: CGPoint(x: left, y: slipTop))
        ctx.addLine(to: CGPoint(x: right, y: slipTop))
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        ink.text("✂", x: left - 40, y: slipTop - 16, width: 30, font: ink.font("Helvetica", 24), color: grey)
        let slipFont = ink.font("Helvetica", 19), slipBold = ink.font("Helvetica-Bold", 20)
        var sy = slipTop + 22
        ink.text("PAYMENT SLIP — Council Tax", x: left, y: sy, width: 600, font: slipBold, color: navy)
        ink.text("Amount due: \(letterAmount)", x: right - 420, y: sy, width: 420, font: slipBold, color: body, alignRight: true)
        sy += 34
        ink.text("Account reference: 4471 0098 2   ·   Mrs M Ellis, 14 Juniper Close, Oxford OX3 9ZZ",
                 x: left, y: sy, width: right - left, font: slipFont, color: body)
        sy += 30
        ink.text("Pay by \(letterDue)", x: left, y: sy, width: 600, font: slipFont, color: body)
        ink.text("Specimen letter for demonstration · OxHack 2026", x: right - 520, y: size.height - 52, width: 520,
                 font: ink.font("Helvetica", 15), color: LetterInk.rgb(0.62, 0.63, 0.65), alignRight: true)
    }
}

/// Text drawing with Core Text into a top-left-origin context (works the same on iOS and on the Mac).
struct LetterInk {
    let ctx: CGContext
    init(_ ctx: CGContext) { self.ctx = ctx }

    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
        CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [r, g, b, 1]) ?? CGColor(gray: 0, alpha: 1)
    }

    func font(_ name: String, _ size: CGFloat) -> CTFont { CTFontCreateWithName(name as CFString, size, nil) }

    /// Wraps `text` to `width`, draws it with its top at `y`, and returns the height used.
    @discardableResult
    func text(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, font: CTFont, color: CGColor,
              alignRight: Bool = false, lineGap: CGFloat = 2) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let setter = CTTypesetterCreateWithAttributedString(string)
        let length = string.length
        var start = 0
        var top = y
        while start < length {
            let count = CTTypesetterSuggestLineBreak(setter, start, Double(width))
            guard count > 0 else { break }
            let line = CTTypesetterCreateLine(setter, CFRange(location: start, length: count))
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
                - CGFloat(CTLineGetTrailingWhitespaceWidth(line))
            let dx = alignRight ? max(0, width - lineWidth) : 0
            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.translateBy(x: x + dx, y: top + ascent)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textPosition = .zero
            CTLineDraw(line, ctx)
            ctx.restoreGState()
            top += ascent + descent + lineGap
            start += count
        }
        return top - y - lineGap
    }
}
