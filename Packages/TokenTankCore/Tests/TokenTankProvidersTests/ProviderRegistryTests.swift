import Testing
import TokenTankDomain
@testable import TokenTankProviders

@Suite("Provider source composition")
struct ProviderRegistryTests {
    @Test("default composition enables all five reviewed sources in fixed order")
    func reviewedDefault() {
        let adapters = TokenTankProviderRegistry.defaultAdapters()
        #expect(adapters.map(\.id) == ProviderID.allCases)
        #expect(Set(adapters.map(\.sourceDescriptor.id)).count == ProviderID.allCases.count)
        #expect(adapters.allSatisfy { !$0.sourceDescriptor.detail.isEmpty })
    }

    @Test("narrower and undocumented source semantics remain explicit")
    func sourceSemanticsAreExplicit() {
        let byID = Dictionary(uniqueKeysWithValues: TokenTankProviderRegistry.defaultAdapters().map { ($0.id, $0) })
        #expect(byID[.claude]?.sourceDescriptor.detail.contains("organization") == true)
        #expect(byID[.claude]?.sourceDescriptor.detail.contains("consumer subscription quota") == true)
        #expect(byID[.grok]?.sourceDescriptor.id == "xai.management-api.prepaid-balance")
        #expect(byID[.grok]?.sourceDescriptor.detail.contains("developer") == true)
        #expect(byID[.grok]?.sourceDescriptor.detail.contains("consumer") == true)
        #expect(byID[.cursor]?.sourceDescriptor.id == "cursor.app-session.usage-summary")
        #expect(byID[.cursor]?.sourceDescriptor.detail.localizedCaseInsensitiveContains("read-only") == true)
        #expect(byID[.codex]?.sourceDescriptor.detail.contains("never reads") == true)
    }
}
