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
        #expect(byID[.claude]?.sourceDescriptor.id == "claude.code.local-usage-cache")
        #expect(byID[.claude]?.sourceDescriptor.kind == .localSession)
        #expect(byID[.claude]?.sourceDescriptor.detail.contains("Orca") == true)
        #expect(byID[.grok]?.sourceDescriptor.id == "grok.cli-proxy.credits")
        #expect(byID[.grok]?.sourceDescriptor.kind == .localSession)
        #expect(byID[.grok]?.sourceDescriptor.detail.contains("cli-chat-proxy.grok.com") == true)
        #expect(byID[.cursor]?.sourceDescriptor.id == "cursor.app-session.usage-summary")
        #expect(byID[.cursor]?.sourceDescriptor.detail.localizedCaseInsensitiveContains("read-only") == true)
        #expect(byID[.codex]?.sourceDescriptor.detail.contains("never reads") == true)
        #expect(byID[.doubao]?.sourceDescriptor.id == "volcano.arkcli.usage-plan")
        #expect(byID[.doubao]?.sourceDescriptor.kind == .officialCLI)
        #expect(byID[.doubao]?.sourceDescriptor.detail.contains("arkcli") == true)
    }
}
