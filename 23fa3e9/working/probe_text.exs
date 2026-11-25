Logger.configure(level: :none)
Application.put_env(:at_mcp, :notifications_settle_ms, 3)
items = for i <- 0..5, do: %{uri: "at://did:plc:b/town.delve.feed.post/n#{i}", reason: "mention", indexed_at: "2026-11-20T10:00:00.00#{div(i,2)}Z", text: String.duplicate("word ", 3000), author: %{did: "did:plc:b", handle: "b.test"}, is_read: false}
fetch = fn _l, _c -> {:ok, %{items: Enum.reverse(items), cursor: nil, seen_at: "2026-11-20T09:00:00.000Z"}} end
r = AtMcp.MCP.Tools.page(fetch, %{order: "oldest", since: "last_read", limit: 6}, %{}, :notifications, "notifications")
IO.inspect(r, limit: 8, printable_limit: 600)
