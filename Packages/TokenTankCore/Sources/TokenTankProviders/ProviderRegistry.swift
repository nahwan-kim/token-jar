import ClaudeProvider
import CodexProvider
import CursorProvider
import DoubaoProvider
import GrokProvider
import TokenTankCore

public enum TokenTankProviderRegistry {
    /// Returns the five reviewed v1 sources in the fixed Provider order.
    public static func defaultAdapters() -> [any ProviderAdapter] {
        [
            CodexAdapter(),
            ClaudeAdapter(),
            GrokAdapter(),
            CursorAdapter(),
            DoubaoAdapter(),
        ]
    }
}
