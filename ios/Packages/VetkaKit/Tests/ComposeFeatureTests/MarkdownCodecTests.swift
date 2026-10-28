import Foundation
import Testing
@testable import ComposeFeature

@Suite struct MarkdownCodecTests {
    func roundTrip(_ markdown: String) -> String {
        MarkdownCodec.markdown(from: MarkdownCodec.attributed(from: markdown))
    }

    func has(_ text: NSAttributedString, _ key: NSAttributedString.Key, on word: String) -> Bool {
        let range = (text.string as NSString).range(of: word)
        guard range.location != NSNotFound else { return false }
        var covered = true
        text.enumerateAttribute(key, in: range) { value, _, _ in if value == nil { covered = false } }
        return covered
    }

    @Test func inlineMarkupBecomesAttributesWithoutMarkers() {
        let text = MarkdownCodec.attributed(from: "очень **важно** и *тихо*, ~~было~~ `код`")
        #expect(text.string == "очень важно и тихо, было код")
        #expect(has(text, .mdBold, on: "важно"))
        #expect(has(text, .mdItalic, on: "тихо"))
        #expect(has(text, .mdStrike, on: "было"))
        #expect(has(text, .mdCode, on: "код"))
        #expect(!has(text, .mdBold, on: "очень"))
    }

    @Test func boldAndItalicNest() {
        let text = MarkdownCodec.attributed(from: "**жирный и *курсив***")
        #expect(text.string == "жирный и курсив")
        #expect(has(text, .mdBold, on: "курсив") && has(text, .mdItalic, on: "курсив"))
        #expect(!has(text, .mdItalic, on: "жирный"))
    }

    @Test func linesBecomeBlocksAndBullets() {
        let text = MarkdownCodec.attributed(from: "## Глава\n> мудрость\n- пункт\nтекст")
        #expect(text.string == "Глава\nмудрость\n• пункт\nтекст")
        #expect(text.attribute(.mdBlock, at: 0, effectiveRange: nil) as? String == "heading")
        let quote = (text.string as NSString).range(of: "мудрость").location
        #expect(text.attribute(.mdBlock, at: quote, effectiveRange: nil) as? String == "quote")
        let plain = (text.string as NSString).range(of: "текст").location
        #expect(text.attribute(.mdBlock, at: plain, effectiveRange: nil) == nil)
    }

    @Test func linksKeepTheirAddress() {
        let text = MarkdownCodec.attributed(from: "смотри [тут](https://vetka.app) ещё")
        #expect(text.string == "смотри тут ещё")
        let range = (text.string as NSString).range(of: "тут")
        #expect(text.attribute(.mdLink, at: range.location, effectiveRange: nil) as? String == "https://vetka.app")
    }

    @Test(arguments: [
        "очень **важно** и *тихо*",
        "## Глава\n> мудрость\n- первый\n- второй\nтекст",
        "смотри [тут](https://vetka.app)",
        "~~было~~ стало `x = 1`",
        "",
        "одна строка\n\nпосле пустой",
    ])
    func markdownSurvivesTheEditor(markdown: String) {
        #expect(roundTrip(markdown) == markdown)
    }

    @Test func literalMarkupCharactersAreEscapedAndComeBack() {
        let typed = NSAttributedString(string: "2*3*4 = ~24~ [не ссылка]\n# не заголовок\n- не список")
        let markdown = MarkdownCodec.markdown(from: typed)
        #expect(!markdown.contains("2*3*4"))
        let back = MarkdownCodec.attributed(from: markdown)
        #expect(back.string == typed.string)
        #expect(back.attribute(.mdItalic, at: 2, effectiveRange: nil) == nil)
        #expect(back.attribute(.mdBlock, at: (back.string as NSString).range(of: "# не").location, effectiveRange: nil) == nil)
    }

    @Test func spacesStayOutsideMarkers() {
        let text = NSMutableAttributedString(string: "очень важно ")
        text.addAttribute(.mdBold, value: true, range: NSRange(location: 5, length: 7)) // " важно "
        #expect(MarkdownCodec.markdown(from: text) == "очень **важно** ")
    }
}
